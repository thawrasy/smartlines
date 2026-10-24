# Releases: one version, its files and what runs with what

Independent review, round 9 (MAN, P1): a release is one name for the tag, the schema, the API, the images and the
evidence pack. The name is the repository's `VERSION` file.

## Rules

- **One version.** `VERSION` names the release being built. The highest version a schema file records in
  `sys.schema_migration` must equal it (`scripts/check_release.py`, CI job "Security and policy checks"); the database
  then records every build and upgrade under that name (`sys.record_release`), and the API, the metrics, reports'
  `source_version` and the evidence pack read it from there. A release adds its row in its last schema file, as 1140
  does for 1.51.0.
- **Published from a tag.** `release.yml` refuses a tag that is not `v<VERSION>` (job "The tag is the release VERSION
  names"), runs the whole CI on the tagged commit, then builds, signs and publishes the archive and the images.
- **Installed from a tag.** A production server refuses to install or update from a checkout that is not the tag
  `v<VERSION>`, and from an archive whose `RELEASE` records another version (`deploy/production/preflight.sh`). Staging
  may run any commit; production runs releases only.
- **Upgraded forward.** Expand, backfill, validate, index concurrently, contract (`docs/database/MIGRATION_PLANS.md`).
  A release never removes what the previous release's API still reads; the contract step comes one release later.

## Releases and their schema files

| Version | Schema files | Tag | What it carried | Upgrade notes |
|---|---|---|---|---|
| 1.48.0 | up to 1079 | `v1.48.0` (05cc3ee) | Review of 1.47.0: packages A to H | **1064** partitions bookings and **1070** moves default-partition rows: both lock their table (measured: about 35 s per million bookings for 1064). Rehearse on a copy of production size and run them in the maintenance window of `docs/database/MIGRATION_PLANS.md`, or before any production data exists |
| 1.49.0 | 1080 to 1083 | `v1.49.0` (dacc603) | Verified request context, role split, production profile | **1080**: the API of 1.48 sends no context ticket. Open `sys.context_unsigned_window` for the upgrade's minutes only, restart the API on 1.49 images, close it (RUNBOOKS.md) |
| 1.50.0 | 1084 to 1093 | `v1.50.0` (fc42bed) | Settings guard, station portal, boarding photo policy | **1084** needs the database image with `masslak_guard` preloaded (`db/guard`); install the 1.50 database image before the upgrade |
| 1.51.0 | 1094 to 1140 | `v1.51.0` (release candidate) | KYC, trip numbers, journeys, charter, geography, connections, freight, the evaluation reports and the independent review (step-up, definer revoke, dead deliveries, company report schedules) | No locking change to a large table. **1136** (step-up) makes 18 sensitive operations ask for a recent second factor: staff who have not enrolled one must do so before the upgrade |

The versions 1.49.0 and 1.50.0 were published without a row in `sys.schema_migration`, so databases built from them
recorded themselves as 1.48.0; schema file 1140 adds the missing rows.

## What runs with what

| API of | on a database of | |
|---|---|---|
| the same release | that release | supported |
| release N | release N+1, during an upgrade | supported for the upgrade's minutes: the schema only expands; 1.48 on 1.49 needs the unsigned window above |
| release N+1 | release N | refused: the API checks the schema hash against the release manifest and does not start (critical control C-02) |

Mobile apps call the public API through the versioned contract (`docs/api/openapi-baseline.json`); a change that
would break an installed app is refused by the contract check in CI.

## Cutting a release

1. Set `VERSION`, and record the version in the release's last schema file.
2. `python3 scripts/check_release.py` passes; CI is green on the commit.
3. Tag the commit `v<VERSION>` and push the tag; `release.yml` publishes the signed archive, images and evidence pack.
4. On the servers: `deploy/verify-release.sh` on the archive, then `deploy/update.sh` (RUNBOOKS.md, section 19).
