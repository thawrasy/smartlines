# Route compliance and school transport

Files `1043_route_compliance.sql`, `1044_school_transport.sql` and `1045_postgis.sql` implement two requests made after
the regulators' review, with the owner's decisions on each open question.

## Owner decisions

| Question | Decision | Where it lives |
|---|---|---|
| Tracking source | The driver's phone in the first phases. Contracted tracking devices later, chosen per vehicle. Nothing is mandatory until a regulator (transport authority, ministry of transport, interior or security) imposes it | `fleet.vehicle.tracking_source`, `fleet.tracking_device`, requirements `tracking.driver_app` (OPTIONAL) and `tracking.gps_device` (OFF) |
| Who is told about a deviation | The driver: a notice, then a continuous sound alarm until the vehicle is back on route. The authorities only when a regulator requires electronic reporting, and only while the vehicle is in service (running a scheduled trip or carrying passengers). Moves outside working hours and maintenance trips are never reported | `ops.route_violation` (`driver_warned_at`, `alarm_started_at`, `in_service`), `ops.violation_report`, requirement `route.report.authority` (OFF) |
| Which trips first | The shuttle, once its lines are defined and its vehicles bound to their approved, licensed line. A vehicle may still run scheduled trips | `fleet.line_permit_vehicle`, requirement `route.vehicle_binding.shuttle` (REQUIRED), `route.vehicle_binding.scheduled` (OPTIONAL) |
| PostGIS | Yes | File 1045, schema `gis` |
| School transport operators | The school's own buses, transport companies, individual owner-drivers with a school transport licence, the ministry or a government carrier, and private carriers under a government contract | `sch.operator.operator_kind` |
| Contracts | The school enrols pupils on its own buses (the guardian's approval in the app comes later); a guardian contracts with a company or an individual; government schemes | `sch.contract.contract_kind`, requirement `school.guardian_consent` (OPTIONAL) |
| Licences | The school transport licence number is required on every operator and contract now. Every other licence (company, vehicle, driver, attendant) is prepared and becomes mandatory by configuration when the government imposes it | `sch.operator.school_transport_license_no`, `sch.contract.school_transport_license_no`, `sys.compliance_requirement` |
| Pupils | A pupil is defined by the guardian from the guardian's own account and stays linked while a minor; they may get an account of their own later | `sch.student.family_member_id`, `iam.is_minor`, setting `person.age_of_majority` (18) |
| Hand-over age | 12: younger pupils leave a homeward bus only into the hands of an authorised receiver | setting `school.handover_age` |
| Place of school transport | A later phase, before the last one | phase `SCH`, ordinal 15.5 (file 1046) |
| Electronic reporting to authorities | Later: it needs the government's e-government infrastructure, expected beyond two years | `ops.violation_report` in Phase 5 (government integration); `route.report.authority` stays OFF (file 1046) |

## Requirements switched by configuration

`sys.compliance_requirement` registers every licence, tracking source and reporting duty a regulator may impose. Each has
a level:

- `OFF`: not asked.
- `OPTIONAL`: collected when given, never blocking.
- `REQUIRED`: enforced from `required_from`.

Raising a level is a configuration change, recorded by the audit trigger. No release is needed.
`sys.unmet_requirements(service, subject_type, subject_id)` lists the required licences a subject lacks, so the API can
show them and activation can refuse them. A licence counts when a verified `fleet.license_record` of its type is in force.
Licence records now also cover any person (`PERSON`, such as school bus attendants) and the types `ROUTE_PERMIT`,
`SCHOOL_TRANSPORT`, `CRIMINAL_RECORD`, `FIRST_AID` and `TRACKING_DEVICE`.

## Route compliance (Phase 2)

- **Binding.** A permit binds named vehicles to its approved line (`fleet.line_permit_vehicle`):
  - one line per vehicle at a time;
  - within the permit's validity and its vehicle limit;
  - only vehicles the carrier owns or leases.
- **Route obligation.** Every trip carries `compliance_source`: an approved line, a transit corridor, a private
  contract's agreed route (which exempts it from the regulated line) or none. While binding is required, a trip on an
  approved line needs a vehicle bound to that line.
- **Diversions.** Temporary detours issued by the regulator (`net.line_diversion`) count as part of the route.
- **Violations.**
  - The tracking service detects a deviation and confirms it over several points. Thresholds are in setting
    `route.adherence`.
  - It warns the driver, then sounds the alarm, then records the violation with its evidence.
  - Once reviewed, the evidence is frozen. Evidence is kept for 730 days, beyond the 7-day retention of positions.
  - A violation is reportable only when reporting is required, the violation is confirmed and the vehicle was in service.
    The database refuses any other report.
- **Phase map.** Tracking positions, deviations and alerts move to Phase 2, because the shuttle is monitored from the
  driver's phone from its first stage.

## School transport (phase SCH)

School transport is its own phase (`SCH`, before the last phase), separate from contracted transport for universities and
staff (phase 14). It is closed by the `school_transport` switch.

| Table | Purpose |
|---|---|
| `sch.school` | The school, with a company account on the platform |
| `sch.operator` | Who carries the pupils, under a school transport licence |
| `sch.student`, `sch.student_guardian` | The pupil, guardians, authorised receivers and custody restrictions |
| `sch.contract` | The four contract kinds, each carrying the licence number |
| `sch.route`, `sch.route_stop` | Bus, driver, attendant, route shape and stops |
| `sch.enrollment` | A pupil on a contract with routes, stops and the guardian's consent |
| `sch.run`, `sch.attendance`, `sch.absence_notice` | Daily runs, boarding and hand-over, absences reported in advance |

Safety rules held by the database:

- A pupil under the hand-over age leaves a homeward bus only into the hands of a guardian or authorised receiver. A person
  under a custody restriction is refused.
- A run cannot close while a pupil is still on board, nor before the check that no child is left on the bus.
- A pupil rides only routes of the contract's operator to and from the pupil's own school.
- Once required by configuration: the guardian's approval in the app, the guardian link of a minor, an attendant on every
  route, and the licences of the company, vehicle, driver and attendant.

Visibility (row-level security):

- The school sees its pupils.
- The operator sees the pupils it carries.
- A guardian sees their own child, their child's runs and the hand-over record.
- Other companies and passengers see nothing.

Pupils' identities, guardians, attendance and absences are classified as personal data (`USER_PRIVATE`). Medical notes are
encrypted.

## PostGIS

The extension lives in schema `gis`. Route shapes stay GeoJSON for the API. Each one gets a generated geography column
(`net.line_version.path`, `net.line_diversion.path`, `net.corridor.path_geo`, `sch.route.path_geo`, `net.station.geo`)
with a GiST index.

- A line version, diversion or corridor becomes binding only with a valid line shape.
- `ops.route_distance_m(trip, lat, lng, at)` measures the distance to the nearest binding shape, counting active
  diversions, and says whether the position is outside every corridor.
- `net.stations_near(lat, lng, radius)` finds stops by spatial index.
- Live detection stays in the tracking service; the database confirms deviations and freezes the evidence.

Deployment needs a PostgreSQL 16 server with PostGIS 3:

- Docker and CI use the image `postgis/postgis:16-3.4`.
- On Ubuntu, install the package `postgresql-16-postgis-3`.

## Tests

`db/tests/run_tests.sql` covers:

- **Configurable requirements:** nothing is imposed except shuttle binding; the company licence blocks approval once it
  is required.
- **Binding and its limits:** an unbound vehicle cannot run an approved line; the permit's vehicle limit holds; another
  carrier's vehicle cannot be bound.
- **Reporting:** nothing is reported while reporting is not required, nor while the vehicle is off duty; a confirmed
  violation in service is reported once required.
- **Evidence:** the evidence of a reviewed violation cannot change.
- **PostGIS:** distances to the route and to an active diversion; invalid route shapes are refused.
- **Operators and contracts:** each operator kind matches its account and its contract kinds.
- **Pupils:** consent and the guardian link; hand-over to strangers and to people under a custody restriction is refused;
  a run cannot close while a pupil is on board or before the empty-bus check.
- **Isolation:** each school, operator and guardian sees only their own rows.
