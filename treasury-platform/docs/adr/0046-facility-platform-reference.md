# ADR 0046: The platform reference of a facility (COMPANY-BANK-CLASS-YY)

Status: accepted on 2026-10-23 at the owner's request (docs/31, row 43). Written by an AI agent.

## Context

A facility had two numbers: the bank's reference from the agreement (`BankReferenceNo`, free text) and an internal
number from a sequence (`FacilityNo`, `FAC-YY-NNN`). Neither tells a treasury user which company, which bank and
which kind of facility a number names. The owner asked for a reference of the platform, "the most important thing":
the company's code (two or three characters), the bank's code (three letters), the class of the facility in the
platform (three letters: CAP for working capital, LTL, STL, MTL and others), and the year, which changes at each
renewal (26 for 2026).

## Decision

- **Shape.** `COMPANY-BANK-CLASS-YY`, for example `IMP-SNB-CAP-26` (BR-FAC-021, `BankFas.Core.Facilities.FacilityReference`).
- **Codes.** `org.Company.RefCode` (two or three capital letters or digits, a letter first) and
  `ins.Institution.RefCode` (three capital letters), each unique in the tenant and checked in the database. Not
  given at creation, they are the company code or the institution code when that code has the shape; otherwise
  they are set on the company or the institution.
- **Class.** `fac.Facility.FacilityClassId`, an item of the lookup list FACILITY_CLASS (CAT.LOOKUPS v4): CAP, STL,
  MTL, LTL, RCF, TRF, GTE, PRJ, FXL; the tenant may add items of three capital letters. It is chosen on the
  facility and changes until the reference is written.
- **Bank.** The sole, lead or agent lender, else the first (the order of the lead bank elsewhere).
- **Year.** The year the facility is in force from (`EffectiveFrom`), two digits.
- **When.** The first approval writes `fac.Facility.PlatformRef` in its transaction, before the facility becomes
  ACTIVE. The revision check refuses the first approval while a part is missing (V-FAC-REF), and the database
  refuses a facility past DRAFT without a reference. Once written, the reference does not change: a later change of
  a code applies to the next facilities, and the class is fixed (V-FAC-REF-FIXED).
- **Renewal.** The successor keeps its predecessor's stem (company-bank-class) and takes its own year:
  `IMP-SNB-CAP-27`. A change of a code does not split the chain.
- **Collision.** A second facility with the same stem and year takes a serial: `IMP-SNB-CAP-26-2`, then `-3`. The
  check and the write hold a range lock on the references of that stem and year.
- **Display.** The facility list, its card, the selection panel of a request and the notifications show the
  reference once written; the internal number stays on the card and in the audit, and is what a draft shows.

## Consequences

- The model has three new columns and two filtered unique indexes; the generated DDL and the data dictionary are
  regenerated. There is no migration script: the release is still the baseline (db/migrations/README.md).
- Every test that approves a facility gives it a class and gives its banks a reference code.
- Open: a screen to manage the FACILITY_CLASS items beyond the catalogue screen; the class list in the facility
  form is the default nine.
