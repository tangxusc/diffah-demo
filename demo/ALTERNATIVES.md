# 增量分发方案对比

同一场景实测：镜像约 210 MiB，三层，只有 2 MiB 的应用层变了一处。

## 先回答一个问题

**目标侧能不能跑一个 registry？**

能 → 别用任何增量工具，直接 push。OCI registry 天然按 blob digest 去重，只上传目标端没有的 blob。零额外工具。

不能（真隔离网、只靠 U 盘/单向光闸搬文件）→ 往下看。

## 三条路线实测

| 方案 | 传输量 | 占全量 | 前提 |
|---|---:|---:|---|
| `docker save` 全量 | 220,754,432 B（210.5 MiB） | 100% | 无 |
| **registry push** | 2,062,935 B（1.97 MiB） | 0.93% | 目标侧有 registry |
| **desync** | 319,134 B（311.7 KiB） | 0.1446% | 两端有 desync + chunk store |
| **diffah** | 8,704 B（8.5 KiB） | 0.0039% | 两端有 diffah + zstd |

三个数字都是本机实测，不是估算。

### registry push 怎么测的

```sh
docker run -d -p 5000:5000 -v /tmp/regdata:/var/lib/registry registry:3
docker push localhost:5000/a:v1        # 首次，全传
docker push localhost:5000/a:v1.0.1    # v1 已在远端
```

第二次 push 的输出：

```
b0e0d4416750: Layer already exists      # 200 MiB 依赖层，跳过
1b349a333453: Layer already exists      # 8.5 MiB alpine 层，跳过
2c33eb1375cd: Pushed                    # 2 MiB 应用层，实际传输
```

registry 存储增长 2,062,935 字节。这是唯一实际过网的量。

### desync 怎么测的

```sh
desync make -s store v1.caibx     a-v1.tar
desync make -s store v1.0.1.caibx a-v1.0.1.tar
desync extract -s store --seed v1.caibx:a-v1.tar v1.0.1.caibx out.tar
```

v1.0.1 相对 v1 只新增 6 个 chunk，合计 319,134 字节。

重建结果校验：`out.tar` 与原 `a-v1.0.1.tar` 的 sha256 完全一致，`docker load` 后镜像 ID 一致，容器内 jar 的 sha256 一致。

### diffah 怎么测的

见 `README.md`。delta 里两个公共层占 0 字节，应用层压成 801 字节 patch。

## desync 和 diffah 的粒度差异

这是关键区别，不是好坏问题。

| | diffah | desync |
|---|---|---|
| 认识镜像结构 | 是，按 layer digest 匹配公共层 | 否，只把 tar 当字节流 |
| 差分粒度 | 层内字节区间（zstd `--patch-from`） | 内容定义分块，默认 16:64:256 KB |
| 本例结果 | 801 字节 | 6 个 chunk，311.7 KiB |
| 交付物 | 单个 delta 文件 | chunk store + 每版本一个 index |
| 服务端要做什么 | 无（点对点算 delta） | 无（静态文件即可） |
| 多版本多客户端 | 每对版本算一次 delta | 一份 store 服务所有客户端和起始版本 |
| 重建后 tar 的元数据 | `RepoTags` 被清空，`docker load` 后要自己补 tag | 逐字节还原，tag 保留 |

**desync 的差分落在 chunk 边界上，diffah 的差分落在字节区间上。** 本例里改的是 jar 内部 64 字节，diffah 能把这 64 字节周边的字节区间单独打补丁；desync 只能以 chunk 为单位，所以动了 6 个 chunk。

反过来，如果你的发版经常一次改几十个文件、分布在镜像各处，desync 的 chunk 复用反而更稳——它不依赖"变化集中在一层的一个小区域"。

## CDC 能不能用，取决于层是否压缩

**实测：Docker 29 的 `docker save` 写出的是未压缩层 tar**（`application/vnd.oci.image.layer.v1.tar`，`file` 识别为 POSIX tar archive）。未压缩数据差分效果好，所以 desync 在本例里表现很好。

**如果层是 gzip 压缩的**，改动一个字节会让整段压缩流都变，CDC 只能复用其他未变层的 chunk，变化的层要整层重传。desync 自己的 README 明确写了这一点：

> A compressed or encrypted payload, for example, changes throughout when a single byte of its input does.

对应到本例：未压缩时 311.7 KiB，压缩时约 2 MiB（整层）。

用之前先跑 `desync info` 估算，别拍脑袋。

## 工具全景

按用途分组，star 与最后推送时间为 2026-10-13 实测。

### 目标侧能跑 registry —— 首选这条路

| 工具 | star | 最后推送 | 说明 |
|---|---:|---|---|
| goharbor/harbor | 29541 | 2026-10-13 | 企业级 registry，带复制、代理缓存、漏洞扫描 |
| distribution/distribution | 10644 | 2026-10-12 | 官方 registry:3 本体，最小可用 |
| podman-container-tools/skopeo | 11305 | 2026-10-09 | 无需 daemon，registry 间 copy/sync，只传缺失 blob |
| google/go-containerregistry | 4075 | 2026-10-07 | `crane` CLI + Go 库 |
| project-zot/zot | 2859 | 2026-10-13 | OCI 原生，单二进制，支持磁盘去重 |
| regclient/regclient | 1948 | 2026-10-04 | `regctl`，脚本友好 |

这条路是标准答案。绝大多数人绕远路，只是因为把 `docker save` 当成了唯一手段。

### 真隔离网、只能搬文件

| 工具 | star | 最后推送 | 说明 |
|---|---:|---|---|
| zarf-dev/zarf | 2066 | 2026-10-09 | OpenSSF 项目，K8s 导向的 airgap 包管理器。有 `--differential`：只打包相对上一个包的变化 |
| folbricht/desync | 434 | 2026-10-05 | 内容定义分块，兼容 systemd casync 格式，store 可以是任意静态文件服务 |
| hauler-dev/hauler | 260 | 2026-10-13 | Rancher Government 出品，内容寻址 store，目标侧内置 registry 和 fileserver，带签名/attestation/SBOM 校验 |
| oll3/bita | 293 | 2026-09-02 | Rust，自包含归档做差分同步 |
| systemd/casync | 1615 | 2025-09-22 | CDC 原版，已停更，用 desync 代替 |
| leosocy/diffah | 2 | 2026-07-20 | 见 `README.md`，单维护者，5 个月无提交 |
| shoufuzhang/dockerImageIncrementalExport | 7 | 2023-07-12 | 已死 |

**zarf 的 `--differential` 值得单独说**，它的定义是：

> Build a package that only contains the differential changes from local resources and differing remote resources from the specified previously built package

代价是它绑定 Kubernetes 部署模型，不是纯镜像搬运工具。

### 拉取慢，不是传输量大 —— 另一类问题

这些解决"节点拉镜像慢"，不解决"隔离网里怎么少搬文件"。

| 工具 | star | 最后推送 | 说明 |
|---|---:|---|---|
| uber/kraken | 6765 | 2026-10-12 | P2P registry |
| spegel-org/spegel | 3810 | 2026-10-06 | 集群内无状态 OCI mirror |
| dragonflyoss/dragonfly | 3347 | 2026-10-10 | CNCF，P2P 分发 |
| dragonflyoss/nydus | 1675 | 2026-10-13 | 按需加载镜像格式 |
| containerd/stargz-snapshotter | 1593 | 2026-10-09 | 懒加载，eStargz |
| awslabs/soci-snapshotter | 779 | 2026-10-09 | 懒加载，含索引 |
| containerd/accelerated-container-image | 474 | 2026-09-28 | overlaybd |

## 建议

1. **目标侧能跑 registry 就跑。** 2 MiB 过网，零工具成本，`docker push` 原样用。这条覆盖 80% 的情况。
2. **只能搬文件、且发版变化集中** → diffah 最省带宽，但要接受单维护者风险，建议 fork 自维护。
3. **只能搬文件、发版变化分散，或者不想绑定单一工具** → desync。434★ 活跃维护，通用，兼容 casync 格式，还顺带解决了 tar 元数据丢失的问题。
4. **已经在用 Kubernetes + airgap 交付整套系统** → 看 zarf 或 hauler，它们是完整交付框架，不只是镜像搬运。

不要选 `docker save` + 手写脚本抽层那条路。CSDN 上那些文章就是这条路，脆弱且没人维护。
