# The application images (ADR 0047, ADR 0051): one build, two targets.
#   docker build -f app/deploy/Dockerfile --target api    -t <REGISTRY>/bankfas-api:<VERSION>    .
#   docker build -f app/deploy/Dockerfile --target worker -t <REGISTRY>/bankfas-worker:<VERSION> .
# Run from treasury-platform/ (its .dockerignore applies; the seed packs under db/ are copied next to both applications).
# Both run as an unprivileged user on a read-only root file system with /tmp as tmpfs (tools/host/compose.yml).
# Behind a proxy that inspects TLS, pass its CA for the build only (it never enters an image):
#   docker build --secret id=extra_ca,src=<proxy-ca.pem> --build-arg HTTPS_PROXY=... ...

FROM node:22-bookworm-slim AS web
WORKDIR /src/app/web
COPY app/web/package.json app/web/package-lock.json ./
RUN --mount=type=secret,id=extra_ca,required=false \
    NODE_EXTRA_CA_CERTS=$([ -f /run/secrets/extra_ca ] && echo /run/secrets/extra_ca) npm ci --no-audit --no-fund
COPY app/web/ ./
RUN npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY db/seed/packs db/seed/packs
COPY app/ app/
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -f /run/secrets/extra_ca ]; then cp /run/secrets/extra_ca /usr/local/share/ca-certificates/extra_ca.crt && update-ca-certificates > /dev/null; fi \
 && dotnet publish app/src/BankFas.Api -c Release -o /out/api --nologo \
 && dotnet publish app/src/BankFas.Worker -c Release -o /out/worker --nologo

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
RUN groupadd --system --gid 10001 bankfas && useradd --system --uid 10001 --gid bankfas --home-dir /nonexistent --shell /usr/sbin/nologin bankfas
ENV DOTNET_EnableDiagnostics=0 TMPDIR=/tmp

# Chromium for the PDF prints (ADR 0051): Playwright's build, the one the browser tests run on; Ubuntu 24.04, the base
# of the .NET 10 images, ships Chromium as a snap only, which does not run in a container. A host that cannot reach
# Playwright's download servers passes a local copy of the chrome-linux folder instead:
#   docker build --build-context chromium=<path>/chrome-linux ...
FROM node:22-bookworm-slim AS chromium-download
RUN --mount=type=secret,id=extra_ca,required=false \
    NODE_EXTRA_CA_CERTS=$([ -f /run/secrets/extra_ca ] && echo /run/secrets/extra_ca) PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    npx -y playwright@1.56.1 install chromium \
 && mv /ms-playwright/chromium-*/chrome-linux /out
FROM scratch AS chromium
COPY --from=chromium-download /out /

# The API: the portal's files and the PDF printer (Chromium with an Arabic font, PdfRenderer). The packages come over
# HTTPS; Chromium's libraries are those Playwright lists for Ubuntu 24.04.
FROM base AS api
RUN --mount=type=secret,id=extra_ca,required=false \
    sed -i 's|http://\(archive\|security\).ubuntu.com|https://\1.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources \
 && CA=$([ -f /run/secrets/extra_ca ] && echo "-o Acquire::https::CAInfo=/run/secrets/extra_ca") \
 && apt-get $CA update \
 && apt-get $CA install -y --no-install-recommends libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64 \
      libdbus-1-3 libglib2.0-0t64 libexpat1 libx11-6 libxcb1 libxext6 libatspi2.0-0t64 fonts-noto-core fonts-noto-ui-core \
      fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
COPY --from=chromium / /opt/chromium/
WORKDIR /app
COPY --from=build /out/api ./
COPY --from=web /src/app/web/dist ./wwwroot
ENV ASPNETCORE_URLS=http://0.0.0.0:8080 Web__Root=/app/wwwroot Pdf__Chromium=/opt/chromium/chrome
USER bankfas
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["/usr/bin/env", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080"]
ENTRYPOINT ["dotnet", "BankFas.Api.dll"]

# The worker: the scheduled jobs and the outbox (JobLoop).
FROM base AS worker
WORKDIR /app
COPY --from=build /out/worker ./
USER bankfas
ENTRYPOINT ["dotnet", "BankFas.Worker.dll"]
