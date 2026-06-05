# syntax=docker/dockerfile:1.7
#
# O-Matic Server image
#   Postgres 18 + pgvector + pg_cron
#
# Built FROM pgvector/pgvector:pg18 (upstream — pgvector pre-installed, auto-updates
# on rebuild). pg_cron comes from the Debian PostgreSQL apt repo.
#
# Vector index method is pgvector HNSW. pgvectorscale/diskann is NOT used and is
# intentionally not built — the factory brain runs on pgvector HNSW alone.
#
# After first start, enable pg_cron once (requires a restart for the preload):
#   ALTER SYSTEM SET shared_preload_libraries = 'pg_cron';
#   -- restart container, then:
#   CREATE EXTENSION IF NOT EXISTS pg_cron;
# Then load the schema (sql/01_schema.sql) and bootstrap (sql/02_bootstrap.sql).

# ---------------------------------------------------------------------------
# Gosu rebuild stage — replace upstream's bundled gosu with one freshly
# compiled against current Go stdlib (closes the Go-stdlib CVEs Trivy flags
# in upstream pgvector/pgvector:pg18's bundled gosu).
# ---------------------------------------------------------------------------
FROM golang:1-bookworm AS gosu-build

ENV GOTOOLCHAIN=auto
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 https://github.com/tianon/gosu.git /tmp/gosu \
 && cd /tmp/gosu \
 && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /usr/local/bin/gosu \
 && /usr/local/bin/gosu --version

# ---------------------------------------------------------------------------
# Final stage — thin runtime image
# ---------------------------------------------------------------------------
FROM pgvector/pgvector:pg18

USER root

# Debian security updates (openssl/libssl3 CVEs Trivy flags on older bases) and
# pg_cron, in one layer.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends \
      postgresql-18-cron \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Replace upstream gosu with the version built fresh against current Go.
COPY --from=gosu-build /usr/local/bin/gosu /usr/local/bin/gosu

USER postgres
