-- O-Matic Server — maintenance bootstrap
-- Run AFTER 01_schema.sql, and after pg_cron has been enabled (see README).
--
-- pg_cron requires shared_preload_libraries = 'pg_cron' + a restart before
-- CREATE EXTENSION will succeed. This file is idempotent and safe to re-run.

-- In-DB scheduled maintenance (SQL-only — pg_cron cannot call OpenAI).
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Keep the 5 materialized views (dashboard, embedding health, kernel health,
-- startup snapshot, agent eval status) fresh between sessions. Hourly is ample
-- at typical factory write volume.
SELECT cron.schedule(
  'refresh-dashboards',
  '0 * * * *',
  $$ SELECT fn_refresh_dashboards(); $$
)
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-dashboards');

-- NOTE: embedding refresh is NOT scheduled here. Postgres cannot call the
-- OpenAI API from inside a function, so stale/unembedded rows are cleared by the
-- EXTERNAL scheduler (scripts/embed_stale.py via the maintenance GitHub Action or
-- host cron). pg_cron only keeps in-DB SQL artifacts fresh.
