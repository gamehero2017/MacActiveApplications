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

# ARCHS=both（默认，打 -arm 与 -amd64 两份）| arm | arm64 | amd64 | x86_64
ARCHS="${ARCHS:-both}"
# 代码签名身份：留空则 ad-hoc（每次打包辅助功能都要重授）。
# 示例：
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   CODESIGN_IDENTITY=auto   # 自动选钥匙串里第一枚可用的 Development / Developer ID
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

echo "==> Version ${VERSION} (from Resources/Info.plist)"
echo "==> Architecture: ${ARCHS}"

resolve_codesign_identity() {
  local requested="${CODESIGN_IDENTITY}"
  if [[ -z "$requested" ]]; then
    printf '%s\n' "-"
    return
  fi
  if [[ "$requested" != "auto" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  # 优先 Developer ID（对外），其次 Apple Development（本机迭代）。
  local picked=""
  picked="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
      | head -n 1
  )"
  if [[ -z "$picked" ]]; then
    picked="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' \
        | head -n 1
    )"
  fi
  if [[ -z "$picked" ]]; then
    echo "error: CODESIGN_IDENTITY=auto 但钥匙串中没有可用的 Developer ID / Apple Development 证书" >&2
    echo "  请先在 Xcode → Settings → Accounts 下载证书，或手动指定：" >&2
    echo "  security find-identity -v -p codesigning" >&2
    exit 1
  fi
  printf '%s\n' "$picked"
}

CODESIGN_ID="$(resolve_codesign_identity)"
if [[ "$CODESIGN_ID" == "-" ]]; then
  echo "==> Code sign: ad-hoc（辅助功能权限在每次重打包后通常需要重新勾选）"
  echo "    建议：CODESIGN_IDENTITY=auto ./scripts/package-dmg.sh"
else
  echo "==> Code sign: ${CODESIGN_ID}"
fi

sign_app() {
  local app_dir="$1"
  if [[ "$CODESIGN_ID" == "-" ]]; then
    echo "==> Ad-hoc code signing…"
    codesign --force --deep --sign - "$app_dir"
  else
    echo "==> Code signing with stable identity…"
    # Developer ID / 公证场景用 hardened runtime；Development 证书同样可带 options runtime。
    codesign --force --deep --options runtime --sign "$CODESIGN_ID" "$app_dir"
  fi
  codesign --verify --deep --strict --verbose=2 "$app_dir" 2>&1 | sed 's/^/    /' || true
  echo "    identity: $(codesign -dv --verbose=2 "$app_dir" 2>&1 | sed -n 's/^Authority=\(.*\)/\1/p' | head -n 1 || echo unknown)"
}

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

# 将 swift 架构名规范为 DMG 后缀：arm | amd64
suffix_for_arch() {
  case "$1" in
    arm64) echo "arm" ;;
    x86_64) echo "amd64" ;;
    *)
      echo "error: unknown arch for suffix: $1" >&2
      exit 1
      ;;
  esac
}

# 组装 .app 并打成带后缀的 DMG。参数：swift 架构名（arm64 / x86_64）
package_arch() {
  local arch="$1"
  local suffix
  suffix="$(suffix_for_arch "$arch")"

  local bin_path resource_bundle
  bin_path="$(build_arch "$arch")"
  resource_bundle="$(dirname "$bin_path")/${APP_NAME}_${APP_NAME}.bundle"

  echo "==> Binary architectures (${suffix}):"
  lipo -info "$bin_path" || file "$bin_path"

  local app_dir dmg_path stage_dir
  app_dir="$DIST_DIR/${APP_NAME}-${suffix}.app"
  dmg_path="$DIST_DIR/${APP_NAME}-${VERSION}-${suffix}.dmg"
  stage_dir="$DIST_DIR/dmg-stage-${suffix}"

  echo "==> Assembling ${APP_NAME}-${suffix}.app…"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  cp "$bin_path" "$app_dir/Contents/MacOS/${APP_NAME}"
  cp "$ROOT/Resources/Info.plist" "$app_dir/Contents/Info.plist"
  chmod +x "$app_dir/Contents/MacOS/${APP_NAME}"

  # SPM 资源包放在 Contents 内（根目录会破坏 codesign：unsealed contents）。
  # L10n 会自行在 MacOS / Resources 下查找，不再依赖 Bundle.module。
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$app_dir/Contents/MacOS/"
    cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
    echo "==> Included localization bundle (MacOS + Resources)"
  else
    echo "warning: localization bundle not found at $resource_bundle" >&2
  fi

  if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
    echo "==> Included AppIcon.icns"
  else
    echo "warning: Resources/AppIcon.icns not found; app will use default icon" >&2
  fi

  echo "==> Code signing (${suffix})…"
  sign_app "$app_dir"

  echo "==> Creating DMG (${suffix})…"
  rm -rf "$stage_dir" "$dmg_path"
  mkdir -p "$stage_dir"
  # DMG 内仍用标准 App 名，便于拖入「应用程序」。
  cp -R "$app_dir" "$stage_dir/${APP_NAME}.app"
  ln -s /Applications "$stage_dir/Applications"

  local tmp_dmg
  tmp_dmg="$DIST_DIR/${APP_NAME}-${suffix}-tmp.dmg"
  rm -f "$tmp_dmg"
  hdiutil create \
    -volname "$DISPLAY_NAME (${suffix})" \
    -srcfolder "$stage_dir" \
    -ov \
    -format UDRW \
    "$tmp_dmg" >/dev/null

  hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
  rm -f "$tmp_dmg"
  rm -rf "$stage_dir"

  echo
  echo "Packaged (${suffix}):"
  echo "  App : $app_dir"
  echo "  DMG : $dmg_path"
  echo "  Arch: $(lipo -archs "$app_dir/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo unknown)"
  echo "  Sign: ${CODESIGN_ID}"
}

mkdir -p "$DIST_DIR"

case "$ARCHS" in
  both)
    package_arch arm64
    package_arch x86_64
    ;;
  arm|arm64)
    package_arch arm64
    ;;
  amd64|x86_64)
    package_arch x86_64
    ;;
  *)
    echo "error: ARCHS must be both, arm, arm64, amd64, or x86_64 (got: $ARCHS)" >&2
    exit 1
    ;;
esac

echo
echo "Done."
echo "Install: open the DMG and drag the app into Applications."
echo "Then enable Accessibility for it in System Settings (stable signing 后一般不必每次重勾)."
echo
echo "Tips:"
echo "  ./scripts/package-dmg.sh                              # 默认 ad-hoc + 两份架构"
echo "  CODESIGN_IDENTITY=auto ./scripts/package-dmg.sh       # 用钥匙串证书稳定签名（推荐）"
echo "  CODESIGN_IDENTITY='Apple Development: …' ./scripts/…"
echo "  ARCHS=arm ./scripts/package-dmg.sh                    # 仅 Apple Silicon → *-arm.dmg"
echo "  ARCHS=amd64 ./scripts/package-dmg.sh                  # 仅 Intel → *-amd64.dmg"
echo "  security find-identity -v -p codesigning              # 查看本机可用签名身份"
