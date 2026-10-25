# The traveller "Me", saved travellers and booking without an account (N18, migration 1153)

## "Me"

A registered passenger is not asked again for what the account holds. The first traveller of a booking is filled with
the account holder ("Me") unless the passenger picks "Someone else (I am not travelling)".

- `GET /api/account/me-traveller` returns the name parts (1149), date of birth, gender, document type, the document's
  last four and `ready` (names complete, date of birth and a document on file). The document number never leaves the
  server.
- `PUT /api/account/document` stores the date of birth, gender, document type, number and expiry on the person
  (`iam.party`). The number is encrypted (AAD `iam.party.id_no`) with a blind index per type and nationality; a number
  registered to another person is refused (`DOCUMENT_IN_USE`). Once the account is verified the details change only
  through a new review (`IDENTITY_LOCKED`).
- A passenger in a booking sent with `"self_traveller": true` is booked with the account's stored identity; whatever
  the form sent for the names is ignored. One booking holds the account holder once (`SELF_TWICE`).

## Saved travellers

Companions booked again (friends, colleagues) are kept in `iam.saved_traveller`, only with the passenger's
confirmation that the person agrees (`consent: true`, else `CONSENT_REQUIRED`); at most 20 per account.

- `GET/POST /api/account/travellers`, `PUT/DELETE /api/account/travellers/{uid}`.
- The document number is encrypted (AAD `iam.saved_traveller.id_no`) with a blind index; only the last four are shown.
  Removing a saved traveller clears the document at once.
- Rows are row-secured to the passenger who saved them (forced row security). A booking passenger sent with
  `"saved_traveller_uid"` takes the stored identity; another passenger's saved traveller is refused (`NOT_SAVED`), and
  the same saved traveller cannot be booked twice in one booking (`DUPLICATE_TRAVELLER`).
- "Me" and saved travellers are for a passenger's own account; an agency or a counter selling on behalf gets
  `OWN_TRAVELLERS_ONLY`.
- The booking form offers "Save this traveller for next time" on a typed traveller; it is saved after the booking
  succeeds, and a failure to save never undoes the booking.
- Family members (4.20) stay a separate register with their own rules and remain offered in the same picker.

## Booking without an account

Phase 1 decision: a guest may book without an account.

1. `POST /api/auth/guest/start {"email"}` sends a six-digit code (template `account.guest_code`). An e-mail that already
   belongs to an account is told to sign in (`ACCOUNT_EXISTS`).
2. `POST /api/auth/guest/verify {"email", "code"}` opens a passenger session for a guest account
   (`iam.app_user.is_guest`, no password; the database refuses a guest with a password or of another account kind).
   Codes are kept as keyed hashes (purpose `GUEST_SIGN_IN`), last `code_minutes`, allow five tries and work once.
3. The guest books as any passenger. `/api/auth/me` returns `is_guest: true`; the web shows a banner, and the account
   page offers `POST /api/account/claim` (name parts and a password typed twice) to turn the guest account into a full
   account that keeps its bookings and gets a wallet and loyalty points.

The setting `booking.guest` controls it:

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Guests may book; `false` answers `GUEST_BOOKING_OFF` |
| `account_required_for` | `NONE` | `CITIZENS`: a guest booking a traveller of the market's nationality (`citizen_country`, default `SY`) gets `ACCOUNT_REQUIRED` |
| `code_minutes` | `15` | How long a guest code lasts |

The web sign-in page links to `/guest`; the mobile passenger app offers "Book without an account" on its sign-in
screen. The mobile app offers "Me" on the trip checkout; claiming a guest account is done on the website.
