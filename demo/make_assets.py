#!/usr/bin/env python3
"""生成 demo 素材：一个体量很大的「依赖层」文件，以及两个只差一处缺陷修复的 jar。

确定性是这套 demo 成立的前提：两次构建里「没变的那一层」必须逐字节相同，
Docker 才会复用同一个 layer digest，diffah 才可能把它识别成公共层而不重复传输。
所以这里所有字节都由固定 seed 经 SHAKE-256 派生，不用 os.urandom。
"""

from __future__ import annotations

import hashlib
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")

DEPS_SIZE = 200 * 1024 * 1024  # 200 MiB，模拟 JRE + 第三方依赖库
CLASS_COUNT = 200
CLASS_SIZE = 10 * 1024  # 每份 10 KiB，200 份 ≈ 2 MiB
BUGFIX_LEN = 64  # 缺陷修复只改动 64 字节


def det_bytes(label: str, size: int) -> bytes:
    """由 label 派生 size 字节的确定性伪随机数据。"""
    return hashlib.shake_256(label.encode()).digest(size)


def build_jar(path: str, version: str, bugfix: bytes | None) -> None:
    # zipfile 默认把当前时间写进每个 entry 的 header，会让产物每次都不一样。
    # 固定时间戳，jar 才是可复现的。
    fixed_ts = (2024, 1, 1, 0, 0, 0)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:

        def put(name: str, data: bytes) -> None:
            info = zipfile.ZipInfo(name, date_time=fixed_ts)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)

        put(
            "META-INF/MANIFEST.MF",
            f"Manifest-Version: 1.0\nImplementation-Version: {version}\n".encode(),
        )
        for i in range(CLASS_COUNT):
            data = bytearray(det_bytes(f"class-{i}", CLASS_SIZE))
            if bugfix is not None and i == CLASS_COUNT // 2:
                off = CLASS_SIZE // 4
                data[off : off + len(bugfix)] = bugfix
            put(f"com/example/demo/Class{i:03d}.class", bytes(data))


def main() -> None:
    os.makedirs(ASSETS, exist_ok=True)

    deps = os.path.join(ASSETS, "deps.bin")
    if not os.path.exists(deps) or os.path.getsize(deps) != DEPS_SIZE:
        print(f"生成 {deps} ({DEPS_SIZE} 字节) ...")
        with open(deps, "wb") as fh:
            fh.write(det_bytes("deps-layer-v1", DEPS_SIZE))

    # v1：有缺陷的实现
    build_jar(os.path.join(ASSETS, "app-v1.jar"), "1.0.0", None)
    # v1.0.1：同一个 jar，只修掉中间那个类文件里的一小段字节
    build_jar(
        os.path.join(ASSETS, "app-v1.0.1.jar"),
        "1.0.1",
        det_bytes("bugfix-patch", BUGFIX_LEN),
    )

    for name in ("deps.bin", "app-v1.jar", "app-v1.0.1.jar"):
        p = os.path.join(ASSETS, name)
        print(f"  {name:16s} {os.path.getsize(p):>12,} 字节")


if __name__ == "__main__":
    main()
