# Factory Vector Memory Design Standard

Updated: 2026-06-07

This document defines the portable vector-memory design for an O-Matic factory. Any factory using the O-Matic Server should be able to implement retrieval from this file without inheriting project-specific assumptions from another factory.

## Design Position

The factory brain is a PostgreSQL database with `pgvector`. It is not an external vector database and does not depend on retired vector backends.

Required position:

- PostgreSQL is the system of record.
- `pgvector` stores embeddings in the same database as operational truth.
- HNSW is the required vector index family for factory recall.
- GIN is the required full-text index family for keyword recall.
- Hybrid retrieval combines full-text search and vector search before the LLM answers.
- Operational truth remains in structured source tables; vector memory is a retrieval layer, not the source of truth.

Do not introduce a second vector backend unless the factory explicitly changes architecture.

## Memory Tiers

| Tier | Table | Purpose | Required Indexes |
|---|---|---|---|
| Tier 1 | `semantic_index` | Entity-level recall and source pointers | HNSW on `embedding`; GIN on stored `tsv` |
| Tier 2 | `document_chunks` | Deep retrieval over long-form content | HNSW on `embedding`; GIN on stored `tsv` |
| Tier 3 | source tables | Canonical truth for rules, SOPs, tasks, sessions, decisions, identity, brand, and operations | Normal relational indexes and constraints |

Tier 1 answers: "What exists and where should I look."

Tier 2 answers: "What does the full document or source content say."

Tier 3 answers: "What is true."

Agents should retrieve candidates from Tier 1 or Tier 2, then fetch authoritative detail from Tier 3 when the task requires exact state.

## Authority Tiers

Storage tiers say where a memory lives. Authority tiers say how much it can be trusted. Without authority, one stray brainstorm is ranked like a brand law — the database becomes a junk drawer where every chunk weighs the same.

Every `semantic_index` row carries an `authority_tier`:

| Tier | Meaning | Typical sources |
|------|---------|-----------------|
| `sacred` | Never casually overridden | brand manifest rows, halt-enforced rules |
| `canon` | Current accepted truth | required rules, SOPs, operator decisions, curated knowledge, agent identity |
| `operational` | Useful working state | tasks, session state |
| `experimental` | Maybe true, maybe useful | drafts, hypotheses |
| `archived` | Historical only | superseded but retained |
| `deprecated` | Known bad / superseded | retired ideas |

Classification rule (apply at write time):

- rule rows with `enforcement = 'halt'` → `sacred`; other rules → `canon`
- brand rows that are manifest entries → `sacred`; other brand rows → `canon`
- SOPs, decisions, curated knowledge, agent identity → `canon`
- tasks and working state → `operational`
- agent suggestions, brainstorms, and experiments default to `operational` and must be **promoted deliberately** by the operator or a halt/required rule — they do not earn `canon` by being written down

Higher tiers outrank lower in retrieval ranking and conflict resolution. A factory must never let `operational` memory be treated as `canon`, or `canon` as `sacred`. The seed path (below) assigns the tier automatically so new rows are never unclassified.

## Embedding Contract

Default embedding model:

```text
text-embedding-3-small
1536 dimensions
cosine distance
```

Required vector columns:

```sql
embedding vector(1536)
```

Required provenance columns:

```sql
tenant_id text not null
embedding_stale boolean not null default true
model_version text
embedded_at timestamptz
authority_tier text not null default 'operational'
```

`authority_tier` records how much a memory may be trusted in retrieval and conflict resolution. See **Authority Tiers** below. It is distinct from the storage tier (Tier 1/2/3): storage tier says *where a memory lives*; authority tier says *how much it outranks other memories*.

Each embedded tier should expose health through a view equivalent to `v_embedding_health`:

```text
tier
tenant_id
total_rows
embedded
unembedded
stale
distinct_models
oldest_embed
newest_embed
```

Healthy steady state:

```text
unembedded = 0
stale = 0
distinct_models = 1
```

## Index Contract

Required HNSW indexes:

```sql
CREATE INDEX semantic_index_embedding_hnsw
ON semantic_index
USING hnsw (embedding vector_cosine_ops)
WHERE embedding IS NOT NULL;

CREATE INDEX document_chunks_embedding_hnsw
ON document_chunks
USING hnsw (embedding vector_cosine_ops)
WHERE embedding IS NOT NULL;
```

Recommended tenant-specific HNSW indexes for multi-tenant or portable factory deployments:

```sql
CREATE INDEX semantic_index_embedding_hnsw_tenant
ON semantic_index
USING hnsw (embedding vector_cosine_ops)
WHERE tenant_id = '<factory_id>' AND embedding IS NOT NULL;

CREATE INDEX document_chunks_embedding_hnsw_tenant
ON document_chunks
USING hnsw (embedding vector_cosine_ops)
WHERE tenant_id = '<factory_id>' AND embedding IS NOT NULL;
```

Required GIN full-text indexes:

```sql
CREATE INDEX semantic_index_tsv_gin
ON semantic_index
USING gin (tsv);

CREATE INDEX document_chunks_tsv_gin
ON document_chunks
USING gin (tsv);
```

Stored `tsv` columns are preferred so search does not compute `to_tsvector(...)` at query time.

Do not use IVFFlat as the default factory index. IVFFlat can be useful in some large, memory-constrained systems, but it requires cluster/list tuning and usually trades away recall. O-Matic factories default to HNSW because interactive agent recall needs speed and high recall more than minimal index memory.

## Retrieval Order

Factory retrieval should run in this order:

1. Direct SQL for known IDs, exact records, active state, and governance truth.
2. GIN-backed full-text search for exact names, titles, acronyms, SOP IDs, task IDs, and quoted language.
3. HNSW-backed vector search for semantic similarity.
4. Hybrid reranking to merge keyword and vector candidates.
5. Tier 3 fetch for authoritative records before acting on exact state.

The LLM should not answer from vector similarity alone when exact state matters. Retrieval finds candidates; source tables establish truth.

## Search Function Shape

Factories should expose two retrieval functions:

```sql
fn_search_semantic(p_query_text text, p_query_vector vector, p_tenant_id text, p_limit integer)
fn_search_documents(p_query_text text, p_query_vector vector, p_tenant_id text, p_limit integer)
```

Required behavior:

- If `p_query_vector IS NULL`, the function runs FTS-only and returns vector distance as a neutral/default value.
- If a query vector is present, the vector branch builds an HNSW nearest-neighbor candidate set first.
- Tenant filtering is applied to the candidate set before final scoring.
- Final scoring uses hybrid reranking, such as Reciprocal Rank Fusion.
- Results include source identifiers, FTS rank, vector distance, combined score, and stale status.

The vector branch should not start by filtering all rows by tenant and then sorting the full tenant set by vector distance. That shape can prevent the planner from using HNSW at scale. Prefer:

```text
HNSW nearest-neighbor candidates -> tenant filter -> final rank
```

Candidate size should be larger than the final limit. A practical starting point:

```text
candidate_limit = greatest(p_limit * 50, 200)
```

Tune this with retrieval evals. Larger candidate sets improve recall and cost more query time.

## Hybrid Ranking

Recommended default: Reciprocal Rank Fusion.

Conceptually:

```text
combined_score =
  1 / (60 + fts_rank_position)
  +
  1 / (60 + vector_rank_position)
```

Why hybrid is required:

- FTS catches exact operational language.
- Vector search catches paraphrase and conceptual matches.
- RRF rewards rows that appear high in both lists.

Pure vector search is not the default because factory work often depends on exact names, IDs, SOP numbers, and governance terms.

## Freshness Contract

Any source-table write must keep the Tier 1 catalog complete and fresh. The most common failure is silent: a new Tier 3 row is inserted but never gets a `semantic_index` entry, so it is invisible to vector search and no health metric flags it. **Every active Tier 3 source row MUST have a matching `semantic_index` row.**

Required workflow:

1. Write the Tier 3 source row.
2. **Seed** the matching `semantic_index` row on INSERT — build `summary_text`, set `authority_tier` per the classification rule, set `embedding_stale = true`.
3. Refresh `summary_text` and mark `embedding_stale = true` when source content changes.
4. On delete, remove the matching `semantic_index` row.
5. Run the factory's canonical embed refresh path.
6. Verify `v_embedding_health` returns `stale = 0` and `unembedded = 0`.

Three triggers are REQUIRED on every Tier 1 source table — not two. A factory that installs only UPDATE and DELETE triggers will silently drop every new row out of vector search:

- **INSERT** → seed the `semantic_index` row (`summary_text`, `authority_tier`, `embedding_stale = true`), `ON CONFLICT DO NOTHING`. This is the one most factories forget. Equivalently, the write path (writer/lib code) may seed inline (embed-on-write), but a trigger is the only safety net that also catches direct SQL and operator edits.
- **UPDATE** → mark `embedding_stale = true`, gated on content-bearing columns only (`AFTER UPDATE OF <cols> ... WHEN (OLD.col IS DISTINCT FROM NEW.col)`) so routine metadata edits do not churn embeddings.
- **DELETE** → cascade-delete the matching `semantic_index` row so no orphan remains. Verify this holds for **bulk and cross-table deletes**: deleting `document_chunks` (or any Tier 3 source) as a set can leave orphaned `semantic_index` rows if the trigger keys on the wrong column or is bypassed by a set-based delete. After any large delete, confirm no `semantic_index` row points to a source that no longer exists.

Postgres should not be assumed to generate embeddings — it cannot call an embedding API from inside a function. The triggers seed and flag; a real external embed generator fills the vectors and is verified separately.

**Both tiers need a refresh path.** The external embed generator must cover **both** `semantic_index` (Tier 1) and `document_chunks` (Tier 2). A common gap: a refresh job that re-embeds only Tier 1 leaves edited Tier-2 chunks permanently stale — the chunk's content changed but its vector never updates and nothing flags it. `v_embedding_health` must report `stale = 0` and `unembedded = 0` for **both** tiers, and the canonical refresh path must be able to re-embed either.

## Retrieval Logging

Every mature factory should add retrieval telemetry.

Recommended table:

```sql
CREATE TABLE retrieval_events (
  id bigserial PRIMARY KEY,
  tenant_id text NOT NULL,
  caller text,
  search_function text NOT NULL,
  query_text text NOT NULL,
  used_vector boolean NOT NULL,
  result_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  latency_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

Purpose:

- confirm which search path agents actually use
- identify slow queries
- measure whether vector search improves recall
- detect overuse of FTS-only fallback
- provide audit evidence when retrieval misses something important

Keep query logs free of secrets and private credentials.

## Retrieval Evals

Every factory should maintain a small golden set of retrieval tests.

Example shape:

```text
question: "How does startup resolve the factory?"
expected_sources:
  - SOP-014
  - startup rule for factory resolution
  - Probot startup protocol
```

Eval dimensions:

- expected source appears in top 5
- expected source appears in top 10
- stale rows are not returned as fresh vector evidence
- exact IDs and SOP names are found through FTS
- paraphrases are found through vector search
- hybrid result order is better than FTS-only or vector-only

Use evals before tuning HNSW, candidate limits, chunking, or reranking. Otherwise tuning is guesswork.

## HNSW Tuning

HNSW is the default. Tune only when there is enough retrieval volume or eval evidence.

Important knobs:

```text
m
ef_construction
hnsw.ef_search
candidate_limit
```

Practical guidance:

- Increase `hnsw.ef_search` when recall is too low.
- Decrease `hnsw.ef_search` when latency matters more than marginal recall.
- Increase candidate limit when hybrid reranking misses relevant records.
- Keep chunk sizes coherent; poor chunks cannot be fixed by index tuning.

Do not optimize only against query latency. Agent systems need the right context more than the fastest wrong context.

## Materialized Views

Materialized views are appropriate for startup state, dashboards, health rollups, and expensive multi-table summaries. They are not a replacement for retrieval indexes.

Recommended MV rules:

- use MVs for factory state snapshots and health summaries
- add unique indexes to support concurrent refresh where appropriate
- expose health through stable public views
- keep retrieval functions live against `semantic_index` and `document_chunks`

## Updating Existing Factories

Other factories should adopt this standard through an audit-and-migrate process. Do not copy the O-Matic database state blindly into another factory. The architecture standard is shared; the source rows, eval cases, tenant IDs, and operational details are factory-specific.

### Migration Rule

Every migration starts by proving database identity:

```sql
SELECT current_database() AS db_name, current_user AS db_user;
```

The returned database must match the target factory. If the target is The Nest, the database must be `thenest`. If the target is LucidIT, it must be that factory's configured database. Do not trust cached plugin connections, unsuffixed tool defaults, or prior session state.

### What Is Shared Across Factories

Apply these standards everywhere:

- PostgreSQL is the source of truth.
- `pgvector` is the vector storage layer.
- HNSW is the required vector index for semantic recall.
- GIN indexes support full-text recall.
- `fn_search_semantic(...)` and `fn_search_documents(...)` or equivalent functions expose retrieval.
- `NULL::vector` means FTS-only fallback.
- real query vectors use HNSW candidate search before final tenant-filtered hybrid ranking.
- `v_embedding_health` or equivalent reports total, embedded, unembedded, stale, and model counts.
- retrieval logging records search behavior for later tuning.
- retrieval evals measure whether the correct factory knowledge appears in top results.
- source-table writes refresh or mark embeddings stale.

### What Is Factory-Specific

Do not reuse these from O-Matic without rewriting them for the target factory:

- `tenant_id`
- expected database name
- eval questions
- expected eval source rows
- startup rules
- SOP IDs if the factory uses different IDs
- project knowledge rows
- document source names
- active agent or skill roster
- connector names and readiness expectations
- embedding credential keys if the factory uses a different config contract

Each factory needs its own golden retrieval cases. Good eval cases should reflect the things operators actually ask that factory.

Example factory-specific eval cases:

| Factory | Example Question | Expected Source Type |
|---|---|---|
| O-Matic | "What governs factory brain retrieval and embedding health?" | SOP-014 / vector design standard |
| The Nest | "Which devices still need Wi-Fi migration attention?" | Home/device knowledge tables |
| LucidIT | "What are the active governance and task-board health rules?" | public startup/governance views |

### Safe Rollout Order

Use this order for each factory:

1. Resolve the factory from the current project folder or explicit `.omatic/factory.json`.
2. Verify `current_database()` and `current_user`.
3. Inventory current extensions, vector columns, indexes, search functions, materialized views, and startup views.
4. Search DB-owned content and repo docs for retired vector-backend terms.
5. Confirm whether old extensions or indexes have user dependencies before dropping anything.
6. Add or update HNSW and GIN indexes.
7. Update search functions so FTS-only and HNSW-backed hybrid modes are explicit.
8. Add retrieval telemetry tables, views, and `fn_record_retrieval_event(...)`.
9. Add retrieval eval tables, views, and a factory-local eval runner.
10. Seed 3 to 10 factory-specific eval cases.
11. Index any new design/governance notes into that factory's brain.
12. Run the canonical embedding refresh path.
13. Verify embedding health returns to zero stale and zero unembedded rows.
14. Run evals and record the baseline.
15. Wire the factory plugin/search layer to record retrieval events during normal memory search.

Stop if any identity, dependency, or health check does not match the target factory.

### Cleanup Rules

Retired backend cleanup is allowed only after dependency inspection.

Required checks:

```sql
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;

SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE indexdef ILIKE '%hnsw%'
   OR indexdef ILIKE '%ivfflat%'
   OR indexdef ILIKE '%gin%';
```

If a retired extension exists but no user objects depend on it, remove it in that factory's migration. If any user index, function, or table depends on it, migrate the dependent object first. Do not use `CASCADE` unless the operator explicitly approves the blast radius.

Duplicate indexes should be removed only when the stronger constraint remains. Example pattern:

- a non-unique lookup index duplicates a unique key on the same columns: drop the non-unique lookup index
- a unique constraint duplicates a primary key on the same column: drop the non-primary unique constraint

Always inspect `pg_constraint` before dropping a constraint-backed index.

### Minimum Acceptance Criteria

A factory is updated when all of these are true:

- database identity was verified for that factory
- only the intended vector extension remains in active use
- no retired vector-backend references remain in active docs, config, DB rows, functions, or indexes
- HNSW indexes exist for semantic and document embeddings
- GIN indexes exist for stored full-text columns
- search functions return live results
- `NULL::vector` search behaves as FTS-only
- query-vector search can use HNSW candidate scans
- retrieval event logging works
- retrieval eval cases exist and run
- baseline eval results are recorded
- embedding health is clean after all updates
- every active Tier 3 source row has a matching `semantic_index` row — no uncatalogued rows
- INSERT, UPDATE, and DELETE triggers exist on every Tier 1 source table (or the write path seeds inline and is verified)
- `authority_tier` is populated on every `semantic_index` row

### Operator Summary

The goal is not to make every factory identical. The goal is to make every factory measurable, fast enough to scale, and honest about what it retrieved.

Shared standard:

```text
pgvector + HNSW + GIN + hybrid retrieval + telemetry + evals
```

Factory-local work:

```text
identity check + local eval cases + local source mapping + local embedding refresh
```

## Audit Checklist

Use this checklist for new factories and periodic health checks:

- `current_database()` matches the expected factory database.
- `pgvector` extension is installed.
- no external or retired vector backend is referenced by config, docs, functions, or indexes.
- `semantic_index.embedding` is `vector(1536)`.
- `document_chunks.embedding` is `vector(1536)`.
- HNSW indexes exist for both vector tables.
- GIN indexes exist for both stored `tsv` columns.
- search functions exist and return live rows.
- `NULL::vector` search falls back to FTS-only.
- query-vector search can use HNSW candidate scans.
- `v_embedding_health` shows zero stale and zero unembedded rows for **both** `semantic_index` and `document_chunks` (Tier-2 staleness needs a refresh path too).
- every active Tier 3 source row has a matching `semantic_index` row — no uncatalogued rows.
- no **orphaned** `semantic_index` rows — every catalog row points to a source that still exists (bulk and cross-table deletes can leave orphans).
- source-table INSERT/UPDATE/DELETE triggers exist: INSERT seeds the catalog, UPDATE marks stale, DELETE cascades. Missing INSERT seed is the most common silent defect.
- `authority_tier` is populated on every `semantic_index` row and assigned at write time.
- retrieval events are logged in mature deployments.
- retrieval evals exist before tuning index parameters.

## Default Recommendation

For an O-Matic factory, the recommended setup is:

```text
Postgres + pgvector
semantic_index + document_chunks
HNSW vector indexes
GIN full-text indexes
direct SQL first
hybrid FTS/vector retrieval
RRF reranking
retrieval logging
retrieval evals
embedding freshness checks
```

This keeps the factory portable, fast, auditable, and understandable by any agent or operator that reads the design.

## Revisions

### 2026-06-04 — Authority tiers + mandatory INSERT seed

Two standards added after a factory audit found a defect this document had propagated:

- **INSERT seed is now mandatory.** Earlier revisions specified only UPDATE (mark stale) and DELETE (cascade) triggers. Any factory built to that contract silently dropped every newly inserted Tier 3 row out of vector search — the row existed, but no `semantic_index` entry was created and no health metric flagged it. The Freshness Contract now requires a third trigger (INSERT seed) or a verified inline embed-on-write path. Factories built on prior revisions should audit for uncatalogued rows and add the INSERT seed.
- **Authority tiers added.** `semantic_index` now carries `authority_tier` (sacred / canon / operational / experimental / archived / deprecated), assigned at write time, so retrieval and conflict resolution can weight trusted memory over noise instead of treating every chunk equally. Tier-weighted ranking inside the search functions is the recommended next step.

These came from an audit principle worth stating directly: a vector database full of ungoverned, equally-weighted chunks is not a brain — it is a junk drawer. Curation and authority matter as much as embeddings and indexes.

### 2026-06-07 — Cascade integrity + both-tier freshness

From a full-factory drift audit (O-Matic Session 80):

- **DELETE cascade must be verified, not assumed.** A bulk delete of Tier-2 `document_chunks` left orphaned `semantic_index` rows — the catalog pointed at sources that no longer existed. Migrations and periodic audits must check for orphans (catalog rows whose source is gone), not only for uncatalogued rows. Catalog integrity runs in **both** directions.
- **Embedding freshness is a two-tier contract.** The canonical refresh path must re-embed `document_chunks` as well as `semantic_index`. A Tier-1-only refresher leaves edited Tier-2 chunks permanently stale. `v_embedding_health` must read zero stale and zero unembedded for both tiers.
- **This standard is canon in commons.** Factories pull it from the shared commons KB (the `kb` connection) and align to it — they do not fork or re-derive it locally. The brain is pgvector + HNSW only; no other vector backend.

