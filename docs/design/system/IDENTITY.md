# Visual identity 1.0 (release candidate 1)

**Status:** release candidate, awaiting the owner's approval. The public website is rebuilt on this identity only once
it is approved; until then the product keeps the same values, which already follow it.
**Version:** `1.0.0-rc.1` (`tokens.json` field `version`). **Checked by:** `scripts/check_design_tokens.py` in CI.

The identity is the set in this folder: the brand rules (`README.md`), the experience and platform rules
(`Experience.md`, `Platforms.md`), the tokens (`tokens.json`), the logo files (`assets/logos`), the icon set
(`assets/icons`), the wordmark font (`fonts`) and the components (`components`). This page records what version 1.0
fixes, how it changes, and what the owner decides before it is final.

## What 1.0 fixes

| Element | Fixed as | Source |
|---|---|---|
| Name | "masslak" (lower case) in Latin, the matching Arabic-script name in the Arabic lockup | `README.md`, Logo |
| Mark | One route arc from a light-blue origin to a green destination stop on a navy rounded square; four variants (mark, outline, symbol, white symbol); app icons for iOS and Android | `assets/logos` |
| Wordmark | Hayyakum Allah Bold (SIL Open Font License), outlined in the lockup files, live in product with the bundled font | `fonts`, `assets/logos` |
| Identity colours | Navy `#0B1F3F`, blue `#2F7BFF`, light blue `#7FB0FF`, destination green `#12A06A`; gold only for loyalty tiers | `tokens.json` (`brand-*`) |
| Product colours | Material 3 roles in light and dark (primary blue `#0A5BD3`, amber for money and waiting, navy for live tracking, green `#0D7650` for success, red for failure) | `tokens.json` |
| Contrast | WCAG 2.2 AA in both themes for 114 promised pairs: every `on-*` role on its fill, content and label text and the role colours on five surfaces, control borders and focus rings at 3:1 | `check_design_tokens.py` |
| Type | Readex Pro for display, prices and times; IBM Plex Sans Arabic for text; IBM Plex Mono for references, trip numbers and plates; Hayyakum Allah for the wordmark only | `tokens.json` (`type`) |
| Numerals | Western digits (0 to 9) in both languages, tabular; 24-hour time; amount then currency | `README.md`, content |
| Icons | Material Symbols Rounded, weight 400, outlined; mirrored only when directional | `assets/icons` |
| Ticket and boarding pass | `radius-xl` card, route as origin and destination with the stop timeline, short trip number and booking reference in mono, first and last name only, QR on white with a quiet zone of four modules, status badge with word and icon | `components/Ticket` |
| Station boards | Separate Arrivals and Departures screens on `brand-navy`, times and trip numbers in mono at board size, Arabic and English alternating every 10 seconds, a cancelled trip in `error` with its word and no strike-through | owner decisions O2 and 214 |
| Carrier logos | Shown next to the carrier's name on tickets, boards and screens, inside its own frame and never recoloured; the Masslak mark is never placed inside a carrier frame | `backend/app/company_logo.py` |

## Official symbols

Masslak is a private platform. The national emblem, the eagle, the flag and its stars never appear in the product, the
website, the apps, tickets or marketing. The flag green survives only as the destination stop and the colour of
success. A ministry, authority or partner logo appears only where an agreement allows it, in its own frame, at no
larger size than the Masslak mark, and only on the pages of that service.

## How the identity changes

| Change | Version step | Who approves |
|---|---|---|
| The mark, the name, the identity colours, the wordmark font | major (2.0.0) | the owner |
| A new token, component or variant; a new locale | minor (1.1.0) | design lead |
| A value fixed to meet the contrast rules, a corrected usage note | patch (1.0.1) | design lead, with the check passing |

Product code reads colours from the tokens only: the web theme (`frontend/src/theme.css`) and the mobile theme
(`mobile/src/ui/theme.ts`) carry the token values, and the check fails when either drifts.

## Changes in 1.0.0-rc.1

- `success` light `#0F7B53` to `#0D7650`: success text on `surface-container-high` was 4.48:1, under the 4.5:1 floor.
  It is now 4.8:1 there and 5.6:1 on `surface`.
- The mobile theme used three colours that were not tokens (amber and error soft fills, the page background); they are
  now `secondary-container`, `error-container` and `surface-dim`.
- `tokens.json` carries a semantic version instead of a counter.

## Decisions for the owner before 1.0.0

1. Approve the mark, the two lockups and the app icons as drawn (`assets/logos/lockups-preview.png`).
2. Approve the colour set, including the darker success green above.
3. Register the name and the mark as trademarks in Syria (and the markets of phase 2) before the public launch; the
   identity does not depend on it, the launch does.
4. Confirm English as the default interface language with Arabic as a full translation, or switch the default to
   Arabic by configuration for the Syrian launch.
5. Keep or drop the gold loyalty tiers (`brand-gold`) before the website shows them.
