# ADR 0043: Slice S2 of the application, its defaults and the gaps it closed

Status: built on 2026-10-22 on the owner's requests "start building S2", "continue the build after the study" and
"continue" (docs/31, row 40). The defaults below were taken from the S2 brief (OQ-1 to OQ-17) and wait for the owner's
approval. Written by an AI agent.

## Context

S2 is the facilities module: the facility package and its revisions, the limit tree, product lines and their terms,
availability and the reservation core, tariffs and pricing, collateral and guarantors, obligations and the reporting
agenda, breaches, and comparable terms. The brief found twenty gaps between the specifications and the database
(S2-GAP-1 to 20) and seventeen open questions (OQ-1 to 17). Its exit is the four agreements of docs/04 entered with no
constraint outside the model (AC-FAC-11) and 100 concurrent reservations on one limit (AC-FAC-12).

## Decision

### 1. Batches

| Batch | Content |
|---|---|
| S2-A | Packs CMP.TERMS v1, FIN.FORMULAS v1, CORE.NUMBERING v2, CORE.EXPIRY v3, NTF.BASE v4; two settings; static script 062; working days and Hijri; expiry providers per kind; S2 in-use sources and merge cases; the open-facility check on closing a relationship |
| S2-B | The facility package, revisions and the approval order, validity and JOB-FAC-VALIDITY, the FACILITY expiry provider, SCR-FAC-01 and 02 |
| S2-C | The limit tree, lines, company rules and line terms in the draft; availability (SVC-FAC-03); utilisations, balances and the reservation core; LIMIT and PRODUCT_LINE providers |
| S2-D | Tariff schedules, facility pricing rules, the resolver (SVC-FAC-05), SCR-PRC-01 and 02 |
| S2-E | Collateral and its versions, links through the revision, coverage, guarantees of a party, PTY.KYC v1, completeness and the guarantor pack |
| S2-F | Obligations, the agenda and JOB-OBL-CALENDAR, reporting instances, breaches, compliance (SVC-FAC-06), comparable terms and their comparison, the DS-AGR packs, the exit tests, these documents |

### 2. Database changes

- `db/static/062_s2_guards.sql`: the code, unit, value kind and system flags of a system `cmp.TermType` are fixed;
  an APPROVED or SUPERSEDED tariff schedule keeps its items and tiers; the typed parts of an APPROVED collateral version
  are fixed except the operational dates (note renewal, last valuation); RELEASED and TRANSFERRED utilisations are
  final. New error 50176, mapped to 409 APPROVED_FINAL.
- Seed 100: `fac.validity.expiring_days` (INT 90, 30 to 180) and `wf.sod.allow_same_person` (BOOL false).
- Packs: CMP.TERMS v1 (35 comparable keys), FIN.FORMULAS v1 (eight TEMPLATE formulas approved by the tenant's system
  user, OQ-5), CORE.NUMBERING v2 (`FAC-{yy}-{seq:000}`), CORE.EXPIRY v3 (seven S2 rules), NTF.BASE v4 (ten S2 events,
  no amount in any text), PTY.KYC v1 (the base profile of BR-PTY-013). The tenant seeder gains an `Activate` step: a
  profile is written DRAFT, its items added, then it is made ACTIVE, because the 041 guards freeze an active profile.

### 3. The approval order of a revision (S2-GAP-2)

One transaction, after a dry run of the checks and the segregation of duties (OQ-6, from the audit rows of the
revision's opening and saves):

1. The draft is already the copy: the first edit of a draft copied every approved row of the [R] tables (limits,
   lines, company rules, line terms, lenders, documents, pricing rules and tiers, collateral links, obligations,
   reporting rules, covenants, entered terms, and their junction rows) to revision R and closed the copied ones at R.
   EffectiveAmount is written root to leaf on every save.
2. Active utilisations and reservations are relinked to the rows R opened.
3. The comparable terms are projected (FromRevision = R) and the open projected rows closed at R.
4. The revision becomes APPROVED.
5. Last, in one UPDATE: ApprovedRevisionNo = R, the lifecycle, and the header changes.
6. The agenda is generated up to the horizon (ReportingInstance is not revisioned).
7. Audit, outbox (`facility.revision.approved`, `term.value.changed` when terms were projected,
   `facility.validity.changed`), FAC.REVISION_STATE, and the supersession of the predecessor when the successor's
   start has come (OQ-15).

Steps 3 and 4 precede step 5 because the triggers of 044 refuse an approved number that names a revision that is not
APPROVED, and a revisioned insert whose FromRevision does not exceed the approved number. DOC-F13 section 7.3 was
corrected to this order.

### 4. The term projection

Twenty-nine of the thirty-five keys are projected from typed fields: pricing (arrangement fee, margin, base rate family,
day count, zero floor, fixed rate, LC commission add-on, treasury fee per million, unilateral change and objection
days), durations (facility term, notice, LC validity, deferral, tenor, the two reporting lags), covenants (capital
preservation, minimum average balance, revenue channelling) and collateral (note percentage, guarantors, insurance, cash
cover, financing ratio, set-off, negative pledge, valuers). A value the agreement leaves empty is projected with the
state NOT_SPECIFIED_IN_AGREEMENT, never as zero, and stays out of the ranking and the average. The other six keys are
entered by hand and are refused when the key is projected (V-CMP-01). Each old projected row is followed by at most one
new one, so two lines with the same key keep two roots. A proposed key (OTHER) is promoted by `cmp.manage`.

### 5. The expiry job

A late first notice stands for the reminders already due: when EXPIRED is sent after the first reminder interval has
passed, the current reminder level is recorded with it, so a catch-up run sends one message, not two.

### 6. The DS-AGR packs (S2-GAP-1)

`app/tests/data/DS-AGR/{A,B,C,D}/v1/` holds `agreement.json` (the facility as the API takes it), `summary.csv` (what
the loaded facility must show) and `manifest.json` (preparer, reviewer, approver, status, SHA-256 fingerprints). JSON
was chosen over spreadsheets because the loader posts it to the API as is and a reviewer can read the diff. The packs
keep the structure of the four agreements and nothing that identifies them: synthetic names, amounts scaled by one
unrecorded factor per pack, dates shifted by whole years, generated clause text. They were written by an AI agent and
are PROPOSED; the roles of DOC-B06 section 6.2 sign them before UAT. The loader checks the fingerprints first.

### 7. Other notable rules

- The guarantor pack is the browser's print of a dedicated page with a watermark on the draft; no PDF library is added.
- C's capital preservation covenant uses the TANGIBLE_NET_WORTH template; it approximates the clause, and the exact
  line definition comes with the statement lines of S2-b.
- A database CHECK violation surfaces as 422 "A value is not valid.", so each endpoint validates the columns of its
  checks first (the pricing objection days are an example found by the D pack).

### 8. The defaults taken

OQ-1 to OQ-17 as listed in docs/45 section 4. None is approved yet; the exit in DOC-B02 section 10 holds once OQ-1
and OQ-17 are.

## Consequences

- S3 adds the reservation hooks, override, convert and adjust, the LC condition check (AC-FAC-3) and the utilisation
  services (AC-FAC-9), and re-runs AC-FAC-12 through the engine.
- S2-b adds covenant tests from statements (AC-FAC-7), WARNING and NeedsReview breaches, the manual review of
  descriptive covenants (FR-OBL-007, OQ-4) and the expression parser of formulas.
- A change of a default is a later change, not a rebuild.
