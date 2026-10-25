# Second-factor channels (N36, migration 1151)

The second step of sign-in accepts a code from any method the platform opens in the setting `auth.mfa`:

| Method | Where the code comes from | Open by default |
|--------|---------------------------|-----------------|
| `TOTP` | An authenticator app (Google Authenticator and similar) | yes |
| `EMAIL` | An e-mail to the account's address, or another address the person gives | yes |
| `TELEGRAM` | A message from the platform's bot to a chat the person linked | yes |
| `WHATSAPP` | A WhatsApp message through the platform's WhatsApp Business account | yes, from the launch (1152) |
| `SMS` | A text message | no: opened when an SMS provider is contracted |
| recovery codes | Ten single-use codes given at the first enrolment | always |

A method open in the policy is offered only when the server can deliver on it (`MASSLAK_NOTIFY_EMAIL`,
`MASSLAK_NOTIFY_TELEGRAM`, `MASSLAK_NOTIFY_SMS`, `MASSLAK_NOTIFY_WHATSAPP`). Codes are kept only as keyed hashes, last
`code_minutes`, allow five tries and work once; the resend wait and the hourly limit apply to every channel.

## E-mail

`POST /api/auth/mfa/enroll {"method": "EMAIL", "email": null}` sends the first code to the account's address (or the one
given); `POST /api/auth/mfa/confirm` with that code finishes it. The address is stored encrypted on the factor and shown
masked (`s•••@example.com`).

## Telegram

1. `POST /api/auth/mfa/enroll {"method": "TELEGRAM"}` makes a pending factor and a one-time link
   `https://t.me/<bot>?start=<token>`, valid 15 minutes; only the keyed hash of the token is kept (`iam.messenger_link`).
2. The person opens the link and presses Start. Telegram calls `POST /api/auth/telegram/webhook` with the header
   `X-Telegram-Bot-Api-Secret-Token`; the server checks it, finds the link, stores the chat id encrypted on the factor
   and sends the first code to that chat. A link works once; a late or unknown token links nothing.
3. The person enters the code (`/api/auth/mfa/confirm`); later sign-ins send codes with `/api/auth/mfa/send`.

Server settings: `MASSLAK_NOTIFY_TELEGRAM=bot`, `MASSLAK_TELEGRAM_BOT_TOKEN`, `MASSLAK_TELEGRAM_BOT_NAME`,
`MASSLAK_TELEGRAM_WEBHOOK_SECRET`. The egress proxy allows `api.telegram.org` when Telegram delivery is on.

## Screens

The web and mobile second-step pages list the open methods, ask for the e-mail address when enrolling by e-mail, and
open the bot link when enrolling by Telegram. The security console's policy page lists all five methods with their
delivery state.

## Tests

`backend/tests/test_second_factor_channels.py` and the "Second factor (1151)" checks in `db/tests/run_tests.sql`.
