# ADR 0001: Schema work and CI run on Linux (RHEL, not Ubuntu)

Status: accepted for schema development and verification (2026-10-12). Ubuntu is excluded by the team's decision. The production host operating system is open (O-23).

## Context

- The team works on Linux and can operate Linux servers. Some company developers use SUSE servers.
- SQL Server 2025 on Linux is supported on RHEL and Ubuntu. Per the Microsoft release notes, SLES (SUSE) is listed only through SQL Server 2022 (checked by search summary; verify on learn.microsoft.com).
- The official RHEL-based SQL Server 2025 image is `mcr.microsoft.com/mssql/rhel/server:2025-latest` (Red Hat Ecosystem Catalog; the base OS version of the tag is not confirmed).
- The earlier stack decision (FR-PLT-045, decision 01 section 13) names Windows Server, ASP.NET Core and the latest GA SQL Server as the target.
- The existing verified path is CI on a GitHub-hosted Ubuntu runner with the Ubuntu-based SQL Server container (`tools/ci/db_ci.sh`, `.github/workflows/db-ci.yml`). That path is excluded by this decision.

## Decision

- Schema models, generated DDL, static scripts and database tests are developed and verified on RHEL.
- The SQL Server container is the RHEL-based image. Verified: the full CI (model, DDL, deployment, object counts, six trigger tests, 34 isolation cases) passes on `mcr.microsoft.com/mssql/rhel/server:2025-latest`, which reports Red Hat Enterprise Linux 10.2. The job runner stays on GitHub's Ubuntu host until a RHEL self-hosted runner exists.
- Deployment uses `tools/deploy/deploy.sh`, which changes to `db/` before it runs `deploy.sql`.
- The CI runner must be a RHEL host (self-hosted), because GitHub-hosted runners run Ubuntu, Windows or macOS. This choice is open until the team decides.
- The Windows wrapper `tools/deploy/deploy.ps1` is kept, but it has not been run.

## Consequences

- The production host must be RHEL for SQL Server 2025 on Linux, or Windows under FR-PLT-045. SUSE is not a supported host. Whether a SQL Server 2025 container may run on a SUSE host is not confirmed.
- SQL Server 2022 on SUSE would keep SUSE, but it conflicts with the latest-GA rule in FR-PLT-045.
- Until a RHEL runner exists, the GitHub workflow runs on Ubuntu and is not a RHEL verification.
- The Windows deployment path remains unverified until it runs on a Windows target.

## Alternatives considered

- SQL Server 2022 on SLES: conflicts with the latest-GA rule.
- Windows Server for the database: consistent with FR-PLT-045, not verified on Windows in this repository.
- Ubuntu: excluded by the team's decision, although it is supported by SQL Server 2025.
- PostgreSQL 16: rejected for now. The PostgreSQL output has no security layer.
