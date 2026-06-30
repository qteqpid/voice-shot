#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VoiceShot"
BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
PACKAGING_DIR="$ROOT/Packaging"
ICON_SOURCE="$PACKAGING_DIR/AppIcon.jpg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${DEVELOPER_ID:-}}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"

log_info() {
  printf '[Info] %s\n' "$*"
}

log_warn() {
  printf '[Warn] %s\n' "$*" >&2
}

log_error() {
  printf '[Error] %s\n' "$*" >&2
}

detect_signing_identity() {
  local apple_development
  apple_development="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
  if [[ -n "$apple_development" ]]; then
    printf '%s\n' "$apple_development"
    return
  fi

  /usr/bin/security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1
}

generate_app_icon() {
  if [[ ! -f "$ICON_SOURCE" ]]; then
    log_warn "App icon source not found: $ICON_SOURCE"
    return
  fi

  local assets="$DIST_DIR/GeneratedAssets.xcassets"
  local iconset="$assets/AppIcon.appiconset"
  rm -rf "$assets"
  mkdir -p "$iconset"

  /usr/bin/sips -s format png -z 16 16 "$ICON_SOURCE" --out "$iconset/icon_16x16.png" >/dev/null
  /usr/bin/sips -s format png -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_16x16@2x.png" >/dev/null
  /usr/bin/sips -s format png -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_32x32.png" >/dev/null
  /usr/bin/sips -s format png -z 64 64 "$ICON_SOURCE" --out "$iconset/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -s format png -z 128 128 "$ICON_SOURCE" --out "$iconset/icon_128x128.png" >/dev/null
  /usr/bin/sips -s format png -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -s format png -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_256x256.png" >/dev/null
  /usr/bin/sips -s format png -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -s format png -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_512x512.png" >/dev/null
  /usr/bin/sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$iconset/icon_512x512@2x.png" >/dev/null

  cat > "$iconset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

  if ! actool_output=$(/usr/bin/xcrun actool "$assets" \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$DIST_DIR/asset-info.plist" 2>&1); then
    log_warn "actool could not compile AppIcon; falling back to tiff2icns."
    if [[ -n "$actool_output" ]]; then
      echo "$actool_output" | sed 's/^/[Warn] /' >&2
    fi
    local tiff_icon="$DIST_DIR/AppIcon.tiff"
    /usr/bin/sips -s format tiff -z 1024 1024 "$ICON_SOURCE" --out "$tiff_icon" >/dev/null
    /usr/bin/tiff2icns "$tiff_icon" "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -f "$tiff_icon"
  fi
  rm -rf "$assets" "$DIST_DIR/asset-info.plist"
}

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(detect_signing_identity)"
fi

if [[ -z "$SIGNING_IDENTITY" && "$ALLOW_UNSIGNED" != "1" ]]; then
  log_error "No Apple code signing certificate found."
  log_error "Create one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Apple Development."
  log_error 'Then run: SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh'
  log_error 'For a temporary unsigned development build, run: ALLOW_UNSIGNED=1 ./scripts/build-app.sh'
  exit 1
fi

log_info "Building $APP_NAME..."
swift build --disable-sandbox -c release

log_info "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
generate_app_icon

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  log_info "Signing app with identity: $SIGNING_IDENTITY"
  /usr/bin/codesign -f -s "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR/Contents/MacOS/$APP_NAME"
  /usr/bin/codesign -f -s "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
  /usr/bin/codesign -v --strict --verbose=2 "$APP_DIR"
else
  log_warn "Built unsigned app. Microphone permission may need to be granted again after rebuilds."
fi

log_info "Built: $APP_DIR"
