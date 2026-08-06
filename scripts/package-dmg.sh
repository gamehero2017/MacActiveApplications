#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacActiveApplications"
DISPLAY_NAME="Mac Active Applications"
# 与 Resources/Info.plist 的 CFBundleShortVersionString 保持一致，避免 DMG 名仍是旧版。
VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null \
    || plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist" 2>/dev/null \
    || echo "0.0.0"
)"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
STAGE_DIR="$DIST_DIR/dmg-stage"

# ARCHS=universal（默认）| arm64 | x86_64
ARCHS="${ARCHS:-universal}"

echo "==> Version ${VERSION} (from Resources/Info.plist)"
echo "==> Architecture: ${ARCHS}"

bin_for_arch() {
  local arch="$1"
  # SwiftPM 按三元组分目录；--show-bin-path 需带上对应 --arch。
  swift build -c release --arch "$arch" --show-bin-path
}

build_arch() {
  local arch="$1"
  echo "==> Building release (${arch})…" >&2
  swift build -c release --arch "$arch" >&2
  local bin
  bin="$(bin_for_arch "$arch")/${APP_NAME}"
  if [[ ! -x "$bin" ]]; then
    echo "error: binary not found at $bin" >&2
    exit 1
  fi
  printf '%s\n' "$bin"
}

case "$ARCHS" in
  universal)
    ARM_BIN="$(build_arch arm64)"
    X86_BIN="$(build_arch x86_64)"
    UNIVERSAL_BIN="$DIST_DIR/${APP_NAME}-universal"
    mkdir -p "$DIST_DIR"
    echo "==> Creating universal binary (lipo)…"
    lipo -create -output "$UNIVERSAL_BIN" "$ARM_BIN" "$X86_BIN"
    BIN_PATH="$UNIVERSAL_BIN"
    RESOURCE_BUNDLE="$(dirname "$ARM_BIN")/${APP_NAME}_${APP_NAME}.bundle"
    # 若 arm 产物旁没有资源包，再试 x86 目录。
    if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
      RESOURCE_BUNDLE="$(dirname "$X86_BIN")/${APP_NAME}_${APP_NAME}.bundle"
    fi
    ;;
  arm64|x86_64)
    BIN_PATH="$(build_arch "$ARCHS")"
    RESOURCE_BUNDLE="$(dirname "$BIN_PATH")/${APP_NAME}_${APP_NAME}.bundle"
    ;;
  *)
    echo "error: ARCHS must be universal, arm64, or x86_64 (got: $ARCHS)" >&2
    exit 1
    ;;
esac

echo "==> Binary architectures:"
lipo -info "$BIN_PATH" || file "$BIN_PATH"

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

# SPM 资源包放在 Contents 内（根目录会破坏 codesign：unsealed contents）。
# L10n 会自行在 MacOS / Resources 下查找，不再依赖 Bundle.module。
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
  echo "==> Included localization bundle (MacOS + Resources)"
else
  echo "warning: localization bundle not found at $RESOURCE_BUNDLE" >&2
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "==> Included AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns not found; app will use default icon" >&2
fi

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Creating DMG…"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Temporary read/write DMG, then convert to compressed UDZO.
TMP_DMG="$DIST_DIR/${APP_NAME}-tmp.dmg"
rm -f "$TMP_DMG"
hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$TMP_DMG" >/dev/null

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE_DIR"
# lipo 中间产物不必保留
rm -f "$DIST_DIR/${APP_NAME}-universal"

echo
echo "Done."
echo "  App : $APP_DIR"
echo "  DMG : $DMG_PATH"
echo "  Arch: $(lipo -archs "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo unknown)"
echo
echo "Install: open the DMG and drag the app into Applications."
echo "Then enable Accessibility for it in System Settings."
echo
echo "Tips:"
echo "  ARCHS=universal ./scripts/package-dmg.sh   # 默认，一份包双架构"
echo "  ARCHS=arm64 ./scripts/package-dmg.sh       # 仅 Apple Silicon"
echo "  ARCHS=x86_64 ./scripts/package-dmg.sh      # 仅 Intel"
