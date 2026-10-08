-- =====================================================================
-- 1054: launch completeness (readiness audit against study v3.2 and design 3.11, October 2026)
--   The audit mapped every table of the launch phases to the API and the portals. These tables had no screen and no
--   endpoint: complaints and claims with their service levels, trip ratings, pricing setup (tax, commission,
--   cancellation and fare tables), loyalty programmes, fleet records, trip templates, the security console, finance
--   controls, data governance, reference data, and the whole school transport phase. This file adds what their
--   screens need from the database:
--   a. complaints and claims: a reference and service-level dates set on every new case from the support.sla setting;
--      the first public reply of the staff stamps the first response; resolving stamps the time and the breach flag;
--      a claim is paid once, by a ledger transaction posted by someone other than the person who decided it
--   b. trip ratings: only the passenger of the ticket, only after the trip, once per ticket
--   c. school transport: a guardian may only give or refuse consent on an enrolment, and only a guardian or the operator
--      may report an absence; the person who checked the bus empty is recorded
--   d. trips generated from a template are unique per template and departure, so generating twice adds nothing
--   e. permissions and module switches for the new screens
-- =====================================================================

-- ------------------------------------------------------------------ e. permissions and switches
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('school.manage','sch','PLATFORM','School transport oversight: schools, operator approval and licences',true),
  ('school.operate','sch','COMPANY','School transport operation: contracts, routes, pupils, runs and attendance',true),
  ('reference.manage','ref','PLATFORM','Reference data: currencies, exchange rates and type catalogues',false),
  ('security.console','sec','PLATFORM','Blocklist, fraud cases, risk decisions, alarms and access reviews',true),
  ('authority.requests','sec','PLATFORM','Data requests and orders received from authorities',true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN','school.manage'),('PLATFORM_ADMIN','reference.manage'),('PLATFORM_ADMIN','security.console'),
  ('PLATFORM_ADMIN','authority.requests'),('PLATFORM_ADMIN','case.handle'),
  ('PLATFORM_SECURITY','security.console'),('PLATFORM_SECURITY','authority.requests'),
  ('PLATFORM_SUPPORT','case.handle'),
  ('CARRIER_OPERATIONS','school.operate')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- The new screens are part of the core and start switched on; school transport keeps its own phase switch
UPDATE sys.setting SET value = '{"support_cases":true,"pricing_setup":true,"fleet_records":true,"security_console":true,
                                 "finance_controls":true,"data_governance":true,"reference_data":true}'::jsonb || value
 WHERE key = 'features' AND NOT (value ? 'support_cases');

INSERT INTO sys.setting (key, value, description) VALUES
  ('support.sla', '{"CRITICAL":[1,8],"HIGH":[4,24],"NORMAL":[8,72],"LOW":[24,120]}',
   'Service levels of complaints and claims by priority: [hours to the first response, hours to the resolution] (7.6)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ a. complaints and claims
CREATE OR REPLACE FUNCTION crm.tg_case_defaults() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE sla jsonb; b record;
BEGIN
  IF NEW.ref IS NULL OR NEW.ref = '' THEN
    LOOP
      NEW.ref := 'C' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 7));
      EXIT WHEN NOT EXISTS (SELECT 1 FROM crm."case" WHERE ref = NEW.ref);
    END LOOP;
  END IF;
  IF NEW.booking_id IS NOT NULL THEN
    SELECT trip_id, company_id INTO b FROM sales.booking WHERE id = NEW.booking_id;
    NEW.trip_id := coalesce(NEW.trip_id, b.trip_id);
    NEW.company_id := coalesce(NEW.company_id, b.company_id);
  ELSIF NEW.trip_id IS NOT NULL AND NEW.company_id IS NULL THEN
    NEW.company_id := (SELECT company_id FROM ops.trip WHERE id = NEW.trip_id);
  END IF;
  IF NEW.party_id IS NULL AND NEW.channel IN ('APP','WEB') THEN
    NEW.party_id := sys.ctx_party_id();
  END IF;
  SELECT value -> NEW.priority INTO sla FROM sys.setting WHERE key = 'support.sla';
  NEW.first_due_at := coalesce(NEW.first_due_at, NEW.created_at + make_interval(hours => coalesce((sla ->> 0)::int, 8)));
  NEW.resolve_due_at := coalesce(NEW.resolve_due_at, NEW.created_at + make_interval(hours => coalesce((sla ->> 1)::int, 72)));
  IF NEW.kind <> 'CLAIM' AND (NEW.claim_amount IS NOT NULL OR NEW.approved_amount IS NOT NULL) THEN
    RAISE EXCEPTION 'NOT_A_CLAIM: only a claim carries amounts' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION crm.tg_case_defaults IS 'New case: reference, company and trip from the booking, the customer''s party, service-level dates from support.sla (1054)';
DROP TRIGGER IF EXISTS a_case_defaults ON crm."case";
CREATE TRIGGER a_case_defaults BEFORE INSERT ON crm."case" FOR EACH ROW EXECUTE FUNCTION crm.tg_case_defaults();

CREATE OR REPLACE FUNCTION crm.tg_case_lifecycle() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE decider bigint; payer bigint;
BEGIN
  IF OLD.status IN ('CLOSED','REJECTED') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'CASE_FINAL: a closed or rejected case does not reopen; open a new case' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'RESOLVED' AND OLD.status <> 'RESOLVED' THEN
    NEW.resolved_at := now();
    NEW.sla_breached := NEW.sla_breached OR now() > NEW.resolve_due_at
                        OR coalesce(NEW.first_response_at, now()) > NEW.first_due_at;
  END IF;
  IF NEW.approved_amount IS NOT NULL AND (NEW.approved_amount < 0 OR NEW.approved_amount > coalesce(NEW.claim_amount, 0)) THEN
    RAISE EXCEPTION 'APPROVED_OVER_CLAIM: the approved amount is between zero and the amount claimed' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.payout_status = 'PENDING_FINANCE' AND OLD.payout_status = 'NONE' THEN
    IF NEW.kind <> 'CLAIM' OR coalesce(NEW.approved_amount, 0) <= 0 OR NEW.liable IS NULL OR NEW.liable NOT IN ('CARRIER','PLATFORM') THEN
      RAISE EXCEPTION 'CLAIM_NOT_DECIDED: a claim goes to finance with an approved amount and the carrier or the platform liable'
        USING ERRCODE = 'P0001';
    END IF;
    -- the decision is recorded with the person who took it, so the payment can be checked against it
    INSERT INTO crm.case_event (case_id, actor_id, actor_role, kind, visibility, body)
    VALUES (NEW.id, sys.ctx_user_id(), 'STAFF', 'DECISION', 'INTERNAL',
            format('Claim approved: %s, liable: %s', NEW.approved_amount, NEW.liable));
  END IF;
  IF OLD.payout_status = 'PAID' AND (NEW.payout_status <> 'PAID' OR NEW.approved_amount IS DISTINCT FROM OLD.approved_amount
                                      OR NEW.payout_ledger_txn_id IS DISTINCT FROM OLD.payout_ledger_txn_id) THEN
    RAISE EXCEPTION 'CLAIM_PAID: a paid claim keeps its amount and its transaction' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.payout_status = 'PAID' AND OLD.payout_status <> 'PAID' THEN
    IF OLD.payout_status <> 'PENDING_FINANCE' OR NEW.payout_ledger_txn_id IS NULL THEN
      RAISE EXCEPTION 'CLAIM_NOT_PAYABLE: a claim is paid from finance with its ledger transaction' USING ERRCODE = 'P0001';
    END IF;
    SELECT actor_id INTO decider FROM crm.case_event WHERE case_id = NEW.id AND kind = 'DECISION' ORDER BY id DESC LIMIT 1;
    SELECT created_by INTO payer FROM fin.ledger_txn WHERE id = NEW.payout_ledger_txn_id;
    IF payer IS NULL OR payer = decider THEN
      RAISE EXCEPTION 'FOUR_EYES: the claim is paid by someone other than the person who decided it' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION crm.tg_case_lifecycle IS 'Case rules: closed is final, resolution stamps time and breach, claims paid once under four eyes (1054)';
DROP TRIGGER IF EXISTS b_case_lifecycle ON crm."case";
CREATE TRIGGER b_case_lifecycle BEFORE UPDATE ON crm."case" FOR EACH ROW EXECUTE FUNCTION crm.tg_case_lifecycle();

CREATE OR REPLACE FUNCTION crm.tg_case_event_effects() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.kind = 'REPLY' AND NEW.visibility = 'PUBLIC' AND NEW.actor_role <> 'CUSTOMER' THEN
    UPDATE crm."case" SET first_response_at = coalesce(first_response_at, NEW.created_at),
                          status = CASE WHEN status = 'NEW' THEN 'OPEN' ELSE status END
     WHERE id = NEW.case_id AND (first_response_at IS NULL OR status = 'NEW');
    -- the customer hears of the reply (in the app and by e-mail), in the transaction that wrote it
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
    SELECT 'case.replied', 'case', c.id, c.company_id,
           jsonb_build_object('case_ref', c.ref, 'subject', c.subject,
                              'user_id', (SELECT u.id FROM iam.app_user u WHERE u.party_id = c.party_id AND u.status = 'ACTIVE'
                                           ORDER BY u.id LIMIT 1))
      FROM crm."case" c WHERE c.id = NEW.case_id AND c.party_id IS NOT NULL;
  ELSIF NEW.actor_role = 'CUSTOMER' THEN
    IF NEW.visibility <> 'PUBLIC' OR NEW.kind NOT IN ('REPLY','ATTACHMENT') THEN
      RAISE EXCEPTION 'CUSTOMER_EVENT: a customer adds public replies and attachments only' USING ERRCODE = 'P0001';
    END IF;
    UPDATE crm."case" SET status = 'OPEN' WHERE id = NEW.case_id AND status IN ('WAITING','RESOLVED');
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION crm.tg_case_event_effects IS 'Case events: the first public staff reply stamps the first response; a customer reply reopens a waiting or resolved case (1054)';
DROP TRIGGER IF EXISTS case_event_effects ON crm.case_event;
CREATE TRIGGER case_event_effects AFTER INSERT ON crm.case_event FOR EACH ROW EXECUTE FUNCTION crm.tg_case_event_effects();

-- a paid claim's ledger transaction points at its case
UPDATE sys.polymorphic_reference SET targets = targets || '{"case": "crm.case"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND type_col = 'ref_type' AND NOT targets ? 'case';

-- ------------------------------------------------------------------ b. trip ratings
CREATE OR REPLACE FUNCTION crm.tg_trip_rating_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k record;
BEGIN
  SELECT t.id, t.trip_id, t.status, b.booker_party_id, t.passenger_id, tr.company_id, tr.status AS trip_status, tr.arrival_at
    INTO k FROM sales.ticket t JOIN sales.booking b ON b.id = t.booking_id JOIN ops.trip tr ON tr.id = t.trip_id
   WHERE t.id = NEW.ticket_id;
  IF k.id IS NULL THEN
    RAISE EXCEPTION 'UNKNOWN_TICKET: no such ticket' USING ERRCODE = 'P0001';
  END IF;
  IF NOT sys.ctx_is_platform() AND NEW.party_id <> k.booker_party_id
     AND NEW.party_id IS DISTINCT FROM (SELECT party_id FROM sales.passenger WHERE id = k.passenger_id) THEN
    RAISE EXCEPTION 'NOT_YOUR_TICKET: only the traveller or the buyer rates a ticket' USING ERRCODE = 'P0001';
  END IF;
  IF k.status = 'CANCELLED' OR NOT (k.trip_status = 'COMPLETED' OR k.status = 'BOARDED' OR k.arrival_at < now()) THEN
    RAISE EXCEPTION 'TRIP_NOT_TRAVELLED: a trip is rated after travelling on it' USING ERRCODE = 'P0001';
  END IF;
  NEW.trip_id := k.trip_id;
  NEW.company_id := k.company_id;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION crm.tg_trip_rating_rules IS 'Ratings: the traveller or buyer of the ticket, after the trip, with the trip and carrier of the ticket (1054)';
DROP TRIGGER IF EXISTS a_trip_rating_rules ON crm.trip_rating;
CREATE TRIGGER a_trip_rating_rules BEFORE INSERT ON crm.trip_rating FOR EACH ROW EXECUTE FUNCTION crm.tg_trip_rating_rules();

-- ------------------------------------------------------------------ c. school transport
CREATE OR REPLACE FUNCTION sch.tg_enrollment_guardian() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE staff boolean;
BEGIN
  -- the passenger portal is the guardian's; company and platform staff are already limited by row security
  staff := sys.ctx_scope() IS DISTINCT FROM 'PASSENGER';
  IF NOT staff THEN
    IF NOT sch.is_guardian(NEW.student_id) THEN
      RAISE EXCEPTION 'NOT_GUARDIAN: only the pupil''s guardian answers for the pupil' USING ERRCODE = 'P0001';
    END IF;
    IF (to_jsonb(NEW) - 'guardian_consent' - 'consent_at' - 'consent_by_party_id')
       IS DISTINCT FROM (to_jsonb(OLD) - 'guardian_consent' - 'consent_at' - 'consent_by_party_id') THEN
      RAISE EXCEPTION 'GUARDIAN_CONSENT_ONLY: a guardian gives or refuses consent and changes nothing else' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.guardian_consent IN ('GIVEN','REFUSED') AND NEW.guardian_consent IS DISTINCT FROM OLD.guardian_consent THEN
    NEW.consent_at := now();
    NEW.consent_by_party_id := CASE WHEN staff THEN coalesce(NEW.consent_by_party_id, sys.ctx_party_id()) ELSE sys.ctx_party_id() END;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sch.tg_enrollment_guardian IS 'A guardian changes only the consent of an enrolment; the answer records who and when (1054)';
DROP TRIGGER IF EXISTS b_enrollment_guardian ON sch.enrollment;
CREATE TRIGGER b_enrollment_guardian BEFORE UPDATE ON sch.enrollment FOR EACH ROW EXECUTE FUNCTION sch.tg_enrollment_guardian();

CREATE OR REPLACE FUNCTION sch.tg_absence_notice_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e record;
BEGIN
  SELECT en.student_id, c.company_id INTO e FROM sch.enrollment en JOIN sch.contract c ON c.id = en.contract_id
   WHERE en.id = NEW.enrollment_id;
  IF sys.ctx_scope() = 'PASSENGER' AND NOT sch.is_guardian(e.student_id) THEN
    RAISE EXCEPTION 'NOT_GUARDIAN: only the pupil''s guardian or the operator reports an absence' USING ERRCODE = 'P0001';
  END IF;
  NEW.reported_by_party_id := coalesce(NEW.reported_by_party_id, sys.ctx_party_id());
  IF NEW.absent_on < (now() AT TIME ZONE 'Asia/Damascus')::date THEN
    RAISE EXCEPTION 'ABSENCE_IN_PAST: an absence is reported for today or a later day' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sch.tg_absence_notice_rules IS 'Absences: from the passenger portal only by a guardian of the pupil, for today or later (1054)';
DROP TRIGGER IF EXISTS absence_notice_rules ON sch.absence_notice;
CREATE TRIGGER absence_notice_rules BEFORE INSERT ON sch.absence_notice FOR EACH ROW EXECUTE FUNCTION sch.tg_absence_notice_rules();

CREATE OR REPLACE FUNCTION sch.tg_run_sweep() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.sweep_checked_at IS NOT NULL AND OLD.sweep_checked_at IS NULL THEN
    NEW.sweep_checked_by := coalesce(NEW.sweep_checked_by, sys.ctx_party_id());
  END IF;
  IF NEW.status = 'IN_PROGRESS' AND OLD.status = 'PLANNED' THEN
    NEW.started_at := coalesce(NEW.started_at, now());
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sch.tg_run_sweep IS 'Runs: starting stamps the time; the empty-bus check records who checked (1054)';
DROP TRIGGER IF EXISTS a_run_sweep ON sch.run;
CREATE TRIGGER a_run_sweep BEFORE UPDATE ON sch.run FOR EACH ROW EXECUTE FUNCTION sch.tg_run_sweep();

-- ------------------------------------------------------------------ f. blocklist and licence changes
-- The blocklist held entries that nothing read. Registration and sign-in now ask this function, which sees the list
-- whatever the caller's scope; the values are HMAC digests made by the API, never the phone, e-mail or device itself.
CREATE OR REPLACE FUNCTION sec.is_blocked(p_type text, p_hash bytea) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT p_hash IS NOT NULL AND EXISTS (SELECT 1 FROM sec.blocklist_entry
                                          WHERE entry_type = p_type AND value_hash = p_hash
                                            AND (expires_at IS NULL OR expires_at > now()))
$$;
COMMENT ON FUNCTION sec.is_blocked IS 'Whether a digest of a phone, e-mail, device or other identifier is on the active blocklist (1054)';
REVOKE ALL ON FUNCTION sec.is_blocked(text, bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.is_blocked(text, bytea) TO masslak_app;

-- A licence change is reviewed by one person and approved by another, neither of them the requester. The approver part
-- is the table's own check (license_change_request_check); this adds the reviewer and the order of the two steps
CREATE OR REPLACE FUNCTION fleet.tg_license_change_four_eyes() RETURNS trigger LANGUAGE plpgsql
  SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.reviewed_by IS NOT NULL AND NEW.reviewed_by = NEW.requested_by THEN
    RAISE EXCEPTION 'FOUR_EYES: the requester does not review the change' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'APPROVED' AND (NEW.reviewed_by IS NULL OR NEW.approved_by IS NULL) THEN
    RAISE EXCEPTION 'FOUR_EYES: a change is approved after its review' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION fleet.tg_license_change_four_eyes IS 'Licence changes: requester, reviewer and approver are three different people (1054)';
DROP TRIGGER IF EXISTS license_change_four_eyes ON fleet.license_change_request;
CREATE TRIGGER license_change_four_eyes BEFORE INSERT OR UPDATE ON fleet.license_change_request
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_license_change_four_eyes();

-- The finance controls screen shows how far the ledger is closed; the marker row is written by maintenance only
GRANT SELECT ON fin.ledger_close TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ g. two parties of one record (found by the isolation sweep)
-- A disruption belongs to the carrier of the trip; the partner company called in to rescue it reads it but does not
-- change it (before, the partner could also write the row, including handing it to a third company).
DROP POLICY IF EXISTS isolation ON ops.trip_disruption;
DROP POLICY IF EXISTS split_read ON ops.trip_disruption;
DROP POLICY IF EXISTS split_write ON ops.trip_disruption;
CREATE POLICY split_read ON ops.trip_disruption FOR SELECT
  USING (EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_disruption.trip_id AND sys.tenant_visible(x.company_id))
         OR sys.tenant_visible(partner_company_id));
CREATE POLICY split_write ON ops.trip_disruption FOR ALL
  USING (EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_disruption.trip_id AND sys.tenant_visible(x.company_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_disruption.trip_id AND sys.tenant_visible(x.company_id)));

-- Compensation to a passenger is decided by the platform: the parties of the booking read it, only the platform writes it
-- (before, a carrier or agency could change who bears it).
DROP POLICY IF EXISTS platform_writes ON sales.passenger_compensation;
DROP POLICY IF EXISTS platform_inserts ON sales.passenger_compensation;
DROP POLICY IF EXISTS platform_deletes ON sales.passenger_compensation;
CREATE POLICY platform_writes ON sales.passenger_compensation AS RESTRICTIVE FOR UPDATE
  USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
CREATE POLICY platform_inserts ON sales.passenger_compensation AS RESTRICTIVE FOR INSERT WITH CHECK (sys.ctx_is_platform());
CREATE POLICY platform_deletes ON sales.passenger_compensation AS RESTRICTIVE FOR DELETE USING (sys.ctx_is_platform());

-- ------------------------------------------------------------------ d. trips from templates
CREATE UNIQUE INDEX IF NOT EXISTS trip_template_departure_uniq ON ops.trip (template_id, departure_at) WHERE template_id IS NOT NULL;
COMMENT ON INDEX ops.trip_template_departure_uniq IS 'A template generates one trip per departure, so generating twice adds nothing (1054)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.36.0', 'Launch completeness: case service levels and claims under four eyes, rating rules, guardian answers, trips from templates'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.36.0');
