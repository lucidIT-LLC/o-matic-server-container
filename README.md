# O-Matic Server

> **What this is:** the self-hosted database brain for an O-Matic factory — a Docker image.
> **What this is NOT:** a plugin, an MCP server, or anything you install into Claude Code or Codex.
> To connect an agent to this server, use the **o-matic-server-connection** plugin.

The **database brain** for an O-Matic factory. An O-Matic factory is a set of AI agents that share persistent memory, governed rules, task state, and decision history — none of which survives in a chat window. This server is where all of that lives: **PostgreSQL 18 + pgvector (HNSW) + pg_cron**, packaged as a container image with a reproducible schema and a bring-your-own-key embedding path. One database — no external vector store, no second system to coordinate.

If you connect an O-Matic agent (Probot, Fred, Data, …) to this server, the agent gains: semantic + keyword recall over everything the factory knows, rules it must follow, a task board, a decision log, and an audit trail. Without it, the agents still run — they just start blank every session.

## Activation key

This image is **free to pull and public to inspect**, but the container **requires an activation key** to start. Pass an O-Matic-issued key as `OMATIC_LICENSE_KEY`:

```bash
docker run -e OMATIC_LICENSE_KEY="<your-key>" -v omatic-data:/var/lib/postgresql/data ghcr.io/lucidit-llc/o-matic-server-container
```

Without a valid key the container exits immediately with instructions. **Get a key at [o-matic.ai](https://o-matic.ai).**

**How it works:** the key is an Ed25519-signed token (`payload.signature`). The image embeds only the **public** key and verifies the signature **offline at startup** — no phone-home, nothing leaves your host. lucidIT-LLC holds the private signing key, so keys can't be forged. Honest scope: this repo is public, so the check is **activation + accountability, not hard DRM** — a determined user could fork and remove it. Keys may carry an optional expiry. See `scripts/omatic-entrypoint.sh` (the gate) and `scripts/issue-license.sh` (issuer, private-key-only).

## Requirements

- **A container host** — Docker or Podman (Unraid, a Linux box, a VPS, etc.) with a **persistent volume** for the Postgres data directory. ~1 GB RAM and a modest CPU are plenty for a single factory.
- **`psql`** (PostgreSQL client) on whatever machine runs setup.
- **Python 3** (standard library only — no pip installs) for the embedding refresh script.
- **An OpenAI API key** *(optional)* for embeddings. Without one, the factory runs **FTS-only** (keyword search works, semantic search is off) and never fails — add a key any time via `setup.sh`. Embeddings use `text-embedding-3-small`; cost is ~$0.02 per 1M tokens (pennies/year at typical volume).
- **Network egress to `api.openai.com`** from wherever the embedding script runs (the host, or a CI runner). Postgres itself never calls out — it can't, by design.

## What's in the image

- **PostgreSQL 18** (from upstream `pgvector/pgvector:pg18` — pgvector auto-updates on rebuild)
- **pgvector** with **HNSW** vector indexes (the only index method used)
- **pg_cron** for in-database scheduled maintenance
- gosu rebuilt from current Go (clears the stdlib CVEs in upstream's bundled binary)

> The brain runs on **pgvector HNSW** alone — HNSW is the only vector index method.

## Memory architecture

| Tier | Table | Index |
|------|-------|-------|
| 1 | `semantic_index` (entity catalog + embeddings) | HNSW on `embedding`, GIN on `tsv` |
| 2 | `document_chunks` (long-form chunks + embeddings) | HNSW on `embedding`, GIN on `tsv` |
| 3 | source tables (rules, SOPs, tasks, decisions, knowledge, brand, identity) | normal relational |

Retrieval is hybrid (FTS + vector via RRF). Embeddings are OpenAI `text-embedding-3-small` (1536-d). See `docs/` for the full standard.

**Schema layout (private kernel, public interface):** state lives in purpose schemas — `factory.*` (config, rules, SOPs, sessions, decisions, tasks, agreements, personas), `brain.*` (semantic_index, document_chunks, knowledge), `brand.*` — and `public` holds **only** the interface (views + functions; no base tables). `setup.sh` sets the database `search_path` to `public, factory, brain, brand` and revokes `USAGE` on the kernel schemas from `PUBLIC`, so callers reach the factory through the public interface, never the kernel directly.

**Catalog integrity (the contract):** every Tier-1 source has **three** triggers — INSERT seeds the catalog row, UPDATE marks it stale, DELETE cascades. The INSERT seed is the one most setups forget; without it, new rows silently never reach vector search. Each catalog row carries an `authority_tier` (sacred / canon / operational / experimental / archived / deprecated), assigned at write time, so retrieval can weight trusted memory over noise.

## Setup

1. **Start the container** against a data volume, with your `OMATIC_LICENSE_KEY` set (see [Activation key](#activation-key)). The container won't start without it.
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
