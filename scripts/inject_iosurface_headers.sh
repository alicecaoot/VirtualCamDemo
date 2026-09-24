#!/usr/bin/env bash
# Copy vendored IOSurface headers into the active iPhoneOS SDK so UIKit/CoreImage modules build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/IOSurface.framework"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DST="$SDK/System/Library/Frameworks/IOSurface.framework"

echo "SDK=$SDK"
echo "Inject IOSurface headers → $DST"

if [[ ! -d "$DST" ]]; then
  echo "error: IOSurface.framework missing in SDK" >&2
  exit 1
fi

mkdir -p "$DST/Headers" "$DST/Modules"
cp -f "$SRC/Headers/"*.h "$DST/Headers/"
if [[ -f "$SRC/Modules/module.modulemap" ]]; then
  cp -f "$SRC/Modules/module.modulemap" "$DST/Modules/"
fi

echo "Headers now:"
ls -la "$DST/Headers"
ls -la "$DST/Modules" 2>/dev/null || true
