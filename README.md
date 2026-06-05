# O-Matic Server

The database brain for O-Matic factories: **PostgreSQL 18 + pgvector (HNSW) + pg_cron**, packaged as a container image with a reproducible schema and a bring-your-own-key embedding path. Single database — no external vector store.

## What's in the image

- **PostgreSQL 18** (from upstream `pgvector/pgvector:pg18` — pgvector auto-updates on rebuild)
- **pgvector** with **HNSW** vector indexes (the only index method used)
- **pg_cron** for in-database scheduled maintenance
- gosu rebuilt from current Go (clears the stdlib CVEs in upstream's bundled binary)

> This image does **not** use pgvectorscale / diskann. The brain runs on pgvector HNSW alone. (Earlier builds carried a `pg18-vectorscale` tag and an unused vectorscale build stage — both removed.)

## Memory architecture

| Tier | Table | Index |
|------|-------|-------|
| 1 | `semantic_index` (entity catalog + embeddings) | HNSW on `embedding`, GIN on `tsv` |
| 2 | `document_chunks` (long-form chunks + embeddings) | HNSW on `embedding`, GIN on `tsv` |
| 3 | source tables (rules, SOPs, tasks, decisions, knowledge, brand, identity) | normal relational |

Retrieval is hybrid (FTS + vector via RRF). Embeddings are OpenAI `text-embedding-3-small` (1536-d). See `docs/` for the full standard.

**Catalog integrity (the contract):** every Tier-1 source has **three** triggers — INSERT seeds the catalog row, UPDATE marks it stale, DELETE cascades. The INSERT seed is the one most setups forget; without it, new rows silently never reach vector search. Each catalog row carries an `authority_tier` (sacred / canon / operational / experimental / archived / deprecated), assigned at write time, so retrieval can weight trusted memory over noise.

## Setup

1. **Start the container** against a data volume.
2. **Enable pg_cron** — one-time, and the only step that needs a restart (it's a Postgres preload requirement):
   ```sql
   ALTER SYSTEM SET shared_preload_libraries = 'pg_cron';   -- then restart the container
   ```
3. **Run setup** — loads the schema, schedules maintenance, and onboards your key:
   ```bash
   TENANT=myfactory ./scripts/setup.sh
   ```

`setup.sh` is the single entry point: it loads `sql/01_schema.sql` if the schema is absent, applies the `sql/02_bootstrap.sql` maintenance job (skipped with a notice if pg_cron isn't enabled yet — just re-run after step 2), then guides you through creating an OpenAI key, validates it, stores it (env or DB, your choice), and backfills embeddings. Until a key is present the factory runs **FTS-only** — keyword search works, vector search is disabled; it never hard-fails. The `sql/` files remain runnable on their own if you prefer to apply them manually.

## Maintenance

- **In-DB (pg_cron):** hourly `fn_refresh_dashboards()` keeps the materialized views current between sessions. Installed by `sql/02_bootstrap.sql`.
- **External (GitHub Action / host cron):** nightly `scripts/embed_stale.py` + `ANALYZE`. Postgres cannot call OpenAI, so the embedding refresh must run outside the database. See `.github/workflows/maintenance.yml`.

Autovacuum handles the rest at typical factory write volume — no manual vacuum or pruning jobs.

## Keys & security

- Key source is **env-first, DB-fallback**: `OPENAI_API_KEY` takes precedence over `factory_config.openai_api_key`. Env keeps the secret out of the database and backups.
- **Bring your own key, per factory** — each factory runs on its own OpenAI billing. This image ships with **no key baked in**; `sql/01_schema.sql` is schema-only (no data, no secrets).

## License

See `LICENSE`.
