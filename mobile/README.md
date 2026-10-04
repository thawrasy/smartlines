# Masslak mobile apps

One Expo (React Native) code base builds two apps:

| Variant | Command | Bundle id | Portal |
|---|---|---|---|
| Passenger | `npm start` | `sy.masslak.app` | `PASSENGER` |
| Driver | `npm run start:driver` | `sy.masslak.driver` | `DRIVER` |

`APP_VARIANT` selects the variant at build time (`app.config.ts`). Native modules (keystore, camera, biometrics,
certificate pinning) need a development build: `npx expo run:android` or `npx expo run:ios`. Expo Go is not enough.

## Configuration

| Variable | Purpose |
|---|---|
| `APP_VARIANT` | `passenger` (default) or `driver` |
| `MASSLAK_API_URL` | API origin, e.g. `https://api.masslak.sy` |
| `MASSLAK_API_PINS` | Comma-separated SHA-256 SPKI pins of the API certificate: current key and at least one backup |

A release build refuses to start without an `https://` API URL and at least two pins.

## Layers

```
src/app/        screens (expo-router): login, mfa, (passenger)/…, driver/…
src/ui/         theme, components, SeatMap (the carrier's real layout), AppLock
src/platform/   React Native adapters: keystore, API client, auth, tickets, boarding, integrity, config
src/core/       pure TypeScript, unit-tested with Node: session refresh, ticket credentials, offline boarding
src/i18n/       en.ts (keys), ar.ts; the only files where Arabic text is allowed
```

`core` imports nothing from React Native; `platform` never renders; screens talk to the API only through
`platform`.

## Security design

- **Tokens**: 15-minute access token and a single-use refresh token bound to this installation's device id. A
  refresh token presented twice revokes the session on the server. Refreshes are single-flight.
- **Storage**: everything sensitive (tokens, saved tickets, offline packs, pending scans) lives in the iOS Keychain /
  Android Keystore with `WHEN_UNLOCKED_THIS_DEVICE_ONLY`: never in plain files, backups or other devices.
  `android.allowBackup` is off. Sign-out wipes every cached item.
- **Transport**: public-key pinning (current and backup pins); no cleartext.
- **Offline tickets**: the passenger app shows a credential signed by the server with Ed25519
  (`T2.<claims>.<signature>`). The driver app holds only the public key, so it can verify tickets but cannot create
  them.
- **Offline boarding**: the driver downloads the trip's ticket list before departure. Scans made with no connection
  are decided locally, kept in the keystore with a random scan id and uploaded later; the server's answer is final
  and the scan id makes a repeated upload harmless.
- **App lock**: after five minutes in the background the app asks for the device biometric or passcode. Content is
  covered in the app switcher. Screenshots and recording are blocked on the ticket and wallet screens.
- **Device integrity**: rooted/jailbroken devices get a warning in the passenger app; the driver app refuses to
  board on them.
- **Privacy**: offline packs carry the ticket name (first and last) and seat only; document numbers never leave the
  server.

## Checks

```
npm run typecheck   # TypeScript, strict
npm test            # core unit tests; set MASSLAK_TEST_URL to also verify a server-signed credential
```

CI also bundles the app with Metro (`expo export`) to catch missing modules.

### Dependency audit

`npm audit --omit=dev` reports advisories in Expo SDK 57's tool chain (Metro, the Expo CLI's `node-forge`,
`braces`, `micromatch`): they run on the build machine and are not in the app bundle. The one on a runtime path
is `decode-uri-component` under `expo-router`'s `query-string@7` (denial of service with a crafted deep link). The
patched releases are ESM-only and break `expo-router`'s `require` call, so it is tracked for the next SDK upgrade.
CI fails on any critical advisory.
