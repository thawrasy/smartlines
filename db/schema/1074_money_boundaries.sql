-- =====================================================================
-- 1074: money boundaries (review of release 1.47.0, package B, and the owner's decisions 4 and 5)
-- =====================================================================
-- a. A payment is recorded before the provider is called, and the call happens outside any transaction (R-16):
--    stage CREATED until the provider answers, PROVIDER_UNKNOWN when the answer never came (timeout, network); the
--    same merchant reference is sent again until the provider gives a definite answer.
-- b. A refund holds the money in the payer's wallet when it is asked for, is sent to the provider under a reference
--    fixed by the refund, and is posted only once the provider accepted it (R-17); an unknown outcome is retried with
--    the same reference.
-- c. Payment fees (decision 4): set by the platform per way of paying, currency and, if wanted, per customer, as a
--    percentage, a fixed amount, both or nothing (offers), within a period; paid by the customer unless the rule says
--    the platform bears it; rounded to a step and direction set on the rule (R-20). The fee is shown before paying,
--    asked from the provider on top of the amount, and posted to the platform's revenue.
-- d. The person who pays a withdrawal out is neither its requester nor one of its approvers (R-22).
-- e. An approval matrix (decision 5): for each kind of money decision, the number of levels, who may decide at each
--    level (holders of a permission, or named people), from which amount a level applies. A credit from a bank
--    statement (R-23) and a refund to the source wait for it; one person decides at most one level, never their own
--    request.

-- ------------------------------------------------------------------ c. fee rules (first: payments refer to them)
CREATE TABLE IF NOT EXISTS fin.fee_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  label         text NOT NULL CHECK (length(btrim(label)) BETWEEN 3 AND 120),
  provider_id   bigint REFERENCES fin.payment_provider(id),          -- NULL: every way of paying
  currency      char(3) REFERENCES ref.currency(code),                -- NULL: every currency (percentage only)
  party_id      bigint REFERENCES iam.party(id),                      -- NULL: every customer; else one passenger or company
  kind          text NOT NULL CHECK (kind IN ('PERCENT','FIXED','PERCENT_PLUS_FIXED','NONE')),
  pct           numeric(6,3) NOT NULL DEFAULT 0 CHECK (pct >= 0 AND pct <= 20),
  fixed_amount  bigint NOT NULL DEFAULT 0 CHECK (fixed_amount >= 0),
  min_fee       bigint CHECK (min_fee >= 0),
  max_fee       bigint CHECK (max_fee >= 0),
  round_to      bigint NOT NULL DEFAULT 1 CHECK (round_to >= 1),      -- in minor units: 100 rounds to whole pounds
  rounding      text NOT NULL DEFAULT 'HALF_UP' CHECK (rounding IN ('HALF_UP','UP','DOWN')),
  borne_by      text NOT NULL DEFAULT 'PAYER' CHECK (borne_by IN ('PAYER','PLATFORM')),
  valid_from    timestamptz NOT NULL DEFAULT now(),
  valid_to      timestamptz,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    bigint REFERENCES iam.app_user(id),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CHECK (max_fee IS NULL OR min_fee IS NULL OR max_fee >= min_fee),
  CHECK (kind <> 'NONE' OR (pct = 0 AND fixed_amount = 0)),
  CHECK (kind <> 'PERCENT' OR fixed_amount = 0),
  CHECK (kind <> 'FIXED' OR pct = 0),
  -- an amount (fixed part, floor, cap, rounding step) means something only in one currency
  CHECK (currency IS NOT NULL OR (fixed_amount = 0 AND min_fee IS NULL AND max_fee IS NULL AND round_to = 1))
);
COMMENT ON TABLE fin.fee_rule IS 'Payment fees set by the platform per way of paying, currency and customer, with a period; the most specific rule in force applies (1074, decision 4)';
COMMENT ON COLUMN fin.fee_rule.borne_by IS 'PAYER: added to what the customer pays (the default); PLATFORM: the platform absorbs it (offers), the customer pays nothing';
COMMENT ON COLUMN fin.fee_rule.round_to IS 'Rounding step in the currency''s minor units, applied in the direction of rounding';
CREATE INDEX IF NOT EXISTS fee_rule_lookup_idx ON fin.fee_rule (currency, provider_id, party_id) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS fee_rule_provider_id_fkx ON fin.fee_rule (provider_id);
CREATE INDEX IF NOT EXISTS fee_rule_party_id_fkx ON fin.fee_rule (party_id);
SELECT sys.rls_platform('fin.fee_rule');
GRANT SELECT, INSERT, UPDATE ON fin.fee_rule TO masslak_app;
GRANT SELECT ON fin.fee_rule TO masslak_readonly, masslak_auditor;

-- The fee for one payment: the most specific rule in force (the customer's own, then the way of paying, then the
-- currency, then the newest), its amount rounded as the rule says. SECURITY DEFINER: a passenger is shown the fee
-- before paying without reading the rules.
CREATE OR REPLACE FUNCTION fin.payment_fee(p_provider bigint, p_currency char(3), p_amount bigint, p_party bigint,
                                           p_at timestamptz DEFAULT now())
RETURNS TABLE (fee bigint, absorbed bigint, rule_id bigint, label text, kind text, pct numeric, fixed_amount bigint, borne_by text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r fin.fee_rule; raw numeric; amt bigint;
BEGIN
  SELECT * INTO r FROM fin.fee_rule f
   WHERE f.status = 'ACTIVE' AND f.valid_from <= p_at AND (f.valid_to IS NULL OR f.valid_to > p_at)
     AND (f.currency IS NULL OR f.currency = p_currency)
     AND (f.provider_id IS NULL OR f.provider_id = p_provider)
     AND (f.party_id IS NULL OR f.party_id = p_party
          OR f.party_id IN (SELECT m.company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id
                             WHERE u.party_id = p_party AND m.status = 'ACTIVE'))
   ORDER BY (f.party_id IS NOT NULL) DESC, (f.provider_id IS NOT NULL) DESC, (f.currency IS NOT NULL) DESC, f.valid_from DESC, f.id DESC
   LIMIT 1;
  IF r.id IS NULL THEN
    RETURN QUERY SELECT 0::bigint, 0::bigint, NULL::bigint, NULL::text, 'NONE'::text, 0::numeric, 0::bigint, 'PAYER'::text;
    RETURN;
  END IF;
  raw := p_amount * r.pct / 100 + r.fixed_amount;
  IF r.min_fee IS NOT NULL AND r.kind <> 'NONE' THEN raw := greatest(raw, r.min_fee); END IF;
  IF r.max_fee IS NOT NULL THEN raw := least(raw, r.max_fee); END IF;
  amt := (CASE r.rounding WHEN 'UP' THEN ceil(raw / r.round_to) WHEN 'DOWN' THEN floor(raw / r.round_to)
                          ELSE round(raw / r.round_to) END * r.round_to)::bigint;
  RETURN QUERY SELECT CASE WHEN r.borne_by = 'PAYER' THEN amt ELSE 0 END, CASE WHEN r.borne_by = 'PLATFORM' THEN amt ELSE 0 END,
                      r.id, r.label, r.kind, r.pct, r.fixed_amount, r.borne_by;
END $$;
COMMENT ON FUNCTION fin.payment_fee IS 'The fee of one payment under the rule in force, rounded as the rule says (1074, decision 4)';
REVOKE EXECUTE ON FUNCTION fin.payment_fee(bigint, char, bigint, bigint, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.payment_fee(bigint, char, bigint, bigint, timestamptz) TO masslak_app, masslak_readonly;

-- What each provider's old fee setting meant becomes a rule of that provider, in every currency
INSERT INTO fin.fee_rule (label, provider_id, kind, pct, borne_by)
SELECT 'Default fee of ' || p.name, p.id, 'PERCENT', round((p.fee_policy ->> 'pct')::numeric, 3),
       CASE WHEN p.fee_policy ->> 'borne_by' = 'PAYER' THEN 'PAYER' ELSE 'PLATFORM' END
  FROM fin.payment_provider p
 WHERE coalesce((p.fee_policy ->> 'pct')::numeric, 0) > 0
   AND NOT EXISTS (SELECT 1 FROM fin.fee_rule f WHERE f.provider_id = p.id AND f.party_id IS NULL AND f.currency IS NULL);

-- ------------------------------------------------------------------ a. payments
ALTER TABLE fin.payment DROP CONSTRAINT IF EXISTS payment_stage_check;
ALTER TABLE fin.payment ADD CONSTRAINT payment_stage_check CHECK (stage IN (
  'CREATED','PROVIDER_UNKNOWN','REDIRECTED','OTP_SENT','AWAITING_TRANSFER','CONFIRMED','FAILED','CANCELLED','EXPIRED','REFUNDED'));
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS provider_attempts smallint NOT NULL DEFAULT 0;
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS provider_checked_at timestamptz;
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS fee_absorbed bigint NOT NULL DEFAULT 0;
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS fee_rule_id bigint REFERENCES fin.fee_rule(id);
CREATE INDEX IF NOT EXISTS payment_fee_rule_id_fkx ON fin.payment (fee_rule_id);
CREATE INDEX IF NOT EXISTS payment_provider_unknown_idx ON fin.payment (provider_checked_at) WHERE stage = 'PROVIDER_UNKNOWN';
DO $$ BEGIN
  ALTER TABLE fin.payment ADD CONSTRAINT payment_fee_check CHECK (fee >= 0 AND fee_absorbed >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fin.payment.fee IS 'Fee the payer pays on top of the amount, asked from the provider with it and posted to platform revenue (1074)';
COMMENT ON COLUMN fin.payment.fee_absorbed IS 'Fee the platform bears under an offer or policy; the payer pays the amount only (1074)';
COMMENT ON COLUMN fin.payment.stage IS 'CREATED: recorded, provider not yet answered; PROVIDER_UNKNOWN: the answer never came, asked again with the same reference (1074)';
COMMENT ON COLUMN fin.payment.provider_attempts IS 'Calls made to the provider to start this payment, all with the same merchant reference (1074, R-16)';

-- ------------------------------------------------------------------ b. refunds
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS stage text NOT NULL DEFAULT 'DONE';
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS attempts smallint NOT NULL DEFAULT 0;
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz;
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS last_error text;
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS provider_reference text;
ALTER TABLE fin.payment_refund ADD COLUMN IF NOT EXISTS held boolean NOT NULL DEFAULT false;
ALTER TABLE fin.payment_refund ALTER COLUMN stage SET DEFAULT 'REQUESTED';
DO $$ BEGIN
  ALTER TABLE fin.payment_refund ADD CONSTRAINT payment_refund_stage_check
    CHECK (stage IN ('REQUESTED','AWAITING_APPROVAL','SENDING','UNKNOWN','DONE','REFUSED','REJECTED'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fin.payment_refund ADD CONSTRAINT payment_refund_stage_status CHECK (
    (status = 'SUCCESS') = (stage = 'DONE') AND (status = 'FAILED') = (stage IN ('REFUSED','REJECTED')));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fin.payment_refund ADD CONSTRAINT payment_refund_last_error_check CHECK (last_error IS NULL OR length(last_error) <= 500);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS payment_refund_due_idx ON fin.payment_refund (next_attempt_at) WHERE stage IN ('SENDING','UNKNOWN');
CREATE UNIQUE INDEX IF NOT EXISTS payment_refund_provider_reference_uq ON fin.payment_refund (provider_reference);
COMMENT ON COLUMN fin.payment_refund.stage IS 'REQUESTED, AWAITING_APPROVAL, SENDING (provider called), UNKNOWN (answer lost, sent again with the same reference), DONE, REFUSED by the provider, REJECTED by an approver (1074, R-17)';
COMMENT ON COLUMN fin.payment_refund.provider_reference IS 'Reference sent to the provider, fixed when the refund is asked: a repeated call is the same refund';
COMMENT ON COLUMN fin.payment_refund.held IS 'The amount is held in the payer''s wallet until the refund is posted or abandoned';

-- the same refund is never posted twice, a posted one never changes, and money held is released when it ends
CREATE OR REPLACE FUNCTION fin.tg_payment_refund_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'PENDING' THEN
      RAISE EXCEPTION 'IMMUTABLE_RECORD: refund % is final (%)', OLD.id, OLD.status USING ERRCODE = 'P0001';
    END IF;
    IF NEW.amount <> OLD.amount OR NEW.payment_id <> OLD.payment_id
       OR NEW.provider_reference IS DISTINCT FROM OLD.provider_reference AND OLD.provider_reference IS NOT NULL THEN
      RAISE EXCEPTION 'IMMUTABLE_RECORD: a refund keeps its amount, payment and provider reference' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status <> 'PENDING' AND NEW.held THEN
      RAISE EXCEPTION 'REFUND_HOLD: release the held amount when a refund ends' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_payment_refund_rules ON fin.payment_refund;
CREATE TRIGGER a_payment_refund_rules BEFORE UPDATE ON fin.payment_refund FOR EACH ROW EXECUTE FUNCTION fin.tg_payment_refund_rules();

-- ------------------------------------------------------------------ d. withdrawals
DO $$ BEGIN
  ALTER TABLE fin.withdrawal_request ADD CONSTRAINT withdrawal_paid_by_not_approver
    CHECK (paid_by IS NULL OR (paid_by IS DISTINCT FROM approved_by AND paid_by IS DISTINCT FROM second_approver)) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON CONSTRAINT withdrawal_paid_by_not_approver ON fin.withdrawal_request IS
  'The person who pays a withdrawal out did not approve it (1074, R-22); rows paid before 1074 are not re-checked';

-- ------------------------------------------------------------------ e. the approval matrix
CREATE TABLE IF NOT EXISTS fin.approval_policy (
  action       text PRIMARY KEY CHECK (action IN ('BANK_CREDIT','REFUND')),
  levels       smallint NOT NULL CHECK (levels BETWEEN 0 AND 5),
  description  text NOT NULL,
  updated_by   bigint REFERENCES iam.app_user(id),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fin.approval_policy IS 'How many approval levels a kind of money decision needs (0: none) (1074, decision 5)';
SELECT sys.rls_platform('fin.approval_policy');
GRANT SELECT, INSERT, UPDATE ON fin.approval_policy TO masslak_app;
GRANT SELECT ON fin.approval_policy TO masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS fin.approval_level (
  action           text NOT NULL REFERENCES fin.approval_policy(action),
  level_no         smallint NOT NULL CHECK (level_no BETWEEN 1 AND 5),
  name             text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 80),
  permission_code  text NOT NULL REFERENCES iam.permission(code),
  min_amount       bigint NOT NULL DEFAULT 0 CHECK (min_amount >= 0),
  PRIMARY KEY (action, level_no)
);
COMMENT ON TABLE fin.approval_level IS 'One level of an approval: who decides (holders of the permission, or the named members only) and from which amount it applies (1074)';
COMMENT ON COLUMN fin.approval_level.min_amount IS 'The level is needed for requests of at least this amount (minor units of the request); 0: always';
CREATE INDEX IF NOT EXISTS approval_level_permission_code_fkx ON fin.approval_level (permission_code);
SELECT sys.rls_platform('fin.approval_level');
GRANT SELECT, INSERT, UPDATE, DELETE ON fin.approval_level TO masslak_app;
GRANT SELECT ON fin.approval_level TO masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS fin.approval_level_member (
  action    text NOT NULL,
  level_no  smallint NOT NULL,
  user_id   bigint NOT NULL REFERENCES iam.app_user(id),
  PRIMARY KEY (action, level_no, user_id),
  FOREIGN KEY (action, level_no) REFERENCES fin.approval_level (action, level_no) ON DELETE CASCADE
);
COMMENT ON TABLE fin.approval_level_member IS 'The named people who decide at a level; a level without members is decided by any holder of its permission (1074)';
CREATE INDEX IF NOT EXISTS approval_level_member_user_id_fkx ON fin.approval_level_member (user_id);
SELECT sys.rls_platform('fin.approval_level_member');
GRANT SELECT, INSERT, DELETE ON fin.approval_level_member TO masslak_app;
GRANT SELECT ON fin.approval_level_member TO masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS fin.approval_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  action          text NOT NULL REFERENCES fin.approval_policy(action),
  object_type     text NOT NULL CHECK (object_type IN ('bank_statement_line','payment_refund')),
  object_id       bigint NOT NULL,
  amount          bigint NOT NULL CHECK (amount > 0),
  currency        char(3) NOT NULL REFERENCES ref.currency(code),
  summary         text NOT NULL CHECK (length(summary) <= 300),
  required_levels smallint[] NOT NULL CHECK (cardinality(required_levels) BETWEEN 1 AND 5),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  decided_at      timestamptz,
  CHECK ((status = 'PENDING') = (decided_at IS NULL))
);
COMMENT ON TABLE fin.approval_request IS 'A money decision waiting for its levels, frozen when asked: the levels its amount needs at that moment (1074)';
COMMENT ON COLUMN fin.approval_request.object_id IS 'Polymorphic: the money decision held back (object_type): a bank statement line or a refund';
CREATE UNIQUE INDEX IF NOT EXISTS approval_request_open_uq ON fin.approval_request (object_type, object_id) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS approval_request_pending_idx ON fin.approval_request (created_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS approval_request_action_fkx ON fin.approval_request (action);
CREATE INDEX IF NOT EXISTS approval_request_currency_fkx ON fin.approval_request (currency);
CREATE INDEX IF NOT EXISTS approval_request_object_idx ON fin.approval_request (object_type, object_id);
SELECT sys.rls_platform('fin.approval_request');
GRANT SELECT, INSERT, UPDATE ON fin.approval_request TO masslak_app;
GRANT SELECT ON fin.approval_request TO masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS fin.approval_decision (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id  bigint NOT NULL REFERENCES fin.approval_request(id),
  level_no    smallint NOT NULL,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  decision    text NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  note        text CHECK (note IS NULL OR length(note) <= 300),
  decided_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, level_no),
  UNIQUE (request_id, user_id),
  CHECK (decision = 'APPROVE' OR length(btrim(coalesce(note, ''))) >= 3)
);
COMMENT ON TABLE fin.approval_decision IS 'One person''s decision at one level of a request; one person decides one level at most, never their own request (1074)';
CREATE INDEX IF NOT EXISTS approval_decision_user_id_fkx ON fin.approval_decision (user_id);
SELECT sys.rls_platform('fin.approval_decision');
GRANT SELECT, INSERT ON fin.approval_decision TO masslak_app;
GRANT SELECT ON fin.approval_decision TO masslak_readonly, masslak_auditor;
CREATE TRIGGER approval_decision_immutable BEFORE UPDATE OR DELETE ON fin.approval_decision
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- whoever decides: the next level of a pending request, not its requester, holding the level's permission and, when the
-- level names people, one of them; the last approval approves the request, a rejection rejects it
CREATE OR REPLACE FUNCTION fin.tg_approval_decision() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE rq fin.approval_request; lv fin.approval_level; next_level smallint; done int;
BEGIN
  SELECT * INTO rq FROM fin.approval_request WHERE id = NEW.request_id FOR UPDATE;
  IF rq.status <> 'PENDING' THEN
    RAISE EXCEPTION 'APPROVAL_FINAL: this request is already %', lower(rq.status) USING ERRCODE = 'P0001';
  END IF;
  IF NEW.user_id = rq.requested_by THEN
    RAISE EXCEPTION 'FOUR_EYES: the person who asked does not decide' USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO done FROM fin.approval_decision WHERE request_id = rq.id;
  next_level := rq.required_levels[done + 1];
  IF NEW.level_no IS DISTINCT FROM next_level THEN
    RAISE EXCEPTION 'APPROVAL_LEVEL: level % decides next, not %', next_level, NEW.level_no USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO lv FROM fin.approval_level WHERE action = rq.action AND level_no = NEW.level_no;
  IF lv.action IS NULL THEN
    RAISE EXCEPTION 'APPROVAL_LEVEL: level % no longer exists; the policy changed after the request', NEW.level_no USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM iam.user_role ur JOIN iam.role_permission rp ON rp.role_id = ur.role_id
                  WHERE ur.user_id = NEW.user_id AND rp.permission_code = lv.permission_code
                    AND (ur.valid_to IS NULL OR ur.valid_to > now())) THEN
    RAISE EXCEPTION 'APPROVAL_NOT_ALLOWED: deciding at "%" needs %', lv.name, lv.permission_code USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM fin.approval_level_member m WHERE m.action = lv.action AND m.level_no = lv.level_no)
     AND NOT EXISTS (SELECT 1 FROM fin.approval_level_member m WHERE m.action = lv.action AND m.level_no = lv.level_no
                       AND m.user_id = NEW.user_id) THEN
    RAISE EXCEPTION 'APPROVAL_NOT_ALLOWED: only the people named for "%" decide at it', lv.name USING ERRCODE = 'P0001';
  END IF;
  IF NEW.decision = 'REJECT' THEN
    UPDATE fin.approval_request SET status = 'REJECTED', decided_at = now() WHERE id = rq.id;
  ELSIF done + 1 = cardinality(rq.required_levels) THEN
    UPDATE fin.approval_request SET status = 'APPROVED', decided_at = now() WHERE id = rq.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER a_approval_decision BEFORE INSERT ON fin.approval_decision FOR EACH ROW EXECUTE FUNCTION fin.tg_approval_decision();

-- a decided request does not change; a pending one changes only by its decisions (or is cancelled)
CREATE OR REPLACE FUNCTION fin.tg_approval_request_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'PENDING' THEN
    RAISE EXCEPTION 'APPROVAL_FINAL: a decided request does not change' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.amount <> OLD.amount OR NEW.object_id <> OLD.object_id OR NEW.object_type <> OLD.object_type
     OR NEW.required_levels <> OLD.required_levels OR NEW.requested_by <> OLD.requested_by THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: a request keeps what it asks and the levels it needs' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER a_approval_request_rules BEFORE UPDATE ON fin.approval_request FOR EACH ROW EXECUTE FUNCTION fin.tg_approval_request_rules();
CREATE TRIGGER approval_request_no_delete BEFORE DELETE ON fin.approval_request FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- the levels a request of this amount needs under the policy in force
CREATE OR REPLACE FUNCTION fin.approval_levels(p_action text, p_amount bigint) RETURNS smallint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(array_agg(l.level_no ORDER BY l.level_no), '{}'::smallint[])
    FROM fin.approval_level l JOIN fin.approval_policy p ON p.action = l.action
   WHERE l.action = p_action AND l.level_no <= p.levels AND l.min_amount <= p_amount
$$;
COMMENT ON FUNCTION fin.approval_levels IS 'The approval levels a request of this amount needs now; empty: none (1074)';
REVOKE EXECUTE ON FUNCTION fin.approval_levels(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.approval_levels(text, bigint) TO masslak_app;

INSERT INTO sys.polymorphic_reference (table_name, type_col, id_col, kind, targets, owner, reason) VALUES
  ('fin.approval_request', 'object_type', 'object_id', 'BUSINESS',
   '{"bank_statement_line":"fin.bank_statement_line","payment_refund":"fin.payment_refund"}', 'fin',
   'An approval names the money decision it holds back; the decision row exists before its request')
ON CONFLICT DO NOTHING;

-- the defaults: a bank statement credit needs one reviewer other than the importer; a refund none (as before)
INSERT INTO fin.approval_policy (action, levels, description) VALUES
  ('BANK_CREDIT', 1, 'Crediting a wallet from a line of an imported bank statement'),
  ('REFUND', 0, 'Sending a payment back to the card, e-wallet, instalment or financing provider it came from')
ON CONFLICT (action) DO NOTHING;
INSERT INTO fin.approval_level (action, level_no, name, permission_code) VALUES
  ('BANK_CREDIT', 1, 'Finance review', 'ledger.reconcile'),
  ('REFUND', 1, 'Finance review', 'compensation.pay')
ON CONFLICT DO NOTHING;

-- statement lines matched by the import or by hand wait for their approval before the wallet is credited
ALTER TABLE fin.bank_statement_line DROP CONSTRAINT IF EXISTS bank_statement_line_status_check;
ALTER TABLE fin.bank_statement_line ADD CONSTRAINT bank_statement_line_status_check
  CHECK (status IN ('UNMATCHED','PROPOSED','MATCHED','IGNORED'));
DO $$ DECLARE c text; BEGIN
  SELECT conname INTO c FROM pg_constraint WHERE conrelid = 'fin.bank_statement_line'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%topup_id IS NOT NULL%' AND conname <> 'bank_statement_line_topup_matches';
  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE fin.bank_statement_line DROP CONSTRAINT %I', c); END IF;
END $$;
DO $$ BEGIN
  ALTER TABLE fin.bank_statement_line ADD CONSTRAINT bank_statement_line_topup_matches
    CHECK ((status IN ('PROPOSED','MATCHED')) = (topup_id IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE UNIQUE INDEX IF NOT EXISTS bank_statement_line_topup_once_uq ON fin.bank_statement_line (topup_id)
  WHERE status IN ('PROPOSED','MATCHED');
ALTER TABLE fin.bank_statement_line ADD COLUMN IF NOT EXISTS proposed_by bigint REFERENCES iam.app_user(id);
CREATE INDEX IF NOT EXISTS bank_statement_line_proposed_by_fkx ON fin.bank_statement_line (proposed_by);
ALTER TABLE fin.bank_statement_line ADD COLUMN IF NOT EXISTS credit_received boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN fin.bank_statement_line.status IS 'UNMATCHED; PROPOSED (matched, waiting for the approval matrix); MATCHED (credited); IGNORED (1074)';
COMMENT ON COLUMN fin.bank_statement_line.credit_received IS 'Matched by hand with an amount other than the transfer''s: the amount that arrived is credited (1074)';

-- a policy's levels and named people are replaced as a whole when it changes (app/modules/payments/approvals.py)
INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  ('fin.approval_level', 'levels above the new count are removed when an approval policy is changed'),
  ('fin.approval_level_member', 'the named people of a level are replaced when an approval policy is changed')
ON CONFLICT (table_name) DO NOTHING;
SELECT sys.enforce_app_delete_grants();

-- ------------------------------------------------------------------ permissions
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('approval.policy', 'fin', 'PLATFORM', 'Set the approval matrix of money decisions: levels, who decides and from which amount', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'approval.policy' FROM iam.role r WHERE r.code = 'PLATFORM_ADMIN' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ figures for the metrics endpoint and alerts
CREATE OR REPLACE FUNCTION fin.money_boundary_metrics() RETURNS TABLE (metric text, labels jsonb, value float8)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_refunds_waiting_provider'::text, '{}'::jsonb, count(*)::float8 FROM fin.payment_refund
   WHERE stage IN ('SENDING', 'UNKNOWN') AND created_at < now() - interval '30 minutes'
  UNION ALL
  SELECT 'masslak_payments_provider_unknown', '{}'::jsonb, count(*)::float8 FROM fin.payment
   WHERE stage = 'PROVIDER_UNKNOWN' AND status = 'PENDING'
  UNION ALL
  SELECT 'masslak_approvals_pending', jsonb_build_object('action', p.action), count(r.id)::float8
    FROM fin.approval_policy p LEFT JOIN fin.approval_request r ON r.action = p.action AND r.status = 'PENDING' GROUP BY p.action
  UNION ALL
  SELECT 'masslak_approvals_oldest_pending_seconds', '{}'::jsonb,
         coalesce(extract(epoch FROM now() - min(created_at)), 0)::float8 FROM fin.approval_request WHERE status = 'PENDING'
  UNION ALL
  SELECT 'masslak_payment_unsigned_notices_last_hour', jsonb_build_object('provider', provider_code), notices::float8
    FROM fin.unsigned_notices()
$$;
COMMENT ON FUNCTION fin.money_boundary_metrics() IS 'Refunds and payments waiting on a provider, approvals waiting, unsigned notices (1074), for the metrics endpoint';
REVOKE EXECUTE ON FUNCTION fin.money_boundary_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.money_boundary_metrics() TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('fin.fee_rule', '1A', 'E16'), ('fin.approval_policy', '1B', 'E16'), ('fin.approval_level', '1B', 'E16'),
  ('fin.approval_level_member', '1B', 'E16'), ('fin.approval_request', '1B', 'E16'), ('fin.approval_decision', '1B', 'E16')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('fin.fee_rule', 'INTERNAL', 'fin', 'Payment fees the platform charges or bears, per way of paying, currency and customer', 'Contract', 3650, 'KEEP_LEGAL', '{replica,backup}', 35),
  ('fin.approval_request', 'CONFIDENTIAL', 'fin', 'Money decisions held for approval and who decided them at each level', 'Accounting law', 3650, 'KEEP_LEGAL', '{replica,backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

SELECT sys.refresh_table_class();
