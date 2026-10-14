#!/usr/bin/env bash
#
# diffah 增量发布 demo：证明「只改一个 jar 的镜像升级」不必整包传输。
#
#   A:v1      -> A:v1.0.1，仅 /app/app.jar 变化
#
# 流程：
#   1. 生成确定性素材（200 MiB 依赖层 + 两个只差 64 字节的 jar）
#   2. 构建 A:v1 / A:v1.0.1，确认公共层 digest 相同
#   3. docker save 两个全量包（复现你现在的痛点）
#   4. diffah diff 生成增量 delta
#   5. diffah apply 用 A:v1 + delta 重建 A:v1.0.1
#   6. docker load 重建结果，逐项校验：镜像 ID / 层 digest / 容器内 jar 的 sha256
#
# 用法：
#   ./run-demo.sh              # 完整跑一遍
#   KEEP=1 ./run-demo.sh       # 保留 work/ 下的中间产物
#   DIFFAH=/path/to/diffah ./run-demo.sh
#
set -euo pipefail

cd "$(dirname "$0")"

DIFFAH=${DIFFAH:-diffah}
PY=${PY:-python3}
KEEP=${KEEP:-0}
WORK=work
ASSETS=assets

# --platform 必须与 docker 构建出的镜像架构一致，否则 diffah 找不到镜像。
# 默认按本机架构推断，可用 PLATFORM=linux/amd64 ./run-demo.sh 覆盖。
case "$(uname -m)" in
  arm64|aarch64) DEFAULT_PLATFORM=linux/arm64 ;;
  *)             DEFAULT_PLATFORM=linux/amd64 ;;
esac
PLATFORM=${PLATFORM:-$DEFAULT_PLATFORM}

# 默认档位在 16 GiB 机器上约 550 MiB 峰值内存、0.4 秒。
# 不要用默认的 --zstd-level 22：配合层内差分要 1.6 GiB 以上，且 delta 并不更小。
ENCODE_FLAGS=${ENCODE_FLAGS:---workers 4 --zstd-level 12 --zstd-window-log 27 --candidates 2}

step() { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✅ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ❌ %s\033[0m\n' "$*"; exit 1; }

# GNU 与 BSD 的 stat / 校验和命令不同，统一一下，让脚本在 macOS 和 Linux 上都能跑。
filesize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

command -v "$DIFFAH" >/dev/null || fail "找不到 diffah，先安装：brew tap leosocy/tap && brew install diffah（或从 https://github.com/leosocy/diffah/releases 下二进制）"
command -v zstd   >/dev/null || fail "找不到 zstd，层内 patch 需要它：brew install zstd / apt install zstd"
"$DIFFAH" doctor >/dev/null 2>&1 || { echo "diffah doctor 未通过："; "$DIFFAH" doctor; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------- 1. 素材
step "1/6 生成确定性素材"
"$PY" make_assets.py

# ---------------------------------------------------------------- 2. 构建
step "2/6 构建 A:v1 与 A:v1.0.1"
docker build -q -t a:v1       --build-arg JAR=$ASSETS/app-v1.jar       -f Dockerfile . >/dev/null
docker build -q -t a:v1.0.1   --build-arg JAR=$ASSETS/app-v1.0.1.jar   -f Dockerfile . >/dev/null

echo "A:v1 的层："
docker inspect -f '{{range .RootFS.Layers}}  {{.}}{{"\n"}}{{end}}' a:v1
echo "A:v1.0.1 的层："
docker inspect -f '{{range .RootFS.Layers}}  {{.}}{{"\n"}}{{end}}' a:v1.0.1

L1_V1=$(docker inspect -f '{{index .RootFS.Layers 1}}' a:v1)
L1_V2=$(docker inspect -f '{{index .RootFS.Layers 1}}' a:v1.0.1)
[ "$L1_V1" = "$L1_V2" ] || fail "依赖层 digest 不同，素材或构建不确定"
ok "依赖层 digest 相同，diffah 可以把它识别为公共层"

# ---------------------------------------------------------------- 3. 全量包
step "3/6 docker save 全量包（你现在的做法）"
docker save a:v1     -o $WORK/a-v1.tar
docker save a:v1.0.1 -o $WORK/a-v1.0.1.tar
FULL_BYTES=$(filesize $WORK/a-v1.0.1.tar)
echo "  全量包大小: $FULL_BYTES 字节"

# ---------------------------------------------------------------- 4. delta
step "4/6 diffah diff 生成增量"
"$DIFFAH" diff --platform "$PLATFORM" --progress off $ENCODE_FLAGS \
  docker-archive:$WORK/a-v1.tar \
  docker-archive:$WORK/a-v1.0.1.tar \
  $WORK/a-v1-to-v1.0.1.delta.tar
DELTA_BYTES=$(filesize $WORK/a-v1-to-v1.0.1.delta.tar)
echo "  增量包大小: $DELTA_BYTES 字节"
echo
"$DIFFAH" inspect $WORK/a-v1-to-v1.0.1.delta.tar

# ---------------------------------------------------------------- 5. 重建
step "5/6 消费者侧：用 A:v1 + delta 重建 A:v1.0.1"
ORIG_ID=$(docker inspect -f '{{.Id}}' a:v1.0.1)
echo "  原始镜像 ID: $ORIG_ID"
"$DIFFAH" apply --progress off \
  $WORK/a-v1-to-v1.0.1.delta.tar \
  docker-archive:$WORK/a-v1.tar \
  docker-archive:$WORK/restored-v1.0.1.tar

# 模拟消费者手里只有 A:v1
docker rmi a:v1.0.1 >/dev/null
docker load -i $WORK/restored-v1.0.1.tar

# diffah 输出的 docker-archive 不带 RepoTags（manifest.json 里是空数组），
# docker load 只会按 ID 载入，需要自己补 tag。
docker tag "$ORIG_ID" a:v1.0.1

# ---------------------------------------------------------------- 6. 校验
step "6/6 校验"
NEW_ID=$(docker inspect -f '{{.Id}}' a:v1.0.1)
echo "  原始镜像 ID: $ORIG_ID"
echo "  重建镜像 ID: $NEW_ID"
[ "$ORIG_ID" = "$NEW_ID" ] || fail "镜像 ID 不一致"
ok "镜像 ID 一致"

BASE0=$(docker inspect -f '{{index .RootFS.Layers 0}}' a:v1)
BASE1=$(docker inspect -f '{{index .RootFS.Layers 1}}' a:v1)
NEW0=$(docker inspect -f '{{index .RootFS.Layers 0}}' a:v1.0.1)
NEW1=$(docker inspect -f '{{index .RootFS.Layers 1}}' a:v1.0.1)
[ "$BASE0" = "$NEW0" ] && [ "$BASE1" = "$NEW1" ] || fail "重建后的公共层 digest 与 A:v1 不一致"
ok "前两个公共层 digest 与 A:v1 一致"

IN_JAR=$(docker run --rm a:v1.0.1 | awk '{print $1}')
WANT_JAR=$(sha256 $ASSETS/app-v1.0.1.jar)
echo "  容器内 jar: $IN_JAR"
echo "  期望值    : $WANT_JAR"
[ "$IN_JAR" = "$WANT_JAR" ] || fail "容器内 jar 内容不对"
ok "容器内 jar 与目标版本逐字节一致"

# ---------------------------------------------------------------- 汇总
step "结果"
awk -v f="$FULL_BYTES" -v d="$DELTA_BYTES" 'BEGIN{
  printf "  全量 docker save : %12d 字节  (%.1f MiB)\n", f, f/1048576
  printf "  diffah 增量      : %12d 字节  (%.1f KiB)\n", d, d/1024
  printf "  缩减比例         : %.4f%%  (缩小 %.0f 倍)\n", d*100/f, f/d
}'

if [ "$KEEP" = "1" ]; then
  echo "  中间产物保留在 $WORK/"
else
  rm -rf "$WORK" "$ASSETS"
  echo "  已清理 $WORK/ 与 $ASSETS/（加 KEEP=1 可保留）"
  echo "  demo 镜像 a:v1 / a:v1.0.1 仍在本地，不需要时：docker rmi a:v1 a:v1.0.1"
fi
