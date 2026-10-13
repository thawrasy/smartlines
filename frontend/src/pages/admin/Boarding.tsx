import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";
import { BaysPanel, platformBaysApi } from "../station/Bays";

// Boarding stations in the platform portal (1097-1112, build step 4): the switches and the check-in window, each
// station's boarding, screens, counters and bays, the station operating companies, and the rights the platform gives a
// state-mandated operating company. Everything here is checked again by the API and the database. The platform names
// each station's administration, which assigns its bays (1115), and sets the languages the departure board shows in turn.

interface StationRow {
  uid: string; code: string; name: string; city: string | null; enabled: boolean; displays: boolean; counter_system: string;
  checkin_opens_minutes: number | null; checkin_closes_minutes: number | null; boarding_on_now: boolean; counters: number; bays: number;
}
interface Gate { code: string; gate_type: string; status: string; operator_uid: string | null; operator_name: string | null }
interface StationView {
  uid: string; code: string; name: string; boarding_on_now: boolean; gates: Gate[];
  boarding: { enabled: boolean; counter_system: "PLATFORM" | "EXTERNAL"; displays: boolean; checkin_opens_minutes: number | null; checkin_closes_minutes: number | null;
    manager_company_uid?: string | null; manager_company_name?: string | null; bay_mode?: "CARRIER" | "TRIP" };
}
interface Company { uid: string; name: string; approval_status: string; created_at: string; counters: number; grants: number }
interface Grant {
  uid: string; permission: string; granted_at: string; revoked_at: string | null; carrier_uid: string | null; carrier_name: string | null; carrier_logo?: string | null;
  operator_uid: string; operator_name: string; station_uid: string | null; station_code: string | null;
}
type Settings = Record<string, unknown>;

export default function AdminBoarding() {
  const { t } = useI18n();
  type Tab = "stations" | "companies" | "grants" | "settings";
  const [tab, setTab] = useState<Tab>("stations");
  return (
    <div className="stack">
      <PageHead title={t("brdadm.title")} sub={t("brdadm.sub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {(["stations", "companies", "grants", "settings"] as Tab[]).map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`brdadm.tab.${v}`)}</button>
        ))}
      </div>
      {tab === "stations" && <Stations />}
      {tab === "companies" && <Companies />}
      {tab === "grants" && <PlatformGrants />}
      {tab === "settings" && <BoardingSettings />}
    </div>
  );
}

function Stations() {
  const { t, city, station: placeName } = useI18n();
  const list = useLoad(() => api.get<{ stations: StationRow[] }>("/api/admin/boarding/stations"));
  const [open, setOpen] = useState<string | null>(null);
  const [bays, setBays] = useState<StationRow | null>(null);
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("brdadm.stationsHint")}</p>
      <Loaded state={list}>{({ stations }) => stations.length === 0 ? <Empty icon="location_off" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.station")}</th><th>{t("common.city")}</th><th>{t("brdadm.boarding")}</th><th>{t("brdadm.screens")}</th>
            <th className="num">{t("brdadm.counters")}</th><th className="num">{t("brdadm.bays")}</th><th /></tr></thead>
          <tbody>{stations.map((s) => (
            <tr key={s.uid}>
              <td><strong className="mono text-nowrap">{s.code}</strong> · {placeName(s.code, s.name)}</td>
              <td>{s.city ? city(s.city) : "—"}</td>
              <td>{s.boarding_on_now ? <Status value="ACTIVE" /> : s.enabled ? <span className="small muted">{t("brdadm.onButOff")}</span> : <span className="small muted">{t("brdadm.off")}</span>}</td>
              <td>{s.displays ? <Link className="btn text small" to={`/board/${s.uid}`} target="_blank" rel="noopener"><Icon name="tv" />{t("brdadm.openBoard")}</Link> : <span className="small muted">{t("brdadm.off")}</span>}</td>
              <td className="num">{s.counters}</td><td className="num">{s.bays}</td>
              <td className="num text-nowrap"><button className="btn text small" onClick={() => setOpen(s.uid)}><Icon name="tune" />{t("brdadm.manage")}</button>
                <button className="btn text small" onClick={() => setBays(s)}><Icon name="local_parking" />{t("bays.nav")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && <StationModal uid={open} onClose={() => { setOpen(null); list.reload(); }} />}
      {bays && (
        <Modal wide title={`${t("bays.title")} · ${bays.code}`} onClose={() => setBays(null)}
          actions={<button className="btn text" onClick={() => setBays(null)}>{t("common.close")}</button>}>
          <p className="small muted" style={{ marginTop: 0 }}>{t("bays.platformHint")}</p>
          <BaysPanel calls={platformBaysApi(bays.uid)} />
        </Modal>
      )}
    </div>
  );
}

function StationModal({ uid, onClose }: { uid: string; onClose: () => void }) {
  const { t, station: placeName } = useI18n();
  const toast = useToast();
  const view = useLoad(() => api.get<StationView>(`/api/admin/boarding/stations/${uid}`), [uid]);
  const companies = useLoad(() => api.get<{ companies: Company[] }>("/api/admin/boarding/operating-companies"));
  const [form, setForm] = useState<StationView["boarding"] | null>(null);
  const [gateType, setGateType] = useState("BAY");
  const [operator, setOperator] = useState("");
  const [error, setError] = useState<unknown>(null);
  const b = form ?? view.data?.boarding ?? null;
  const set = (patch: Partial<StationView["boarding"]>) => b && setForm({ ...b, ...patch });
  const num = (v: string) => (v === "" ? null : Number(v));
  const save = async () => {
    if (!b) return;
    setError(null);
    try {
      await api.put(`/api/admin/boarding/stations/${uid}`, { enabled: b.enabled, counter_system: b.counter_system, displays: b.displays,
        checkin_opens_minutes: b.checkin_opens_minutes, checkin_closes_minutes: b.checkin_closes_minutes,
        manager_company_uid: b.manager_company_uid || null });
      toast(t("common.saved")); setForm(null); view.reload();
    } catch (e) { setError(e); }
  };
  const openGate = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const g = await api.post<{ code: string }>(`/api/admin/boarding/stations/${uid}/gates`,
        { gate_type: gateType, operator_company_uid: gateType === "COUNTER" ? operator || undefined : undefined });
      toast(t("brdadm.gateOpened", { code: g.code })); view.reload();
    } catch (err) { setError(err); }
  };
  return (
    <Modal wide title={view.data ? `${view.data.code} · ${placeName(view.data.code, view.data.name)}` : t("common.loading")} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.close")}</button><button className="btn" disabled={!form} onClick={save}>{t("common.save")}</button></>}>
      <Loaded state={view}>{(v) => b && (
        <div className="stack">
          <ErrorBox error={error} />
          <label className="check-row"><input type="checkbox" checked={b.enabled} onChange={(e) => set({ enabled: e.target.checked })} />{t("brdadm.enabled")}</label>
          <label className="check-row"><input type="checkbox" checked={b.displays} onChange={(e) => set({ displays: e.target.checked })} />{t("brdadm.displays")}</label>
          <div className="grid cols-3">
            <Field label={t("brdadm.counterSystem")}>
              <select className="input" value={b.counter_system} onChange={(e) => set({ counter_system: e.target.value as "PLATFORM" | "EXTERNAL" })}>
                <option value="PLATFORM">{t("brdadm.system.PLATFORM")}</option><option value="EXTERNAL">{t("brdadm.system.EXTERNAL")}</option>
              </select>
            </Field>
            <Field label={t("brdadm.opens")} hint={t("brdadm.windowHint")}>
              <input className="input" type="number" min={0} max={1440} value={b.checkin_opens_minutes ?? ""} onChange={(e) => set({ checkin_opens_minutes: num(e.target.value) })} />
            </Field>
            <Field label={t("brdadm.closes")}>
              <input className="input" type="number" min={0} max={1440} value={b.checkin_closes_minutes ?? ""} onChange={(e) => set({ checkin_closes_minutes: num(e.target.value) })} />
            </Field>
          </div>
          <Field label={t("bays.manager")} hint={t("bays.managerHint")}>
            <select className="input" value={b.manager_company_uid ?? ""} onChange={(e) => set({ manager_company_uid: e.target.value || null })}>
              <option value="">{t("bays.noManager")}</option>
              {(companies.data?.companies ?? []).filter((c) => c.approval_status === "APPROVED").map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
            </select>
          </Field>
          <div className="alert info small"><Icon name="info" />{v.boarding_on_now ? t("brdadm.onNow") : t("brdadm.offNow")}</div>
          {b.displays && <div className="small"><Link to={`/board/${v.uid}`} target="_blank" rel="noopener"><Icon name="tv" /> {t("brdadm.boardLink")}</Link> <span className="mono ltr">{`${window.location.origin}/board/${v.uid}`}</span></div>}
          <h3 style={{ margin: 0 }}>{t("brdadm.gates")}</h3>
          {v.gates.length === 0 ? <Empty icon="door_front" title={t("brdadm.noGates")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("common.code")}</th><th>{t("common.type")}</th><th>{t("brdadm.operator")}</th><th>{t("common.status")}</th></tr></thead>
              <tbody>{v.gates.map((g) => (
                <tr key={g.code}><td className="mono">{g.code}</td><td>{t(`brdadm.gate.${g.gate_type}`)}</td><td>{g.operator_name ?? "—"}</td><td><Status value={g.status} /></td></tr>
              ))}</tbody>
            </table></div>
          )}
          <form className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }} onSubmit={openGate}>
            <Field label={t("common.type")}>
              <select className="input" value={gateType} onChange={(e) => setGateType(e.target.value)}>
                {["BAY", "PLATFORM", "GATE", "COUNTER"].map((g) => <option key={g} value={g}>{t(`brdadm.gate.${g}`)}</option>)}
              </select>
            </Field>
            {gateType === "COUNTER" && (
              <Field label={t("brdadm.operator")}>
                <select className="input" value={operator} onChange={(e) => setOperator(e.target.value)}>
                  <option value="">—</option>
                  {(companies.data?.companies ?? []).filter((c) => c.approval_status === "APPROVED").map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
                </select>
              </Field>
            )}
            <button className="btn outlined" disabled={gateType === "COUNTER" && !operator}><Icon name="add" />{t("brdadm.openGate")}</button>
          </form>
        </div>
      )}</Loaded>
    </Modal>
  );
}

function Companies() {
  const { t, date } = useI18n();
  const toast = useToast();
  const list = useLoad(() => api.get<{ companies: Company[] }>("/api/admin/boarding/operating-companies"));
  const [adding, setAdding] = useState(false);
  const [f, setF] = useState({ legal_name: "", license_no: "", owner_name: "", owner_email: "", owner_password: "" });
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setError(null);
    try {
      await api.post("/api/admin/boarding/operating-companies", { ...f, license_no: f.license_no || undefined });
      toast(t("brdadm.companyAdded")); setAdding(false); setF({ legal_name: "", license_no: "", owner_name: "", owner_email: "", owner_password: "" }); list.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <div className="row between"><p className="small muted" style={{ margin: 0 }}>{t("brdadm.companiesHint")}</p>
        <button className="btn" onClick={() => setAdding(true)}><Icon name="add_business" />{t("brdadm.addCompany")}</button></div>
      <Loaded state={list}>{({ companies }) => companies.length === 0 ? <Empty icon="storefront" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("common.status")}</th><th className="num">{t("brdadm.counters")}</th><th className="num">{t("brdadm.grants")}</th><th>{t("common.date")}</th></tr></thead>
          <tbody>{companies.map((c) => (
            <tr key={c.uid}><td>{c.name}</td><td><Status value={c.approval_status} /></td><td className="num">{c.counters}</td><td className="num">{c.grants}</td><td>{date(c.created_at)}</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {adding && (
        <Modal title={t("brdadm.addCompany")} onClose={() => setAdding(false)}
          actions={<><button className="btn text" onClick={() => setAdding(false)}>{t("common.cancel")}</button>
            <button className="btn" disabled={f.legal_name.length < 3 || f.owner_name.length < 3 || !f.owner_email || !f.owner_password} onClick={save}>{t("common.create")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("brdadm.legalName")}><input className="input" value={f.legal_name} onChange={(e) => setF({ ...f, legal_name: e.target.value })} /></Field>
            <Field label={t("brdadm.licenseNo")}><input className="input mono ltr" value={f.license_no} onChange={(e) => setF({ ...f, license_no: e.target.value })} /></Field>
            <Field label={t("brdadm.ownerName")}><input className="input" value={f.owner_name} onChange={(e) => setF({ ...f, owner_name: e.target.value })} /></Field>
            <Field label={t("common.email")}><input className="input ltr" type="email" value={f.owner_email} onChange={(e) => setF({ ...f, owner_email: e.target.value })} /></Field>
            <Field label={t("common.password")} hint={t("brdadm.ownerHint")}><input className="input ltr" type="password" autoComplete="new-password" value={f.owner_password} onChange={(e) => setF({ ...f, owner_password: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

function PlatformGrants() {
  const { t, date, station: placeName } = useI18n();
  const toast = useToast();
  const list = useLoad(() => api.get<{ grants: Grant[] }>("/api/admin/boarding/operator-grants"));
  const companies = useLoad(() => api.get<{ companies: Company[] }>("/api/admin/boarding/operating-companies"));
  const stations = useLoad(() => api.get<{ stations: StationRow[] }>("/api/admin/boarding/stations"));
  const [f, setF] = useState({ operator_company_uid: "", station_uid: "", permission: "BOARDING_PASS" });
  const [error, setError] = useState<unknown>(null);
  const add = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await api.post("/api/admin/boarding/operator-grants", { ...f, station_uid: f.station_uid || undefined });
      toast(t("common.saved")); list.reload();
    } catch (err) { setError(err); }
  };
  const revoke = async (g: Grant) => {
    setError(null);
    try { await api.post(`/api/admin/boarding/operator-grants/${g.uid}/revoke`); toast(t("brdadm.revoked")); list.reload(); } catch (err) { setError(err); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("brdadm.grantsHint")}</p>
      <ErrorBox error={error} />
      <form className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }} onSubmit={add}>
        <Field label={t("brdadm.operator")}>
          <select className="input" value={f.operator_company_uid} onChange={(e) => setF({ ...f, operator_company_uid: e.target.value })}>
            <option value="">—</option>
            {(companies.data?.companies ?? []).filter((c) => c.approval_status === "APPROVED").map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
          </select>
        </Field>
        <Field label={t("common.station")}>
          <select className="input" value={f.station_uid} onChange={(e) => setF({ ...f, station_uid: e.target.value })}>
            <option value="">{t("st.everyStation")}</option>
            {(stations.data?.stations ?? []).map((s) => <option key={s.uid} value={s.uid}>{s.code} · {placeName(s.code, s.name)}</option>)}
          </select>
        </Field>
        <Field label={t("st.right")}>
          <select className="input" value={f.permission} onChange={(e) => setF({ ...f, permission: e.target.value })}>
            {["BOOKING", "BOARDING_PASS", "BOARDING"].map((p) => <option key={p} value={p}>{t(`st.perm.${p}`)}</option>)}
          </select>
        </Field>
        <button className="btn" disabled={!f.operator_company_uid}><Icon name="key" />{t("brdadm.grant")}</button>
      </form>
      <Loaded state={list}>{({ grants }) => grants.length === 0 ? <Empty icon="key_off" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("brdadm.operator")}</th><th>{t("st.carrier")}</th><th>{t("common.station")}</th><th>{t("st.right")}</th><th>{t("common.date")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{grants.map((g) => (
            <tr key={g.uid}>
              <td>{g.operator_name}</td><td>{g.carrier_name ? <CarrierName name={g.carrier_name} uid={g.carrier_uid} logo={g.carrier_logo} /> : t("brdadm.byPlatform")}</td><td className="mono text-nowrap">{g.station_code ?? t("st.everyStation")}</td>
              <td>{t(`st.perm.${g.permission}`)}</td><td>{date(g.granted_at)}</td><td><Status value={g.revoked_at ? "REVOKED" : "ACTIVE"} /></td>
              <td className="num">{!g.revoked_at && !g.carrier_uid && <button className="btn text small" onClick={() => revoke(g)}>{t("brdadm.revoke")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}

function BoardingSettings() {
  const { t } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ settings: Settings }>("/api/admin/boarding/settings"));
  const [error, setError] = useState<unknown>(null);
  const [refs, setRefs] = useState<string | null>(null);
  const put = async (key: string, value: unknown) => {
    setError(null);
    try { await api.put("/api/admin/boarding/settings", { key, value }); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); }
  };
  const flags = ["boarding.stations.enabled", "boarding.mode.state_mandated", "boarding.mode.carrier_contracted"];
  return (
    <div className="card stack">
      <ErrorBox error={error} />
      <Loaded state={state}>{({ settings }) => {
        const required = (settings["boarding.references.required"] as string[] | undefined) ?? [];
        return (
          <div className="stack">
            <div className="grid cols-3">
              {flags.map((k) => (
                <Stat key={k} icon={settings[k] ? "toggle_on" : "toggle_off"} label={t(`brdadm.set.${k.replace(/\./g, "_")}`)}
                  value={<button className="btn text small" disabled={!can("boarding.manage")} onClick={() => put(k, !settings[k])}>{settings[k] ? t("brdadm.on") : t("brdadm.off")}</button>}
                  tone={settings[k] ? "blue" : undefined} />
              ))}
            </div>
            <div className="grid cols-2">
              {["boarding.checkin.opens_minutes", "boarding.checkin.closes_minutes"].map((k) => (
                <Field key={k} label={t(`brdadm.set.${k.replace(/\./g, "_")}`)} hint={t("brdadm.windowHint")}>
                  <input className="input" type="number" min={0} max={1440} defaultValue={(settings[k] as number | null) ?? ""}
                    onBlur={(e) => { const v = e.target.value === "" ? null : Number(e.target.value); if (v !== settings[k]) put(k, v); }} />
                </Field>
              ))}
            </div>
            <Field label={t("brdadm.set.boarding_references_required")} hint={t("brdadm.refsHint")}>
              <input className="input mono ltr" value={refs ?? required.join(", ")} onChange={(e) => setRefs(e.target.value)}
                onBlur={() => { if (refs !== null) { put("boarding.references.required", refs.split(",").map((s) => s.trim()).filter(Boolean)); setRefs(null); } }} />
            </Field>
            <BoardLanguages settings={settings} put={put} />
            <div className="alert info small"><Icon name="no_photography" />{t("brdadm.photoNote")}</div>
          </div>
        );
      }}</Loaded>
    </div>
  );
}

/** The languages the departure board shows in turn and how long each stays (1115, owner's decision O2). */
function BoardLanguages({ settings, put }: { settings: Settings; put: (key: string, value: unknown) => void }) {
  const { t } = useI18n();
  const { can } = useAuth();
  const langs = (settings["boarding.board.languages"] as string[] | undefined) ?? ["ar", "en"];
  const options: Record<string, string[]> = { "ar,en": ["ar", "en"], "en,ar": ["en", "ar"], ar: ["ar"], en: ["en"] };
  return (
    <div className="grid cols-2">
      <Field label={t("brdadm.set.boarding_board_languages")} hint={t("brdadm.languagesHint")}>
        <select className="input" disabled={!can("boarding.manage")} value={langs.join(",")} onChange={(e) => put("boarding.board.languages", options[e.target.value])}>
          {Object.keys(options).map((k) => <option key={k} value={k}>{options[k].map((l) => t(`brdadm.lang.${l}`)).join(" · ")}</option>)}
        </select>
      </Field>
      <Field label={t("brdadm.set.boarding_board_rotate_seconds")} hint={t("brdadm.rotateHint")}>
        <input className="input" type="number" min={5} max={60} disabled={!can("boarding.manage") || langs.length < 2}
          defaultValue={(settings["boarding.board.rotate_seconds"] as number | undefined) ?? 10}
          onBlur={(e) => { const v = Number(e.target.value); if (v !== settings["boarding.board.rotate_seconds"]) put("boarding.board.rotate_seconds", v); }} />
      </Field>
    </div>
  );
}

