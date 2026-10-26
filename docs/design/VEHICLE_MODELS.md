# Vehicle makes and models (owner's request N8, migration 1157)

## What it solves

Carriers typed the make and model of each vehicle. The same bus was written several ways, so reports and checks could
not group vehicles. The platform now keeps one list of makes and models, and carriers pick from it.

## The list

| Table | What it holds |
|---|---|
| `ref.vehicle_make` | code (from the English name), English and Arabic names, country |
| `ref.vehicle_model` | make, model name, class (bus, truck, train, car, other), vehicle type, approximate seats (from–to) or a truck's weight class, whether still made, how sure the name is, notes |

Every make and model carries:

- `status`: `PENDING_REVIEW`, `ACTIVE`, `REJECTED` or `RETIRED`;
- `source`: `MANUAL`, `IMPORT` or `REQUEST`;
- who entered it and who reviewed it.

The rules:

- The person who entered an entry never reviews it (`*_review_ck`).
- A model is accepted only after its make.
- Only `ACTIVE` entries are offered to carriers.
- Only trucks have a weight class, and a seat range never ends before it starts.

The owner's table (`Masslak_Vehicle_Models_*.xlsx`) is imported at `POST /api/admin/vehicle-models/import`:

- Every sheet that has the `make_en`, `make_ar` and `model` columns is read.
- Rows the owner marked "remove" are left out.
- A model already in the list is skipped.
- Everything comes in as `PENDING_REVIEW`.
- A row with an unknown class, type or weight refuses the whole file.
- The data itself is not kept in the repository.

## Carriers' requests

A carrier that does not find its model sends a request (`fleet.vehicle_model_request`). The request names a make from
the list or writes a new one, and gives the model, the type and the seats. Platform staff then:

- **approve** it: the make (when new, with its Arabic name) and the model are added. They still wait for a second
  person's review;
- **match** it to a model already in the list; or
- **reject** it, with a reason.

The carrier can withdraw a request before it is handled. Requests are row-secured to the carrier.

## Vehicles

- `fleet.vehicle.model_id` points to the list.
- A trigger accepts only a reviewed model under a reviewed make, and copies the make and model names onto the vehicle.
  Old rows keep the names they had.
- The carrier's vehicle form offers the make, then the model, and fills the vehicle type from the model. A link,
  "my model is not in the list", opens the request.
- The same form now offers the insurance company from the registry (1156).

## Screens

- **Platform → Banks and insurers → Vehicle models**:
  - makes with their models;
  - add a make or a model;
  - accept or reject;
  - retire;
  - import the owner's table;
  - the requests, each with its decision.
- **Carrier → Vehicles → Add a vehicle**: make and model pickers, the request form, and the insurer picker.

## Tests

- `backend/tests/test_vehicle_models.py` covers:
  - review by a second person, with the make accepted before its models;
  - a vehicle carrying the names from its list entry;
  - a pending model refused on a vehicle;
  - requests approved, matched, rejected and withdrawn;
  - the import, where a whole file is refused, rows marked "remove" are skipped, a truck gets its weight class, and a
    second import skips entries already there.
- `db/tests/run_tests.sql`, block "Vehicle models (1157)", covers:
  - companies cannot write the list;
  - four eyes;
  - the seats range;
  - the truck weight class;
  - vehicles pick only reviewed models;
  - names copied onto the vehicle;
  - the request rules.
