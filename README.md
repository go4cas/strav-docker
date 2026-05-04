# strav-docker

Docker environment for [Strav](https://strav.dev) — the Bun backend framework. Covers local development with hot-reload and a hardened multi-replica production setup with Caddy, PostgreSQL, and Redis.

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Development setup](#development-setup)
- [Production setup](#production-setup)
- [Service profiles](#service-profiles)
- [Environment variables](#environment-variables)
- [Common tasks](#common-tasks)
- [Image internals](#image-internals)

---

## Architecture

```
                ┌──────────┐
  Browser ────► │  Caddy   │ :80 / :443 (HTTP/3)
                └────┬─────┘
                     │ reverse proxy
              ┌──────┴──────┐
              │    web ×2   │ :3000  (Bun / Strav)
              └──────┬──────┘
              ┌──────┴──────┐
              │  PostgreSQL │        ← persistent volume
              └─────────────┘
              ┌─────────────┐
              │    Redis    │        ← queue, sessions, cache
              └─────────────┘
              ┌─────────────┐
              │   worker    │        (optional profile)
              └─────────────┘
              ┌─────────────┐
              │  scheduler  │        (optional profile, 1 replica only)
              └─────────────┘
```

**Caddy** handles TLS (self-signed in dev via its local CA, Let's Encrypt in production), compression, security headers, and static file serving. Only Caddy is exposed to the internet; all app services communicate over the internal Docker network.

---

## Requirements

| Tool | Version |
|------|---------|
| Docker Engine | 24+ |
| Docker Compose plugin (`docker compose`) | v2.20+ |
| `gh` CLI | any (for GitHub operations) |

> **Note:** This setup uses the Compose v2 plugin (`docker compose`), not the legacy `docker-compose` v1 binary.

---

## Development setup

### 1. Clone and configure environment

```bash
git clone https://github.com/go4cas/strav-docker.git my-app
cd my-app
cp .env.example .env
```

Edit `.env` and set at minimum:

```bash
APP_KEY=   # required — generate with: bun strav generate:key
```

All other values in `.env.example` are pre-set for the local Docker network and work out of the box.

### 2. Start the stack

```bash
# Web server + PostgreSQL + Caddy (minimum)
docker compose up

# Also start the queue worker and Redis
docker compose --profile worker up

# Everything (web, db, redis, worker, scheduler)
docker compose --profile full up
```

The app is available at **http://localhost** (Caddy proxies to the Bun process on port 3000).

### 3. Trust Caddy's local CA (HTTPS in dev)

Caddy issues a self-signed certificate from its local CA on first boot. To avoid browser warnings:

```bash
docker compose exec caddy caddy trust
```

After trusting, the site is also available at **https://localhost**.

### 4. Run database migrations

Migrations run automatically when the `web` container starts. To run them manually:

```bash
docker compose exec web bun strav migrate
```

Other database commands:

```bash
docker compose exec web bun strav generate:migration   # create a new migration
docker compose exec web bun strav rollback             # revert last migration
docker compose exec web bun strav fresh                # drop all tables and rebuild
docker compose exec web bun strav seed                 # seed test data
```

### 5. Hot reload

The entire project directory is mounted into the `web` container (`bun run dev` uses Bun's built-in file watcher). Save a file — the process restarts automatically. Node modules are isolated in a named volume so host `node_modules/` never interferes.

### 6. Running tests

```bash
docker compose exec web bun test
```

---

## Production setup

### 1. Provision a server

Any Linux host with Docker Engine 24+ works. A single VM with 2 vCPUs / 2 GB RAM handles modest traffic comfortably; add more web or worker replicas as needed.

### 2. Configure environment

```bash
cp .env.prod.example .env.prod
```

Fill in every value — none have safe defaults in production:

| Variable | Notes |
|----------|-------|
| `APP_KEY` | Generate with `bun strav generate:key`. Rotate with care. |
| `APP_DOMAIN` | The public domain (`example.com`). DNS A record must point here before first boot. |
| `DB_USER` / `DB_PASSWORD` / `DB_DATABASE` | Use a strong password. |
| `REDIS_PASSWORD` | Required — the Redis service is started with `--requirepass`. |
| `REDIS_URL` | Pre-filled in example as `redis://:${REDIS_PASSWORD}@redis:6379`. |

### 3. Build the production image

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml build
```

This runs the multi-stage build (deps → builder → runner) and tags the result as `strav-app:latest`. All three app services (web, worker, scheduler) share this single image.

### 4. Deploy

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

On first boot, Compose starts the services in dependency order:

1. `db` and `redis` (with healthchecks)
2. `migrate` — runs `bun strav migrate`, then exits cleanly
3. `web` (×2), `worker` (×2), `scheduler` (×1) — start after `migrate` completes

Caddy automatically obtains a Let's Encrypt TLS certificate on the first request. No manual certificate management needed.

### 5. Static assets

The Caddy service serves files from `./public/` on the host. If you check out the source code on the server, this directory is populated by the build step. For **image-only deploys** (no source checkout), copy assets out of the builder stage in CI:

```bash
docker create --name tmp strav-app:latest
docker cp tmp:/app/public ./public
docker rm tmp
```

### 6. Updating the app

```bash
# Pull latest code / new image
docker compose -f docker-compose.yml -f docker-compose.prod.yml build

# Roll the stack — migrate runs first automatically
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Zero-downtime updates rely on the `migrate` init container completing before new `web` replicas start. Old replicas continue serving traffic while new ones start.

### 7. Monitoring

```bash
# Follow logs for all services
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f

# Follow only the app
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f web worker scheduler

# Check health status
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
```

---

## Service profiles

| Profile | Extra services started |
|---------|----------------------|
| _(none)_ | `db`, `caddy`, `web` |
| `worker` | + `redis`, `worker` |
| `scheduler` | + `scheduler` |
| `full` | + `redis`, `worker`, `scheduler` |

In **production** all services (including `worker` and `scheduler`) start unconditionally — profiles are development-only.

---

## Environment variables

### Application

| Variable | Default (dev) | Description |
|----------|---------------|-------------|
| `APP_ENV` | `local` | `local` or `production` |
| `APP_KEY` | _(empty)_ | Application encryption key. Generate once with `bun strav generate:key`. |
| `APP_DOMAIN` | `localhost` | Public hostname. Used by Caddy for TLS and virtual hosting. |

### Database

| Variable | Default (dev) | Description |
|----------|---------------|-------------|
| `DB_HOST` | `db` | Postgres hostname (Docker service name). |
| `DB_PORT` | `5432` | Postgres port. |
| `DB_USER` | `postgres` | Postgres user. |
| `DB_PASSWORD` | `postgres` | Postgres password. **Change in production.** |
| `DB_DATABASE` | `my_app` | Database name. |

### Redis

| Variable | Default (dev) | Description |
|----------|---------------|-------------|
| `REDIS_URL` | `redis://redis:6379` | Full Redis connection URL. |
| `REDIS_PASSWORD` | _(prod only)_ | Redis `requirepass` value. Required in production. |

### Process control

| Variable | Values | Description |
|----------|--------|-------------|
| `STRAV_PROCESS` | `web`, `worker`, `scheduler`, `migrate` | Controls what the entrypoint starts. Set automatically by Compose per service. |

---

## Common tasks

```bash
# Open a shell in the running web container
docker compose exec web sh

# Generate a new application key
docker compose exec web bun strav generate:key

# Generate models from the current schema
docker compose exec web bun strav generate:models

# Retry failed queue jobs
docker compose exec worker bun strav queue:retry

# Run only migrations (no server start)
docker compose run --rm -e STRAV_PROCESS=migrate web

# Connect to Postgres directly
docker compose exec db psql -U postgres -d my_app

# Connect to Redis
docker compose exec redis redis-cli
```

---

## Image internals

The Dockerfile uses three stages:

| Stage | Base | Purpose |
|-------|------|---------|
| `deps` | `oven/bun:1-alpine` | Installs production-only dependencies (`--production`). |
| `builder` | `oven/bun:1-alpine` | Installs all dependencies, copies source, runs `bun run build`. |
| `runner` | `oven/bun:1-alpine` | Copies app source from `builder` and prod `node_modules` from `deps`. Runs as a non-root system user (`strav`, uid 1001). |

The `runner` stage is the production image. Dev compose uses the `builder` stage directly with a source mount, so hot-reload works without rebuilding.

### Entrypoint behaviour

The `docker-entrypoint.sh` script probes Postgres before starting the selected process. It handles four modes via `STRAV_PROCESS`:

| Mode | Behaviour |
|------|-----------|
| `web` | Runs `bun strav migrate`, then hands off to `CMD` |
| `migrate` | Runs `bun strav migrate` and exits — CMD is skipped |
| `worker` | Starts immediately, skips migrations |
| `scheduler` | Starts immediately, skips migrations |

In production the `migrate` Compose service runs in `migrate` mode as an init container. The `web` replicas declare `depends_on: migrate: condition: service_completed_successfully`, ensuring migrations finish exactly once before any HTTP traffic is accepted.
