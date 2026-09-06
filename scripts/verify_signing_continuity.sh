#!/usr/bin/env bash
# Prove that two certificate-signed HushType builds retain the same TCC-facing
# designated requirement while still being different code directories.
set -euo pipefail

usage() {
  echo "usage: $0 <old-HushType.app> <new-HushType.app>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

old_app=$1
new_app=$2
expected_identifier='com.felix.hushtype'
script_dir=$(cd "$(dirname "$0")" && pwd)
expected_leaf_sha1=$(tr -d '[:space:]' < "$script_dir/release-signing.sha1")

for app_path in "$old_app" "$new_app"; do
  [[ -d "$app_path" ]] || { echo "error: app bundle does not exist: $app_path" >&2; exit 66; }
  codesign --verify --deep --strict "$app_path"
done

old_details=$(codesign -d --verbose=4 "$old_app" 2>&1)
if grep -qx 'Signature=adhoc' <<<"$old_details"; then
  echo "error: old app is ad-hoc signed; a certificate-signed baseline is required for continuity verification" >&2
  exit 65
fi

bundle_identifier() {
  codesign -d --verbose=4 "$1" 2>&1 | awk -F= '/^Identifier=/{ print $2 }'
}

info_plist_identifier() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

leaf_sha1() (
  app_path=$1
  # Extract public certificates outside Trash: codesign may be denied direct
  # access to Trash by TCC even when the invoking shell can move files there.
  cert_dir=$(mktemp -d "${TMPDIR:-/tmp}/hushtype-signing-cert.XXXXXX")
  trap 'mv "$cert_dir" "${HOME}/.Trash/" || echo "Public certificate workspace retained: $cert_dir" >&2' EXIT
  if ! codesign -d --extract-certificates="$cert_dir/cert" "$app_path" >/dev/null 2>&1; then
    echo "error: could not extract a leaf certificate from $app_path" >&2
    return 1
  fi
  cert_path="$cert_dir/cert0"
  if [[ ! -s "$cert_path" ]]; then
    echo "error: no leaf certificate found in $app_path" >&2
    return 1
  fi
  fingerprint=$(openssl x509 -inform der -in "$cert_path" -noout -fingerprint -sha1 | sed 's/.*=//' | tr -d ':')
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || { echo "error: could not read leaf SHA-1 from $app_path" >&2; return 1; }
  printf '%s\n' "$fingerprint"
)

actual_designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

cdhash() {
  codesign -d --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{ print $2 }'
}

old_identifier=$(bundle_identifier "$old_app")
new_identifier=$(bundle_identifier "$new_app")
[[ "$old_identifier" == "$expected_identifier" && "$new_identifier" == "$expected_identifier" ]] || {
  echo "error: both bundles must identify as $expected_identifier (old=$old_identifier, new=$new_identifier)" >&2
  exit 65
}
old_info_identifier=$(info_plist_identifier "$old_app")
new_info_identifier=$(info_plist_identifier "$new_app")
[[ "$old_info_identifier" == "$expected_identifier" && "$new_info_identifier" == "$expected_identifier" ]] || {
  echo "error: both Info.plist files must identify as $expected_identifier (old=$old_info_identifier, new=$new_info_identifier)" >&2
  exit 65
}

old_leaf=$(leaf_sha1 "$old_app")
new_leaf=$(leaf_sha1 "$new_app")
[[ "$old_leaf" == "$expected_leaf_sha1" && "$new_leaf" == "$expected_leaf_sha1" ]] || {
  echo "error: both bundles must use the fixed certificate $expected_leaf_sha1" >&2
  exit 65
}

# `codesign -d -r-` canonicalizes the hexadecimal requirement literal to
# lowercase, while OpenSSL emits the certificate fingerprint in uppercase.
expected_requirement_leaf=$(printf '%s' "$expected_leaf_sha1" | tr '[:upper:]' '[:lower:]')
expected_requirement="identifier \"$expected_identifier\" and certificate leaf = H\"$expected_requirement_leaf\""
old_requirement=$(actual_designated_requirement "$old_app")
new_requirement=$(actual_designated_requirement "$new_app")
[[ "$old_requirement" == "$expected_requirement" && "$new_requirement" == "$expected_requirement" ]] || {
  echo "error: both bundles must carry the fixed designated requirement" >&2
  exit 65
}

# Read each recorded DR, then require the other app to satisfy that exact DR.
codesign --verify --deep --strict -R "=$old_requirement" "$new_app"
codesign --verify --deep --strict -R "=$new_requirement" "$old_app"

old_cdhash=$(cdhash "$old_app")
new_cdhash=$(cdhash "$new_app")
[[ -n "$old_cdhash" && -n "$new_cdhash" ]] || { echo "error: could not read both CDHash values" >&2; exit 65; }
[[ "$old_cdhash" != "$new_cdhash" ]] || { echo "error: old and new bundles have the same CDHash; this is not a distinct update" >&2; exit 65; }

echo "Signing continuity verified"
echo "  identifier: $expected_identifier"
echo "  certificate SHA-1: $expected_leaf_sha1"
echo "  old CDHash: $old_cdhash"
echo "  new CDHash: $new_cdhash"
