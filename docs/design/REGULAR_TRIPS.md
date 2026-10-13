# Regular trips

The owner's decision of October 2026 (migration 1117). A carrier defines a trip that leaves at the same time and repeats,
as airlines run a flight every day or every week under one number. In the first phase the platform approves each
regular trip and organizes its number; the law may later ask government authorities (the Ministry of Transport, the
Interior, the traffic police) to approve as well. Every rule that a law or a regulator may change is a setting, so a new
rule needs no new release.

## What a regular trip is

A regular trip (`ops.trip_template`) has a route, a departure time (local time at the first station), a vehicle, a base
price, a trip type and a pattern:

| Pattern | Example | Fields |
| --- | --- | --- |
| Daily | DC 201 at 07:15 every day | `recurrence = 'DAILY'` |
| On days of the week | DC 202 at 16:45 on Friday and Sunday; one day is weekly | `recurrence = 'WEEKLY'`, `days_of_week` (1 Monday to 7 Sunday) |
| On days of the month | DC 301 at 09:30 on the 1st and 15th | `recurrence = 'MONTHLY'`, `days_of_month` (1 to 31; a month without that day skips it) |

Each runs from a date, either to a date or with no end until it is stopped (`active`, a date range), without the dates
listed in `skip_dates` (a holiday, say). `ops.recurrence_days` gives the days a pattern runs between two dates; the
carrier's form shows them before the request is sent (`POST /api/carrier/schedules/preview`).

A regular trip keeps one number every day it runs (its `net.service_number`, shown as the trip code of 1114: `DC 201`).
A change makes a new version under the same number, so passengers see the same number before and after.

## Requests and approval

The carrier never writes a regular trip directly. It asks, and each request (`ops.schedule_request`) is one of:

| Kind | What it asks | When approved |
| --- | --- | --- |
| `NEW` | a new regular trip, with a number it would like (optional) | becomes an active regular trip under the number given |
| `CHANGE` | a new time, pattern, end, price or publishing from a date | the current version ends the day before; the next one starts under the same number |
| `STOP` | the first day without the trip | the regular trip ends the day before |
| `TRIP` | a trip made by hand (only while `TRIP` is among the kinds that need approval) | the trip is published |

A request passes the approval stages in order (`schedule.approval_stages`). Each stage is the platform or a government
authority by its code (`sec.authority_profile`). The stages in force when a request is made are kept with it, so a later
change of the setting never moves a request already waiting. Each decision is kept (`ops.schedule_approval`, never
changed afterwards):

- one person decides one stage of a request (`SECOND_PERSON_REQUIRED`);
- the platform's stages are decided with `schedule.approve`, by someone who is not a member of an authority;
- an authority's stages are decided by its members (`sec.authority_member`), and only those;
- a refusal says why (`REASON_REQUIRED`); the carrier sees the reason;
- the carrier may withdraw a request while it waits.

When the last stage approves, the database applies the request (`ops.apply_schedule_request`) in the same transaction.
A kind not among `schedule.approval_kinds` is applied at once, without stages.

### Stopping and changing with trips already sold

A change or a stop takes effect from a date. Trips already made from that date are cancelled when nobody holds a
booking on them. Trips with bookings stay, and the result names them, for the carrier to move them or cancel them with
refunds (1102). The carrier's requests list shows that note.

## Numbers

The platform organizes the numbers: it may give a number other than the one asked for, and its screen suggests the
lowest free one (`ops.suggest_schedule_number`). A number belongs to a block by trip type, and its parity follows the
direction:

| Trip type | Block |
| --- | --- |
| Scheduled | 1 to 999 |
| International | 1000 to 1999 |
| Shuttle | 2000 to 2999 |
| Cargo | 3000 to 3999 |
| Extra (and trips made by hand without a number) | 5000 to 9999 |

An outbound trip takes an odd number and its return an even one (`NUMBER_PARITY`). A number serves one regular trip at a
time on the same days (`SERVICE_NUMBER_TAKEN`), and a carrier never runs two trips under one number on one day
(`trip_number_day_uq`, 1114).

## Making the trips

Once approved, the trips of a regular trip are made ahead, up to `schedule.horizon_days` from today. Approval makes the
first ones at once; then the worker (`generate_due` in the notify worker, every minute) extends every regular trip whose
horizon moved on (`ops.schedules_due`). So one with no end keeps running until it is stopped. Each day stands alone: a
day that cannot be made is skipped and named in the regular trip's last run (`last_run`), with its reason:

| Reason | Meaning |
| --- | --- |
| `TOO_SOON` | less than 30 minutes before it leaves |
| `EXISTS` | already made |
| `TRIP_NUMBER_TAKEN` | the number is used that day by a trip kept with its bookings |
| `SAME_DEPARTURE` | another trip of the carrier on the route at that minute |
| `VEHICLE_BUSY` | the vehicle runs another trip at that time |
| `TEMPLATE_INCOMPLETE` | no active route or no vehicle |

The carrier may pause an active regular trip (no new trips are made) and resume it, without approval.

## Settings

All are platform settings (`sys.setting`), changed on the platform's regular trips page by someone with
`schedule.settings`, and checked by the database (`ops.schedule_setting_problem`) before they are saved:

| Key | Default | Meaning |
| --- | --- | --- |
| `schedule.approval_stages` | `[{"by":"PLATFORM"}]` | who approves, in order; up to six stages, e.g. the platform, then `{"by":"AUTHORITY","authority":"MOT"}` |
| `schedule.approval_kinds` | `["NEW","CHANGE"]` | which requests pass the stages: `NEW`, `CHANGE`, `STOP`, `TRIP` |
| `schedule.min_notice_days` | `0` | the fewest days between a request and the day it takes effect (0 to 90) |
| `schedule.horizon_days` | `30` | how far ahead the trips are made (7 to 120) |
| `schedule.recurrences` | `["DAILY","WEEKLY","MONTHLY"]` | the patterns a carrier may ask for |

The same page names the members of each government authority (`POST/DELETE /api/admin/authorities/{code}/members`).
When the law asks the Ministry of Transport to approve, the platform adds its stage and its members; nothing else
changes.

## Screens and API

| Who | Page | API |
| --- | --- | --- |
| Carrier (`trip.publish`) | Regular trips: the list with each number, pattern, period, next departure and trips ahead; a new regular trip, a change, a stop, pause and resume; its requests and their state | `/api/carrier/schedules`, `/preview`, `/{uid}/change`, `/{uid}/stop`, `/{uid}/pause`, `/{uid}/resume`, `/api/carrier/schedule-requests/{uid}/withdraw` |
| Platform (`schedule.approve`) and authority members | Requests for regular trips: waiting, decided; approve with a number or refuse with a reason | `/api/admin/schedules/requests`, `/{uid}/decide` |
| Platform (`schedule.settings`) | Settings: stages, kinds, notice, horizon, patterns, authority members | `/api/admin/schedules/settings`, `/{key}`, `/api/admin/authorities/{code}/members` |

The generic resource screens show trip templates and service numbers read only: both come from approved requests.
