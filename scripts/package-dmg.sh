#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-menubar"
PACKAGING_DIR="$APP_DIR/Packaging"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="VoiceShot"
VOLUME_NAME="VoiceShot Installer"
PROJECT_PATH="$APP_DIR/VoiceShot.xcodeproj"
SCHEME_NAME="VoiceShot"
ARCHIVE_PATH="$DIST_DIR/VoiceShot.xcarchive"
APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/VoiceShot.dmg"
RW_DMG_PATH="$DIST_DIR/VoiceShot-rw.dmg"
ENTITLEMENTS="$PACKAGING_DIR/entitlements.plist"
SKIP_SIGNING="${SKIP_SIGNING:-0}"
DEVELOPER_ID="${DEVELOPER_ID:-${SIGNING_IDENTITY:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DIST_DIR/DerivedData}"

log_info() {
  printf '[Info] %s\n' "$*"
}

log_error() {
  printf '[Error] %s\n' "$*" >&2
}

log_info_block() {
  sed 's/^/[Info] /'
}

log_error_block() {
  sed 's/^/[Error] /' >&2
}

apply_volume_icon() {
  local icon_source="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  if [[ ! -f "$icon_source" ]]; then
    log_info "Warning: App icon not found; skipping DMG volume icon: $icon_source"
    return
  fi

  /usr/bin/ditto "$icon_source" "$volume/.VolumeIcon.icns"
  if setfile_path=$(/usr/bin/xcrun -find SetFile 2>/dev/null); then
    "$setfile_path" -c icnC "$volume/.VolumeIcon.icns"
    "$setfile_path" -a V "$volume/.VolumeIcon.icns"
    "$setfile_path" -a C "$volume"
  else
    log_info "Warning: SetFile not found; DMG volume icon may not appear on the desktop."
  fi
  /usr/bin/touch "$volume/.VolumeIcon.icns" "$volume"
}

detect_developer_id() {
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p'
}

detach_existing_volume() {
  local volume_path="/Volumes/$VOLUME_NAME"
  if [[ -e "$volume_path" ]]; then
    log_info "Detaching existing mounted volume: $volume_path"
    /usr/bin/hdiutil detach "$volume_path" -quiet >/dev/null 2>&1 || \
      /usr/sbin/diskutil unmount force "$volume_path" >/dev/null 2>&1 || true
  fi
}

if [[ "$SKIP_SIGNING" != "1" && -z "$DEVELOPER_ID" ]]; then
  developer_ids=("${(@f)$(detect_developer_id)}")
  if [[ "${#developer_ids[@]}" == "1" && -n "${developer_ids[1]}" ]]; then
    DEVELOPER_ID="${developer_ids[1]}"
    log_info "Using detected Developer ID: $DEVELOPER_ID"
  elif [[ "${#developer_ids[@]}" == "0" || -z "${developer_ids[1]:-}" ]]; then
    log_error "No Developer ID Application certificate found in your keychain."
    log_error "Create one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application"
    log_error 'Then run: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    exit 1
  else
    log_error "Multiple Developer ID Application certificates found:"
    for developer_id in "${developer_ids[@]}"; do
      log_error "  $developer_id"
    done
    log_error 'Set the one to use explicitly, for example:'
    log_error 'DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    exit 1
  fi
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
detach_existing_volume

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  archive
  SKIP_INSTALL=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGN_IDENTITY=""
)

/usr/bin/xcodebuild "${xcodebuild_args[@]}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  log_error "Xcode archive did not produce $APP_BUNDLE"
  exit 1
fi

if [[ "$SKIP_SIGNING" != "1" ]]; then
  /usr/bin/codesign --force \
    --deep \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
  log_info "Built unsigned app for local testing."
fi

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -size 64m \
  -type UDIF \
  -fs HFS+ \
  -ov \
  "$RW_DMG_PATH"

attach_output=$(/usr/bin/hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen)
device=$(echo "$attach_output" | awk '/^\/dev\// {print $1; exit}')
if [[ -z "$device" ]]; then
  log_error "Could not determine attached DMG device."
  exit 1
fi
volume=$(echo "$attach_output" | awk 'index($0, "/Volumes/") {print substr($0, index($0, "/Volumes/")); exit}')
if [[ -z "$volume" ]]; then
  log_error "Could not determine mounted DMG volume."
  exit 1
fi

cleanup_dmg_mount() {
  if [[ -n "${device:-}" ]]; then
    /usr/bin/hdiutil detach "$device" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup_dmg_mount EXIT

/usr/bin/ditto "$APP_BUNDLE" "$volume/$APP_NAME.app"
/bin/ln -s /Applications "$volume/Applications"
/usr/bin/touch "$volume/$APP_NAME.app"
/usr/bin/touch "$volume"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$volume/$APP_NAME.app" >/dev/null 2>&1 || true

/usr/bin/open "$volume"
sleep 1

if ! layout_output=$(/usr/bin/osascript <<APPLESCRIPT 2>&1
tell application "Finder"
  set dmgDisk to disk "$VOLUME_NAME"
  open dmgDisk
  delay 1

  try
    set dmgWindow to container window of dmgDisk
  on error
    try
      set dmgWindow to front window
    on error errorMessage
      return "Skipped Finder layout: " & errorMessage
    end try
  end try

  try
    set icon of dmgDisk to icon of item "$APP_NAME.app" of dmgDisk
  end try

  try
    set current view of dmgWindow to icon view
  end try
  try
    set toolbar visible of dmgWindow to false
  end try
  try
    set statusbar visible of dmgWindow to false
  end try
  try
    set bounds of dmgWindow to {120, 120, 760, 500}
  end try
  try
    set viewOptions to the icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
  end try
  try
    set position of item "$APP_NAME.app" of dmgWindow to {180, 190}
  end try
  try
    set position of item "Applications" of dmgWindow to {460, 190}
  end try
  try
    set position of item "$APP_NAME.app" of dmgDisk to {180, 190}
  end try
  try
    set position of item "Applications" of dmgDisk to {460, 190}
  end try
  try
    update dmgDisk without registering applications
  end try
  delay 3
  try
    close dmgWindow
  end try
end tell
APPLESCRIPT
); then
  log_info "Warning: Finder DMG window layout step failed; continuing. $layout_output"
elif [[ -n "$layout_output" ]]; then
  log_info "$layout_output"
fi

for _ in {1..10}; do
  if [[ -f "$volume/.DS_Store" ]]; then
    break
  fi
  sleep 1
done

if [[ -f "$volume/.DS_Store" ]]; then
  log_info "Configured Finder DMG window layout."
else
  log_info "Warning: Finder did not write .DS_Store; DMG window layout may not persist."
fi

apply_volume_icon

/bin/sync
/usr/bin/hdiutil detach "$device" -quiet
device=""

/usr/bin/hdiutil convert "$RW_DMG_PATH" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -f "$RW_DMG_PATH"

if [[ "$SKIP_SIGNING" != "1" ]]; then
  /usr/bin/codesign --force \
    --sign "$DEVELOPER_ID" \
    --timestamp \
    "$DMG_PATH"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    if ! notary_output=$(/usr/bin/xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait 2>&1); then
      echo "$notary_output" | log_error_block
      submission_id=$(echo "$notary_output" | awk '/id:/ {print $2; exit}')
      if [[ -n "$submission_id" ]]; then
        /usr/bin/xcrun notarytool log "$submission_id" \
          --keychain-profile "$NOTARY_PROFILE" || true
      fi
      exit 1
    fi
    echo "$notary_output" | log_info_block
    if echo "$notary_output" | grep -q "status: Invalid"; then
      submission_id=$(echo "$notary_output" | awk '/id:/ {print $2; exit}')
      if [[ -n "$submission_id" ]]; then
        /usr/bin/xcrun notarytool log "$submission_id" \
          --keychain-profile "$NOTARY_PROFILE" || true
      fi
      exit 1
    fi
    /usr/bin/xcrun stapler staple "$DMG_PATH"
  else
    log_info "NOTARY_PROFILE not set; skipping notarization."
  fi
fi

log_info "Built: $DMG_PATH"
