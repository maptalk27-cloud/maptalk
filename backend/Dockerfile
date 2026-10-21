# Build with backend/ as the context. Do not copy a developer's node_modules:
# sharp's optional native packages must be installed for the Linux target.
FROM caddy:2-alpine AS proxy
# The upstream binary may carry cap_net_bind_service=ep, which makes execve
# fail with cap_drop=ALL even when only high ports are used.
RUN capabilities="$(getcap /usr/bin/caddy)" \
    && if [ -n "$capabilities" ]; then setcap -r /usr/bin/caddy; fi
USER 1000:1000

FROM node:24-bookworm-slim AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --include=optional --engine-strict \
    && npm cache clean --force

FROM node:24-bookworm-slim AS runtime
# Video input is independently decoded/validated and remuxed without metadata.
# Debian's supported ffmpeg package supplies both ffmpeg and ffprobe; no media
# is sent to a third-party transcoder, and no additional cloud service is used.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && ffmpeg -version >/dev/null && ffprobe -version >/dev/null
ENV NODE_ENV=production \
    MAPTALK_MODE=beta \
    MAPTALK_BIND=0.0.0.0 \
    PORT=8787 \
    TMPDIR=/tmp \
    NODE_OPTIONS=--max-old-space-size=384
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json ./
COPY src/ ./src/
COPY scripts/container-healthcheck.mjs scripts/deployment-preflight.mjs scripts/beta.mjs scripts/backup.mjs scripts/encrypted-backup.mjs ./scripts/
RUN mkdir -p /var/lib/maptalk /var/backups/maptalk \
    && chown node:node /var/lib/maptalk /var/backups/maptalk
USER 1000:1000
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["node", "scripts/container-healthcheck.mjs"]
# Validate domain, secrets, storage and AWS settings locally before starting.
# This preflight does not contact AWS or prove DNS/TLS/deployment readiness.
CMD ["sh", "-c", "node scripts/deployment-preflight.mjs && exec node src/main.mjs"]
