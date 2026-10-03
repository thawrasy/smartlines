import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";

interface Overview { carriers: number; carriers_pending: number; passengers: number; active_trips: number; bookings: number; gmv: number; stations: number }
interface Company { uid: string; legal_name: string; company_type: string; approval_status: string; created_at: string; code3: string | null; vehicles: number; trips: number }
interface AdminStation { uid: string; code: string; name: string; station_class: string; status: string; city_code: string; lat: number; lng: number; owner_name: string | null }

export function AdminOverview() {
  const { t, num, money } = useI18n();
  const state = useLoad(() => api.get<Overview>("/api/admin/overview"));
  return (
    <div className="stack">
      <PageHead title={t("admin.overview")} />
      <Loaded state={state}>{(o) => (
        <div className="grid cols-4">
          <Stat icon="apartment" label={t("admin.carriers")} value={num(o.carriers)} />
          <Stat icon="history" label={t("admin.pending")} value={num(o.carriers_pending)} tone="wheat" />
          <Stat icon="group" label={t("admin.passengers")} value={num(o.passengers)} tone="blue" />
          <Stat icon="directions_bus" label={t("admin.activeTrips")} value={num(o.active_trips)} />
          <Stat icon="confirmation_number" label={t("admin.bookings")} value={num(o.bookings)} tone="blue" />
          <Stat icon="payments" label={t("admin.gmv")} value={money(o.gmv)} tone="wheat" />
          <Stat icon="location_on" label={t("admin.stationsCount")} value={num(o.stations)} />
        </div>
      )}</Loaded>
    </div>
  );
}

export function AdminCompanies() {
  const { t, date } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ companies: Company[] }>("/api/admin/companies"));
  const [open, setOpen] = useState(false);
  const blank = { legal_name: "", code3: "", transport_license_no: "", owner_name: "", owner_email: "", owner_password: "" };
  const [f, setF] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [statusFor, setStatusFor] = useState<{ uid: string; status: string } | null>(null);
  const [reason, setReason] = useState("");
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: k === "code3" ? e.target.value.toUpperCase() : e.target.value });

  const onboard = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/admin/companies", { ...f, transport_license_no: f.transport_license_no || null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const changeStatus = async () => {
    if (!statusFor) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/admin/companies/${statusFor.uid}/status`, { status: statusFor.status, reason });
      setStatusFor(null); setReason(""); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className="stack">
      <PageHead title={t("admin.companies")}>
        {can("company.approve") && <button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("admin.onboard")}</button>}
      </PageHead>
      <ErrorBox error={!open && !statusFor ? error : null} />
      <Loaded state={state}>{({ companies }) => companies.length === 0 ? <div className="card"><Empty icon="apartment" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("admin.legalName")}</th><th>{t("common.code")}</th><th>{t("admin.vehiclesCount")}</th><th>{t("admin.tripsCount")}</th><th>{t("admin.created")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{companies.map((c) => (
            <tr key={c.uid}>
              <td style={{ fontWeight: 500 }}>{c.legal_name}</td><td className="mono">{c.code3}</td><td className="num">{c.vehicles}</td><td className="num">{c.trips}</td>
              <td>{date(c.created_at, { year: "numeric" })}</td><td><Status value={c.approval_status} /></td>
              <td>{can("company.approve") && <div className="row nowrap" style={{ gap: 4 }}>
                {c.approval_status !== "APPROVED" && <button className="btn tonal small" onClick={() => setStatusFor({ uid: c.uid, status: "APPROVED" })}>{t("admin.approve")}</button>}
                {c.approval_status === "APPROVED" && <button className="btn danger small" onClick={() => setStatusFor({ uid: c.uid, status: "SUSPENDED" })}>{t("admin.suspend")}</button>}
              </div>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("admin.onboard")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={onboard}>{t("common.create")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("admin.legalName")}><input className="input" value={f.legal_name} onChange={set("legal_name")} /></Field>
            <div className="grid cols-2">
              <Field label={t("admin.code3")}><input className="input ltr mono" maxLength={3} value={f.code3} onChange={set("code3")} /></Field>
              <Field label={`${t("admin.license")} (${t("common.optional")})`}><input className="input ltr" value={f.transport_license_no} onChange={set("transport_license_no")} /></Field>
              <Field label={t("admin.ownerName")}><input className="input" value={f.owner_name} onChange={set("owner_name")} /></Field>
              <Field label={t("admin.ownerEmail")}><input className="input ltr" type="email" value={f.owner_email} onChange={set("owner_email")} /></Field>
            </div>
            <Field label={t("admin.ownerPassword")} hint={t("auth.passwordHint")}><input className="input ltr" type="password" value={f.owner_password} onChange={set("owner_password")} /></Field>
          </div>
        </Modal>
      )}
      {statusFor && (
        <Modal title={t("admin.changeStatus")} onClose={() => setStatusFor(null)}
               actions={<><button className="btn text" onClick={() => setStatusFor(null)}>{t("common.cancel")}</button><button className="btn" disabled={busy || reason.trim().length < 3} onClick={changeStatus}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Status value={statusFor.status} />
            <Field label={t("common.reason")}><textarea className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

export function AdminStations() {
  const { t, station, city } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ stations: AdminStation[] }>("/api/admin/stations"));
  const [open, setOpen] = useState(false);
  const blank = { city_code: "DAM", number: "2", name: "", address: "", lat: "", lng: "" };
  const [f, setF] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const cities = ["ALP", "DAM", "DRA", "DRZ", "HMA", "HMS", "HSK", "IDL", "LTK", "QNT", "RDM", "RQA", "SWD", "TRT"];
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/admin/stations", { ...f, number: Number(f.number), lat: Number(f.lat), lng: Number(f.lng), address: f.address || null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("admin.stations")}>
        {can("station.approve") && <button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("admin.newStation")}</button>}
      </PageHead>
      <Loaded state={state}>{({ stations }) => (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("common.code")}</th><th>{t("common.station")}</th><th>{t("common.city")}</th><th>{t("common.type")}</th><th>{t("admin.lat")}, {t("admin.lng")}</th><th>{t("common.status")}</th></tr></thead>
          <tbody>{stations.map((s) => (
            <tr key={s.uid}><td className="mono small">{s.code}</td><td>{station(s.code, s.name)}</td><td>{city(s.city_code)}</td><td>{s.station_class}</td>
              <td className="mono small ltr">{s.lat.toFixed(4)}, {s.lng.toFixed(4)}</td><td><Status value={s.status} /></td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("admin.newStation")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={submit}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("common.city")}><select className="input" value={f.city_code} onChange={set("city_code")}>{cities.map((c) => <option key={c} value={c}>{city(c)}</option>)}</select></Field>
              <Field label={t("admin.number")}><input className="input ltr" type="number" min={1} max={999} value={f.number} onChange={set("number")} /></Field>
            </div>
            <Field label={`${t("common.name")} (English)`}><input className="input ltr" value={f.name} onChange={set("name")} /></Field>
            <Field label={`${t("admin.address")} (${t("common.optional")})`}><input className="input" value={f.address} onChange={set("address")} /></Field>
            <div className="grid cols-2">
              <Field label={t("admin.lat")}><input className="input ltr" type="number" step="0.0001" value={f.lat} onChange={set("lat")} /></Field>
              <Field label={t("admin.lng")}><input className="input ltr" type="number" step="0.0001" value={f.lng} onChange={set("lng")} /></Field>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
