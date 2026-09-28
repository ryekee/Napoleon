#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Napoleon"
BUNDLE_ID="com.napoleon.Napoleon"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_existing_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  # project.yml is authoritative; never reuse stale generated signing settings.
  (cd "$ROOT_DIR" && xcodegen generate)
  xcodebuild \
    -project "$ROOT_DIR/Napoleon.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
}

verify_signing() {
  local expected_requirement='identifier "com.napoleon.Napoleon" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "JQTFJ8P2T7"'
  /usr/bin/codesign --verify --deep --strict -R "=$expected_requirement" "$APP_BUNDLE"

  local installed_app="/Applications/$APP_NAME.app"
  if [[ -d "$installed_app" ]]; then
    local installed_requirement
    installed_requirement=$(/usr/bin/codesign -d -r- "$installed_app" 2>&1 | sed -n 's/^designated => //p')
    if [[ -z "$installed_requirement" ]]; then
      echo "error: Cannot read installed app signing identity; refusing to launch." >&2
      return 1
    fi
    /usr/bin/codesign --verify -R "=$installed_requirement" "$APP_BUNDLE"
  fi
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

build_app
verify_signing
# Keep the running app available if building or signature verification fails.
stop_existing_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
