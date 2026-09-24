#!/usr/bin/env bash
# build_ipa.sh — 在 macOS + Theos 上编译 VirtualCamDemo 并打出 .ipa
#
# 依赖：
#   - macOS
#   - Xcode + Command Line Tools
#   - Theos (https://theos.dev) 且 THEOS 已设置
#   - 可选：ldid（Theos 通常自带）
#
# 用法：
#   chmod +x build_ipa.sh
#   export THEOS=/opt/theos
#   ./build_ipa.sh
#
# 输出：
#   ./dist/VirtualCamDemo.ipa
#   ./packages/*.deb   (tweak + app deb，若 make package 成功)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: 本脚本必须在 macOS 上运行（需要 Xcode/iOS SDK）。" >&2
  echo "当前系统: $(uname -s). 请把整个 MyFirstTweak 目录拷到 Mac 再执行。" >&2
  exit 1
fi

if [[ -z "${THEOS:-}" || ! -d "$THEOS" ]]; then
  echo "error: 请设置 THEOS 指向 Theos 根目录，例如:" >&2
  echo "  export THEOS=/opt/theos" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: 未找到 xcrun，请安装 Xcode Command Line Tools。" >&2
  exit 1
fi

echo "==> THEOS=$THEOS"
echo "==> SDK: $(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo unknown)"

# 清旧产物
rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"

echo "==> make app (application)"
(
  cd "$ROOT/app"
  make clean || true
  make all
)

# Theos application 产物路径常见为 .theos/obj/.../VirtualCamDemo.app
APP_PATH=""
CANDIDATES=(
  "$ROOT/app/.theos/obj/VirtualCamDemo.app"
  "$ROOT/app/.theos/obj/debug/VirtualCamDemo.app"
  "$ROOT/app/.theos/obj/linux/VirtualCamDemo.app"
  "$ROOT/.theos/obj/VirtualCamDemo.app"
  "$ROOT/.theos/obj/debug/VirtualCamDemo.app"
)
for c in "${CANDIDATES[@]}"; do
  if [[ -d "$c" ]]; then
    APP_PATH="$c"
    break
  fi
done

# 再搜一遍
if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(find "$ROOT" -type d -name 'VirtualCamDemo.app' 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: 未找到 VirtualCamDemo.app，请检查 make 输出。" >&2
  exit 1
fi

echo "==> found app: $APP_PATH"

# 可选：塞一个占位说明；真正 demo.mp4 由用户用 Files App 放入 Documents
PAYLOAD_DIR="$ROOT/dist/_ipa/Payload"
rm -rf "$ROOT/dist/_ipa"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

# 确保 Info.plist 在
if [[ ! -f "$PAYLOAD_DIR/VirtualCamDemo.app/Info.plist" ]]; then
  cp "$ROOT/app/Info.plist" "$PAYLOAD_DIR/VirtualCamDemo.app/Info.plist"
fi

# 重新签名（越狱/TrollStore 侧载常用 ldid）
if command -v ldid >/dev/null 2>&1; then
  echo "==> ldid sign"
  ldid -S"$ROOT/app/entitlements.plist" "$PAYLOAD_DIR/VirtualCamDemo.app/VirtualCamDemo" || \
    ldid -S "$PAYLOAD_DIR/VirtualCamDemo.app/VirtualCamDemo" || true
elif [[ -x "$THEOS/toolchain/linux/iphone/bin/ldid" ]]; then
  "$THEOS/toolchain/linux/iphone/bin/ldid" -S"$ROOT/app/entitlements.plist" \
    "$PAYLOAD_DIR/VirtualCamDemo.app/VirtualCamDemo" || true
else
  echo "warn: ldid 未找到，IPA 可能无法直接安装；可在设备上用 TrollStore/AltStore 再签。"
fi

IPA_OUT="$ROOT/dist/VirtualCamDemo.ipa"
(
  cd "$ROOT/dist/_ipa"
  zip -qr "$IPA_OUT" Payload
)

echo "==> IPA: $IPA_OUT"
ls -lh "$IPA_OUT"

# 同时打 tweak deb（可选）
echo "==> make package (tweak + app deb)"
(
  cd "$ROOT"
  make package || make -C tweak package || true
) || true

echo ""
echo "完成。"
echo "  IPA:  $IPA_OUT"
echo "安装方式（任选）："
echo "  - TrollStore 安装 IPA"
echo "  - 越狱: scp deb 后 dpkg -i"
echo "  - 把 demo.mp4 拷进 App Documents（Files / itunes 文件共享）"
echo ""
echo "注意：Windows 上无法生成真实 arm64 机器码 IPA；本脚本只在 macOS+Theos 有效。"
