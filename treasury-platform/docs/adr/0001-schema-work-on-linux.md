# ADR 0001: Schema work and CI run on Linux

Status: accepted for schema development and CI (2026-10-12). The production host operating system is open (O-23).

## Context

- The team works on Linux and can operate Linux servers. Some company developers use SUSE servers.
- SQL Server 2025 on Linux is supported on RHEL and Ubuntu. Per the Microsoft release notes, SLES (SUSE) is listed only through SQL Server 2022 (checked by search summary; verify on learn.microsoft.com).
- The earlier stack decision (FR-PLT-045, decision 01 section 13) names Windows Server, ASP.NET Core and the latest GA SQL Server as the target.
- The existing verified path is CI on an Ubuntu 24.04 runner with the SQL Server 2025 container (`tools/ci/db_ci.sh`, `.github/workflows/db-ci.yml`).

## Decision

- Schema models, generated DDL, static scripts and database tests are developed and verified on Linux.
- CI and local verification use the Ubuntu 24.04 host with the SQL Server 2025 container. Deployment uses `tools/deploy/deploy.sh`, which changes to `db/` before it runs `deploy.sql`.
- The Windows wrapper `tools/deploy/deploy.ps1` is kept, but it has not been run.

## Consequences

- The production host must be RHEL or Ubuntu for SQL Server 2025, or Windows under FR-PLT-045. SUSE is not a supported host for SQL Server 2025. Whether a container of SQL Server 2025 may run on a SUSE host is not confirmed.
- SQL Server 2022 on SUSE would keep SUSE, but it conflicts with the latest-GA rule in FR-PLT-045.
- The Windows deployment path remains unverified until it runs on a Windows target.
- Developers on SUSE can run the same CI image through a container runtime. This needs a test before the team relies on it.

## Alternatives considered

- SQL Server 2022 on SLES: conflicts with the latest-GA rule.
- Windows Server for the database: consistent with FR-PLT-045, not verified on Windows in this repository.
- PostgreSQL 16: rejected for now. The PostgreSQL output has no security layer (see the port analysis in the database design notes).
