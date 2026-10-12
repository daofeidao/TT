#!/usr/bin/env bash
# 编一份**宿主机**（macOS）可执行的 mksh，交给 mksh_probe.sh 探行为。
#
# 为什么要编宿主机那份：真正打进 App 的那份是交叉到 iOS arm64 的
# （build-mksh.sh 里 `-sdk iphoneos -arch arm64`），**macOS runner 跑不起来**。
# 而我们要问的是「这份 mksh 的 shell 语言支持哪些特性」——
# 花括号展开、case、算术这些都由 mksh 自己的代码决定，跟目标平台无关，
# 所以同一份源码编出来的宿主机版本是有效代理。
#
# 版本必须与打进 App 的完全一致（同一个 R59c），否则探出来的结论会张冠李戴。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MKSH_RELEASE="R59c"
TARBALL="build/mksh-${MKSH_RELEASE}.tar.gz"
OUT_BIN="build/mksh-host/mksh"
SRC_DIR="build/mksh-host-src"

mkdir -p build

if [ ! -f "$TARBALL" ]; then
  echo "下载 mksh ${MKSH_RELEASE} ..."
  for url in \
    "https://deb.debian.org/debian/pool/main/m/mksh/mksh_59c.orig.tar.gz" \
    "https://ftp.debian.org/debian/pool/main/m/mksh/mksh_59c.orig.tar.gz" \
    "https://www.mirbsd.org/MirOS/dist/mir/mksh/mksh-${MKSH_RELEASE}.tar.gz"
  do
    echo "  尝试 $url"
    if curl -fL --retry 2 --connect-timeout 20 "$url" -o "$TARBALL"; then
      break
    fi
    rm -f "$TARBALL"
  done
fi
[ -s "$TARBALL" ] || { echo "::error::mksh 源码包下载失败"; exit 1; }

rm -rf "$SRC_DIR" "$(dirname "$OUT_BIN")"
mkdir -p "$SRC_DIR"
tar -xf "$TARBALL" -C "$SRC_DIR"

BUILD_SH="$(find "$SRC_DIR" -maxdepth 3 -type f -name 'Build.sh' | head -n 1)"
[ -n "$BUILD_SH" ] || { echo "::error::mksh 源码（Build.sh）未找到"; exit 1; }
cd "$(dirname "$BUILD_SH")"

# -r = 发布构建，跳过自测执行（跟 build-mksh.sh 一致，只是目标换回宿主机）
CFLAGS="-O2 -fno-stack-protector -Wno-deprecated-declarations" sh Build.sh -r

mkdir -p "$ROOT/$(dirname "$OUT_BIN")"
cp mksh "$ROOT/$OUT_BIN"
chmod 755 "$ROOT/$OUT_BIN"
cd "$ROOT"

file "$OUT_BIN"
"$OUT_BIN" -c 'echo "宿主机 mksh 就绪：$KSH_VERSION"'