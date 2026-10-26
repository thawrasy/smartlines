# Know your customer for companies

The owner's request of October 2026 (migration 1118). When the platform establishes a company it opens the company's
know-your-customer (KYC) file. The file holds what compliance, tax and finance officers and the transport regulators ask
of a carrier:

- who the company is, and who owns and controls it;
- its licences, finances and taxes;
- how it operates today: trips direct and with stops, passengers, routes and ticket prices, stations, fleet, staff and
  agents;
- what it expects to run on the platform and what it expects from the platform;
- its declarations and consents.

Every rule a law or a regulator may change is data or a setting, so a new rule needs no new release.

## Standards the form follows

| Standard | What it asks | Where in the form |
| --- | --- | --- |
| FATF Recommendation 10 (customer due diligence) | identity of the legal person, its nature and purpose, its directors and signatories, source of funds | identity, contacts, ownership, financial |
| FATF Recommendation 24 and its guidance (beneficial ownership) | every natural person who owns or controls 25% or more (the threshold is a setting), directly or through layers, or controls by other means; the senior manager when there is none | ownership: shareholders, beneficial owners, layers, bearer shares |
| FATF Recommendations 6 and 12 (sanctions, politically exposed persons) | sanctions listing and dealings, PEPs among owners, directors and signatories | compliance declarations |
| OECD Common Reporting Standard | the entity's tax residency and its CRS status (active or passive NFE, financial institution) | tax |
| Tax authorities | tax number and office, regime, indirect tax, stamp duty, withholding, invoicing today and the e-invoicing mandate, tax clearance and disputes | tax |
| Transport regulators | licence number, issuer, dates and scope, route permits, suspensions; fleet by type, make, model, seats, year, fuel and ownership; average age; technical inspection; passenger and vehicle insurance; licensed drivers | licensing, fleet, people, financial |

## The form

The form is a versioned definition (`iam.kyc_form`) of sections, fields, option sets and the documents asked for. One
version is active. A version that was in force is never changed (`KYC_FORM_FROZEN`): the platform makes a new version,
the database checks it (`iam.kyc_form_problem`), and the platform activates it. Each file keeps the version it was opened
on.

The first version has 13 sections, 122 fields, 26 option sets and 13 documents:

| Section | Fields | What it asks |
| --- | --- | --- |
| Legal identity | 15 | legal and trade names, legal form, country, commercial register (number, dates, authority), incorporation, chamber of commerce, LEI, paid capital, activity, group, website |
| Transport licence | 8 | licence number, issuer, dates, scope, route permits, suspensions in the last five years, the regulator's code |
| Addresses and contacts | 8 | head office, operating address, phone, email; the responsible people (at least the general manager and the compliance officer) |
| Ownership and control | 6 | shareholders, beneficial owners, layers between the company and its owners, bearer shares, directors, authorized signatories with their authority and limit |
| Compliance declarations | 9 | PEPs, sanctions listing and dealings, criminal record, litigation, penalties, adverse media, AML policy, cash controls |
| Financial | 12 | revenue, monthly ticket sales, cash share, payment methods, source of funds and of wealth, bank accounts, audited accounts, settlement cycle, passenger insurance |
| Tax | 13 | tax number and office, regime, residency, indirect tax, prices with tax, stamp duty, withholding, invoicing today, e-invoicing, CRS status, clearance, disputes |
| Current operations | 13 | operating since, services; trips a week direct and with stops; passengers and parcels a month; routes with trips a day, first and last departure, ticket price, occupancy and permit; stations used; sales channels; current system and process; refund policy; peak seasons |
| Fleet | 9 | vehicles; the fleet by type, make, model, count, seats, average year, fuel, ownership, air conditioning, accessibility; average age; oldest vehicle; inspection; maintenance; tracking; cameras; insurance |
| Staff and agents | 7 | employees by function, licensed drivers, training, social insurance; agents with city, commission, monthly sales and contract |
| Expected activity | 8 | trips a week and passengers a month expected in 6 and 12 months, online share, new routes, fleet growth, go-live date |
| Expectations from the platform | 7 | objectives, features, integrations, users to train, support, concerns, how it heard of the platform |
| Consents and declaration | 7 | consent to processing, screening and sharing with the authorities; commitment to report changes; the declarant and the declaration |

The documents asked for are the commercial register extract, articles of association, transport licence, tax
registration, identity documents of owners, directors and signatories, a bank letter and the insurance policy (required),
and a power of attorney, ownership chart, chamber certificate, financial statements, tax clearance and vehicle
registrations (when available). They are uploaded on the company's documents page and reviewed there.

A field's type is one of text, textarea, number, decimal, percent, money, date, time, email, phone, url, country,
station, select, multi, yes/no (with details), checkbox and table. A field may be required, may require details when the
answer is yes, and a table may require a number of rows. The labels of the built-in fields come from the interface's
locale files (English and Arabic). A field the platform adds carries its own labels: `"label": {"en": "...", "ar": "..."}`.

## The file and its review

A company's file (`iam.company_kyc`) holds the answers. A company has at most one open file and one approved file.

| State | Meaning |
| --- | --- |
| `DRAFT` | being filled, by the company in its portal or by platform staff from the company's paper form |
| `SUBMITTED` | complete and waiting for the next review stage |
| `RETURNED` | a stage sent it back with a note and the fields to correct |
| `APPROVED` | in force until it is reviewed again or replaced |
| `REJECTED` | refused, with the reason |
| `SUPERSEDED` | an approved file replaced by a newer approved version |

A file is submitted only when nothing is missing (`KYC_INCOMPLETE` names what is): every required field, the details a
yes asks for, the table rows asked for, and, while `kyc.documents_on_submit` is on, the required documents.

It then passes the review stages of `kyc.review_stages` in order. A stage is `COMPLIANCE`, `FINANCE`, `TAX`, or a
government authority by its code, decided by its members (`sec.authority_member`, 1117). The stages in force when a file
is submitted are kept with it. Each decision is kept in `iam.kyc_decision`, which is never changed:

- a stage approves, returns the file with what to correct, or rejects it; a return or a rejection says why
  (`REASON_REQUIRED`);
- one person decides one stage, and never the person who submitted the file (`SECOND_PERSON_REQUIRED`, while
  `kyc.distinct_reviewers` is on);
- the compliance stage may set another risk level, with its reason;
- a file of prohibited risk is never approved (`KYC_PROHIBITED`).

An approved file is reviewed again after the months its risk level sets (`kyc.review_months`). An update opens a new
version from the approved answers, and the approved version stays in force until the new one is approved.

## Risk

Risk is scored from the answers by the rules in `kyc.risk_rules` (`iam.kyc_risk`). Each matching rule adds its points
and may set a minimum level. The score gives the level from `kyc.risk_levels`, and the highest minimum wins.

| Rule | When | Points | Minimum level |
| --- | --- | --- | --- |
| `SANCTIONS` | listed on a sanctions list | 100 | PROHIBITED |
| `SANCTIONED_DEALINGS` | dealings with sanctioned parties | 40 | HIGH |
| `PEP`, `PEP_OWNER` | a PEP among the company's people, or a PEP beneficial owner | 30 | HIGH |
| `CRIMINAL_RECORD` | a criminal record | 40 | HIGH |
| `BEARER_SHARES` | bearer shares or nominees | 25 | |
| `ADVERSE_MEDIA` | adverse media | 20 | |
| `OWNERSHIP_LAYERS` | two layers or more | 15 | |
| `CASH_HEAVY` | 80% or more of sales in cash | 15 | |
| `LICENCE_SUSPENDED` | a licence suspended in the last five years | 15 | |
| `FOREIGN_OWNER` | a beneficial owner resident outside Syria | 10 | |
| `INTERNATIONAL` | international services | 10 | |
| `YOUNG_COMPANY` | incorporated less than 12 months ago | 10 | |
| `NO_CASH_CONTROLS`, `LITIGATION`, `PENALTIES`, `NO_TAX_CLEARANCE` | as named | 10 each | |
| `NO_AML_POLICY`, `OLD_FLEET` | no AML policy; an average fleet age of 20 years or more | 5 each | |

A rule names a field and an operator: `yes`, `no`, `eq`, `ne`, `in`, `not_in`, `gte`, `lte`, `has`,
`younger_than_months`, or `any_row` (a table row that matches, such as a PEP beneficial owner). The database checks each
rule before it is saved (`iam.kyc_rule_problem`).

## Sensitive values

Identity document numbers and bank account numbers are marked `sensitive` in the form. The application encrypts them
before they are stored (AES-GCM, the application's field cipher), bound to the company, the field and the column, and keeps
the last four characters for display. A reviewer sees `•••• 4518`. Reading one in clear needs `kyc.view`, the purpose
`KYC_REVIEW` and a reason; it is recorded in the policy decisions and in `audit.data_access_log`. Opening a file on the
platform is recorded in the same log.

## Settings

All are platform settings (`sys.setting`), changed on the KYC page by someone with `kyc.settings`, and checked by the
database (`iam.kyc_setting_problem`) before they are saved:

| Key | Default | Meaning |
| --- | --- | --- |
| `kyc.review_stages` | `[{"by":"COMPLIANCE"},{"by":"FINANCE"}]` | who reviews, in order; up to six stages, e.g. adding `{"by":"TAX"}` or `{"by":"AUTHORITY","authority":"MOT"}` |
| `kyc.risk_rules` | the 19 rules above | how risk is scored |
| `kyc.risk_levels` | `{"MEDIUM":25,"HIGH":50}` | the scores from which a file is of medium and of high risk |
| `kyc.review_months` | `{"LOW":36,"MEDIUM":24,"HIGH":12}` | when an approved file is reviewed again |
| `kyc.ubo_threshold_pct` | `25` | the share from which a natural person is a beneficial owner (5 to 50) |
| `kyc.documents_on_submit` | `true` | whether the required documents must be uploaded before submitting |
| `kyc.distinct_reviewers` | `true` | whether each stage is decided by a different person |
| `kyc.required_before` | `[]` | what a company may do only with an approved file: `PUBLISH_TRIPS`, `PAYOUTS` (`KYC_REQUIRED`) |

`kyc.required_before` is empty at first, so the companies already on the platform keep working while their files are
filled. Each of them got a first file, prefilled from what the platform knows, when the migration ran.

## Permissions

| Permission | Who has it at first | What it allows |
| --- | --- | --- |
| `company.kyc` | the carrier's owner and accountant | fill and submit the company's own file |
| `kyc.view` | platform admin, security, finance, support | see the files |
| `kyc.capture` | platform admin, support | fill a file from the company's paper form and submit it for the company |
| `kyc.review.compliance` | platform admin, security | decide the compliance stage |
| `kyc.review.finance`, `kyc.review.tax` | platform admin, finance | decide the finance and tax stages |
| `kyc.settings` | platform admin | change the form and the settings |

The members of a government authority see and decide the files waiting at their stage.

## Screens and API

| Who | Page | API |
| --- | --- | --- |
| Company (`company.kyc`) | KYC: state, completeness, the sections with what is missing, the documents, save and submit, what a return asks to correct | `/api/carrier/kyc`, `/open`, `/{uid}`, `/{uid}/submit` |
| Platform (`kyc.view`, `kyc.capture`, the review permissions) | KYC files: waiting, due for review, open, without a file, all; a file with its risk, factors, documents, decisions and the stage's decision | `/api/admin/kyc`, `/{uid}`, `/{uid}/decide`, `/{uid}/reveal`, `/companies/{uid}/open`, `PUT /{uid}`, `/{uid}/submit` |
| Platform (`kyc.settings`) | Form: the version in force and its history, a new version and its activation. Settings: stages, risk, review months, the beneficial-owner threshold, the gates | `/api/admin/kyc/form`, `/form/{version}/activate`, `/api/admin/kyc/settings`, `/{key}` |
