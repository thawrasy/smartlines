# Sign-in doors (N16, migration 1150)

Two doors replace the sign-in page with a portal picker.

| Door | Who | What they type | Portal |
|------|-----|----------------|--------|
| Individuals (`POST /api/auth/login/individual`) | Passengers | E-mail or mobile number, password | PASSENGER |
| Businesses (`POST /api/auth/login/business`) | Carriers, agencies, station operators, platform staff | Company number, username, password | From the company's kind |

## Company numbers and usernames

* Every company has a public number, `iam.company.company_no` (6 to 8 digits, from `iam.company_no_seq`, starting at 100101).
  The platform's own staff use the platform number in the setting `auth.doors.platform_no` (100000).
* A username is unique within its company (`iam.app_user.home_company_id`); platform staff have no home company.
  It is made from the e-mail's local part when the account joins a company (`iam.tg_member_home`) or, for platform staff,
  when the account is made (`iam.tg_platform_username`). A taken name gets a number (`door1`, `door12`).
* The company's kind picks the portal: AGENCY → AGENCY, STATION_OPERATOR → STATION, any carrier → OPERATOR, or DRIVER
  for an employee whose role is `CARRIER_DRIVER` (or when the driver's app asks for it). Platform staff land in PLATFORM;
  the inspector's app asks for INSPECTOR.
* An unknown company number is answered exactly as a wrong password, after the same hashing work and with the same rate
  limits, so numbers and usernames cannot be probed.

## Temporary passwords

A password an administrator sets for a new member of staff (crew, agency staff, a new company's owner, a station
operator's owner) is temporary:

* `password_must_change` is set and `temp_password_expires_at` = now + `auth.doors.temp_password_hours` (72).
* The sign-in answers `password_change_required: true`. Every API call except the second-factor endpoints and
  `POST /api/account/password/first` returns `403 PASSWORD_CHANGE_REQUIRED` until the employee chooses their own password.
* After expiry the sign-in returns `403 TEMP_PASSWORD_EXPIRED`; the administrator sets a new one.
* The creating endpoints return `sign_in: {company_no, username, temp_password_expires_at}`, shown once to the
  administrator so they can hand it to the employee. The password itself is never shown back.

## The older sign-in

`POST /api/auth/login` with a portal stays while the setting `auth.doors.legacy_portal_login` is true, for apps not yet
updated. When it is false the endpoint answers `410 USE_SIGN_IN_DOORS`. The plan is to turn it off at the public launch.

## Screens

* Web: the sign-in page has two tabs (Individuals, Businesses); `/first-password` asks for the new password before the
  second factor; the staff screens show the sign-in details after creating an account.
* Mobile: the passenger app uses the individuals' door; the driver's and the operator's apps use the business door and
  ask for the person's own password on the same screen when the password was temporary.

## Tests

`backend/tests/test_signin_doors.py` (doors, probing, platform number, temporary password, expiry, turning the older
sign-in off) and the "Sign-in doors (1150)" checks in `db/tests/run_tests.sql`.
