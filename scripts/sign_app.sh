#!/usr/bin/env bash
# Sign the outer HushType bundle with one fixed local certificate.
# Nested Sparkle components are deliberately left untouched: --deep is only
# used during verification because re-signing Sparkle's helpers/XPC services
# as a flat bundle is unsafe.
set -euo pipefail

usage() {
  echo "usage: $0 <HushType.app> <required-code-signing-identity-sha1>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

app_path=$1
identity_sha1=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
bundle_identifier='com.felix.hushtype'

[[ -d "$app_path" ]] || { echo "error: app bundle does not exist: $app_path" >&2; exit 66; }
[[ "$identity_sha1" =~ ^[0-9A-F]{40}$ ]] || {
  echo "error: identity must be an exact 40-character SHA-1 fingerprint" >&2
  exit 64
}
info_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)
[[ "$info_identifier" == "$bundle_identifier" ]] || {
  echo "error: app Info.plist must identify as $bundle_identifier (found: ${info_identifier:-missing})" >&2
  exit 65
}

# A SHA-1 fingerprint is required so codesign can never choose a similarly
# named identity. Refuse before signing if that exact usable identity is absent.
if ! security find-identity -v -p codesigning | awk -v sha="$identity_sha1" '
  $2 == sha { found = 1 }
  END { exit(found ? 0 : 1) }
'; then
  echo "error: usable code-signing identity not found for SHA-1 $identity_sha1" >&2
  exit 69
fi

requirement_clause="identifier \"$bundle_identifier\" and certificate leaf = H\"$identity_sha1\""
# `--requirements` consumes a requirements-set expression, not a bare runtime
# requirement. The leading `=` keeps it inline rather than treating it as a
# filename, and names the designated-requirement slot explicitly.
designated_requirement="=designated => $requirement_clause"
test_requirement="=$requirement_clause"

codesign --force \
  --sign "$identity_sha1" \
  --identifier "$bundle_identifier" \
  --requirements "$designated_requirement" \
  "$app_path"

# Verify both integrity and the exact stable identity/identifier requirement.
codesign --verify --deep --strict -R "$test_requirement" "$app_path"
expected_display_leaf=$(printf '%s' "$identity_sha1" | tr '[:upper:]' '[:lower:]')
expected_recorded_requirement="identifier \"$bundle_identifier\" and certificate leaf = H\"$expected_display_leaf\""
recorded_requirement=$(codesign -d -r- "$app_path" 2>&1 | sed -n 's/^designated => //p')
[[ "$recorded_requirement" == "$expected_recorded_requirement" ]] || {
  echo "error: signed app did not retain the expected designated requirement" >&2
  exit 65
}
echo "Signed and verified $app_path with fixed identity $identity_sha1"
