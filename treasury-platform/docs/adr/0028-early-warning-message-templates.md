# ADR 0028: The message templates of the early warning, in Arabic and English

Status: decided by the database architect on the owner's request of 2026-10-20 to build the message templates of the
early warning in Arabic and English. Builds on ADR 0027 (the early warning job) and on the notification path of
DOC-F17 (section 6.4: templates and language) and DOC-B05 (section 6: the seed packs).

## Context

ADR 0027 sent one event, FIN.READINESS_WARNING, for red and amber dates alike. A template belongs to an event, a
channel and a language (`ntf.NotificationTemplate`), and so does the mandatory flag (`ntf.NotificationEventType`).
With one event, a red date and an amber one would read the same, and either both would be mandatory or neither.
The request carried no text either: the notification builder had nothing to fill a template with but identifiers.

## Decision

1. **Two events**, by readiness:
   - FIN.READINESS_RED: severity HIGH, mandatory, in the application and by email;
   - FIN.READINESS_AMBER: severity WARNING, in the application, which a user may take in the daily digest or turn off.
   The job writes the event code by the readiness of the warning; the dedup key becomes
   `<event code>:<kind>:<reference>:<stage>:<yyyymmdd of the date>`.
2. **The reason**: `fin.fn_CreditReadinessEvents` (049) gives the first rule that set the readiness (`ReasonCode`, in the
   order of BR-FIN-038: 13 codes), and `fin.EarlyWarningAlert` keeps it, so the message says why.
3. **The values of the placeholders**: `fin.v_EarlyWarningMessageValues` (051), by the MessageId of the request, in
   Arabic and English: the company, the kind of date, its reference (the facility number or the obligation's title),
   the date, the days left, the stage, the reason, the grade and liquidity of the assessment, the lead time, and the
   link to the readiness file. No restricted value is among them (FR-NTF-021).
4. **The templates** are the first content of the tenant pack NTF.BASE (`db/seed/packs/NTF.BASE/v1/`, DOC-B05 section 6):
   - CSV files with the model's columns, and a manifest that maps each placeholder to its view column;
   - the two event types, the recipient rules (TM, FO and FA within the company scope; TM and FO mandatory for red),
     and eight templates: in the application and by email, Arabic and English, for each event;
   - the email gives the reason, the grade, three steps before the date, when the warnings come, and that the grade
     is the system's internal calibration for the company, not the lender's rating.
   The application's tenant seeder (ITenantSeeder) loads the pack.
5. **The checks**: `tools/dbgen/ntf_pack.py`, in CI, checks the pack: the columns against the model, every
   placeholder in the event's allowed list and mapped to a column of the view, the four templates of each event, the
   subject length, no coalescing of a mandatory or HIGH event, the roles of CORE.ROLES. It also writes the test's
   fixture from the pack, so the test reads the templates as shipped.

## Consequences

- One column on `fin.EarlyWarningAlert` (`ReasonCode`), one view, and the first tenant pack in the repository.
- Test CA24 fills the templates as the builder would, for a red renewal and an amber covenant test:
  - the Arabic and English notices in the application;
  - the Arabic email;
  - all eight messages without a placeholder left, within 300 and 2000 characters.
  Test CA23 checks the new event code and dedup key.
- The wording was written by an AI agent. The treasury and the owner approve the pack before it is used (DOC-B05
  section 5: whoever prepares a list does not approve it).
- Left to the application: the seeder that loads the pack, and the builder that fills the template of the
  recipient's language, falling back to English (DOC-F17 6.4).
