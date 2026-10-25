# ADR 0049: Slice S4 of the application (sales letters of credit), its defaults and deviations

Status: built on 2026-10-24, at the owner's request "continue the plan after the check finishes" and "finish to the
end without coming back to me". The twelve open questions (OQ-1 to OQ-12) were built on their recommended defaults,
**pending the owner's approval** (docs/31, row 50; docs/49 §4). Written by an AI agent.

## Context

S4 is the sales side of letters of credit: the proforma invoice a customer opens a credit against (FR-LCE-001 to
008, FR-LCT-029), the received credit and its balances (FR-LCE-009 to 015), sales orders that earmark it and
collection documents that convert the earmarks into drawings (FR-LCE-016 to 021), amendments, close and the
comparison with the proforma (FR-LCE-022 to 027, FR-LCT-031), on the S3 workflow engine. The exit is AC-LCE-1,
AC-LCE-2 and AC-LCE-3.

## Decision

### 1. Batches

| Batch | Content | Commit |
|---|---|---|
| S4-A | WFL.BASE v2 (roles SLP, SLR, SLA; PROFORMA_REQUEST, SALES_ORDER_APPROVAL, COLLECTION_DOCS_REQUEST), CORE.NUMBERING v4, NTF.BASE v7, settings `lc.earmark.cap_includes_tolerance` and `lc.proforma.no_lc_days`, hook keys | fd00239 |
| S4-B | Proforma form and totals, PROFORMA terms, `lc.issue_proforma`, sealed print, register, card, void, copy | fd00239 |
| S4-C to E | Received credits, search and balances, `lc.earmark_sales_order`, `lc.convert_earmark`, drawings, discrepancies, amendments, close | 23fa986 |
| S4-F | Comparison, JOB-LCE-NOLC, screens, e2e, documents | 069a374 and the documents commit |

### 2. The balance invariant

`Amount = EarmarkedRemaining + Drawn + Available` on every received credit. Every move (earmark, conversion,
refusal, order close, amendment) runs in one transaction under an update lock on the credit's row, and checks the
invariant through `SalesRules` in `BankFas.Core`. The raise of a sales order checks the balance as advice only;
the earmark hook checks it again under the lock and is the binding check (OQ-5).

### 3. Proforma numbers and documents

The number is `{seq:000}-{erp}-{yy}` from `cfg.usp_AllocateNumber('PROFORMA', company, today)`, gap free per company
and calendar year; the `cfg.NumberIssue` row is bound to the proforma in the same transaction. The printed
proforma is a self-contained HTML page with the IBAN, stored encrypted as a `PROFORMA_ISSUED` document through
`IProformaServices` (the API holds the tenant keys; the worker never issues). No server-side PDF library is added
(OQ-4); the browser prints it.

### 4. Terms of a sale

Sales terms (scope SALES, purpose PROFORMA or RECEIVED) refuse the purchase-only fields (beneficiary, margin,
accounts, previous credit, supplier proforma). The applicant is the proforma's customer; the amount is the part of
the total paid by credit, written at submission.

### 5. Comparison

`TermsComparison` gives each field a verdict from the beneficiary's side (BR-LCT-021). The verdicts are stored with
the run; the treasury decides each difference (ACCEPT, REQUEST_AMENDMENT, IGNORE) and the run is REVIEWED when all
are decided. The locked terms never change.

### 6. Amendments without a workflow (OQ-7)

A sales amendment is recorded with its decision by the holder of `lc.amendment.record`. An accepted one supersedes
the terms and copies them as the next version; one that lowers the amount below what is earmarked and drawn is
refused (V-LCE-11).

## Consequences

- The three sales roles are custom roles that a tenant may change (OQ-1).
- An expired credit keeps its earmarks until the treasury closes it (OQ-8).
- Deviations and what is not built yet are listed in docs/49 §5: PDF, an amendment workflow, sales reports.
