# Masslak: one image holding the API, the built web interface and the database scripts.

# ---- web interface ----
FROM node:22-alpine AS web
WORKDIR /web
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
ARG VITE_SHOW_DEMO=false
ARG VITE_DEFAULT_LOCALE=ar
ENV VITE_SHOW_DEMO=$VITE_SHOW_DEMO VITE_DEFAULT_LOCALE=$VITE_DEFAULT_LOCALE
RUN npm run build

# ---- API ----
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    MASSLAK_STATIC_DIR=/app/static
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app masslak
WORKDIR /app/backend
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ ./
COPY db/ /app/db/
COPY deploy/migrate.sh /app/deploy/migrate.sh
COPY --from=web /web/dist /app/static
# The encrypted document store is a volume owned by the unprivileged app user
RUN mkdir -p /data/files /data/messages && chown masslak /data/files /data/messages
USER masslak
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')"
# Client addresses are resolved by the application from MASSLAK_TRUSTED_PROXIES, so uvicorn's own handling is off
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--no-proxy-headers"]
