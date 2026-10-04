# Platforms

One set of tokens and components, adapted to how each platform feels. The brand stays the same; navigation and system controls follow the host platform.

## Web (public site and portals)

- **Public site:** translucent top bar (`surface` at 86 percent with a background blur, `divider` bottom edge, the active link underlined in `primary`), content centred at `size-content`, footer on `brand-navy`. Hero on `surface-dim` with a faint dot grid, a two-line `display-large` headline (navy, then `primary`), a one-line promise, three inline figures, a floating boarding pass and the search card overlapping the hero's lower edge.
- **Portals:** `NavigationDrawer` at `size-drawer` on the reading-start side, sticky `TopAppBar` over content, content gutter `space-8`, maximum content width 1360px. Below 960px the drawer becomes a modal drawer opened from a menu button.
- **Breakpoints:** compact under 600px, medium 600–959px, expanded 960–1279px, large 1280px and up (Material 3 window classes).
- **Keyboard:** every action reachable by Tab; Escape closes dialogs and drawers; Enter submits forms. Visible focus ring on all controls.
- **Direction:** `<html lang="en" dir="ltr">` by default; switching language flips `dir` without reloading. Logical CSS properties only.

## Android (Material 3)

- Use Material 3 components with this system's colour roles mapped one to one (`primary`, `on-primary`, `primary-container` and so on). Turn dynamic colour off so the brand stays consistent.
- Top app bar (small or center-aligned), bottom `NavigationBar` with 3 to 5 destinations, FAB only for the shuttle Scan action.
- Respect system back and predictive back; edge-to-edge layout with insets applied to the app bar and navigation bar.
- Typography: map the type styles to the Material type scale; ship IBM Plex Sans Arabic as a downloadable font with a Noto Sans Arabic fallback.
- Haptics on scan results: confirm for valid, reject pattern for invalid.

## iOS (Human Interface Guidelines)

- Same colours, type and components, with iOS structure: large titles on root screens (`headline-medium`), a tab bar instead of the Material navigation bar, navigation stack with swipe back, sheets with grabbers for filters and seat details.
- Controls follow iOS behaviour where users expect it: date pickers, action sheets for destructive choices, system share sheet for tickets, Apple Wallet pass for the boarding ticket.
- Buttons keep the Masslak pill shape and colours; switches and segmented controls may use native components tinted with `primary`.
- Minimum target 44pt (`size-control`); Dynamic Type support through the text styles.

## Shared mobile rules

- Bottom navigation for the passenger app: Home, Trips, Shuttle, Wallet, Account.
- Driver app: Today, Boarding, Route, Profile, with SOS always reachable from the app bar.
- Tickets and the driver manifest are stored on the device and readable offline.
- Location lock: when location permission or the location service is off, show a full-screen explanation with a single "Turn on location" action; SOS stays available.
- Night mode: the driver app follows the system dark setting and switches to the dark theme automatically between sunset and sunrise when the OS has no setting.

## Right-to-left

- Mirror layout, navigation order, progress direction and directional icons.
- Do not mirror: clocks, phone numbers, plates, booking references, QR codes, maps, media controls, checkmarks.
- Numbers are Western digits in both directions; wrap mixed-direction strings in an isolate (`<bdi>` on web, `TextDirectionHeuristics` on Android, `NSWritingDirection` on iOS).
- Seat maps keep the vehicle's real geometry (driver on the left in Syria) and do not mirror; only the labels around them move.
