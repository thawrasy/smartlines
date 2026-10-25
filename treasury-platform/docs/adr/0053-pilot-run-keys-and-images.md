# ADR 0053: Master keys in host files, persisted data protection keys, and Playwright's Chromium in the image

Status: built on 2026-10-25 during the pilot run (docs/31 row 54, docs/53). Written by an AI agent.

## Context

The owner approved the S5 completion assumptions and asked to start the pilot run. Running the release images as the
host runs them showed four things that would have stopped or hurt a real start:

1. The only master key provider was `local` (configuration), refused outside development and tests (DQ-S02-1 open),
   so a production host could not start at all.
2. ASP.NET data protection kept its keys in the container's tmpfs: every restart invalidated the opaque references,
   list cursors and pending enrolment secrets.
3. The .NET 10 images are Ubuntu 24.04, whose `chromium` package is a snap stub that does not run in a container,
   so the API image had no working PDF printer.
4. The image build failed behind a TLS-inspecting proxy (NuGet's certificate chain).

## Decision

1. **`Keys:Provider=file`** (interim until a key store or HSM is chosen; DQ-S02-1 stays open): each `<name>.key` in
   `Keys:File:Directory` is the base64 of 32 bytes and the key `file:<name>`; a file readable by group or others is
   refused. The same envelope as the local provider. Allowed in every environment.
2. **`DataProtection:KeysDirectory`**: the keys are persisted there, each wrapped with the current master key
   (an `IXmlEncryptor` over `IKeyWrapper`); required outside development and tests.
3. **Chromium from Playwright** (the build the browser and PDF tests run on), downloaded in a build stage, with the
   libraries Playwright lists for Ubuntu 24.04 from the HTTPS mirrors; `--build-context chromium=<chrome-linux>`
   replaces the download where Playwright's servers are not reachable.
4. **An optional build secret `extra_ca`** for a proxy's CA, used by npm, NuGet and apt during the build only; it
   never enters an image.
5. **`tools/ci/image_pilot.sh`**: the browser tests of `e2e.sh` against the two containers, read-only, no
   capabilities, user 10001, file master keys and persisted data protection keys; it checks that both stay up, that
   the worker ran its jobs and that the stored keys are wrapped.

## Consequences

- A production host needs, before the first start: the master key files (and an offline copy), the data protection
  directory, the full leaked-password list (`tools/host/download_breached.sh`), ClamAV, an SMTP relay and a trusted
  SQL Server certificate (`tools/host/README.md`).
- Losing the master key files loses every encrypted value; the offline copy is part of the provisioning record.
- The API image is about 1.5 GB because of Chromium.
