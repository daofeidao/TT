#!/usr/bin/env bash
# 交叉编译 mksh（MirBSD Korn shell）→ TT/ttbin/mksh
# 移植自 TrollTerm 的同款脚本（在本 CI 与目标机型上验证过思路）。
# mksh 是对 Darwin/iOS 兼容性最好的开源 shell；TrollTerm 实测 busybox 在 iOS 上
# SIGBUS 崩溃，故本项目只内置 mksh。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MKSH_RELEASE="R59c"
TARBALL="build/mksh-${MKSH_RELEASE}.tar.gz"
mkdir -p build TT/ttbin
rm -f TT/ttbin/mksh

if [ ! -f "$TARBALL" ]; then
  echo "下载 mksh ${MKSH_RELEASE} ..."
  # mirbsd.org 从 GitHub runner 经常连不上，Debian 官方镜像优先
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
[ -s "$TARBALL" ] || { echo "错误：mksh 源码包下载失败（所有镜像均不可用）"; exit 1; }

rm -rf "build/mksh-${MKSH_RELEASE}" "build/mksh-59c" "build/mksh"
tar -xf "$TARBALL" -C build
# 按 Build.sh 定位源码目录（上游 tarball 为 mksh-R59c/，Debian orig 为 mksh/，布局可能不同）
BUILD_SH="$(find build -maxdepth 2 -type f -name 'Build.sh' | head -n 1)"
[ -n "$BUILD_SH" ] || { echo "错误：mksh 源码（Build.sh）未找到"; exit 1; }
cd "$(dirname "$BUILD_SH")"

SDK="$(xcrun --show-sdk-path --sdk iphoneos)"
# mksh 的 Build.sh 自身在 macOS 上开发，交叉到 iOS 很直接：
# 覆盖 CC 指向 iphoneos SDK / arm64，-r 表示发布构建（跳过自测执行）。
env CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -isysroot ${SDK}" \
    CFLAGS="-O2 -fno-stack-protector -Wno-deprecated-declarations" \
    sh Build.sh -r

cp mksh "$ROOT/TT/ttbin/mksh"
chmod 755 "$ROOT/TT/ttbin/mksh"

echo "产物检查："
file "$ROOT/TT/ttbin/mksh"
file "$ROOT/TT/ttbin/mksh" | grep -q "arm64" || {
  echo "错误：mksh 不是 arm64 的 Mach-O 可执行文件"
  exit 1
}
echo "mksh 构建成功 ($(wc -c < "$ROOT/TT/ttbin/mksh" | tr -d ' ') 字节)"

# ---------------------------------------------------------------------------
# 为所有嵌套二进制附加 entitlements 签名。
# 背景（已由包内取证确认）：打包步骤的 codesign --deep 只签主程序，
# ttprobe / ttbin/* 原样以未签名状态进入 IPA；TrollStore 安装时虽会重新签名，
# 但只从主程序提取 entitlements，嵌套二进制最终是"无权限身份"，posix_spawn
# 拉起后被 AMFI 立刻 SIGKILL（真机退出码 137）。
# 本脚本在打包步骤之前逐个签名；codesign --deep 不处理这些路径，签名得以保留，
# TrollStore 安装时会提取并沿用其中的 entitlements（与主程序同一机制）。
echo "为嵌套二进制附加 entitlements 签名 ..."
ENTITLEMENTS="$ROOT/tt.entitlements"
[ -s "$ENTITLEMENTS" ] || { echo "::error::找不到 tt.entitlements"; exit 1; }

# 签名清单**自动扫目录**，不再写死。
#
# 原来这里是手写列表，结果连着漏了两次：
# v0.6.0 加的 seq/tee/nl、v0.8.0 加的 6 个，全都没签进去。
# 后果是 App 能装、能启动，一执行这些命令就被 SIGKILL（信号 9 / 退出码 137）——
# 真机表现为「命令莫名其妙被 9 终止」，跟 C 代码本身毫无关系，排查起来很绕。
#
# 两份清单分处 build.yml 和本文件，加一个工具要改两处，必然会忘。
# 现在只保留编译那一份，签名这边扫到什么签什么。
SIGNED_LIST=("$ROOT/scripts/ttprobe")
for bin in "$ROOT"/TT/ttbin/*; do
  [ -f "$bin" ] || continue
  SIGNED_LIST+=("$bin")
done
for bin in "${SIGNED_LIST[@]}"; do
  [ -s "$bin" ] || { echo "::error::嵌套二进制不存在: $bin"; exit 1; }
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$bin"
  /usr/bin/codesign -d --entitlements - "$bin" 2>/dev/null | grep -q "no-sandbox" || {
    echo "::error::嵌套二进制签名校验失败（无 no-sandbox）: $bin"
    exit 1
  }
  echo "  已签名: $(basename "$bin")"
done
echo "嵌套二进制签名完成"
