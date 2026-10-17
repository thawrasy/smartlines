# Mobile apps: builds and the device matrix

Reviews of October 2026, M-14. CI proves that the three apps type-check, pass their unit tests (session, ticket
credentials, offline boarding) and bundle (`expo export`), and that no dependency advisory ships unclassed
(M-11, `mobile/advisories.json`). What CI cannot prove is how the apps behave on real devices: installing a store
build, the keystore, the camera, biometrics, certificate pinning and the network dropping. That is this matrix.

## Builds

`mobile/eas.json` holds the build profiles, one per variant:

| Profile | Variant | Distribution | API |
|---|---|---|---|
| `preview-passenger`, `preview-driver`, `preview-operator` | passenger, driver, operator | internal (an APK, an ad hoc iOS build) | staging |
| `production-passenger`, `production-driver`, `production-operator` | the same | the stores (app bundle, App Store build) | production |

The certificate pins (`MASSLAK_API_PINS`, the current key and a backup) are EAS environment variables of the
`preview` and `production` environments (`eas env:create --environment production --name MASSLAK_API_PINS ...`), never
in the repository; a release build refuses to start without an `https://` API address and two pins. Builds run from
the workflow "Mobile builds" (`.github/workflows/mobile-builds.yml`, started by hand: variant, platform, profile),
which needs the repository secret `EXPO_TOKEN` (an Expo robot token) and stops with that message when it is missing.
Locally: `cd mobile && npx eas-cli@24.8.0 build --profile preview-driver --platform android`.

## The devices

At least one device from each row before a release reaches the stores; the low-end Android rows matter most for
drivers and counter staff, whose phones are often old.

| Row | Example | Why |
|---|---|---|
| Android 10, 2 GB memory | Samsung Galaxy A10s | the oldest Android supported; memory pressure kills apps in the background |
| Android 13 or 14, mid range | Samsung Galaxy A34, Xiaomi Redmi Note 12 | the most common phones among passengers |
| Android 15, current | Pixel 8 or a current Samsung | the newest permission and background rules |
| iOS 16 | iPhone 8 | the oldest iOS supported |
| iOS 18 | iPhone 13 or later, Face ID | Face ID and the current privacy prompts |

## The cases

Each case on each row, with the build's version and the result recorded in the table below.

| # | Case | Expected |
|---|---|---|
| 1 | Install the preview build, first start, sign in (passenger, driver, operator) | sign-in works; the session survives closing and reopening the app |
| 2 | Arabic and English, right to left | every screen reads right to left in Arabic; no truncated label |
| 3 | Biometric lock: background the app for more than five minutes, reopen | the device biometric or passcode is asked; the app switcher shows the cover, not the content |
| 4 | Screenshots on the ticket and wallet screens | blocked (Android) or blank (iOS screen recording) |
| 5 | Offline ticket: book, turn on aeroplane mode, reopen the app | the ticket shows and its code scans |
| 6 | Offline boarding (driver): download the trip, aeroplane mode, scan valid, used and foreign tickets, reconnect | decisions made on the device; the scans upload once with no duplicate; the server's answer replaces a local one |
| 7 | Clock wrong by an hour on the driver's phone | boarding uses the server's clock offset; an expired ticket is still refused |
| 8 | Certificate pinning: a proxy with its own certificate between the phone and the API | the app refuses to talk to it and says so; nothing is sent |
| 9 | Poor network: 2G profile, packet loss | requests retry; a booking or a payment is never made twice (idempotency keys) |
| 10 | Rooted or jailbroken device | the passenger app warns; the driver app refuses to board |
| 11 | Sign out | every cached ticket, pack and pending scan is gone from the keystore |
| 12 | Update from the previous build | the session and the offline tickets survive the update |
| 13 | A ticket before its window: booked for a trip more than three hours away | the ticket shows no code and says it opens three hours before departure |
| 14 | Offline for more than 72 hours after the last check | the ticket asks for a connection before it shows; the wallet stays read-only |

## Limits of the root check

`checkIntegrity` (mobile/src/platform/integrity.ts) asks Expo whether the device is rooted or jailbroken. Expo marks that
call experimental: it finds common root tools and known signs of a jailbreak, and a determined user can hide both. The
result is therefore a warning, not proof. The passenger app warns; the driver app refuses to board on a rooted phone,
because a rooted phone could forge boarding records offline. A stronger second signal needs a service of the platform:
Google Play Integrity on Android (a verdict checked by the server, needs a Google Cloud project) and Apple App Attest on
iOS (needs an Apple developer key). Both send device data to the vendor, so the choice is a decision for the owner
(legal review of the privacy notice first). Until it is made, this matrix records the warning as its limit.

## Results

| Date | Build | Device row | Device | Cases passed | Failures and their tickets | Tester |
|---|---|---|---|---|---|---|
| | | | | | | |

No run is recorded yet: the first runs need the Expo account's token in the repository and the devices of the
rows above. Until the table holds one passing run per row for a build, that build does not go to the stores
(launch gate register, `LAUNCH_GATES.md`).
