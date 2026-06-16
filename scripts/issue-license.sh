#!/usr/bin/env bash
# Mint an O-Matic Server license key. lucidIT-LLC internal tool.
#
# The private signing key lives ON THE O-MATIC SERVER (factory_config, category
# 'licensing', key 'omatic_license_signing_key_private') — stored there so it is
# retrievable in an instant and is not left loose on disk. This tool fetches it from
# the server, signs, and shreds the temp copy. Override with a local file via
# OMATIC_LICENSE_PRIVKEY=/path/key.pem if you must sign offline.
#
# Usage:
#   scripts/issue-license.sh "Acme Corp" [2027-06-15]
#     arg1 = licensee (required)   arg2 = expiry YYYY-MM-DD (optional, omit = perpetual)
#   Connection: OMATIC_DB_URL=postgresql://...  (or resolved from ./.omatic/factory.json)
set -euo pipefail

licensee="${1:?usage: issue-license.sh <licensee> [expires YYYY-MM-DD]}"
expires="${2:-}"

resolve_dsn() {
  [ -n "${OMATIC_DB_URL:-}" ] && { printf '%s' "$OMATIC_DB_URL"; return; }
  local fj="${OMATIC_FACTORY_JSON:-./.omatic/factory.json}"
  [ -f "$fj" ] || { echo "no OMATIC_DB_URL and no $fj" >&2; exit 1; }
  python3 - "$fj" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
conns=c.get('connections') or c.get('factory',{}).get('connections',[])
for x in conns:
    if x.get('name')=='omatic':
        print(f"postgresql://{x['user']}:{x['password']}@{x['host']}:{x['port']}/{x['database']}"); break
PY
}

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
priv="$tmp/priv.pem"

if [ -n "${OMATIC_LICENSE_PRIVKEY:-}" ] && [ -f "$OMATIC_LICENSE_PRIVKEY" ]; then
  cp "$OMATIC_LICENSE_PRIVKEY" "$priv"
else
  DSN="$(resolve_dsn)"
  psql "$DSN" -X -tA -c \
    "SELECT value #>> '{}' FROM factory_config WHERE key='omatic_license_signing_key_private' AND tenant_id='omatic'" \
    > "$priv"
  [ -s "$priv" ] || { echo "signing key not found on the O-Matic Server (factory_config/licensing)." >&2; exit 1; }
fi
chmod 600 "$priv"

issued="$(date -u +%Y-%m-%d)"
if [ -n "$expires" ]; then
  payload="{\"licensee\":\"$licensee\",\"issued\":\"$issued\",\"expires\":\"$expires\"}"
else
  payload="{\"licensee\":\"$licensee\",\"issued\":\"$issued\"}"
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# Ed25519 (-rawin) needs the input as a real file, not a pipe.
printf '%s' "$payload" > "$tmp/payload.bin"
sig="$(openssl pkeyutl -sign -inkey "$priv" -rawin -in "$tmp/payload.bin" | b64url)"
printf '%s.%s\n' "$(printf '%s' "$payload" | b64url)" "$sig"
