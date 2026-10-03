Masslak (مسلك, "the way through") is one platform for booking intercity trips, riding shuttle lines, sending shipments and running carrier, station, agency and government portals in Syria. The interface is light, calm and exact: Material 3 structure with the restraint of Apple's platforms and the confidence of leading Gulf government-tech products. Deep navy carries authority, a clear blue carries action, and a green destination stop, taken from the Syrian flag green, marks arrival and success. Arabic (RTL) is the primary language; English (LTR) ships alongside it, and later locales (Turkish, French, Spanish) reuse the same tokens.

Read this page first, then `Experience` (journeys and information architecture) and `Platforms` (web, Android and iOS rules). Every value below is a token in `tokens.json`; never paste raw hex or pixel values into product code.

## Brand essence

- **Promise:** every trip, ticket and payment is clear before the passenger commits. Nothing is hidden behind a tap.
- **Character:** official enough for ministries and border authorities, warm enough for a family booking seats to Aleppo.
- **Three words:** trustworthy, precise, welcoming.
- **What we borrow from the national identity:** the flag green as the destination stop and the colour of success. We never use the national emblem, the eagle drawing, the flag or the three stars inside the product: Masslak is a private platform and must not look like a government body.

## Logo

- The mark is a route: one arc that leaves a light-blue origin stop (`brand-blue-soft`), rises in `brand-blue` and settles on a green destination stop (`brand-green`), on a deep navy rounded square (`brand-navy`). Blue is movement and trust; green is arrival, taken from the Syrian flag green. No gradients.
- Files: `masslak-mark.svg` (navy square, the default everywhere), `masslak-mark-outline.svg` (white square with a navy outline and a `primary` route, for headers on white when a lighter touch is needed), `masslak-symbol.svg` (route alone in `primary` with a green stop, for white grounds), `masslak-symbol-white.svg` (white route with a green stop, for navy or photo grounds).
- The wordmark is set, not drawn: "مسلك" in Readex Pro 700 in `on-surface` (navy in light, near-white in dark), followed on the same line by "masslak" in IBM Plex Sans Arabic 600 at 10px, letter-spaced 1.5px, in `on-surface-variant`. In English the name is "Masslak" in Readex Pro 700 alone. The mark sits on the reading-start side of the name at a gap of `space-3`.
- Clear space is one quarter of the mark's width. Minimum size 20px on screen. Never recolour the square away from `brand-navy`, never swap the stop colours, never add shadows or rotate the mark.
- App icons: `app-icon-ios.svg` is the full-bleed 1024px master (iOS applies the corner mask); `app-icon-android-foreground.svg` is the adaptive-icon foreground on a `brand-navy` background layer.

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

- The product is light. Pages sit on `surface-dim`, optionally with a faint dot grid in `outline-variant` on public heroes; cards, sheets and app bars sit on `surface` with a 1px `outline-variant` hairline. The dark theme exists only for the driver app at night and for OS-level dark mode on mobile.
- `brand-navy` and `on-surface` carry headlines; the second line of a display headline may switch to `primary` for emphasis ("مسارك واضح. / رحلتك محسوبة.").
- `primary` (blue) carries the single most important action on a screen, links and the active navigation item. One filled `primary` button per view; everything else is tonal (`primary-container`), outlined or text.
- `success` (green) means confirmed, valid, paid and arrived. `secondary` (amber) marks money and waiting: fares due, pending payments, boarding soon. `tertiary` (navy) marks live tracking and neutral emphasis. `error` marks failure and destructive actions only.
- Status colours always pair with a word and an icon (`StatusBadge`): green confirmed, amber pending, blue in progress, red cancelled. Never rely on hue alone.
- Text: `on-surface` for content, `on-surface-variant` for labels and secondary lines. Both pass 6.8:1 or more on every surface token in light and dark.
- Borders: inputs and outlined buttons use `outline` (3:1 or more). `outline-variant` and `divider` are hairlines and never the only edge of a control.
- Identity colours (`brand-navy`, `brand-blue`, `brand-green`) are for the logo, app icons, footers, the hero and print. Inside product screens use the role tokens. `brand-gold` survives only for loyalty tiers.
- Gradients: only inside the logo route. Heroes use flat `surface-dim` with the dot grid, never colour washes.

### Typography

- Two families. Readex Pro (Google Fonts) for display and headline styles, prices, times and big numbers, at 600 to 700: geometric, confident and clear in Arabic. IBM Plex Sans Arabic for body, labels and UI text at 400 to 600.
- IBM Plex Mono for booking references, ticket numbers, trip numbers and plates (`data-code`, `data-large`).
- The scale is Material 3 with Arabic line heights opened by 4px to 6px so diacritics and descenders never collide. Use the styles by role: `headline-large` page titles on web, `headline-medium` on mobile, `title-large` card titles, `body-medium` default portal text, `body-large` default app text, `label-large` buttons.
- Keep lines near 60 to 70 characters. Headings use `text-wrap: balance`. Never letter-space Arabic; the `letterSpacing` values apply to Latin only.

### Spacing and layout

- 4px base grid: `space-1` to `space-16`. Mobile gutter `space-4`; web gutter `space-6`; portal content gutter `space-8`.
- Public web pages are centred at `size-content`. Portals use a `size-drawer` navigation drawer plus fluid content up to 1360px. Mobile apps use a top app bar and a bottom navigation bar.
- Use CSS logical properties everywhere (`margin-inline-start`, `inset-inline-end`, `padding-inline`). One stylesheet serves RTL and LTR; never write `left` or `right` in component code.
- Directional icons (back arrow, chevrons) mirror in RTL. Clocks, media controls, checkmarks and the QR scanner do not.

### Shape and elevation

- Rounded but precise: chips `radius-sm`, buttons, fields and search cells `radius-md`, cards `radius-lg`, dialogs, sheets and tickets `radius-xl`; `radius-full` only for avatars, dots and the mobile navigation pill.
- Hairlines first, shadows second: every card carries a 1px `outline-variant` hairline; `elevation-1` adds a barely visible lift, `elevation-2` is for the search card, dialogs and menus, `elevation-3` for sheets and the floating boarding pass in heroes.

### Motion

- Calm and quick. 150ms for hover and press state layers, 200ms for drawers and sheets, 250ms to 300ms for page transitions, Material 3 standard easing (cubic-bezier(0.2, 0, 0, 1)).
- Motion explains state: a seat fills when selected, a ticket slides up when issued, the boarding progress bar runs down. No decorative loops.
- Respect `prefers-reduced-motion`: replace movement with a fade.

### States and interaction

- Material 3 state layers over the element's own content colour: hover `state-hover`, focus `state-focus`, pressed `state-pressed`; disabled content at `state-disabled`.
- Focus ring: a solid 3px `primary` outline offset by 2px on every interactive element. It reaches 5.7:1 on light surfaces and 10.1:1 on dark ones.
- Touch targets are at least `size-touch` on mobile; default controls are `size-control` high.
- Loading: skeletons in `surface-container-highest` for lists and cards; a spinner only inside buttons and for short waits.
- Empty states: an outlined icon in `outline`, a `title-medium` sentence that says what will appear, and one action.

### Imagery

- Real Syrian places and roads, natural light, people in everyday travel. No stock clichés, no 3D illustrations, no AI-generated faces.
- Maps use a light basemap tinted towards `surface-container-low`; routes draw in `primary`, live vehicles in `tertiary`, destinations in `success`.

## Iconography

- Material Symbols Rounded, weight 400, optical size 24, fill 0 (fill 1 only for the active bottom-navigation icon). The web frontend bundles them as SVG from `@material-symbols/svg-400/rounded`; Android uses the same set; iOS uses SF Symbols equivalents at matching weight where a native look is required.
- Icon sizes: 20px inside chips and dense tables, 24px default, 32px to 48px in empty states and feature tiles.
- Icons take the colour of their text role (`on-surface-variant` by default, `primary` when active). The SVGs in `assets/Icons` are drawn in `on-surface-variant` (#424844) because an `<img>` cannot inherit colour; in product code inline them and use `currentColor`.
- Pair an icon with a label everywhere except universally understood actions in app bars (back, close, menu, search). Provide an accessible name for icon-only buttons.

## Accessibility

- WCAG 2.2 AA is the floor on every surface in both themes: 4.5:1 for text, 3:1 for large text, control borders, focus rings and meaningful icons.
- Every screen works with a screen reader in Arabic and English (TalkBack, VoiceOver, NVDA), with dynamic type up to 200 percent and with keyboard alone on the web.
- Never communicate state by colour alone. Time limits (seat holds, QR refresh) show remaining time and can be extended where policy allows.
