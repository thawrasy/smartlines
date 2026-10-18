# Fonts

The identity's type families (docs/design/IDENTITY.md), one static file per weight, loaded by `src/app/_layout.tsx`:

| File | Family | Use |
| --- | --- | --- |
| ReadexPro-SemiBold.ttf, ReadexPro-Bold.ttf | Readex Pro 600 and 700 | titles, prices, times, big numbers |
| IBMPlexSansArabic-Regular.ttf, -Medium.ttf, -SemiBold.ttf | IBM Plex Sans Arabic 400, 500 and 600 | text, labels, interface |
| IBMPlexMono-Medium.ttf | IBM Plex Mono 500 | trip, ticket and booking numbers |

All are under the SIL Open Font License 1.1 (https://openfontlicense.org): Readex Pro © The Readex Pro Project Authors,
IBM Plex © IBM Corp. They were taken from Google Fonts unmodified. The logo's wordmark is not a font here: the lockups are
drawn from the design files (`src/ui/logos.ts`).
