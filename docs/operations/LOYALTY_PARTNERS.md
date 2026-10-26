# Loyalty partners: redemption under agreements

Owner's decision (October 2026): the platform bears the cost of points redeemed at partners, at prices agreed with each
partner and entered in the platform per partner. Migration 1107; code in `backend/app/modules/loyalty/partners.py`.

## The agreement

Each partner has one active agreement per currency at a time (`pricing.loyalty_agreement`):

| Term | Meaning |
|---|---|
| points = amount | How many points buy how much at the partner (for example 100 points = SYP 10,000) |
| platform share % | The percentage of a voucher's value the platform pays the partner when it is honoured; the rest is the partner's own contribution |
| minimum and step | The fewest points a member may redeem there, and the multiple |
| voucher days | How long a voucher stays valid (1 to 365 days) |
| validity, contract reference | The period and the signed agreement it records |

An officer with `loyalty.manage` writes the agreement as a draft (screen **Loyalty agreements**). A second officer
activates it; the person who wrote it cannot. Once active, its terms are frozen: to change the rate, end it and record a
new one. The partner must be active first.

Example: 100 points = SYP 10,000, platform pays 80 %. A member spends 300 points for a SYP 30,000 voucher. When the rest
stop honours it, the platform owes the rest stop SYP 24,000; the other SYP 6,000 is the rest stop's contribution.

## The member

In the wallet's points card (web and app), the member sees the partners that take points and their rates, never the
percentage the platform pays. Points become a voucher at once (`MV-XXXX-XXXX-XXXX-XXXX`); the code stays visible in the
app until the voucher is used. An unused voucher can be cancelled, and one past its date is released by the daily
upkeep; either way the points come back to the balance. The member gets a notice when a voucher is used and when its
points come back.

The member's own redemption for wallet credit (1103) is unchanged: the programme's point value is the platform's own
rate. Turning off the programme's BURN rule leaves partner vouchers as the only way to redeem.

## The partner

A partner honours vouchers through its API client: kind `PARTNER`, scope `vouchers:redeem`, linked to the partner on
its record (field **API client**).

| Call | What it does |
|---|---|
| `POST /api/v1/loyalty/vouchers/check` `{code}` | What the voucher is worth here and whether it can still be used |
| `POST /api/v1/loyalty/vouchers/redeem` `{code, reference}` | Honours it once; returns `payable`, what the platform now owes |
| `GET /api/v1/loyalty/redemptions?from=&to=` | The vouchers honoured in a period (at most 62 days) and their statement |

A code held at another partner reads as unknown. A partner without an API client calls the platform, and an officer
honours the voucher for it (`POST /api/admin/loyalty/vouchers/accept`).

## Money and settlement

When a voucher is honoured, the platform's share is posted from the loyalty expense wallet (`EXPENSE`) to the partner's
wallet (`PARTNER`), so the partner wallet's balance is what the platform owes it. Settlement:

1. An officer draws up the partner's statement for a period (`POST /api/admin/loyalty/settlements`); each honoured
   voucher goes into one statement only.
2. A second officer approves it (screen **Loyalty statements**).
3. A third person with `payout.run` records the bank transfer (`POST /api/admin/loyalty/settlements/{uid}/pay`); the
   partner wallet is debited to bank clearing.

A draft statement can be cancelled; its vouchers go into the next one.

In the platform portal these steps are on the payments desk, tab **Loyalty partners**: each partner with its active
agreement and what is honoured but not yet on a statement (`GET /api/admin/loyalty/partners`), the latest statements
(`GET /api/admin/loyalty/settlements`), and the buttons to honour a voucher, draw up a statement and record the transfer.
The approval itself stays in the generic screen, by another person. The cancellation penalty of 1106 is on the same desk,
tab **Cancellation penalty**.

## Phases and switches

Partners, agreements, vouchers, redemptions and statements belong to the loyalty release (1B). The module switch
`loyalty_partners` turns the partner screens, routes and API on; it no longer opens phase 9. The reward catalogue,
award seats and points transfers stay in phase 9.
