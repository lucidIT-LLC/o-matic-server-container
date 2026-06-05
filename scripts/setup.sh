#!/usr/bin/env bash
# O-Matic Server — one-command setup.
#
# Orchestrates the whole bring-up: loads the schema (if absent), schedules in-DB
# maintenance, then runs the bring-your-own-key embedding onboarding. The SQL
# files in sql/ are the artifacts this applies; this script is the entry point.
#
# The only step this can't do for you is enabling pg_cron — that needs
# shared_preload_libraries = 'pg_cron' plus a container restart (see README).
# If pg_cron isn't ready, maintenance scheduling is skipped with a notice and the
# rest of setup still completes; just re-run this once pg_cron is enabled.
#
# Connection: standard libpq env vars (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)
# or a single DSN in OMATIC_DB_URL. Key, if you have one: OPENAI_API_KEY.
#
# Usage:  TENANT=myfactory PGHOST=... PGUSER=... PGDATABASE=... ./scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
TENANT="${TENANT:-omatic}"
MODEL="${OPENAI_EMBEDDING_MODEL:-text-embedding-3-small}"
PSQL=(psql ${OMATIC_DB_URL:+"$OMATIC_DB_URL"} -X -A -t -q)

echo "O-Matic Server setup — factory '${TENANT}'"
echo

# --- 1. Schema (load only if not already present) --------------------------
if [ "$("${PSQL[@]}" -c "SELECT to_regclass('public.semantic_index') IS NOT NULL;")" = "t" ]; then
  echo "[1/3] Schema already present — skipping."
else
  echo "[1/3] Loading schema (sql/01_schema.sql)..."
  "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$ROOT/sql/01_schema.sql" >/dev/null
  echo "      Schema loaded."
fi

# --- 2. In-DB maintenance (tolerate pg_cron not yet enabled) ----------------
echo "[2/3] Scheduling in-DB maintenance (sql/02_bootstrap.sql)..."
if "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$ROOT/sql/02_bootstrap.sql" >/dev/null 2>&1; then
  echo "      Maintenance scheduled (hourly fn_refresh_dashboards)."
else
  echo "      SKIPPED — pg_cron not enabled yet. Set shared_preload_libraries='pg_cron',"
  echo "      restart, then re-run this script (or: psql -f sql/02_bootstrap.sql). Continuing."
fi

# --- 3. Embedding key onboarding (bring your own) --------------------------
echo "[3/3] Embedding key..."
"${PSQL[@]}" -c "INSERT INTO public.factory_config (tenant_id, category, key, value)
  VALUES ('${TENANT}','embedding','openai_embedding_model', to_jsonb('${MODEL}'::text))
  ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;" >/dev/null
echo "      Embedding model set to ${MODEL}."

KEY="${OPENAI_API_KEY:-}"
if [ -z "$KEY" ]; then
  KEY="$("${PSQL[@]}" -c "SELECT value #>> '{}' FROM public.factory_config
    WHERE tenant_id='${TENANT}' AND category='embedding' AND key='openai_api_key';" || true)"
fi

if [ -z "$KEY" ]; then
  cat <<'GUIDE'

      No OpenAI embedding key found. The factory will run FTS-only (keyword
      search works; vector search disabled) until you add one.

      To create a key:
        1. https://platform.openai.com           — sign in / sign up
        2. https://platform.openai.com/account/billing  — add a payment method
           (embeddings need a paid account; trial credit may not cover them)
        3. https://platform.openai.com/api-keys   — "Create new secret key"
        4. Paste it below.

      Cost: text-embedding-3-small is ~$0.02 per 1M tokens. A factory embeds a
      few writes a day — pennies per year. Not a meaningful cost.

GUIDE
  read -r -p "      Paste your OpenAI API key (or Enter to stay FTS-only): " KEY
  echo
fi

if [ -z "$KEY" ]; then
  echo "      No key provided. Operating FTS-only. Re-run setup (or set OPENAI_API_KEY) to enable vector search."
  echo
  echo "Setup complete (FTS-only)."
  exit 0
fi

echo "      Validating key against the OpenAI embeddings endpoint..."
DIMS="$(curl -fsS https://api.openai.com/v1/embeddings \
  -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"input\":\"ok\"}" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || echo "0")"
if [ "$DIMS" != "1536" ]; then
  echo "      Key validation FAILED (expected 1536 dims, got '${DIMS}'). Check key/billing/model access. Nothing stored." >&2
  exit 1
fi
echo "      Key valid (${DIMS}-dim)."

echo "      Store the key where?  [e] env var only (recommended)  [d] factory_config (lands in backups)"
read -r -p "      Choice [e/d]: " WHERE
if [ "${WHERE:-e}" = "d" ]; then
  "${PSQL[@]}" -c "INSERT INTO public.factory_config (tenant_id, category, key, value)
    VALUES ('${TENANT}','embedding','openai_api_key', to_jsonb('${KEY}'::text))
    ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;" >/dev/null
  echo "      Key stored in factory_config for '${TENANT}'."
else
  echo "      Keep this in your environment:  export OPENAI_API_KEY='...'  (embed_stale.py reads it first)."
fi

echo "      Backfilling embeddings for any stale/unembedded rows..."
OPENAI_API_KEY="$KEY" python3 "$SCRIPT_DIR/embed_stale.py" || true
echo
echo "Setup complete."
