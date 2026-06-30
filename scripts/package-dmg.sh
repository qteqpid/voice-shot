#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VoiceShot"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/VoiceShot.dmg"
RW_DMG_PATH="$DIST_DIR/VoiceShot-rw.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${DEVELOPER_ID:-}}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
ALLOW_UNSTYLED_DMG="${ALLOW_UNSTYLED_DMG:-0}"

log_info() {
  printf '[Info] %s\n' "$*"
}

log_warn() {
  printf '[Warn] %s\n' "$*" >&2
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

log_warn_block() {
  sed 's/^/[Warn] /' >&2
}

detect_developer_id() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p'
}

detach_existing_volume() {
  local volume_path="/Volumes/$APP_NAME"
  if [[ -e "$volume_path" ]]; then
    log_info "Detaching existing mounted volume: $volume_path"
    /usr/bin/hdiutil detach "$volume_path" -quiet >/dev/null 2>&1 || \
      /usr/sbin/diskutil unmount force "$volume_path" >/dev/null 2>&1 || true
  fi
}

sign_and_notarize_dmg() {
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    log_info "Signing DMG..."
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

    if [[ -n "$NOTARY_PROFILE" ]]; then
      log_info "Submitting DMG for notarization..."
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
  else
    log_warn "Built unsigned DMG for local testing."
  fi
}

create_fallback_dmg() {
  log_warn "Falling back to hdiutil makehybrid. The DMG is usable, but Finder window layout will not be customized."
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  /usr/bin/ditto "$APP_DIR" "$DMG_ROOT/$APP_NAME.app"
  /bin/ln -s /Applications "$DMG_ROOT/Applications"

  /usr/bin/hdiutil makehybrid \
    -hfs \
    -hfs-volume-name "$APP_NAME" \
    -o "$DMG_PATH" \
    "$DMG_ROOT" 2>&1 | log_info_block

  rm -rf "$DMG_ROOT"
  sign_and_notarize_dmg
  log_info "Built: $DMG_PATH"
  exit 0
}

if [[ -z "$SIGNING_IDENTITY" && "$ALLOW_UNSIGNED" != "1" ]]; then
  developer_ids=()
  while IFS= read -r developer_id; do
    if [[ -n "$developer_id" ]]; then
      developer_ids+=("$developer_id")
    fi
  done < <(detect_developer_id)

  if [[ "${#developer_ids[@]}" == "1" ]]; then
    SIGNING_IDENTITY="${developer_ids[0]}"
    log_info "Using detected Developer ID: $SIGNING_IDENTITY"
  elif [[ "${#developer_ids[@]}" == "0" ]]; then
    log_error "No Developer ID Application certificate found in your keychain."
    log_error "Create one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application."
    log_error 'Then run: SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    log_error 'For a local unsigned DMG, run: ALLOW_UNSIGNED=1 ./scripts/package-dmg.sh'
    exit 1
  else
    log_error "Multiple Developer ID Application certificates found:"
    for developer_id in "${developer_ids[@]}"; do
      log_error "  $developer_id"
    done
    log_error 'Set the one to use explicitly, for example:'
    log_error 'SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    exit 1
  fi
fi

cd "$ROOT"
mkdir -p "$DIST_DIR"
detach_existing_volume
rm -f "$DMG_PATH" "$RW_DMG_PATH"

log_info "Building app bundle..."
if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$SIGNING_IDENTITY" ./scripts/build-app.sh
else
  ALLOW_UNSIGNED=1 ./scripts/build-app.sh
fi

if [[ ! -d "$APP_DIR" ]]; then
  log_error "App bundle was not produced: $APP_DIR"
  exit 1
fi

log_info "Creating writable DMG..."
if ! create_output=$(/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -size 64m \
  -type UDIF \
  -fs HFS+ \
  -ov \
  "$RW_DMG_PATH" 2>&1); then
  echo "$create_output" | log_error_block
  if [[ "$ALLOW_UNSTYLED_DMG" == "1" ]]; then
    create_fallback_dmg
  fi
  log_error "Could not create the writable DMG required for Finder window styling."
  log_error "This styled DMG flow is the same as browser-time-tracker and needs hdiutil create/attach support."
  log_error "If you only need a plain installable DMG, rerun with ALLOW_UNSTYLED_DMG=1."
  exit 1
fi
echo "$create_output" | log_info_block

attach_output=$(/usr/bin/hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen)
device=$(echo "$attach_output" | awk '/^\/dev\// {print $1; exit}')
volume=$(echo "$attach_output" | awk 'index($0, "/Volumes/") {print substr($0, index($0, "/Volumes/")); exit}')

if [[ -z "$device" || -z "$volume" ]]; then
  log_error "Could not determine mounted DMG volume."
  exit 1
fi

cleanup_dmg_mount() {
  if [[ -n "${device:-}" ]]; then
    /usr/bin/hdiutil detach "$device" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup_dmg_mount EXIT

log_info "Copying app and Applications shortcut..."
/usr/bin/ditto "$APP_DIR" "$volume/$APP_NAME.app"
/bin/ln -s /Applications "$volume/Applications"
/usr/bin/touch "$volume/$APP_NAME.app"
/usr/bin/touch "$volume"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$volume/$APP_NAME.app" >/dev/null 2>&1 || true

log_info "Configuring Finder DMG window layout..."
/usr/bin/open "$volume"
sleep 1

if ! layout_output=$(/usr/bin/osascript <<APPLESCRIPT 2>&1
tell application "Finder"
  set dmgDisk to disk "$APP_NAME"
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
  log_warn "Finder DMG window layout step failed; continuing. $layout_output"
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
  log_warn "Finder did not write .DS_Store; DMG window layout may not persist."
fi

/bin/sync
/usr/bin/hdiutil detach "$device" -quiet
device=""

log_info "Compressing DMG..."
/usr/bin/hdiutil convert "$RW_DMG_PATH" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -f "$RW_DMG_PATH"

sign_and_notarize_dmg

log_info "Built: $DMG_PATH"
