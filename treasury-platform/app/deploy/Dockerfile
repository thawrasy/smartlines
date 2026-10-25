# The application images (ADR 0047, ADR 0051): one build, two targets.
#   docker build -f app/deploy/Dockerfile --target api    -t <REGISTRY>/bankfas-api:<VERSION>    .
#   docker build -f app/deploy/Dockerfile --target worker -t <REGISTRY>/bankfas-worker:<VERSION> .
# Run from treasury-platform/ (its .dockerignore applies; the seed packs under db/ are copied next to both applications).
# Both run as an unprivileged user on a read-only root file system with /tmp as tmpfs (tools/host/compose.yml).

FROM node:22-bookworm-slim AS web
WORKDIR /src/app/web
COPY app/web/package.json app/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/web/ ./
RUN npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY db/seed/packs db/seed/packs
COPY app/ app/
RUN dotnet publish app/src/BankFas.Api -c Release -o /out/api --nologo \
 && dotnet publish app/src/BankFas.Worker -c Release -o /out/worker --nologo

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
RUN groupadd --system --gid 10001 bankfas && useradd --system --uid 10001 --gid bankfas --home-dir /nonexistent --shell /usr/sbin/nologin bankfas
ENV DOTNET_EnableDiagnostics=0 TMPDIR=/tmp

# The API: the portal's files and the PDF printer (Chromium with an Arabic font, PdfRenderer).
FROM base AS api
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium fonts-noto-core fonts-noto-ui-core fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/api ./
COPY --from=web /src/app/web/dist ./wwwroot
ENV ASPNETCORE_URLS=http://0.0.0.0:8080 Web__Root=/app/wwwroot Pdf__Chromium=/usr/bin/chromium
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
