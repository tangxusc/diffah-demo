# diffah 增量发布 demo

验证一件事：镜像里只改了一个 jar，升级时不必重传整个镜像。

> 想知道有没有更好的工具、以及各方案的实测传输量对比，见 [`ALTERNATIVES.md`](ALTERNATIVES.md)。

- 基线 `A:v1`
- 目标 `A:v1.0.1`，与 `A:v1` 只差 `/app/app.jar` 里的 64 字节
- 镜像约 210 MiB，其中 200 MiB 的依赖层完全没变

## 跑一遍

```sh
brew install zstd
brew tap leosocy/tap && brew install diffah
# brew 拒绝加载第三方 tap 时：brew trust leosocy/tap
# 或者直接下预编译二进制：https://github.com/leosocy/diffah/releases

./run-demo.sh            # 完整流程 + 自动校验
KEEP=1 ./run-demo.sh     # 保留 work/ 下的中间产物
```

脚本会生成 200 MiB 素材，确保磁盘有空间。全程约 15 秒。

## 实测结果

| 项目 | 大小 |
|---|---|
| `docker save a:v1.0.1` 全量包 | 220,754,432 字节（210.5 MiB） |
| `diffah diff` 增量包 | 8,704 字节（8.5 KiB） |
| 缩减比例 | 0.0039%，约 **25,000 倍** |

增量包里的三个 blob：

| 层 | 目标大小 | 增量包内占用 | 编码方式 |
|---|---|---|---|
| alpine rootfs | 8.5 MiB | 0 | `baseline_only` — 消费者本地已有 |
| 依赖层 `deps.bin` | 200.0 MiB | 0 | `baseline_only` — 消费者本地已有 |
| 应用层 `app.jar` | 2.0 MiB | **801 字节** | `patch` — 对基线层做层内差分 |

脚本自动断言，全部通过：

- 重建镜像 ID 与原始一致（`sha256:11ed61c4…`）
- 前两个公共层 digest 与 `A:v1` 一致
- 容器内 `/app/app.jar` 的 sha256 与目标版本逐字节相同

## 命令速查

生产端，两个镜像都在本地：

```sh
diffah diff --platform linux/arm64 \
  docker-archive:./a-v1.tar \
  docker-archive:./a-v1.0.1.tar \
  ./a-v1-to-v1.0.1.delta.tar
```

消费端，本地已有基线镜像：

```sh
diffah apply ./a-v1-to-v1.0.1.delta.tar \
  docker-archive:./a-v1.tar \
  docker-archive:./restored.tar

docker load -i ./restored.tar
docker tag <image-id> a:v1.0.1        # 见「注意事项」
```

`diffah` 也直接认 registry 引用，可以完全绕开 `docker save`：

```sh
# 生产端：从 registry 读两个 tag，算出 delta
diffah diff docker://harbor/app:v1 docker://harbor/app:v1.0.1 ./app.delta.tar

# 消费端：本地 registry 已有 v1，直接把 v1.0.1 推上去
diffah apply ./app.delta.tar docker://harbor/app:v1 docker://harbor/app:v1.0.1
```

基线是 registry 引用时，apply 只拉取 patch 实际引用到的 blob，不会整包下载。

## 注意事项

**必须显式指定 `--platform`。** 默认值是 `linux/amd64`。arm64 Mac 上构建出的是 `linux/arm64`，不指定会报找不到镜像。

**`docker load` 之后要补 tag。** `diffah apply` 产出的 docker-archive 里，`manifest.json` 的 `RepoTags` 是空数组、`repositories` 是 `{}`，所以 `docker load` 只按 image ID 载入，不会创建 `a:v1.0.1`。镜像内容本身没问题——ID 和层 digest 都对得上。

**基线必须逐字节固定。** diffah 靠 layer digest 判断哪层没变。基线 tag 被覆盖、或用浮动 tag，就算不出公共层，delta 退化成全量。基线要用不可变 tag 或 digest 引用。

**两边都要有 zstd。** `--intra-layer` 打开时，产出的 delta 需要 zstd 才能 apply。`diffah inspect` 会显示 `intra-layer patches required: yes`。消费端没有 zstd 就用 `--intra-layer off`，代价是变化的层整层传——本例从 801 字节变成 2.0 MiB。

**delta 不是字节级可复现的。** 同一对镜像、同一组参数重跑两次，`diffah.json` 里的 `created_at` 会不同，包整体 sha256 因此不同。但除该时间戳外所有内容一致——patch blob 是确定性的。所以不要拿 delta 包的 sha256 做校验和比对，要校验就用 `diffah inspect` 里的 manifest digest。

### 参数与内存

`--zstd-level` 默认 22（ultra）。层内差分要对 top-K 个基线层各试一次 `zstd --patch-from`，候选里出现大层时，level 22 又慢又吃内存。本机（16 GiB）实测：

| 参数 | 耗时 | 峰值内存 | delta |
|---|---|---|---|
| `--workers 4 --zstd-level 22 --zstd-window-log 27` | — | 超限被杀 | — |
| `--workers 1 --zstd-level 22 --zstd-window-log 27` | 慢 | 1,687 MiB | 8,704 B |
| `--workers 8 --zstd-level 12 --zstd-window-log 27` | 2.0 s | 573 MiB | 8,704 B |
| `--workers 4 --zstd-level 12 --zstd-window-log 27 --candidates 2` | 0.4 s | ~570 MiB | 8,704 B |
| `--workers 4 --zstd-level 12 --zstd-window-log 27 --candidates 1` | 0.3 s | ~490 MiB | 8,704 B |
| `--workers 4 --zstd-level 3 --zstd-window-log 27` | 0.6 s | 555 MiB | 10,752 B |

level 22 比 level 12 多花 3 倍内存，delta 一个字节都没小。**不要用默认的 level 22。** 脚本默认用倒数第三行那组。

`--candidates 2` 相比默认的 3 快 5 倍、体积不变——那个 200 MiB 的依赖层跟 jar 层毫无共同 tar 条目，却被当候选试了一遍，纯属浪费。基线层多、层间相似度不确定时再往上调。

**适用边界。** diffah 只做单镜像的层间复用和层内差分。它不替代 `skopeo`：首次投递（消费者手里还没有基线镜像）仍然要传一个完整镜像，之后的每次升级才走 delta。

## 文件

| 文件 | 作用 |
|---|---|
| `make_assets.py` | 生成确定性素材：200 MiB 依赖层 + 两个只差 64 字节的 jar |
| `Dockerfile` | 三层镜像：alpine → 依赖层 → 应用层 |
| `run-demo.sh` | 完整流程，含自动校验 |
