#!/usr/bin/env python3
"""
embed_stale.py - O-Matic canonical Tier-1 + Tier-2 embedder.

Refreshes stale/unembedded rows in:
  - public.semantic_index  (Tier 1 - entity catalog, uses summary_text)
  - public.document_chunks (Tier 2 - full content, uses content)

Both passes run sequentially for tenant "omatic".

Design constraints:
  - stdlib only: urllib for OpenAI, subprocess + psql for Postgres
  - no psycopg2, no OpenAI SDK
  - credentials come from public.factory_config category='embedding'
  - every read/write is tenant-scoped
  - current_database() must be "o-matic" or the script refuses to run

Usage:
    python3 _omatic/scripts/embed_stale.py
    OMATIC_DB_URL=postgresql://... python3 _omatic/scripts/embed_stale.py
"""

import json
import os
import pathlib
import subprocess
import sys
import urllib.request

EXPECTED_DB = "o-matic"
SCHEMA = "public"
TENANT = "omatic"
BATCH_SIZE = 50
EXPECTED_DIM = 1536
DEFAULT_MODEL = "text-embedding-3-small"


def repo_root():
    return pathlib.Path(__file__).resolve().parents[2]


def load_default_dsn():
    factory_path = repo_root() / ".omatic" / "factory.json"
    try:
        config = json.loads(factory_path.read_text())
    except FileNotFoundError:
        return None

    connections = config.get("connections") or []
    for entry in connections:
        if isinstance(entry, str):
            return entry
        if isinstance(entry, dict) and entry.get("database") == EXPECTED_DB:
            host = entry["host"]
            port = entry.get("port", 5432)
            database = entry["database"]
            user = entry["user"]
            password = entry.get("password", "")
            ssl_mode = entry.get("ssl_mode") or entry.get("sslMode")
            auth = f"{user}:{password}" if password else user
            dsn = f"postgresql://{auth}@{host}:{port}/{database}"
            if ssl_mode:
                dsn += f"?sslmode={ssl_mode}"
            return dsn
    return config.get("database_url") or config.get("databaseUrl")


DB_DSN = os.environ.get("OMATIC_DB_URL") or load_default_dsn()


def sql_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def psql(sql):
    if not DB_DSN:
        raise RuntimeError("OMATIC_DB_URL is not set and .omatic/factory.json has no usable O-Matic connection.")
    cmd = ["psql", DB_DSN, "-X", "-v", "ON_ERROR_STOP=1", "-tA", "-c", sql]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "psql failed")
    return result.stdout.strip()


def unwrap_json_scalar(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (TypeError, ValueError, json.JSONDecodeError):
            return value
    return value


def assert_db():
    db = psql("SELECT current_database();")
    if db != EXPECTED_DB:
        print(
            f"ERROR: connected to {db!r}, expected {EXPECTED_DB!r}. "
            "Refusing to run - wrong factory DB.",
            file=sys.stderr,
        )
        sys.exit(2)


def get_embedding_config():
    raw = psql(
        "SELECT coalesce(json_object_agg(key, value), '{}'::json) "
        f"FROM {SCHEMA}.factory_config "
        f"WHERE tenant_id = {sql_quote(TENANT)} AND category = 'embedding';"
    )
    config = json.loads(raw or "{}")
    return {k: unwrap_json_scalar(v) for k, v in config.items()}


def get_stale_rows():
    raw = psql(
        "SELECT coalesce(json_agg(json_build_object('id', id, 'text', summary_text) ORDER BY id), '[]'::json) "
        f"FROM {SCHEMA}.semantic_index "
        f"WHERE tenant_id = {sql_quote(TENANT)} "
        "AND (embedding IS NULL OR embedding_stale = true);"
    )
    return json.loads(raw or "[]")


def embed_texts(api_key, model, texts):
    payload = {"model": model, "input": texts}
    request = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))
    return [item["embedding"] for item in sorted(data["data"], key=lambda item: item["index"])]


def write_embedding(row_id, vector, model):
    literal = "[" + ",".join(repr(round(float(v), 8)) for v in vector) + "]"
    psql(
        f"UPDATE {SCHEMA}.semantic_index "
        "SET "
        f"embedding = {sql_quote(literal)}::vector, "
        "embedding_stale = false, "
        f"model_version = {sql_quote(model)}, "
        "embedded_at = now() "
        f"WHERE id = {int(row_id)} AND tenant_id = {sql_quote(TENANT)};"
    )


def get_stale_chunks():
    raw = psql(
        "SELECT coalesce(json_agg(json_build_object('id', id, 'text', content) ORDER BY id), '[]'::json) "
        f"FROM {SCHEMA}.document_chunks "
        f"WHERE tenant_id = {sql_quote(TENANT)} "
        "AND (embedding IS NULL OR embedding_stale = true);"
    )
    return json.loads(raw or "[]")


def write_chunk_embedding(row_id, vector, model):
    literal = "[" + ",".join(repr(round(float(v), 8)) for v in vector) + "]"
    psql(
        f"UPDATE {SCHEMA}.document_chunks "
        "SET "
        f"embedding = {sql_quote(literal)}::vector, "
        "embedding_stale = false, "
        f"model_version = {sql_quote(model)}, "
        "embedded_at = now() "
        f"WHERE id = {int(row_id)} AND tenant_id = {sql_quote(TENANT)};"
    )


def embed_tier(label, rows, api_key, model, write_fn):
    if not rows:
        print(f"embed_stale [{label}]: nothing to do - clean")
        return 0
    print(f"embed_stale [{label}]: {len(rows)} stale rows (tenant={TENANT}, model={model})")
    total = 0
    for offset in range(0, len(rows), BATCH_SIZE):
        batch = rows[offset : offset + BATCH_SIZE]
        texts = [(row.get("text") or "")[:8000] for row in batch]
        vectors = embed_texts(api_key, model, texts)
        dims = {len(vector) for vector in vectors}
        if dims != {EXPECTED_DIM}:
            raise RuntimeError(f"[{label}] unexpected embedding dims {sorted(dims)}, expected {EXPECTED_DIM}")
        for row, vector in zip(batch, vectors):
            write_fn(row["id"], vector, model)
        total += len(batch)
        print(f"  [{label}] batch {offset // BATCH_SIZE + 1}: embedded {len(batch)} (total {total}/{len(rows)})")
    return total


def main():
    assert_db()
    config = get_embedding_config()
    # Key source: env-first, DB-fallback. OPENAI_API_KEY keeps the secret out of
    # the database and backups; factory_config.openai_api_key is the convenience fallback.
    api_key = os.environ.get("OPENAI_API_KEY") or config.get("openai_api_key")
    model = config.get("openai_embedding_model") or DEFAULT_MODEL
    if not api_key:
        print(
            "ERROR: no OpenAI key. Set the OPENAI_API_KEY env var, or store it in "
            "public.factory_config (category='embedding', key='openai_api_key'). "
            "Run scripts/setup.sh to configure one. Vector search stays FTS-only until a key is provided.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Tier 1 - semantic_index (entity catalog)
    t1_total = embed_tier("tier1:semantic_index", get_stale_rows(), api_key, model, write_embedding)

    # Tier 2 - document_chunks (full content)
    t2_total = embed_tier("tier2:document_chunks", get_stale_chunks(), api_key, model, write_chunk_embedding)

    t1_remaining = psql(
        f"SELECT count(*) FROM {SCHEMA}.semantic_index "
        f"WHERE tenant_id = {sql_quote(TENANT)} AND (embedding IS NULL OR embedding_stale = true);"
    )
    t2_remaining = psql(
        f"SELECT count(*) FROM {SCHEMA}.document_chunks "
        f"WHERE tenant_id = {sql_quote(TENANT)} AND (embedding IS NULL OR embedding_stale = true);"
    )
    print(
        f"embed_stale: done - tier1 embedded={t1_total} remaining={t1_remaining} | "
        f"tier2 embedded={t2_total} remaining={t2_remaining}"
    )


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
