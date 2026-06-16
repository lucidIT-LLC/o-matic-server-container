#!/usr/bin/env bash
# Mint an O-Matic Server license key. lucidIT-LLC internal tool.
#
# Requires the PRIVATE signing key — operator-held, NEVER committed or shipped in
# the image. The container verifies keys minted here against the embedded public key.
#
# Usage:
#   OMATIC_LICENSE_PRIVKEY=/secure/omatic-license-priv.pem \
#     scripts/issue-license.sh "Acme Corp" [2027-06-15]
#
#   arg1 = licensee (required)   arg2 = expiry YYYY-MM-DD (optional, omit = perpetual)
set -euo pipefail

PRIV="${OMATIC_LICENSE_PRIVKEY:-keys/omatic-license-priv.pem}"
licensee="${1:?usage: issue-license.sh <licensee> [expires YYYY-MM-DD]}"
expires="${2:-}"
[ -f "$PRIV" ] || { echo "private signing key not found: $PRIV" >&2; exit 1; }

issued="$(date -u +%Y-%m-%d)"
if [ -n "$expires" ]; then
  payload="{\"licensee\":\"$licensee\",\"issued\":\"$issued\",\"expires\":\"$expires\"}"
else
  payload="{\"licensee\":\"$licensee\",\"issued\":\"$issued\"}"
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# Ed25519 (-rawin) needs the input as a real file, not a pipe ("oneshot" requires a size).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s' "$payload" > "$tmp/payload.bin"
sig="$(openssl pkeyutl -sign -inkey "$PRIV" -rawin -in "$tmp/payload.bin" | b64url)"
printf '%s.%s\n' "$(printf '%s' "$payload" | b64url)" "$sig"
