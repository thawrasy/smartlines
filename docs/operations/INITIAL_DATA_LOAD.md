# Initial data load with the bulk import tool

The initial data load (the Arabic plan is `docs/readiness/Masslak_Initial_Data_Load_Plan_AR_v0.1.docx`) is done with
`backend/app/tools/bulk_import.py`. The tool reads a CSV file and sends each row to the same API a clerk uses, so every
rule, permission and audit record applies; it never writes to the database itself. It closes gap 6 of the use case
review (October 2026).

## Order

1. Platform reference data, as a platform administrator (`--portal PLATFORM`): stations, cities and any catalogue the
   generic screens hold, with `resource:<key>` (for example `resource:station-contact`). Central stations are created
   and approved by the platform before carriers use them.
2. For each carrier, signed in as its owner or operations staff (`--portal OPERATOR`):
   1. `routes`: one row per stop, the station by its code, on a route of the network named by its code (the platform
      defines those routes first, 1163; the system then sets each route's code and the report gives it);
   2. `vehicles`: with their insurance and seat layout (by name); a vehicle without valid insurance is refused;
   3. `drivers`: each gets an account and the driver role;
   4. `trips`: by route code, plate number and driver e-mail, at the market's local time.

## Running it

```
cd backend
export MASSLAK_IMPORT_PASSWORD='...'        # read from the environment, never from the command line
python -m app.tools.bulk_import --template vehicles > vehicles.csv          # the header; required columns first
python -m app.tools.bulk_import --base https://masslak.example --email ops@carrier.sy vehicles vehicles.csv --dry-run
python -m app.tools.bulk_import --base https://masslak.example --email ops@carrier.sy vehicles vehicles.csv
```

- The CSV is UTF-8 (a byte-order mark from a spreadsheet is accepted) with a header line. Dates are `YYYY-MM-DD`.
- `--dry-run` checks every row (required columns, numbers, dates, that the stations, layouts, routes, vehicles and
  drivers named exist, and which rows are already present) and creates nothing. Rules only the server knows, such as an
  expired insurance, are checked on the real run.
- Every run writes `<file>.report.csv`: the row number, its key, `CREATED`, `EXISTS`, `WOULD_CREATE`, `INVALID` (refused
  before sending, with the reason) or `FAILED` (refused by the server, with its error code and message), and the new
  record's id. Fix the rows that did not pass and send the same file again: rows already present are reported as
  `EXISTS` and not created twice (vehicles by plate, drivers by e-mail, routes by code, or on a route of the network by the same stations; generic records by the
  server's own uniqueness rules).
- Drivers without a password get a generated one, written only to `<file>.credentials.csv` with mode 0600 and never to
  the report. Give each driver theirs, then delete the file; the driver changes it at first sign-in.
- A portal that asks for a second factor takes the code from `MASSLAK_IMPORT_OTP`, or asks for it.
- The server's rate limits are respected: a 429 or 503 answer is waited out (its Retry-After) and the row sent again.
- Exit status: 0 when every row was created or was present, 2 when some rows were invalid or failed, 1 when the run
  could not start (sign-in refused, unknown resource).

## Columns

| Kind | Required | Optional |
|---|---|---|
| `routes` | `code`, `seq`, `station_code`, `arr_offset_min`, `dep_offset_min`, `fare_from_origin` | `network_route` |
| `vehicles` | `plate_no`, `chassis_no`, `insurance_no`, `insurer`, `insurance_issue`, `insurance_expiry` | `vehicle_type`, `make`, `model`, `manufacture_year`, `passenger_seats`, `seat_layout` |
| `drivers` | `full_name`, `email` | `password`, `mobile`, `license_class` |
| `trips` | `route_code`, `plate_no`, `driver_email`, `departure_local` (`YYYY-MM-DDTHH:MM`) | |
| `resource:<key>` | the record's required fields (`GET /api/r/<key>/_spec`) | any other field of its form; `<field>@lookup` to give a reference by the label the screens show (usually its code) |

Fares are in minor units (1 SYP = 100), like every amount in the API. A route's first stop has offsets and fare 0,
and the fare increases at every stop.

Tests: `backend/tests/test_bulk_import.py` (dry run, report, second run, generated passwords, routes and trips, a
generic record with a lookup).
