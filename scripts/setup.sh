#!/usr/bin/env bash
# O-Matic Server — first-run setup / embedding-key onboarding.
#
# Makes a fresh factory BYO-key instead of inheriting anyone else's OpenAI key.
# Detects a missing key, guides the operator to create one, validates it, stores it.
#
# Connection comes from standard libpq env vars (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)
# or a single DSN in OMATIC_DB_URL. The key, if you have one, comes from OPENAI_API_KEY.
#
# Usage:
#   TENANT=myfactory PGHOST=... PGUSER=... PGDATABASE=... ./scripts/setup.sh
set -euo pipefail

TENANT="${TENANT:-omatic}"
MODEL="${OPENAI_EMBEDDING_MODEL:-text-embedding-3-small}"
PSQL=(psql ${OMATIC_DB_URL:+"$OMATIC_DB_URL"} -X -A -t -q)

echo "O-Matic Server setup — factory '${TENANT}'"
echo

# 1. Ensure the embedding model is configured (no key yet — that's fine).
"${PSQL[@]}" -c "INSERT INTO public.factory_config (tenant_id, category, key, value)
  VALUES ('${TENANT}','embedding','openai_embedding_model', to_jsonb('${MODEL}'::text))
  ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;" >/dev/null
echo "Embedding model set to ${MODEL}."

# 2. Find a key: env first, then DB.
KEY="${OPENAI_API_KEY:-}"
if [ -z "$KEY" ]; then
  KEY="$("${PSQL[@]}" -c "SELECT value #>> '{}' FROM public.factory_config
    WHERE tenant_id='${TENANT}' AND category='embedding' AND key='openai_api_key';" || true)"
fi

if [ -z "$KEY" ]; then
  cat <<'GUIDE'

No OpenAI embedding key found. The factory will run in FTS-only mode (keyword
search works; semantic/vector search is disabled) until you add one.

To create a key:
  1. Go to https://platform.openai.com  and sign in (or sign up).
  2. Add a payment method  —  https://platform.openai.com/account/billing
     (embeddings require a paid account; free trial credit may not cover them).
  3. Create a key       —  https://platform.openai.com/api-keys  ->  "Create new secret key"
  4. Paste it below.

Cost: the default model (text-embedding-3-small) is ~$0.02 per 1M tokens. A typical
factory embeds a few writes a day — pennies per year. This is not a meaningful cost.

GUIDE
  read -r -p "Paste your OpenAI API key (or press Enter to stay FTS-only): " KEY
  echo
fi

if [ -z "$KEY" ]; then
  echo "No key provided. Factory will operate FTS-only. Re-run setup, or set OPENAI_API_KEY, to enable vector search."
  exit 0
fi

# 3. Validate the key with a 1-token test embedding.
echo "Validating key against the OpenAI embeddings endpoint..."
DIMS="$(curl -fsS https://api.openai.com/v1/embeddings \
  -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"input\":\"ok\"}" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || echo "0")"

if [ "$DIMS" != "1536" ]; then
  echo "Key validation FAILED (expected 1536 dims, got '${DIMS}'). Check the key, billing, and model access. Nothing stored." >&2
  exit 1
fi
echo "Key valid (${DIMS}-dim embeddings)."

# 4. Store the key. Recommend env for production; offer DB storage for convenience.
echo
echo "Where should the key live?"
echo "  [e] environment variable only (recommended — keeps the secret out of the DB and backups)"
echo "  [d] store in factory_config (convenient, single-DB, but lands in pg_dump backups)"
read -r -p "Choice [e/d]: " WHERE
if [ "${WHERE:-e}" = "d" ]; then
  "${PSQL[@]}" -c "INSERT INTO public.factory_config (tenant_id, category, key, value)
    VALUES ('${TENANT}','embedding','openai_api_key', to_jsonb('${KEY}'::text))
    ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;" >/dev/null
  echo "Key stored in factory_config for tenant '${TENANT}'."
else
  echo "Keep this in your environment:  export OPENAI_API_KEY='...'  (embed_stale.py reads it first)."
fi

# 5. Backfill any rows that accumulated while keyless.
echo
echo "Backfilling embeddings for any stale/unembedded rows..."
OPENAI_API_KEY="$KEY" python3 "$(dirname "$0")/embed_stale.py" || true
echo "Setup complete."
