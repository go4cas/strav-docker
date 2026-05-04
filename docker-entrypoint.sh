#!/bin/sh
# =============================================================================
# Strav — Docker entrypoint
#
# STRAV_PROCESS  (env var)
#   web          Run migrations, then start the HTTP server  [default]
#   worker       Skip migrations, start the queue worker
#   scheduler    Skip migrations, start the scheduler
#   migrate      Run migrations only, then exit (useful for init containers)
# =============================================================================
set -e

# ── Wait for Postgres ─────────────────────────────────────────────────────────
# Docker Compose healthchecks + depends_on handle this in most cases,
# but a belt-and-suspenders loop here protects manual `docker run` usage.
if [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ]; then
  echo "[entrypoint] Waiting for Postgres at ${DB_HOST}:${DB_PORT}..."
  RETRIES=30
  until nc -z -w 1 "$DB_HOST" "$DB_PORT" 2>/dev/null || [ "$RETRIES" -eq 0 ]; do
    RETRIES=$((RETRIES - 1))
    sleep 1
  done
  if [ "$RETRIES" -eq 0 ]; then
    echo "[entrypoint] ERROR: Postgres not reachable after 30s. Aborting." >&2
    exit 1
  fi
  echo "[entrypoint] Postgres is up."
fi

# ── Process-specific bootstrap ────────────────────────────────────────────────
case "${STRAV_PROCESS:-web}" in

  web)
    echo "[entrypoint] Running database migrations..."
    bun strav migrate
    echo "[entrypoint] Migrations complete. Starting HTTP server..."
    ;;

  migrate)
    echo "[entrypoint] Running database migrations (migrate-only mode)..."
    bun strav migrate
    echo "[entrypoint] Migrations complete. Exiting (CMD is intentionally skipped)."
    exit 0
    ;;

  worker)
    echo "[entrypoint] Starting queue worker..."
    ;;

  scheduler)
    echo "[entrypoint] Starting scheduler..."
    ;;

  *)
    echo "[entrypoint] Unknown STRAV_PROCESS='${STRAV_PROCESS}'. Starting with given command." >&2
    ;;
esac

# Hand off to the CMD (or whatever was passed to `docker run`)
exec "$@"
