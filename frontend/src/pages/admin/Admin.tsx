import { useState } from "react";
import { api, newKey } from "../../api";
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

// ------------------------------------------------------------------ agencies
interface AdminAgency {
  uid: string; legal_name: string; approval_status: string; commission_bp: number | null; daily_limit: number | null;
  agreement_status: string | null; balance: number | null; currency: string | null; bookings: number;
}

// Amounts are typed in whole Syrian pounds and sent in minor units
const toMinor = (v: string) => Math.round(Number(v || 0) * 100);

export function AdminAgencies() {
  const { t, money } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ agencies: AdminAgency[] }>("/api/admin/agencies"));
  const blank = { legal_name: "", license_no: "", owner_name: "", owner_email: "", owner_password: "", commission_pct: "5", daily_limit: "500000" };
  const [f, setF] = useState(blank);
  const [mode, setMode] = useState<null | "new" | { terms: AdminAgency } | { deposit: AdminAgency }>(null);
  const [terms, setTerms] = useState({ commission_pct: "", daily_limit: "", status: "ACTIVE", reason: "" });
  const [dep, setDep] = useState({ amount: "", bank_reference: "", key: newKey() });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });
  const close = () => { setMode(null); setError(null); };
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); close(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };

  const onboard = () => run(() => api.post("/api/admin/agencies", {
    legal_name: f.legal_name, license_no: f.license_no || null, owner_name: f.owner_name, owner_email: f.owner_email,
    owner_password: f.owner_password, commission_bp: Math.round(Number(f.commission_pct) * 100), daily_limit: toMinor(f.daily_limit),
  }).then(() => setF(blank)));
  const saveTerms = (a: AdminAgency) => run(() => api.post(`/api/admin/agencies/${a.uid}/agreement`, {
    commission_bp: Math.round(Number(terms.commission_pct) * 100), daily_limit: toMinor(terms.daily_limit), status: terms.status, reason: terms.reason,
  }));
  const deposit = (a: AdminAgency) => run(() => api.post(`/api/admin/agencies/${a.uid}/deposit`, {
    amount: toMinor(dep.amount), bank_reference: dep.bank_reference.trim(), idempotency_key: dep.key,
  }));
  const openTerms = (a: AdminAgency) => {
    setTerms({ commission_pct: String((a.commission_bp ?? 0) / 100), daily_limit: String((a.daily_limit ?? 0) / 100), status: a.agreement_status === "SUSPENDED" ? "SUSPENDED" : "ACTIVE", reason: "" });
    setMode({ terms: a });
  };
  const openDeposit = (a: AdminAgency) => { setDep({ amount: "", bank_reference: "", key: newKey() }); setMode({ deposit: a }); };
  const actions = (ok: () => void, disabled = false) => (
    <><button className="btn text" onClick={close}>{t("common.cancel")}</button><button className="btn" disabled={busy || disabled} onClick={ok}>{t("common.confirm")}</button></>
  );

  return (
    <div className="stack">
      <PageHead title={t("admin.agencies")} sub={t("admin.agenciesHint")}>
        {can("company.approve") && <button className="btn" onClick={() => setMode("new")}><Icon name="add" />{t("admin.onboardAgency")}</button>}
      </PageHead>
      <ErrorBox error={!mode ? error : null} />
      <Loaded state={state}>{({ agencies }) => agencies.length === 0 ? <div className="card"><Empty icon="store" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("admin.legalName")}</th><th className="num">{t("agency.rate")}</th><th className="num">{t("admin.dailyLimit")}</th>
            <th className="num">{t("agency.balance")}</th><th className="num">{t("agency.bookings")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{agencies.map((a) => (
            <tr key={a.uid}>
              <td style={{ fontWeight: 500 }}>{a.legal_name}</td>
              <td className="num">{a.commission_bp != null ? `${a.commission_bp / 100}%` : "—"}</td>
              <td className="num">{a.daily_limit != null ? money(a.daily_limit) : "—"}</td>
              <td className="num">{a.balance != null ? money(a.balance) : "—"}</td>
              <td className="num">{a.bookings}</td>
              <td><Status value={a.agreement_status ?? a.approval_status} /></td>
              <td><div className="row nowrap" style={{ gap: 4 }}>
                {can("company.approve") && <button className="btn tonal small" onClick={() => openTerms(a)}>{t("admin.terms")}</button>}
                {can("cash.remittance") && <button className="btn outlined small" onClick={() => openDeposit(a)}>{t("admin.deposit")}</button>}
              </div></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>

      {mode === "new" && (
        <Modal title={t("admin.onboardAgency")} onClose={close} actions={actions(onboard)}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("admin.legalName")}><input className="input" value={f.legal_name} onChange={set("legal_name")} /></Field>
            <div className="grid cols-2">
              <Field label={`${t("admin.license")} (${t("common.optional")})`}><input className="input ltr" value={f.license_no} onChange={set("license_no")} /></Field>
              <Field label={t("admin.commissionPct")} hint={t("admin.commissionHint")}><input className="input ltr" type="number" min={0} max={20} step={0.25} value={f.commission_pct} onChange={set("commission_pct")} /></Field>
              <Field label={t("admin.dailyLimitSyp")}><input className="input ltr" type="number" min={1} value={f.daily_limit} onChange={set("daily_limit")} /></Field>
              <Field label={t("admin.ownerName")}><input className="input" value={f.owner_name} onChange={set("owner_name")} /></Field>
            </div>
            <Field label={t("admin.ownerEmail")}><input className="input ltr" type="email" value={f.owner_email} onChange={set("owner_email")} /></Field>
            <Field label={t("admin.ownerPassword")} hint={t("auth.passwordHint")}><input className="input ltr" type="password" autoComplete="new-password" value={f.owner_password} onChange={set("owner_password")} /></Field>
          </div>
        </Modal>
      )}
      {mode && typeof mode === "object" && "terms" in mode && (
        <Modal title={`${t("admin.terms")} · ${mode.terms.legal_name}`} onClose={close} actions={actions(() => saveTerms(mode.terms), terms.reason.trim().length < 3)}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("admin.commissionPct")} hint={t("admin.commissionHint")}><input className="input ltr" type="number" min={0} max={20} step={0.25} value={terms.commission_pct} onChange={(e) => setTerms({ ...terms, commission_pct: e.target.value })} /></Field>
              <Field label={t("admin.dailyLimitSyp")}><input className="input ltr" type="number" min={1} value={terms.daily_limit} onChange={(e) => setTerms({ ...terms, daily_limit: e.target.value })} /></Field>
            </div>
            <Field label={t("common.status")}>
              <select className="input" value={terms.status} onChange={(e) => setTerms({ ...terms, status: e.target.value })}>
                <option value="ACTIVE">{t("status.ACTIVE")}</option><option value="SUSPENDED">{t("status.SUSPENDED")}</option>
              </select>
            </Field>
            <Field label={t("common.reason")}><textarea className="input" value={terms.reason} onChange={(e) => setTerms({ ...terms, reason: e.target.value })} /></Field>
            <p className="small muted">{t("admin.termsNote")}</p>
          </div>
        </Modal>
      )}
      {mode && typeof mode === "object" && "deposit" in mode && (
        <Modal title={`${t("admin.deposit")} · ${mode.deposit.legal_name}`} onClose={close}
               actions={actions(() => deposit(mode.deposit), !(Number(dep.amount) > 0) || dep.bank_reference.trim().length < 3)}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("admin.depositAmount")}><input className="input ltr" type="number" min={1} value={dep.amount} onChange={(e) => setDep({ ...dep, amount: e.target.value })} /></Field>
            <Field label={t("admin.bankReference")}><input className="input ltr mono" value={dep.bank_reference} onChange={(e) => setDep({ ...dep, bank_reference: e.target.value.replace(/[^0-9A-Za-z\-/]/g, "") })} /></Field>
            {Number(dep.amount) > 0 && <div className="alert info"><Icon name="account_balance_wallet" /><span>{t("admin.depositConfirm", { amount: money(toMinor(dep.amount)), name: mode.deposit.legal_name })}</span></div>}
          </div>
        </Modal>
      )}
    </div>
  );
}
