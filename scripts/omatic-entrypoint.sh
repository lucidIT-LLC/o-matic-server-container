#!/usr/bin/env bash
# O-Matic Server — activation-key gate.
#
# The container refuses to start without a valid OMATIC_LICENSE_KEY. The key is an
# Ed25519-signed token minted by O-Matic (scripts/issue-license.sh, private key held
# by lucidIT-LLC). This image embeds only the PUBLIC key and verifies offline — no
# phone-home. After the check it hands off to the stock Postgres entrypoint.
#
# Honest limit: this repo is public, so a determined user can remove this check and
# build their own image. The gate is activation + accountability, not hard DRM.
#
# Token format:  base64url(payload_json) "." base64url(ed25519_signature)
# payload_json:  {"licensee":"...","issued":"YYYY-MM-DD"[,"expires":"YYYY-MM-DD"]}
set -euo pipefail

PUBKEY="${OMATIC_LICENSE_PUBKEY:-/etc/omatic/omatic-license-pub.pem}"
KEY="${OMATIC_LICENSE_KEY:-}"

die() {
  echo "============================================================" >&2
  echo "  O-Matic Server — activation required" >&2
  echo "  $1" >&2
  echo "  Get a key at https://o-matic.ai  then run with:" >&2
  echo "    -e OMATIC_LICENSE_KEY=<your-key>" >&2
  echo "============================================================" >&2
  exit 1
}

[ -n "$KEY" ] || die "OMATIC_LICENSE_KEY is not set."
[ -f "$PUBKEY" ] || die "license public key missing in image ($PUBKEY)."
case "$KEY" in *.*) : ;; *) die "OMATIC_LICENSE_KEY is malformed (expected payload.signature)." ;; esac

payload_b64="${KEY%%.*}"
sig_b64="${KEY#*.}"

b64url_decode() {  # base64url -> bytes (restore padding + alphabet)
  local s="${1//-/+}"; s="${s//_//}"
  case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
  printf '%s' "$s" | openssl base64 -d -A
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
b64url_decode "$payload_b64" > "$tmp/payload.bin" 2>/dev/null || die "license payload not decodable."
b64url_decode "$sig_b64"     > "$tmp/sig.bin"     2>/dev/null || die "license signature not decodable."

openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
  -in "$tmp/payload.bin" -sigfile "$tmp/sig.bin" >/dev/null 2>&1 \
  || die "license signature is invalid (not issued by O-Matic, or tampered)."

# Optional expiry (ISO dates compare lexically).
expires="$(grep -o '"expires":"[^"]*"' "$tmp/payload.bin" | cut -d'"' -f4 || true)"
if [ -n "$expires" ]; then
  today="$(date -u +%Y-%m-%d)"
  if [[ "$today" > "$expires" ]]; then die "license expired on $expires."; fi
fi

licensee="$(grep -o '"licensee":"[^"]*"' "$tmp/payload.bin" | cut -d'"' -f4 || true)"
echo "O-Matic Server: license verified — licensee: ${licensee:-unknown}${expires:+, expires $expires}"

# Hand off to the stock Postgres entrypoint.
exec docker-entrypoint.sh "$@"
