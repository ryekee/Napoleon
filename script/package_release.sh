#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Napoleon"
PROJECT="Napoleon.xcodeproj"
SCHEME="Napoleon"
SIGN_IDENTITY="Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)"
TEAM_ID="JQTFJ8P2T7"
NOTARY_PROFILE="Hiko-notray"
DIST="$ROOT/build/dist"
DERIVED_DATA="$ROOT/build/release-dd"

usage() {
  cat <<'EOF'
用法：
  script/package_release.sh
  script/package_release.sh --resume <submission-id>

默认流程会构建、递归签名、制作 DMG、提交 Apple 公证并等待最多 30 分钟。
--resume 只继续已有 submission，绝不会重复提交同一个 DMG。
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --resume)
    [ "$#" -eq 2 ] || { usage >&2; exit 64; }
    RESUME_ID="$2"
    ;;
  "")
    RESUME_ID=""
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

if [ -n "$RESUME_ID" ] && [[ ! "$RESUME_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "✗ 无效的 Submission ID：$RESUME_ID" >&2
  exit 64
fi

VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || { echo "✗ 无法从 project.yml 读取版本号" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)*$ ]] \
  || { echo "✗ 非法版本号：$VERSION" >&2; exit 1; }
DMG="$DIST/$APP_NAME-$VERSION.dmg"

require_signing_identity() {
  security find-identity -v -p codesigning \
    | grep -F "\"$SIGN_IDENTITY\"" >/dev/null \
    || { echo "✗ 钥匙串中没有可用的 Developer ID 身份：$SIGN_IDENTITY" >&2; exit 1; }
}

require_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || { echo "✗ 公证凭据不可用：$NOTARY_PROFILE" >&2; exit 1; }
}

sign_nested_code() {
  local app="$1"
  local item

  # 先签嵌套 Mach-O，再按 find -depth 从最内层 bundle 向外签；主 App 最后签。
  for code_dir in Frameworks XPCServices PlugIns Helpers; do
    [ -d "$app/Contents/$code_dir" ] || continue
    while IFS= read -r -d '' item; do
      if file -b "$item" | grep -q 'Mach-O'; then
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$item"
      fi
    done < <(find "$app/Contents/$code_dir" -type f -print0)
  done

  while IFS= read -r -d '' item; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$item"
  done < <(find "$app/Contents" -depth -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \) \
    -print0)

  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$app"
}

verify_code_object() {
  local item="$1"
  local details
  codesign --verify --strict --verbose=2 "$item"
  details="$(codesign -dvvv "$item" 2>&1)"
  grep -F "TeamIdentifier=$TEAM_ID" <<<"$details" >/dev/null \
    || { echo "✗ TeamIdentifier 不匹配：$item" >&2; exit 1; }
  grep -E 'flags=.*runtime' <<<"$details" >/dev/null \
    || { echo "✗ 未启用 Hardened Runtime：$item" >&2; exit 1; }
  grep -F 'Timestamp=' <<<"$details" >/dev/null \
    || { echo "✗ 缺少 secure timestamp：$item" >&2; exit 1; }
}

verify_app_signatures() {
  local app="$1"
  local item
  for code_dir in Frameworks XPCServices PlugIns Helpers; do
    [ -d "$app/Contents/$code_dir" ] || continue
    while IFS= read -r -d '' item; do
      if file -b "$item" | grep -q 'Mach-O'; then
        verify_code_object "$item"
      fi
    done < <(find "$app/Contents/$code_dir" -type f -print0)
  done
  while IFS= read -r -d '' item; do
    verify_code_object "$item"
  done < <(find "$app/Contents" -depth -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \) \
    -print0)
  verify_code_object "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}

validate_gatekeeper_app() {
  local mount_dir assess_status detach_status
  mount_dir="$(mktemp -d /tmp/napoleon-release.XXXXXX)"
  if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null; then
    if spctl --assess --type execute --verbose=4 "$mount_dir/$APP_NAME.app"; then
      assess_status=0
    else
      assess_status=$?
    fi
    if hdiutil detach "$mount_dir" >/dev/null; then
      detach_status=0
    else
      detach_status=$?
    fi
    rmdir "$mount_dir" 2>/dev/null || true
    [ "$assess_status" -eq 0 ] && [ "$detach_status" -eq 0 ]
  else
    rmdir "$mount_dir"
    return 1
  fi
}

finish_submission() {
  local submission_id="$1"
  local info status log_path
  info="$(xcrun notarytool info "$submission_id" \
    --keychain-profile "$NOTARY_PROFILE" --output-format json)"
  status="$(plutil -extract status raw -o - - <<<"$info")"

  case "$status" in
    Accepted)
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
      spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
      validate_gatekeeper_app
      shasum -a 256 "$DMG"
      echo "✓ 公证完成：$DMG"
      echo "  Submission ID：$submission_id"
      ;;
    "In Progress")
      echo "⚠ 公证仍在处理；不要重复提交：$submission_id" >&2
      echo "  script/package_release.sh --resume $submission_id" >&2
      exit 2
      ;;
    *)
      log_path="$DIST/notary-log-$submission_id.json"
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$log_path" || true
      echo "✗ 公证状态：$status；日志：$log_path" >&2
      exit 1
      ;;
  esac
}

require_signing_identity
require_notary_profile

if [ -n "$RESUME_ID" ]; then
  [ -f "$DMG" ] || { echo "✗ 找不到原始 DMG：$DMG" >&2; exit 1; }
  finish_submission "$RESUME_ID"
  exit 0
fi

command -v xcodegen >/dev/null || { echo "✗ 缺少 xcodegen" >&2; exit 1; }

echo "▸ 生成工程并构建 Release（arm64 + x86_64）"
xcodegen generate
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT_APP" ] || { echo "✗ 构建产物不存在：$BUILT_APP" >&2; exit 1; }

WORK="$DIST/.work"
STAGED_APP="$WORK/$APP_NAME.app"
mkdir -p "$DIST"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
ditto "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

echo "▸ Developer ID 递归签名与验证"
sign_nested_code "$STAGED_APP"
verify_app_signatures "$STAGED_APP"

GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
[ "$GOT_VERSION" = "$VERSION" ] \
  || { echo "✗ 包内版本 $GOT_VERSION 与 project.yml 的 $VERSION 不一致" >&2; exit 1; }

ln -s /Applications "$WORK/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$WORK" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "▸ 提交 Apple 公证（成功上传后不会自动重复提交）"
if ! SUBMISSION_JSON="$(xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" --no-s3-acceleration --output-format json)"; then
  echo "✗ 上传未确认成功；请先检查 history，确认没有已创建的 submission 后再重试" >&2
  echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi
SUBMISSION_ID="$(plutil -extract id raw -o - - <<<"$SUBMISSION_JSON")"
[ -n "$SUBMISSION_ID" ] || { echo "✗ 公证响应缺少 Submission ID" >&2; exit 1; }
echo "  Submission ID：$SUBMISSION_ID"

xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
  --timeout 30m || true
finish_submission "$SUBMISSION_ID"
