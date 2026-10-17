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
| Daily | DC 1201 at 07:15 every day | `recurrence = 'DAILY'` |
| On days of the week | DC 1202 at 16:45 on Friday and Sunday; one day is weekly | `recurrence = 'WEEKLY'`, `days_of_week` (1 Monday to 7 Sunday) |
| On days of the month | DC 1301 at 09:30 on the 1st and 15th | `recurrence = 'MONTHLY'`, `days_of_month` (1 to 31; a month without that day skips it) |

Each runs from a date, either to a date or with no end until it is stopped (`active`, a date range), without the dates
listed in `skip_dates` (a holiday, say). `ops.recurrence_days` gives the days a pattern runs between two dates; the
carrier's form shows them before the request is sent (`POST /api/carrier/schedules/preview`).

A regular trip keeps one number every day it runs (its `net.service_number`, shown as the trip code of 1114: `DC 1201`).
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

The platform organizes the numbers: it may give a number other than the one asked for, and its screen suggests one
(`ops.request_number`). A number has four digits in the block of its trip type (scheduled 1000 to 4999, international
5000 to 5999, shuttle 6000 to 6999, cargo 7000 to 7999, extra 8000 to 8999; `NUMBER_NOT_IN_BLOCK`), and its parity
follows the direction: an outbound trip takes an odd number and its return an even one (`NUMBER_PARITY`). A number
serves one regular trip at a time on the same days (`SERVICE_NUMBER_TAKEN`), and a carrier never runs two trips under
one number on one day (`trip_number_day_uq`, 1114). See `TRIP_NUMBERS.md` for the blocks and the legs (1119).

### The legs of a vehicle's day (1119)

A regular trip on its own starts a line of its own: the platform suggests the first leg of a line whose eight numbers
are free (`ops.suggest_schedule_number`: leg 1 outbound, leg 2 for a return on its own), so that the vehicle's next legs
can follow it. The carrier may instead name the regular trip whose vehicle runs the new one next (`follows_uid` in the
request, `follows` in its proposal). The new one then takes the number after it and its direction from that number,
and the platform cannot give it another (`ROTATION_INVALID`). It must:

- leave from the city where the leg before it arrives;
- run on the same vehicle, when both name one;
- run only on days the leg before it runs;
- leave at least `schedule.min_turnaround_min` minutes after the leg before it arrives, on the same day.

A change to either leg is checked against the other (`ops.leg_problem`, `ops.rotation_problem`,
`ops.followers_problem`). A leg whose leg before it has stopped stands alone and may still be changed. The carrier's
list shows each regular trip's leg before it and after it.

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
| `schedule.min_turnaround_min` | `30` | the fewest minutes between a vehicle's arrival and its next leg (0 to 600, 1119) |

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
