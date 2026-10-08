# Minimum operations staffing (October 2026)

The smallest team that runs the platform safely at each stage: the pre-launch trial, the pilot launch in selected cities,
and general launch. "Minimum" means the fewest people that still respect three constraints the system itself imposes:
separation of duties (a second person on every money or sensitive action), on-call cover to acknowledge an alert within
15 minutes around the clock, and customer service during travel hours. Builds on study v3.2 chapter 20 and section 22.3.

## 1. Summary

| Stage | In-house FTE | Monthly salaries (USD) | Notes |
|---|---:|---|---|
| Trial (first three months) | 7.5 | 7,900 to 13,600 | half a contracted DBA |
| Pilot launch | 17.5 | 13,200 to 22,600 | 17,700 to 32,700 with 17 % employer social insurance and outsourcing (SOC, legal, audit) |
| General launch (stage 1) | 47 | about 45,000 to 75,000 | study scenario (a) plus the commercial and finance teams |

- At least **four different people** hold platform roles (administrator, security, finance, second finance approver).
- At least **three engineers** for a sustainable on-call rota (one week in three).

## 2. Constraints from the system

### 2.1 Separation of duties (enforced by the database)

| Action | Prepared or requested by | Approved by | People |
|---|---|---|---:|
| Carrier and agency payouts | finance officer | another finance approver | 2 |
| Compensation for a case or claim | support decides amount and liable party | finance pays; the payer is not the decider | 2 |
| Activating price, commission and tax schemes | preparer | a second person | 2 |
| Vehicle or line licence change | requester | reviewer, then approver | 3 |
| Authority data requests | the person recording it | a second person | 2 |
| Travel-document exceptions | administrator drafts | security approves | 2 |
| Break-glass access | requester | witness, then review | 2 |

Platform roles: `PLATFORM_ADMIN`, `PLATFORM_SECURITY`, `PLATFORM_FINANCE`, `PLATFORM_SUPPORT`, `PLATFORM_MARKETING`. Each
is held by a named person with a named deputy for leave; finance needs at least two people.

### 2.2 On-call

Booking and payment availability is 99.9 % and an alert is acknowledged within 15 minutes, 24/7 (launch gate 5). Three
engineers rotate weekly with an on-call allowance and the runbooks in [RUNBOOKS.md](RUNBOOKS.md).

### 2.3 Support hours

A seat staffed 24/7 needs about 5 people; a seat staffed 16 hours a day, 7 days a week, about 3.5. The pilot runs one
16-hour seat (06:00 to 22:00) plus a peak seat; at night, in-app cases and e-mail are answered in the morning.

## 3. Trial team

| Role | FTE | Monthly salary (USD) | Main duties |
|---|---:|---|---|
| Platform and operations manager | 1 | 2,000 to 3,500 | contracts with payment, SMS and carriers; second finance approver |
| Lead SRE / DevOps engineer | 1 | 1,500 to 2,500 | servers, deployment, backups, monitoring, launch gates |
| Full-stack developer | 1 | 900 to 1,600 | fixes, payment and SMS integration |
| Security officer | 1 | 1,200 to 2,200 | access, penetration test follow-up, `PLATFORM_SECURITY` |
| Finance and settlement officer | 1 | 600 to 1,000 | settlements and payouts, `PLATFORM_FINANCE` |
| Partnerships and carrier onboarding | 1 | 600 to 1,000 | carrier and agency contracts and data |
| Support and training lead | 1 | 500 to 800 | training carriers, drivers and agents; first support line |
| DBA (contract, half time) | 0.5 | 1,200 to 2,000 | PostgreSQL tuning, restore and upgrade drills |
| **Total** | **7.5** | **7,900 to 13,600** | |

## 4. Pilot launch (minimum to operate)

| Team | Role | FTE | Monthly salary (USD) | Duties and system role |
|---|---|---:|---|---|
| Management | Platform and operations manager | 1 | 2,000 to 3,500 | `PLATFORM_ADMIN`, deputy finance approver |
| Management | Product and project manager | 1 | 1,000 to 1,800 | priorities, partners, releases |
| Technology | Lead SRE | 1 | 1,500 to 2,500 | on-call 1, servers, deployment, monitoring |
| Technology | Full-stack developer | 1 | 900 to 1,600 | on-call 2, fixes and integrations |
| Technology | Mobile developer | 1 | 800 to 1,400 | passenger, driver and operator apps; store releases |
| Technology | DBA (half time) | 0.5 | 1,200 to 2,000 | performance, replication, recovery, upgrades |
| Security | Security officer | 1 | 1,200 to 2,200 | on-call 3, `PLATFORM_SECURITY`, SOC provider, data protection |
| Finance | Finance and settlement officer | 1 | 600 to 1,000 | `PLATFORM_FINANCE`: daily settlement, payouts, compensation |
| Finance | Accountant and second approver | 1 | 500 to 900 | payout approval, bank reconciliation, tax returns |
| Commercial | Partnerships and carrier onboarding | 2 | 600 to 1,000 | carriers, agencies, stations, documents |
| Commercial | Field operations and training | 1 | 500 to 800 | station training, drivers and boarding |
| Commercial | Marketing and content | 1 | 600 to 1,000 | `PLATFORM_MARKETING`: campaigns, offers, site, social media |
| Support | First-line support | 4 | 300 to 500 | `PLATFORM_SUPPORT`: one 16-hour seat 7 days a week plus a peak seat |
| Support | Support supervisor and second line | 1 | 600 to 900 | complex cases and claims, referral to finance |
| **Total** | | **17.5** | **13,200 to 22,600** | |

**Outsourced (monthly):** managed SOC (MSSP) 1,500 to 4,000; legal counsel (payments, data protection, contracts) 500 to
1,500; external accounting audit 300 to 800; managed hosting optional, 0 to 1,000.

**One-off:** independent penetration test and retest 8,000 to 20,000 (before general launch, then yearly); training and
certifications 3,000 to 8,000 (first year); recruitment 1,000 to 3,000 per stage.

**Monthly total:** salaries 13,200 to 22,600; employer social insurance (about 17 %) 2,244 to 3,842; outsourcing 2,300 to
6,300; **17,744 to 32,742** (212,928 to 392,904 a year).

## 5. General launch

| Team | Roles (FTE) | Total |
|---|---|---:|
| Management | platform manager (1), product manager (1), project and release manager (1) | 3 |
| Engineering | SRE (3), backend (3), web frontend (1), mobile (2), QA (1), DBA (1), data and reports (1), integration: payments and authorities (2) | 14 |
| Security and compliance | security officer (1), application security (1), fraud and AML analysts (2), data protection officer (1) | 5 |
| Finance | finance manager (1), settlement officers (2), accountant (1) | 4 |
| Commercial | partnerships (3), marketing (2), field operations and training (3) | 8 |
| Support | first line, two 24/7 seats (10), second line (2), supervisor (1) | 13 |
| **Total** | | **47** |

The SOC stays outsourced until study scenario (b) (in-house 24/7 NOC and SOC, a second DBA; about 80 to 100 people).
Shuttle, freight and school transport each add field operations and specialised support when switched on, not before.
The AI assistant phase adds an AI and knowledge supervisor only after the DPIA sign-off (gate 9).

## 6. Operating model

| Team | Hours | Cover outside hours |
|---|---|---|
| Engineering | working days | weekly on-call among 3 engineers, 15-minute response, allowance |
| Security | working days | MSSP SOC 24/7, escalating to the security officer |
| First-line support | 06:00 to 22:00 daily (pilot); 24/7 (general launch) | in-app cases and e-mail, answered in the morning |
| Finance | working days; daily settlement before noon | no payouts outside hours without the manager's approval |
| Field operations | travel peaks and holidays | seasonal temporary contracts |

Blameless review within five working days after every incident; quarterly restore drill; alert drill and incident
simulation twice a year; quarterly access review in the access review screen; leavers' access removed on their last day;
second factor for every employee; managed work devices for finance and security roles.

## 7. Expertise

| Role | Core expertise | Preferred certifications |
|---|---|---|
| SRE | Linux, Docker, networking, Prometheus and Grafana, backup and recovery | CKA, a cloud certification |
| DBA | PostgreSQL 16 performance, partitioning, replication, pgBackRest, row-level security | proven large-scale PostgreSQL work |
| Backend developer | Python, FastAPI, advanced SQL, asyncpg | — |
| Mobile developer | React Native, Expo, Google Play and App Store releases | — |
| Security officer | identity and access, incident response, data protection, OWASP | CISSP or CISM, ISO 27001 Lead Implementer |
| Finance | double-entry accounting, bank reconciliation, Syrian tax | chartered accountant; CAMS for AML |
| Support | Arabic and English, communication, transport sector | internal training on the user guide |

## 8. Hiring timeline

| When | Who |
|---|---|
| Now (trial) | platform manager, lead SRE, full-stack developer, security officer, finance officer, partnerships, support and training lead, contracted DBA |
| One month before the pilot | product manager, mobile developer, accountant and second approver, second partnerships officer, field coordinator, marketing, four support agents and a supervisor; contract the SOC provider, legal counsel and auditor |
| Three months before general launch | more SRE and developers, application security, QA, two integration engineers, two fraud analysts, data protection officer, support to 24/7 |
| At scenario (b) | in-house NOC and SOC, second DBA |

## 9. Salary assumptions

There is no published survey of technology pay in Syria. Ranges start from the indicators below and are raised to
compete with remote work for foreign companies, the real alternative for experienced engineers. Validate them with a short
local recruitment survey before hiring.

| Indicator | Value | Source |
|---|---|---|
| Minimum wage 2026 | 12,560 new SYP a month (about USD 103 at 122 SYP per USD) | Enab Baladi, Ministry of Finance (May 2026) |
| Public pay after the 50 % raise | about USD 200 to 300 | Decree 67 of 2026, Enab Baladi |
| Software engineers (model) | median about USD 400, upper quartile about USD 520 | GlobalCostData (modelled from World Bank data, not a survey) |
| Exchange rate | about 122 new SYP per USD (July 2026) | market rate, UN operational rates |

Employer social insurance is taken as about 17 %; confirm with legal counsel.
