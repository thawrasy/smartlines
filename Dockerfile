# Masslak: one image holding the API, the built web interface and the database scripts.

# ---- web interface ----
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS web
WORKDIR /web
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
ARG VITE_SHOW_DEMO=false
ARG VITE_DEFAULT_LOCALE=ar
ENV VITE_SHOW_DEMO=$VITE_SHOW_DEMO VITE_DEFAULT_LOCALE=$VITE_DEFAULT_LOCALE
RUN npm run build

# ---- API ----
FROM python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f
# the commit the image was built from, recorded by the migrate step in the release manifest (1058)
ARG MASSLAK_RELEASE_COMMIT=unknown
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    MASSLAK_STATIC_DIR=/app/static MASSLAK_RELEASE_COMMIT=${MASSLAK_RELEASE_COMMIT}
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app masslak
WORKDIR /app/backend
# every package pinned with its hashes, transitive ones included (reviews of October 2026, H-08)
COPY backend/requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY backend/ ./
COPY db/ /app/db/
COPY deploy/migrate.sh /app/deploy/migrate.sh
COPY deploy/egress/selftest.sh /app/deploy/egress/selftest.sh
COPY --from=web /web/dist /app/static
# The encrypted document store is a volume owned by the unprivileged app user
RUN mkdir -p /data/files /data/messages && chown masslak /data/files /data/messages
USER masslak
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')"
# Client addresses are resolved by the application from MASSLAK_TRUSTED_PROXIES, so uvicorn's own handling is off.
# Idle connections stay open 75 s, longer than Caddy keeps them (60 s, deploy/Caddyfile): the proxy always closes
# first, so it never sends a request on a connection the API is closing (uvicorn's default of 5 s let a booking fail
# with a reset now and then, found by the concurrency tests).
# Two worker processes, given as WEB_CONCURRENCY (uvicorn's default for --workers) so the application knows how many
# processes share the instance's in-memory request limits and metrics (app/ratelimit.py, app/metrics.py).
ENV WEB_CONCURRENCY=2
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers", "--timeout-keep-alive", "75"]
