#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/package_release.sh"

bash -n "$SCRIPT"

HELP="$(bash "$SCRIPT" --help)"
grep -F -- "--resume <submission-id>" <<<"$HELP" >/dev/null

grep -F 'Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)' "$SCRIPT" >/dev/null
grep -F 'NOTARY_PROFILE="Hiko-notray"' "$SCRIPT" >/dev/null
if rg -n 'RuaKey-notary' "$ROOT/README.md" "$ROOT/RELEASING.md" "$ROOT/script" "$ROOT/.claude" >/dev/null; then
  echo "legacy notarization profile name must not remain in release configuration" >&2
  exit 1
fi
grep -F -- '--timeout 30m' "$SCRIPT" >/dev/null
grep -F -- '--no-s3-acceleration' "$SCRIPT" >/dev/null

if BAD_RESUME_OUTPUT="$(bash "$SCRIPT" --resume '../../outside-dist' 2>&1)"; then
  echo "malformed submission IDs must be rejected" >&2
  exit 1
fi
grep -F '无效的 Submission ID' <<<"$BAD_RESUME_OUTPUT" >/dev/null

if grep -E 'codesign .*--force .*--deep|codesign .*--deep .*--force' "$SCRIPT" >/dev/null; then
  echo "release signing must recurse explicitly instead of using codesign --deep" >&2
  exit 1
fi

if grep -E 'AuthKey_|\.p8|store-credentials' "$SCRIPT" >/dev/null; then
  echo "release script must consume a keychain profile, not raw API credentials" >&2
  exit 1
fi

echo "release script contract: PASS"
