
## 2026-10-10: notification payloads are free-form per event and no longer compared field by field

- GET /api/notifications.notifications[].payload: was an object

## 2026-10-14: Trip numbers have four digits (owner's decision, migration 1119): a number asked for or given is 1000 to 9999

- app POST /api/admin/schedules/requests/{request_uid}/decide body.number: minimum tightened to 1000.0
- app POST /api/carrier/schedules body.proposed_number: minimum tightened to 1000.0

## 2026-10-25: carrier crew: license_class is a licence class (letters, digits, space, + and -, up to 16 characters), checked since crew details (N3, 1158)

- app POST /api/carrier/crew body.license_class: pattern changed to ^[A-Za-z0-9][A-Za-z0-9 +-]{0,15}$
