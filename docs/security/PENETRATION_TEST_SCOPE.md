# Penetration test: scope and rules of engagement

**Owner decisions (8 October 2026) this follows:**
- The test is run by an external cybersecurity firm or an independent tester, not by the developers.
- The testers get access only through the permission matrix: time-bound, never by default, never open-ended.

**Launch condition:** every critical or high finding is fixed and retested before general launch, or the owner accepts
it formally in writing with a reason and a date (launch gate 8, `docs/operations/LAUNCH_GATES.md`).

## 1. Parties and authorisation

| Item | Content |
|---|---|
| Client | Masslak platform owner (signs this document and the engagement letter) |
| Tester | Independent firm or tester, named in the engagement letter, with no part in building the system |
| Engagement reference | Recorded on every access grant (`engagement_ref`) and every report |
| Authorisation | Written, signed before any testing; it names the targets, the window and the testers' source addresses |
| Contacts | One technical contact and one escalation contact on each side, reachable during the whole window |

## 2. Targets

The test runs on **staging** (`docs/operations/STAGING.md`). It never runs against production or real personal data.
Staging is in sandbox mode, with synthetic data only.

| Area | Targets | Focus |
|---|---|---|
| Web API | All routes under `/api` (OpenAPI from the staging build): auth, account, wallet, finance, carrier, agency, driver, family, reports, admin, regulator, security, documents, notifications | Authentication and session handling; authorisation between roles and between companies (IDOR); input validation; business-logic abuse (prices, seats, refunds, wallet, commissions); rate limits |
| Partner API | `/api/v1` with client credentials; webhook subscriptions and deliveries | Key and signature handling; tenant isolation between partners; replay and idempotency; SSRF through webhook URLs (private, metadata, IPv6, IPv4-mapped, DNS rebinding, redirects) |
| Payment notices | `/api/payments/notify/{code}` | Signature forgery, replay, amount and currency tampering, order of notices |
| Web application | The SPA served by the API | XSS, CSRF, clickjacking, security headers, content security policy, storage of tokens |
| Mobile apps | Passenger, driver and operator apps (`mobile/`), Android and iOS builds for staging | Local storage, certificate handling, offline ticket credentials, device binding and attestation of positions, spoofed GPS and replay |
| Database isolation | Row-level security through the application roles | A user of one company reading or changing another company's data through any route; access to platform-only tables (`sys.rls`); report builder reaching beyond the user's scope |
| Authentication | Sign-in, password reset, MFA (TOTP) for staff, session expiry, device revocation | Brute force, enumeration, MFA bypass, session fixation, token reuse after revoke |
| Files | Document upload and download | Malicious files (scanned, fail-closed), path traversal, content-type confusion, access to another company's files |
| Infrastructure (staging host) | Exposed ports, TLS, the egress proxy | Only 80/443 exposed; TLS configuration; no direct route out from the API or worker containers |

**Out of scope:**
- denial of service or load beyond what the firm agrees with the operator;
- social engineering of staff;
- physical tests;
- third-party providers' own systems (payment gateways, SMS, e-mail);
- the AI and contact-centre phase (switched off; it gets its own test before it opens).

## 3. Access given to the testers

| Access | How | Limit |
|---|---|---|
| Application accounts | Test accounts of every role (passenger, carrier staff, agency, driver, regulator, platform admin), created on staging for the engagement | Staging only; removed at the end |
| Read-only platform view (when the test is grey-box) | Role `EXTERNAL_AUDITOR` (audit and policy matrix, read-only), granted only through `sec.external_access_grant`: `POST /api/admin/external-access` with the engagement reference | At most 30 days per grant (`security.external_access_max_days`). Granted by a platform admin or security officer other than the reviewer. Cannot be extended, only replaced by a new grant. Revocable at once. Every grant and revocation is an audited event |
| Source code (when the test is white-box) | Read access to the repository given to named people for the engagement, with an expiry date equal to the grant's | Never a standing or default access. Removed at the end of the window. Recorded in the engagement's access log with who granted it |
| Evidence pack | `db/tools/evidence_pack.sh` output for the tested commit | Contains no business rows, secrets or key material |

**No production credentials, keys or personal data are given at any time.**

## 4. Rules of engagement

1. **Window:** testing only within the agreed dates and hours. Source addresses are given in advance.
2. **Stop and call:** stop at once and call the technical contact if any of these happens:
   - a test affects other tenants on staging;
   - real personal data appears;
   - a critical vulnerability with remote impact is found (report it within 24 hours, without waiting for the report).
3. **Data:** no exfiltration beyond what proves a finding (a record identifier, not the record). Anything collected is
   destroyed at the end, and the firm confirms this in writing.
4. **No persistence:** no back doors, no changes left behind. Test accounts and objects are listed in the report so they
   can be removed.
5. **Confidentiality:** findings are shared only with the named contacts until they are fixed.

## 5. Severity and remediation

| Severity (CVSS 3.1 or 4.0, adjusted for business impact) | Fix deadline | Launch |
|---|---|---|
| Critical | Fix within 7 days, retest by the firm | Blocks launch until retested closed |
| High | Fix within 14 days, retest by the firm | Blocks launch until retested closed, or accepted by the owner in writing |
| Medium | Fix within 45 days, or before launch if it touches money, authentication or isolation | Tracked; does not block unless the owner decides so |
| Low / informational | Planned in the backlog | Does not block |

**After the test:**
- Every finding goes into a remediation register: id, severity, owner, fix commit, retest result and date.
- The firm's retest letter confirms each critical and high finding is closed. That letter is the evidence of launch
  gate 8.

## 6. Deliverables from the firm

- **Executive summary.**
- **Technical report:** each finding with its steps to reproduce, evidence, affected targets, severity and recommended
  fix.
- **Accounts and objects:** the list of test accounts and objects created.
- **Retest letter** after remediation.
- **Data destruction:** written confirmation that collected data was destroyed and access ended. The platform side
  confirms that every `sec.external_access_grant` of the engagement is revoked or expired, and that repository access
  has been removed.
