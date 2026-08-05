#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacActiveApplications"
DISPLAY_NAME="Mac Active Applications"
VERSION="1.0.0"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
STAGE_DIR="$DIST_DIR/dmg-stage"
BIN_PATH=""

echo "==> Building release binary…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

# SPM 本地化资源包需与可执行文件同目录，供 Bundle.module 加载。
RESOURCE_BUNDLE="$(dirname "$BIN_PATH")/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
  echo "==> Included localization bundle"
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

echo
echo "Done."
echo "  App : $APP_DIR"
echo "  DMG : $DMG_PATH"
echo
echo "Install: open the DMG and drag the app into Applications."
echo "Then enable Accessibility for it in System Settings."
