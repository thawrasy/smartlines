-- 1171: stations and companies are edited in place, every edit kept (owner's note, 25 October 2026; second part of
-- 1170). The platform could add a station, a carrier, an agency or a station operating company, and change a station's
-- place or a company's status, but not correct a name, an address, a position or a licence. They now are, with the
-- same trigger as 1170 (sys.tg_edit_history) keeping each table's history:
--   * net.station_change: a station's name, address and position (regulated: a reason, since tickets and boards show
--     them), its contacts, hours of lead, licence and its status and place.
--   * iam.company_change: a company's registration and licence numbers and their dates, its status and its legal
--     name. The name lives on the company's party; the party's trigger fires for companies only and writes into the
--     company's history (a person's names are not kept in such a history: 1170).

-- ------------------------------------------------------------------ stations
ALTER TABLE net.station ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN net.station.change_reason IS 'Given with an edit and moved into net.station_change by the trigger (1171)';

CREATE TABLE IF NOT EXISTS net.station_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id  bigint NOT NULL REFERENCES net.station(id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE net.station_change IS 'Every edit of a station, field by field, with who, when and why (1171); never updated or deleted';
CREATE INDEX IF NOT EXISTS station_change_station ON net.station_change (station_id, changed_at);
CREATE INDEX IF NOT EXISTS station_change_user ON net.station_change (changed_by);

DROP TRIGGER IF EXISTS station_edit_history ON net.station;
CREATE TRIGGER station_edit_history BEFORE UPDATE ON net.station FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'net.station_change', 'station_id', 'id',
  'name,address,lat,lng,phone,email,operator_name,license_no,license_authority,license_expiry,lead_min,status,place_id',
  'name,lat,lng', 'STATION');
DROP TRIGGER IF EXISTS station_change_append_only ON net.station_change;
CREATE TRIGGER station_change_append_only BEFORE UPDATE OR DELETE ON net.station_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();

-- ------------------------------------------------------------------ companies
ALTER TABLE iam.company ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN iam.company.change_reason IS 'Given with an edit and moved into iam.company_change by the trigger (1171)';
ALTER TABLE iam.party ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN iam.party.change_reason IS 'Given with a correction of a company''s legal name and moved into iam.company_change (1171)';

CREATE TABLE IF NOT EXISTS iam.company_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE iam.company_change IS 'Every edit of a company and of its legal name, field by field, with who, when and why (1171); never updated or deleted';
CREATE INDEX IF NOT EXISTS company_change_company ON iam.company_change (company_id, changed_at);
CREATE INDEX IF NOT EXISTS company_change_user ON iam.company_change (changed_by);

DROP TRIGGER IF EXISTS company_edit_history ON iam.company;
CREATE TRIGGER company_edit_history BEFORE UPDATE ON iam.company FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'iam.company_change', 'company_id', 'id',
  'cr_no,cr_expiry,transport_license_no,regulator_code,settlement_cycle,approval_status',
  'cr_no,transport_license_no', 'COMPANY');
-- the legal name of a company is on its party; a company's row in iam.company has the same id
DROP TRIGGER IF EXISTS company_name_history ON iam.party;
CREATE TRIGGER company_name_history BEFORE UPDATE ON iam.party FOR EACH ROW
  WHEN (OLD.party_type = 'COMPANY')
  EXECUTE FUNCTION sys.tg_edit_history('iam.company_change', 'company_id', 'id', 'legal_name,name_latin', 'legal_name', 'COMPANY');
DROP TRIGGER IF EXISTS company_change_append_only ON iam.company_change;
CREATE TRIGGER company_change_append_only BEFORE UPDATE OR DELETE ON iam.company_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();

SELECT sys.rls_parent('net.station_change', 'station_id', 'net.station');
SELECT sys.rls_parent('iam.company_change', 'company_id', 'iam.company');
GRANT SELECT, INSERT ON net.station_change, iam.company_change TO masslak_app;
GRANT SELECT ON net.station_change, iam.company_change TO masslak_readonly, masslak_auditor;
GRANT UPDATE (change_reason) ON net.station, iam.company, iam.party TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module)
SELECT t, '1A', (SELECT module FROM sys.table_phase WHERE table_name = parent)
  FROM (VALUES ('net.station_change', 'net.station'), ('iam.company_change', 'iam.company')) v(t, parent)
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.station_change', 'net records', 'the history of every edit of a station (1171)'),
  ('iam.company_change', 'iam records', 'the history of every edit of a company and its legal name (1171)')
ON CONFLICT (table_name) DO NOTHING;
