#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE_DIR="$ROOT/mac-menubar"
DIST_DIR="$ROOT/dist"
APP_NAME="VoiceShot"
PROJECT_PATH="$APP_SOURCE_DIR/VoiceShot.xcodeproj"
SCHEME_NAME="VoiceShot"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DIST_DIR/DerivedData}"

log_info() {
  printf '[Info] %s\n' "$*"
}

mkdir -p "$DIST_DIR"

log_info "Building $APP_NAME..."
/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
APP_DIR="$DIST_DIR/$APP_NAME.app"

log_info "Copying app bundle..."
rm -rf "$APP_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_DIR"

log_info "Built: $APP_DIR"
