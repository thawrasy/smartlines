# ADR 0055: The BankFas visual identity on the site

Status: built on 2026-10-25 at the owner's request: "apply the attached visual identity to the site design" (identity
guide v2.0, October 2026, docs/31 row 58). Written by an AI agent.

## Context

The site had plain S0 styles ("the design system comes later"): system fonts, a blue top bar, no logo. The owner sent
the identity guide (27 pages) and asked for the whole site in it before the pilot launch.

## Decision

1. **Logo files** in `app/web/src/brand`, drawn by `tools/brand/logo.js`: the symbol from its geometry on the 200 grid
   (guide p.6), and the name in Sekuya turned into outlines, so the site never loads the logo's font (guide p.16).
   The colour version goes on light grounds, the inverse one on vault green (guide p.8). The symbol is the favicon.
2. **Fonts bundled** with the site (`@fontsource`, exact versions): IBM Plex Sans Arabic (Arabic subset), IBM Plex
   Sans (Latin) and IBM Plex Mono. The CSP stays `font-src 'self'`; no font is fetched from a third party.
3. **Tokens** in `styles.css`: the five brand colours (p.11), the platform colours (p.13: action #007A5C, text
   #11211D, secondary #4E6660, lines #DCE5E1) and the five status pairs. Mint is used on dark grounds only.
4. **Shell** (guide p.23): a vault-green side bar with the inverse logo and the current item in mint, a white top bar,
   white cards on ivory. On a phone the side bar becomes a scrolling strip above the page.
5. **Sign-in pages** (p.18, p.27): a brand panel with the slant pattern (one or two mint slots) and the brand promise,
   the form beside it. The panel sits at the reading start, so on the right in Arabic.
6. **Status chips** (`Chip`, p.13): colour, mark and word together (○ draft, ◇ in progress, ◆ committee, ● done,
   ✕ stopped). The tone comes from the status code; an unknown code reads as draft, never as a success.
   The Status columns of the tables use it.
7. **Numbers** (p.16, p.17): tables use tabular figures, and the left-to-right values in a table (amounts,
   references, addresses) are set in Plex Mono.

## Consequences

- The screens keep their structure and their tests. Only the shell, the sign-in pages, the logo and the status
  cells changed in the markup.
- The first chunk grows by the CSS of the fonts. The font files load per character range (unicode-range): an Arabic
  page fetches the Arabic subset, and Latin text fetches the Latin one.
- A status code that a new screen adds gets a tone from its name. A new state that reads wrongly is fixed in
  `toneOf` (brand.tsx), with its test.
- The printouts (terms, proforma, request print) keep their own styles. Taking them to the identity is a separate step.
