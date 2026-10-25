# ADR 0051: PDF from headless Chromium, and files uploaded onto requests, credits and facilities

Status: built on 2026-10-25 at the owner's request (docs/31 row 52). Written by an AI agent.

## Context

S4 and S5 printed HTML for the browser and exported CSV (S4 OQ-4, S5 OQ-2). The owner asked for PDF printing and
saving, and for files attached to requests and credits (SWIFT copies, amendments, approvals of an authorised person)
and agreements, all kept in the system.

## Decision

1. **PDF.** `PdfRenderer` runs a headless Chromium on the platform's own self-contained HTML (`--print-to-pdf`), in a
   new temporary profile, with every host name unresolvable, two at a time, one minute at most. Chromium shapes Arabic
   and right-to-left text correctly; the .NET PDF libraries we could use do not, and the HTML pages already exist.
   `format=pdf` on the terms print, the request print and the report export; the issued proforma stores its PDF as
   version 2 (current) over the sealed HTML version 1. Without Chromium the PDF answers are 503 PDF_UNAVAILABLE.
2. **Request print** (FR-REQ-026): HTML of the request in the viewer's view with a watermark (who and when), as page,
   PDF, or PDF saved as a REQUEST_PRINT attachment of the request.
3. **Uploads onto an entity.** `/requests/{id}/attachments/upload`, `/lcs/{id}/documents/upload` and
   `/sales/lcs/{id}/documents/upload` store the file through the same document creation as the register (scan,
   envelope encryption, link, audit) and attach it, with the access of the request or the credit rather than
   org.document.manage. A slot takes its own type; an extra attachment a type that applies to REQUEST (or LC).
4. **Credit files** are the documents linked to the credit plus the attachments of its issue request and child
   requests (`LcDocuments`); filing needs one of lc.issuance.record, lc.amendment.record, lc.drawing.record,
   lc.export.record.
5. **Types**: CAT.DOCTYPES v2 adds AUTHORITY_APPROVAL, LC_AMENDMENT_COPY and the system type REQUEST_PRINT.

## Consequences

- The API image carries Chromium and an Arabic font (`app/deploy/`); `Pdf__Chromium` names the binary.
- Rendering a proforma's PDF happens inside its issue transaction (a few seconds).
