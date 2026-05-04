# =============================================================================
# Strav — Production Dockerfile
# Runtime: Bun (oven/bun:1-alpine)
# Stages:  deps → builder → runner
# =============================================================================

# ── Stage 1: Production dependencies ─────────────────────────────────────────
FROM oven/bun:1-alpine AS deps
WORKDIR /app

COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile --production


# ── Stage 2: Full build (dev deps + frontend assets) ─────────────────────────
FROM oven/bun:1-alpine AS builder
WORKDIR /app

COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile

COPY . .

# Build frontend assets (Vue islands, CSS bundles, etc.) if the script exists.
# Remove this line if your app is API-only.
RUN bun run --if-present build

# Remove node_modules so COPY --from=builder in the runner stage never pulls
# them in — the runner stage supplies its own production-only deps from deps.
RUN rm -rf node_modules


# ── Stage 3: Lean production runner ──────────────────────────────────────────
FROM oven/bun:1-alpine AS runner
WORKDIR /app

# Hardened environment defaults — override per-service at runtime
ENV NODE_ENV=production \
    APP_ENV=production \
    PORT=3000

# Non-root system user
RUN addgroup --system --gid 1001 strav \
 && adduser  --system --uid 1001 --ingroup strav strav

# netcat-openbsd: used by docker-entrypoint.sh to probe Postgres readiness.
# BusyBox nc varies by build; netcat-openbsd guarantees -z and -w support.
RUN apk add --no-cache netcat-openbsd

# Application source + built assets from builder stage (node_modules already
# removed there — see builder stage above).
COPY --from=builder --chown=strav:strav /app .

# Production-only node_modules (no devDependencies)
COPY --from=deps    --chown=strav:strav /app/node_modules ./node_modules

# Entrypoint (handles migrations + graceful process selection)
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/entrypoint.sh

USER strav

# Mount a named volume here in production to persist logs, uploads, and cache:
#   volumes: [strav_storage:/app/storage]
EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default: HTTP server. Override per service in Compose:
#   worker:    bun strav queue:work
#   scheduler: bun strav schedule
CMD ["bun", "run", "start"]
