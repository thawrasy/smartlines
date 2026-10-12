# ADR 0001: Production runs on Ubuntu 24.04 LTS; schema work and CI run on Linux

Status: accepted by the owner (2026-10-12). The production VPS runs Ubuntu 24.04 LTS. This replaces the earlier exclusion of Ubuntu. The database-host part of FR-PLT-045 and decision 01 section 13 (Windows Server) is superseded by this ADR; both texts are updated (O-23). The application tier stays on Windows Server per 01 section 13 until it is reviewed.

## Context

- The team works on Linux and can operate Linux servers. Some company developers use SUSE servers.
- The production database host is an external VPS from a hosting provider (Q-PLT-03, decided 2026-10-10).
- SQL Server 2025 on Linux is supported on RHEL and Ubuntu. Per the Microsoft release notes, SLES (SUSE) is listed only through SQL Server 2022 (checked by search summary; verify on learn.microsoft.com).
- FR-PLT-045 and decision 01 section 13 name Windows Server, ASP.NET Core and the latest GA SQL Server as the stack. This ADR changes the database host only.
- The verified path for this ADR is `tools/ci/db_ci.sh` run against the Ubuntu-based SQL Server 2025 container (`mcr.microsoft.com/mssql/server:2025-latest`, Ubuntu 24.04). It passes in full in the development container and on GitHub: the workflow `.github/workflows/treasury-db-ci.yml` at the repository root runs it on an `ubuntu-24.04` runner with that container (first green run 2026-10-12, https://github.com/thawrasy/smartlines/actions/runs/38283663041). Correction (2026-10-12): an earlier text of this ADR said the GitHub run had passed before it had; the workflow then sat under `treasury-platform/.github/`, which GitHub does not read.
- As a further check, the full CI also passed on the RHEL-based image `mcr.microsoft.com/mssql/rhel/server:2025-latest` (Red Hat Enterprise Linux 10.2). That check is evidence, not the production target.

## Decision

- The production VPS runs Ubuntu 24.04 LTS with SQL Server 2025.
- Schema models, generated DDL, static scripts and database tests are developed and verified on Linux.
- CI runs on `ubuntu-24.04` with the Ubuntu-based SQL Server 2025 container, the same operating system as production (`.github/workflows/treasury-db-ci.yml` at the repository root).
- Deployment uses `tools/deploy/deploy.sh`, which changes to `db/` before it runs `deploy.sql`.
- The Windows wrapper `tools/deploy/deploy.ps1` is kept, but it has not been run and is not part of the production path.

## Consequences

- A self-hosted RHEL runner is no longer needed for CI.
- SUSE is not used for the database. Whether a SQL Server 2025 container may run on a SUSE host is not confirmed, and it is not needed for this decision.
- Before real data is loaded, the open decisions on key custody (the outer key that wraps `sec.TenantKey`, and the TDE certificate), data residency, and backups must be closed (see the open-items register).
- The Ubuntu 24.04 support for SQL Server 2025 must be confirmed on the official Microsoft page, because the sources used so far are search summaries.

## Alternatives considered

- RHEL on the VPS: supported and tested in this session through the RHEL image. Not chosen by the owner.
- SQL Server 2022 on SLES: conflicts with the latest-GA rule in FR-PLT-045.
- Windows Server for the database: consistent with FR-PLT-045, not verified on Windows in this repository.
- PostgreSQL 16: rejected for now. The PostgreSQL output has no security layer.
