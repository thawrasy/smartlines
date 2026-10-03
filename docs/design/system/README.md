Masslak (مسلك, "the way through") is one platform for booking intercity trips, riding shuttle lines, sending shipments and running carrier, station, agency and government portals in Syria. The interface is light, calm and exact: Material 3 structure, the finish and restraint of Apple's platforms, and a colour story taken from the new Syrian visual identity (flag green, eagle gold, sand). Arabic (RTL) is the primary language; English (LTR) ships alongside it, and later locales (Turkish, French, Spanish) reuse the same tokens.

Read this page first, then `Experience` (journeys and information architecture) and `Platforms` (web, Android and iOS rules). Every value below is a token in `tokens.json`; never paste raw hex or pixel values into product code.

## Brand essence

- **Promise:** every trip, ticket and payment is clear before the passenger commits. Nothing is hidden behind a tap.
- **Character:** official enough for ministries and border authorities, warm enough for a family booking seats to Aleppo.
- **Three words:** trustworthy, precise, welcoming.
- **What we borrow from the national identity:** the flag green as the anchor colour, the gold of the eagle as the mark of value (loyalty, premium fares, the logo's route line), sand for print and signage. We never use the national emblem, the eagle drawing, the flag or the three stars inside the product: Masslak is a private platform and must not look like a government body.

## Logo

- The mark is a route: a curved line between two stops, on a rounded green square. Use `masslak-mark.svg` (wheat route) in product; `masslak-mark-gold.svg` (gold route) on marketing, app stores and print.
- Use `masslak-symbol-green.svg` without the square on white or `surface-dim`, and `masslak-symbol-white.svg` on `primary` or `brand-green` grounds.
- The wordmark is set, not drawn: "مسلك" in IBM Plex Sans Arabic 700, and "Masslak" in the same family for Latin, placed after the mark at a gap of `space-3`. In RTL the mark sits on the right of the word; in LTR on the left.
- Clear space around the mark is one third of its width. Minimum size 24px on screen. Never recolour the square away from `primary` or `brand-green`, never add shadows or outlines, never rotate or stretch it.
- App icons: `app-icon-ios.svg` is the full-bleed 1024px master (iOS applies the corner mask); `app-icon-android-foreground.svg` is the adaptive-icon foreground on a `primary` background layer.

## Content fundamentals

- **Voice:** plain Modern Standard Arabic that a Syrian passenger reads at a glance. Short sentences, active verbs, no slogans inside the product.
- **Address the user directly** with the second person in both languages: "احجز مقعدك", "Choose your seat". Refer to the platform as "we" only in policies and help.
- **Buttons say the action:** "احجز الآن / Book now", "ادفع 85,000 ل.س / Pay SYP 85,000", "امسح الرمز / Scan code". Never "OK", "Submit" or "Yes".
- **Errors explain and fix:** "الرصيد غير كافٍ للمقطع الأول. اشحن 15,000 ل.س على الأقل." / "Your balance doesn't cover the first segment. Top up at least SYP 15,000." No apologies, no error codes shown to passengers (codes go to logs and support views).
- **Confirmations name the result:** "تم تأكيد الحجز" / "Booking confirmed", "تم خصم 2,500 ل.س" / "SYP 2,500 deducted".
- **Case:** sentence case in English for every title, button and label. No ALL CAPS except booking references and plate numbers.
- **Digits:** Western digits (0–9) in both languages, set tabular, matching identity documents, plates and phone numbers (`ar-SY-u-nu-latn`). Money: amount then currency, "85,000 ل.س" in Arabic, "SYP 85,000" in English. Time: 24-hour, "14:30".
- **Names:** passenger names follow the identity document; Syrian citizens show four parts (first, father, grandfather, family).
- **No emoji** in product UI, notifications or receipts. Status is carried by colour, icon and word together.
- **Bidirectional text:** wrap Latin codes, plates, phone numbers and emails in an LTR isolate inside Arabic sentences so their characters never reorder.

## Visual foundations

### Colour

- The product is light. Pages sit on `surface-dim`; cards, sheets and app bars on `surface`; quiet panels on `surface-container-low`. The dark theme exists only for the driver app at night and for OS-level dark mode on mobile.
- `primary` carries the single most important action on a screen and the active navigation item. One filled `primary` button per view; everything else is tonal (`primary-container`), outlined or text.
- `secondary` (wheat) marks money and waiting: fares, pending payments, boarding soon. `tertiary` (blue-grey) marks information and live tracking. `error` marks failure and destructive actions only.
- Status colours always pair with a word and an icon (`StatusBadge`): green confirmed, wheat pending, blue in progress, red cancelled. Never rely on hue alone; green and red chips sit at similar lightness, so the word is mandatory.
- Text: `on-surface` for content, `on-surface-variant` for labels and secondary lines. Both pass 8:1 on every surface token in light and dark.
- Borders: inputs and outlined buttons use `outline` (3:1 or more). `outline-variant` and `divider` are decorative and never the only edge of a control.
- Identity colours (`brand-green`, `brand-gold`, `brand-sand`, `brand-ink`) are for logos, app icons, covers, marketing and print. Inside product screens use the role tokens. Where gold must be read (a loyalty tier, a premium fare brand), use `brand-gold-ink`.
- Gradients: only the soft hero wash from `primary-container` through `surface-container-low` to `secondary-soft`, on public heroes and auth side panels. No other gradients, no glass effects except the translucent top bar.

### Typography

- One family for everything: IBM Plex Sans Arabic (Google Fonts), which carries Arabic and Latin with matching weights. Use 400 for body, 500 for labels, 600 for titles, 700 for the wordmark and large prices.
- IBM Plex Mono for booking references, ticket numbers, trip numbers and plates (`data-code`, `data-large`).
- The scale is Material 3 with Arabic line heights opened by 4px to 6px so diacritics and descenders never collide. Use the styles by role: `headline-large` page titles on web, `headline-medium` on mobile, `title-large` card titles, `body-medium` default portal text, `body-large` default app text, `label-large` buttons.
- Keep lines near 60 to 70 characters. Headings use `text-wrap: balance`. Never letter-space Arabic; the `letterSpacing` values apply to Latin only.

### Spacing and layout

- 4px base grid: `space-1` to `space-16`. Mobile gutter `space-4`; web gutter `space-6`; portal content gutter `space-8`.
- Public web pages are centred at `size-content`. Portals use a `size-drawer` navigation drawer plus fluid content up to 1360px. Mobile apps use a top app bar and a bottom navigation bar.
- Use CSS logical properties everywhere (`margin-inline-start`, `inset-inline-end`, `padding-inline`). One stylesheet serves RTL and LTR; never write `left` or `right` in component code.
- Directional icons (back arrow, chevrons) mirror in RTL. Clocks, media controls, checkmarks and the QR scanner do not.

### Shape and elevation

- Rounded and soft, following the radius scale: chips `radius-sm`, fields `radius-md`, cards `radius-lg`, dialogs, sheets and tickets `radius-xl`, buttons and pills `radius-full`.
- Elevation is light and green-tinted: `elevation-1` for resting cards, `elevation-2` for hero cards, tickets and dialogs, `elevation-3` for sheets. Flat cards use a `divider` outline instead of a shadow. Never stack a shadow and a border on the same card.

### Motion

- Calm and quick. 150ms for hover and press state layers, 200ms for drawers and sheets, 250ms to 300ms for page transitions, Material 3 standard easing (cubic-bezier(0.2, 0, 0, 1)).
- Motion explains state: a seat fills when selected, a ticket slides up when issued, the boarding progress bar runs down. No decorative loops.
- Respect `prefers-reduced-motion`: replace movement with a fade.

### States and interaction

- Material 3 state layers over the element's own content colour: hover `state-hover`, focus `state-focus`, pressed `state-pressed`; disabled content at `state-disabled`.
- Focus ring: a solid 3px `primary` outline offset by 2px on every interactive element. It reaches 6:1 on light surfaces and 10.9:1 on dark ones.
- Touch targets are at least `size-touch` on mobile; default controls are `size-control` high.
- Loading: skeletons in `surface-container-highest` for lists and cards; a spinner only inside buttons and for short waits.
- Empty states: an outlined icon in `outline`, a `title-medium` sentence that says what will appear, and one action.

### Imagery

- Real Syrian places and roads, natural light, people in everyday travel. No stock clichés, no 3D illustrations, no AI-generated faces.
- Maps use a light basemap tinted towards `surface-container-low`; routes draw in `primary`, live vehicles in `tertiary`.

## Iconography

- Material Symbols Rounded, weight 400, optical size 24, fill 0 (fill 1 only for the active bottom-navigation icon). The web frontend bundles them as SVG from `@material-symbols/svg-400/rounded`; Android uses the same set; iOS uses SF Symbols equivalents at matching weight where a native look is required.
- Icon sizes: 20px inside chips and dense tables, 24px default, 32px to 48px in empty states and feature tiles.
- Icons take the colour of their text role (`on-surface-variant` by default, `primary` when active). The SVGs in `assets/Icons` are drawn in `on-surface-variant` (#424844) because an `<img>` cannot inherit colour; in product code inline them and use `currentColor`.
- Pair an icon with a label everywhere except universally understood actions in app bars (back, close, menu, search). Provide an accessible name for icon-only buttons.

## Accessibility

- WCAG 2.2 AA is the floor on every surface in both themes: 4.5:1 for text, 3:1 for large text, control borders, focus rings and meaningful icons.
- Every screen works with a screen reader in Arabic and English (TalkBack, VoiceOver, NVDA), with dynamic type up to 200 percent and with keyboard alone on the web.
- Never communicate state by colour alone. Time limits (seat holds, QR refresh) show remaining time and can be extended where policy allows.
