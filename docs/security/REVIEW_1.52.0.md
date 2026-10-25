# Review of all modules before release 1.52.0

The owner asked for a review of every module before release 1.52.0 (wave 8). The release waits for this review and for
the owner's approval. This note records what was checked, what was found and fixed, and what remains. Schema files up to
`1168_ports_of_entry.sql`; about 760 API addresses; the web, mobile and database layers.

## What was checked

| Area | How | Result |
|---|---|---|
| Who may read what | `backend/tests/test_access_sweep.py`: every address under each portal's prefix is called anonymously and by every other portal's session | Refused everywhere outside the owner portal |
| Who may write what | The same sweep with POST, PUT, PATCH and DELETE, for anonymous callers and the PASSENGER, DRIVER, AGENCY and STATION sessions; the station portal joined the sweep | Refused (401/403), or the body is refused (400/405) before any change |
| Addresses no test named | `backend/tests/test_address_smoke.py`: 25 addresses, each called by its own portal with a value that names nothing or an empty body | No server error |
| Translation | Every key of the English files exists in Arabic, and the reverse (web, mobile, API messages); a search for hard-coded English text in screens | Complete; no hard-coded text found |
| The web against the API | The contract check of the web calls against the API's addresses | Every call has its address |
| SQL built from text | Every f-string query in the API | Only column lists and placeholders the code itself chooses; values always go as parameters |
| Unauthenticated writes | Public write addresses (sign-up, guest booking, sign-in, relay) | Each has its own limit or secret |
| Uploaded files | Every upload reads at most its limit plus one byte; the edge refuses bodies over 6 MB | Bounded |
| Uploaded workbooks | The five importers that read Excel files | **Finding 2** |
| Money rounding | Every Python `round(` in the API | **Finding 1** |
| Foreign keys without an index | `db/tools/fitness.py` | 251 of 1822 on a clean build, all in the accepted baseline, which only shrinks; no new one |
| Browser code | `dangerouslySetInnerHTML`, `eval`, `console.log` in web and mobile | One use, for the built-in icon set (no outside text) |
| Server-side calls | `subprocess`, `shell=True`, disabled certificate checks | None |
| Full suite on a fresh database | 951 backend tests, 1132 database checks | **Finding 3** |
| Production installation | The CI job that installs the production profile | **Finding 4** |
| Screens | Accessibility, direction and language, sideways scrolling, in both languages and both screen sizes (292 page views) | No critical or serious finding |

## Findings and fixes

1. **Halves rounded by parity.** Prices that round to a whole currency unit used Python's `round()`, which takes a half
   to the even unit: 2,550 became 2,600 and 2,650 became 2,600 too, while the database's `round()` gives 2,700. The
   difference reached the counter sale price and the fare by passenger category. The freight rate per ton and the taxi
   fare per km rounded minor units the same way. Fixed: `app/util.py` has `round_unit` (whole unit) and `round_minor`
   (minor units), both halves up; sales, fare categories, freight and taxi use them
   (`backend/tests/test_rounding.py`).
2. **Workbooks parsed without defusedxml.** openpyxl turns off XML entities only when `defusedxml` is installed. It was
   installed on the developers' machines through other packages, but not in the image, which installs only
   `requirements.lock`. An uploaded workbook could declare entities that expand (the "billion laughs"). Fixed:
   `defusedxml` is a direct requirement, locked with its hashes. `backend/tests/test_xlsx_entities.py` checks that
   openpyxl runs with it, and that every importer (geography, roads, ports, registries, vehicles) treats a workbook with
   entities as a file error. The first check fails when the package is missing.

3. **Port edits trusted two unguarded settings.** The history of border crossings and airports (1168) took the reason
   of a hand edit and the file of a load from two session settings. Only the settings the database module guards may
   carry trust (1084), and these two were not among them. The full run caught it
   (`test_every_custom_setting_the_schema_trusts_is_guarded`). Fixed before release: a hand edit gives its reason in
   the row's `change_reason`, which the trigger moves into the history and clears; a load is recognised by the new
   `source_id` it sets. The helper `net.port_change_note` is gone.
4. **The egress proxy refused calls once a minute.** Its entrypoint ran `squid -k reconfigure` every 60 seconds. A
   reconfigure closes and reopens the listening port, so an outbound call (payments, notices, webhooks) made in that
   moment was refused. The production installation job's self-test hit it. Fixed: Squid is reconfigured only when the
   shared lists change, and the self-test retries a refused connection for a few seconds.

## Open items (not blockers)

* The 251 foreign keys without an index stay in the accepted baseline of `db/tools/fitness.py`. The baseline only
  shrinks, and a new foreign key must come with its index. Each one should be looked at before its tables grow.
* The local screen checks skip the station portal and the departure board unless a station session is given
  (`MASSLAK_UI_STATION`). CI gives one, so they are checked there.
* N46 (station screens over the network) is deferred by the owner until the waves are finished.
* Server hardening of SSH is planned for wave 9, with the owner present.

## Release

Release 1.52.0 (wave 8) is held until the owner approves this review.
