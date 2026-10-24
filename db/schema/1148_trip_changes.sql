-- =====================================================================
-- 1148: changes to a scheduled trip (owner's request N42, October 2026)
--   A trip keeps its number and its reference whatever happens to it; what changes is recorded in ops.trip_change with
--   a reason from the platform's catalogue, a note, who and when, how many bookings it touched and how many of them
--   could be told. The carrier:
--   * changes the vehicle (a breakdown, an accident), before departure or on the way: the database checks the new
--     vehicle as for any trip (active, owned or leased, licences valid, free at that time); seats keep their numbers
--     where the new vehicle has them, the others move to free seats; on the way the stop where it was changed is kept
--     (ops.vehicle_swap);
--   * moves the departure (a late incoming trip, a repair): every stop moves by the same minutes; a passenger whose trip
--     moved by at least the platform's threshold may cancel with everything back, without the fare's fee;
--   * moves passengers to another of its trips on the same route (one booking or all), for instance before cancelling
--     the trip: the booking keeps its reference, each ticket gets a new number on the new trip (sales.ticket_move), the
--     passenger pays no difference; those not moved are refunded in full when the trip is cancelled (1102).
--   Every booking touched is told at once (in the app, by e-mail, by text for a counter or agency sale) with the new
--   number, time, seat or vehicle; those that cannot be reached are listed for the carrier to call
--   (ops.trip_change_contact), and the carrier records the call.
-- =====================================================================

INSERT INTO sys.setting (key, value, description) VALUES
  ('trips.change_policy', jsonb_build_object(
      'reasons', jsonb_build_array(
        jsonb_build_object('code', 'BREAKDOWN',           'en', 'Breakdown',                    'ar', 'عطل فني'),
        jsonb_build_object('code', 'ACCIDENT',            'en', 'Accident',                     'ar', 'حادث'),
        jsonb_build_object('code', 'LATE_INCOMING_TRIP',  'en', 'Late arrival of the incoming trip', 'ar', 'تأخر وصول الرحلة القادمة'),
        jsonb_build_object('code', 'REPAIR_IN_PROGRESS',  'en', 'Repair in progress',           'ar', 'إصلاح قيد التنفيذ'),
        jsonb_build_object('code', 'VEHICLE_REPLACEMENT', 'en', 'Vehicle replacement',          'ar', 'استبدال المركبة'),
        jsonb_build_object('code', 'WEATHER',             'en', 'Weather',                      'ar', 'أحوال جوية'),
        jsonb_build_object('code', 'ROAD_CLOSURE',        'en', 'Road closure',                 'ar', 'إغلاق طريق'),
        jsonb_build_object('code', 'AUTHORITY_ORDER',     'en', 'Order of an authority',        'ar', 'قرار جهة رسمية'),
        jsonb_build_object('code', 'OTHER',               'en', 'Other (explained in the note)', 'ar', 'سبب آخر (يُشرح في الملاحظة)')),
      'free_cancel_shift_min', 60,
      'max_shift_min', 1440,
      'rebook_window_hours', 72),
   'Changes to a trip (N42, 1148): the reasons a carrier picks from, the move of the departure from which a passenger cancels without fee, the largest move, how far ahead passengers may be moved')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ the change log, fuller
ALTER TABLE ops.trip_change DROP CONSTRAINT IF EXISTS trip_change_kind_check;
ALTER TABLE ops.trip_change ADD CONSTRAINT trip_change_kind_check
  CHECK (kind IN ('DELAY','RESCHEDULE','CANCEL','VEHICLE_SWAP','STOP_CHANGE','REBOOK'));
ALTER TABLE ops.trip_change
  ADD COLUMN IF NOT EXISTS uid          uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS reason_code  text CHECK (reason_code ~ '^[A-Z_]{3,40}$'),
  ADD COLUMN IF NOT EXISTS note         text CHECK (length(note) <= 500),
  ADD COLUMN IF NOT EXISTS details      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  ADD COLUMN IF NOT EXISTS affected     integer NOT NULL DEFAULT 0 CHECK (affected >= 0),
  ADD COLUMN IF NOT EXISTS notified     integer NOT NULL DEFAULT 0 CHECK (notified >= 0),
  ADD COLUMN IF NOT EXISTS unreachable  integer NOT NULL DEFAULT 0 CHECK (unreachable >= 0);
ALTER TABLE ops.trip_change DROP CONSTRAINT IF EXISTS trip_change_other_note_ck;
ALTER TABLE ops.trip_change ADD CONSTRAINT trip_change_other_note_ck
  CHECK (reason_code IS DISTINCT FROM 'OTHER' OR coalesce(length(btrim(note)), 0) >= 3);
CREATE UNIQUE INDEX IF NOT EXISTS trip_change_uid_uq ON ops.trip_change (uid);
CREATE INDEX IF NOT EXISTS trip_change_by_user_id_fkx ON ops.trip_change (by_user_id) WHERE by_user_id IS NOT NULL;
COMMENT ON COLUMN ops.trip_change.reason_code IS 'Code from the platform''s catalogue (trips.change_policy); OTHER needs a note (1148)';
COMMENT ON COLUMN ops.trip_change.affected IS 'Bookings the change touched; notified: told by the system; unreachable: left for the carrier to call (1148)';

-- ------------------------------------------------------------------ a vehicle change, fuller
ALTER TABLE ops.vehicle_swap
  ADD COLUMN IF NOT EXISTS trip_change_id bigint REFERENCES ops.trip_change(id),
  ADD COLUMN IF NOT EXISTS reason_code    text CHECK (reason_code ~ '^[A-Z_]{3,40}$'),
  ADD COLUMN IF NOT EXISTS en_route       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS at_stop_seq    smallint CHECK (at_stop_seq >= 0),
  ADD COLUMN IF NOT EXISTS seats_moved    integer NOT NULL DEFAULT 0 CHECK (seats_moved >= 0),
  ADD COLUMN IF NOT EXISTS driver_changed boolean NOT NULL DEFAULT false;
ALTER TABLE ops.vehicle_swap DROP CONSTRAINT IF EXISTS vehicle_swap_en_route_ck;
ALTER TABLE ops.vehicle_swap ADD CONSTRAINT vehicle_swap_en_route_ck CHECK (en_route OR at_stop_seq IS NULL);
CREATE INDEX IF NOT EXISTS vehicle_swap_trip_change_id_fkx ON ops.vehicle_swap (trip_change_id) WHERE trip_change_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS vehicle_swap_approved_by_fkx ON ops.vehicle_swap (approved_by) WHERE approved_by IS NOT NULL;

-- ------------------------------------------------------------------ a ticket moved to another trip or seat
CREATE TABLE IF NOT EXISTS sales.ticket_move (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticket_id       bigint NOT NULL REFERENCES sales.ticket(id),
  trip_change_id  bigint NOT NULL REFERENCES ops.trip_change(id),
  from_trip_id    bigint NOT NULL REFERENCES ops.trip(id),
  to_trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  old_ticket_no   text NOT NULL,
  new_ticket_no   text NOT NULL,
  old_seat_no     smallint,
  new_seat_no     smallint,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ticket_move_changed_ck CHECK (from_trip_id <> to_trip_id OR old_seat_no IS DISTINCT FROM new_seat_no)
);
CREATE INDEX IF NOT EXISTS ticket_move_ticket_id_fkx ON sales.ticket_move (ticket_id);
CREATE INDEX IF NOT EXISTS ticket_move_trip_change_id_fkx ON sales.ticket_move (trip_change_id);
CREATE INDEX IF NOT EXISTS ticket_move_from_trip_id_fkx ON sales.ticket_move (from_trip_id);
CREATE INDEX IF NOT EXISTS ticket_move_to_trip_id_fkx ON sales.ticket_move (to_trip_id);
COMMENT ON TABLE sales.ticket_move IS 'A ticket moved by a change of its trip: to another trip (new number) or to another seat (1148, N42)';
SELECT sys.rls_parent('sales.ticket_move', 'ticket_id', 'sales.ticket');

-- ------------------------------------------------------------------ who could not be told
CREATE TABLE IF NOT EXISTS ops.trip_change_contact (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_change_id  bigint NOT NULL REFERENCES ops.trip_change(id),
  booking_id      bigint NOT NULL REFERENCES sales.booking(id),
  contacted_at    timestamptz,
  contacted_by    bigint REFERENCES iam.app_user(id),
  outcome         text CHECK (outcome IN ('INFORMED','NO_ANSWER','WRONG_NUMBER')),
  note            text CHECK (length(note) <= 300),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trip_change_contact_uq UNIQUE (trip_change_id, booking_id),
  CONSTRAINT trip_change_contact_done_ck CHECK ((contacted_at IS NULL) = (outcome IS NULL))
);
CREATE INDEX IF NOT EXISTS trip_change_contact_booking_id_fkx ON ops.trip_change_contact (booking_id);
CREATE INDEX IF NOT EXISTS trip_change_contact_contacted_by_fkx ON ops.trip_change_contact (contacted_by) WHERE contacted_by IS NOT NULL;
COMMENT ON TABLE ops.trip_change_contact IS 'A booking the system could not tell of a trip change (no account, no mobile): the carrier calls and records it (1148, N42)';
SELECT sys.rls_parent('ops.trip_change_contact', 'trip_change_id', 'ops.trip_change');
GRANT SELECT, INSERT ON sales.ticket_move TO masslak_app;
GRANT SELECT ON sales.ticket_move TO masslak_readonly, masslak_auditor;
GRANT SELECT, INSERT, UPDATE ON ops.trip_change_contact TO masslak_app;
GRANT SELECT ON ops.trip_change_contact TO masslak_readonly, masslak_auditor;

-- a booking moved to another trip changes its trip and its tickets' trip together: the pair is checked at commit
ALTER TABLE sales.ticket ALTER CONSTRAINT ticket_booking_trip_fk DEFERRABLE INITIALLY IMMEDIATE;

INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ops.trip_change', 'details', 'SNAPSHOT', 1, '{"type": "object"}'::jsonb,
   'what a trip change did: the vehicles, the stop on the way, the trip passengers moved to and the bookings (1148)')
ON CONFLICT DO NOTHING;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sales.ticket_move', '1A', 'E11'), ('ops.trip_change_contact', '1A', 'E08')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sales.ticket_move', 'sales records', 'a ticket moved to another trip or seat by a trip change (1148)'),
  ('ops.trip_change_contact', 'ops records', 'a passenger the carrier must call about a trip change (1148)')
ON CONFLICT (table_name) DO NOTHING;
