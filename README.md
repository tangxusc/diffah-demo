# diffah-demo

验证一件事：**镜像里只改了一个 jar，升级时不必重传整个镜像。**

这个仓库用可复现的 demo 量化了几种增量分发方案的实际传输量，并逐字节校验重建结果。

## 结论

同一个场景：镜像约 210 MiB，三层，只有 2 MiB 的应用层改了一处（64 字节）。

| 方案 | 传输量 | 占全量 | 前提 |
|---|---:|---:|---|
| `docker save` 全量 | 220,754,432 B（210.5 MiB） | 100% | 无 |
| registry push | 2,062,935 B（1.97 MiB） | 0.93% | 目标侧有 registry |
| desync（内容定义分块） | 319,134 B（311.7 KiB） | 0.1446% | 两端有 desync + chunk store |
| diffah（层内 patch） | 8,704 B（8.5 KiB） | 0.0039% | 两端有 diffah + zstd |

三个数字都是实测，不是估算。完整对比、工具全景和选型建议见 [`demo/ALTERNATIVES.md`](demo/ALTERNATIVES.md)。

## 先回答一个问题

**目标侧能不能跑一个 registry？**

能 → 别用任何增量工具。OCI registry 天然按 blob digest 去重，`docker push` 只上传目标端没有的 blob。实测第二次推送的输出：

```
b0e0d4416750: Layer already exists    # 200 MiB 依赖层，跳过
1b349a333453: Layer already exists    # 8.5 MiB alpine 层，跳过
2c33eb1375cd: Pushed                  # 2 MiB 应用层，实际传输
```

只有 1.97 MiB 过网，零额外工具。

不能（真隔离网、只靠 U 盘或单向光闸搬文件）→ 再看 diffah / desync / zarf / hauler。

## 跑一遍

```sh
brew install zstd
brew tap leosocy/tap && brew install diffah
# brew 拒绝加载第三方 tap 时：brew trust leosocy/tap
# 或从 https://github.com/leosocy/diffah/releases 下预编译二进制

git clone https://github.com/tangxusc/diffah-demo.git
cd diffah-demo/demo
./run-demo.sh
```

脚本会生成 200 MiB 素材，确保磁盘有空间。全程约 15 秒。

它做完这些事并自动断言：

1. 生成确定性素材（200 MiB 依赖层 + 两个只差 64 字节的 jar）
2. 构建 `A:v1` / `A:v1.0.1`，确认公共层 digest 相同
3. `docker save` 两个全量包
4. `diffah diff` 生成增量 delta
5. `diffah apply` 用 `A:v1` + delta 重建 `A:v1.0.1`
6. `docker load` 重建结果，校验镜像 ID、层 digest、容器内 jar 的 sha256

`KEEP=1 ./run-demo.sh` 保留中间产物。

## 目录

| 文件 | 作用 |
|---|---|
| `demo/run-demo.sh` | 完整流程 + 自动校验 |
| `demo/ALTERNATIVES.md` | 方案对比、工具全景、选型建议 |
| `demo/make_assets.py` | 生成确定性素材 |
| `demo/Dockerfile` | 三层测试镜像 |
| `demo/README.md` | diffah 用法与踩坑记录 |

## 踩到的坑

完整清单见 [`demo/README.md`](demo/README.md)，几个容易忽略的：

- `diffah` 的 `--platform` 默认 `linux/amd64`，arm64 机器上必须显式传 `linux/arm64`
- `diffah apply` 产出的 docker-archive 里 `RepoTags` 是空数组，`docker load` 后要自己补 tag
- `diffah` 的 `--zstd-level` 默认 22，配合层内差分在 16 GiB 机器上会被 OOM 杀掉，而 delta 并不比 level 12 小
- `--candidates` 默认 3 会让大依赖层被当候选白试一遍，`--candidates 2` 快 5 倍且体积不变
- Docker 29 的 `docker save` 写**未压缩**层 tar，这是 CDC 类工具能在上面生效的前提；层若为 gzip，变化层要整层重传

## 环境

实测环境：macOS arm64，Docker 29.4.0（OrbStack），zstd 1.5.7，diffah v0.2.0，desync v1.1.4。

脚本已做 GNU / BSD 兼容，Linux 上可直接跑。
