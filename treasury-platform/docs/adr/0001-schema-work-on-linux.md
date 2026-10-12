# ADR 0001: Production runs on Ubuntu 24.04 LTS; schema work and CI run on Linux

Status: accepted by the owner (2026-10-12). The production VPS runs Ubuntu 24.04 LTS. This replaces the earlier exclusion of Ubuntu. The database-host part of FR-PLT-045 and decision 01 section 13 (Windows Server) is superseded by this ADR and still needs its text updated (O-23).

## Context

- The team works on Linux and can operate Linux servers. Some company developers use SUSE servers.
- The production database host is an external VPS from a hosting provider (Q-PLT-03, decided 2026-10-10).
- SQL Server 2025 on Linux is supported on RHEL and Ubuntu. Per the Microsoft release notes, SLES (SUSE) is listed only through SQL Server 2022 (checked by search summary; verify on learn.microsoft.com).
- FR-PLT-045 and decision 01 section 13 name Windows Server, ASP.NET Core and the latest GA SQL Server as the stack. This ADR changes the database host only.
- The verified path for this ADR is the CI on a GitHub-hosted Ubuntu 24.04 runner with the Ubuntu-based SQL Server 2025 container (`tools/ci/db_ci.sh`, `.github/workflows/db-ci.yml`). It passed in full.
- As a further check, the full CI also passed on the RHEL-based image `mcr.microsoft.com/mssql/rhel/server:2025-latest` (Red Hat Enterprise Linux 10.2). That check is evidence, not the production target.

## Decision

- The production VPS runs Ubuntu 24.04 LTS with SQL Server 2025.
- Schema models, generated DDL, static scripts and database tests are developed and verified on Linux.
- CI runs on `ubuntu-24.04` with the Ubuntu-based SQL Server 2025 container, the same operating system as production.
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
