import { useState, type FormEvent } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Stat, Status, useLoad, useToast } from "../../components/ui";

// The carrier and the boarding stations (1097-1110, build step 4): the rights it gives a station operating company for
// its own trips (selling at the counter, the counter check and boarding pass, boarding at the bay), its agreement and
// licence numbers, and what the operating companies did on its trips in a day. Checked again by the API and database.

interface Option { uid: string; name: string }
interface StationOption { uid: string; code: string; name: string; boarding_on_now: boolean }
interface Grant {
  uid: string; permission: string; granted_at: string; revoked_at: string | null; operator_uid: string; operator_name: string;
  station_uid: string | null; station_code: string | null;
}
interface Reference {
  uid: string; kind: "AGREEMENT" | "LICENCE"; licence_type: string | null; reference_no: string; issued_by: string | null;
  issued_on: string | null; expires_on: string | null; status: string; created_at: string;
}
interface Activity {
  day: string;
  checkins: { pass_no: string; status: string; created_at: string; document_checked: boolean; station: string; operator: string; counter: string | null; trip_no: string; ticket_no: string }[];
  sales: { booking_ref: string; status: string; total: number; currency: string; created_at: string; station: string; operator: string; counter: string | null; trip_no: string }[];
}

export default function StationOps() {
  const { t } = useI18n();
  const { can } = useAuth();
  type Tab = "grants" | "references" | "activity";
  const tabs = ([["grants", can("boarding.operators")], ["activity", can("boarding.operators")], ["references", can("boarding.references")]] as [Tab, boolean][])
    .filter(([, ok]) => ok).map(([v]) => v);
  const [tab, setTab] = useState<Tab | undefined>(tabs[0]);
  return (
    <div className="stack">
      <PageHead title={t("stops.title")} sub={t("stops.sub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {tabs.map((v) => <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`stops.tab.${v}`)}</button>)}
      </div>
      {tab === "grants" && <Grants />}
      {tab === "activity" && <DayActivity />}
      {tab === "references" && <References />}
    </div>
  );
}

function Grants() {
  const { t, date } = useI18n();
  const toast = useToast();
  const list = useLoad(() => api.get<{ grants: Grant[] }>("/api/carrier/station-operators/grants"));
  const opts = useLoad(() => api.get<{ companies: Option[]; stations: StationOption[] }>("/api/carrier/station-operators/options"));
  const [f, setF] = useState({ operator_company_uid: "", station_uid: "", permission: "BOARDING_PASS" });
  const [error, setError] = useState<unknown>(null);
  const add = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await api.post("/api/carrier/station-operators/grants", { ...f, station_uid: f.station_uid || undefined });
      toast(t("common.saved")); list.reload();
    } catch (err) { setError(err); }
  };
  const revoke = async (g: Grant) => {
    setError(null);
    try { await api.post(`/api/carrier/station-operators/grants/${g.uid}/revoke`); toast(t("brdadm.revoked")); list.reload(); } catch (err) { setError(err); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("stops.grantsHint")}</p>
      <ErrorBox error={error} />
      <Loaded state={opts}>{(o) => o.companies.length === 0 ? <Empty icon="storefront" title={t("stops.noCompanies")} hint={t("stops.noCompaniesHint")} /> : (
        <form className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }} onSubmit={add}>
          <Field label={t("brdadm.operator")}>
            <select className="input" value={f.operator_company_uid} onChange={(e) => setF({ ...f, operator_company_uid: e.target.value })}>
              <option value="">—</option>
              {o.companies.map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
            </select>
          </Field>
          <Field label={t("common.station")}>
            <select className="input" value={f.station_uid} onChange={(e) => setF({ ...f, station_uid: e.target.value })}>
              <option value="">{t("st.everyStation")}</option>
              {o.stations.map((s) => <option key={s.uid} value={s.uid}>{s.code} · {s.name}{s.boarding_on_now ? "" : ` (${t("stops.notBoarding")})`}</option>)}
            </select>
          </Field>
          <Field label={t("st.right")}>
            <select className="input" value={f.permission} onChange={(e) => setF({ ...f, permission: e.target.value })}>
              {["BOOKING", "BOARDING_PASS", "BOARDING"].map((p) => <option key={p} value={p}>{t(`st.perm.${p}`)}</option>)}
            </select>
          </Field>
          <button className="btn" disabled={!f.operator_company_uid}><Icon name="key" />{t("brdadm.grant")}</button>
        </form>
      )}</Loaded>
      <Loaded state={list}>{({ grants }) => grants.length === 0 ? <Empty icon="key_off" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("brdadm.operator")}</th><th>{t("common.station")}</th><th>{t("st.right")}</th><th>{t("common.date")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{grants.map((g) => (
            <tr key={g.uid}>
              <td>{g.operator_name}</td><td className="mono">{g.station_code ?? t("st.everyStation")}</td><td>{t(`st.perm.${g.permission}`)}</td>
              <td>{date(g.granted_at)}</td><td><Status value={g.revoked_at ? "REVOKED" : "ACTIVE"} /></td>
              <td className="num">{!g.revoked_at && <button className="btn text small" onClick={() => revoke(g)}>{t("brdadm.revoke")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}

function DayActivity() {
  const { t, time, money } = useI18n();
  const [day, setDay] = useState("");
  const state = useLoad(() => api.get<Activity>("/api/carrier/station-operators/activity", { day: day || undefined }), [day]);
  return (
    <div className="stack">
      <div className="card row between" style={{ flexWrap: "wrap", gap: 8 }}>
        <p className="small muted" style={{ margin: 0 }}>{t("stops.activityHint")}</p>
        <input className="input" type="date" value={day} onChange={(e) => setDay(e.target.value)} style={{ maxWidth: 200 }} />
      </div>
      <Loaded state={state}>{(a) => (
        <>
          <div className="grid cols-3">
            <Stat icon="how_to_reg" label={t("stops.checkins")} value={a.checkins.filter((c) => c.status === "CHECKED_IN").length} tone="blue" />
            <Stat icon="point_of_sale" label={t("stops.sales")} value={a.sales.filter((s) => s.status !== "CANCELLED").length} tone="wheat" />
            <Stat icon="payments" label={t("common.total")} value={money(a.sales.filter((s) => s.status !== "CANCELLED").reduce((x, s) => x + s.total, 0))} />
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("stops.checkins")}</h3>
            {a.checkins.length === 0 ? <Empty icon="how_to_reg" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("common.time")}</th><th>{t("st.pass")}</th><th>{t("st.trip")}</th><th>{t("st.ticket")}</th><th>{t("common.station")}</th>
                  <th>{t("brdadm.operator")}</th><th>{t("st.counter")}</th><th>{t("stops.document")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{a.checkins.map((c) => (
                  <tr key={c.pass_no}>
                    <td>{time(c.created_at)}</td><td className="mono">{c.pass_no}</td><td className="mono">{c.trip_no}</td><td className="mono">{c.ticket_no}</td>
                    <td className="mono">{c.station}</td><td>{c.operator}</td><td className="mono">{c.counter ?? "—"}</td>
                    <td>{c.document_checked ? <Icon name="check" /> : "—"}</td><td><Status value={c.status} /></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("stops.sales")}</h3>
            {a.sales.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("common.time")}</th><th>{t("st.bookingRef")}</th><th>{t("st.trip")}</th><th>{t("common.station")}</th><th>{t("brdadm.operator")}</th>
                  <th>{t("st.counter")}</th><th className="num">{t("common.total")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{a.sales.map((s) => (
                  <tr key={s.booking_ref}>
                    <td>{time(s.created_at)}</td><td className="mono">{s.booking_ref}</td><td className="mono">{s.trip_no}</td><td className="mono">{s.station}</td>
                    <td>{s.operator}</td><td className="mono">{s.counter ?? "—"}</td><td className="num">{money(s.total)}</td><td><Status value={s.status} /></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
        </>
      )}</Loaded>
    </div>
  );
}

function References() {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ references: Reference[]; required: string[]; missing: string[] }>("/api/carrier/references"));
  const blank = { kind: "AGREEMENT" as "AGREEMENT" | "LICENCE", licence_type: "", reference_no: "", issued_by: "", issued_on: "", expires_on: "" };
  const [f, setF] = useState(blank);
  const [error, setError] = useState<unknown>(null);
  const add = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await api.post("/api/carrier/references", {
        kind: f.kind, reference_no: f.reference_no, licence_type: f.kind === "LICENCE" ? f.licence_type : undefined,
        issued_by: f.issued_by || undefined, issued_on: f.issued_on || undefined, expires_on: f.expires_on || undefined,
      });
      toast(t("common.saved")); setF(blank); state.reload();
    } catch (err) { setError(err); }
  };
  const retire = async (r: Reference) => {
    setError(null);
    try { await api.post(`/api/carrier/references/${r.uid}/retire`); toast(t("stops.retired")); state.reload(); } catch (err) { setError(err); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("stops.refsHint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => (
        <div className="stack">
          {d.missing.length > 0 && <div className="alert error small"><Icon name="warning" />{t("stops.missing")}: <span className="mono">{d.missing.join(", ")}</span></div>}
          <form className="stack" onSubmit={add}>
            <div className="grid cols-3">
              <Field label={t("common.type")}>
                <select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as "AGREEMENT" | "LICENCE" })}>
                  <option value="AGREEMENT">{t("stops.kind.AGREEMENT")}</option><option value="LICENCE">{t("stops.kind.LICENCE")}</option>
                </select>
              </Field>
              {f.kind === "LICENCE" && (
                <Field label={t("stops.licenceType")} hint={d.required.length ? `${t("stops.required")}: ${d.required.join(", ")}` : undefined}>
                  <input className="input mono ltr" value={f.licence_type} onChange={(e) => setF({ ...f, licence_type: e.target.value })} />
                </Field>
              )}
              <Field label={t("stops.number")}><input className="input mono ltr" value={f.reference_no} onChange={(e) => setF({ ...f, reference_no: e.target.value })} /></Field>
              <Field label={t("stops.issuedBy")}><input className="input" value={f.issued_by} onChange={(e) => setF({ ...f, issued_by: e.target.value })} /></Field>
              <Field label={t("stops.issuedOn")}><input className="input" type="date" value={f.issued_on} onChange={(e) => setF({ ...f, issued_on: e.target.value })} /></Field>
              <Field label={t("stops.expiresOn")}><input className="input" type="date" value={f.expires_on} onChange={(e) => setF({ ...f, expires_on: e.target.value })} /></Field>
            </div>
            <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!f.reference_no.trim() || (f.kind === "LICENCE" && !f.licence_type.trim())}><Icon name="add" />{t("common.add")}</button>
          </form>
          {d.references.length === 0 ? <Empty icon="badge" title={t("common.noData")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("common.type")}</th><th>{t("stops.number")}</th><th>{t("stops.issuedBy")}</th><th>{t("stops.issuedOn")}</th><th>{t("stops.expiresOn")}</th><th>{t("common.status")}</th><th /></tr></thead>
              <tbody>{d.references.map((r) => (
                <tr key={r.uid}>
                  <td>{r.kind === "LICENCE" ? `${t("stops.kind.LICENCE")} · ${r.licence_type}` : t("stops.kind.AGREEMENT")}</td>
                  <td className="mono">{r.reference_no}</td><td>{r.issued_by ?? "—"}</td><td>{r.issued_on ? date(r.issued_on) : "—"}</td>
                  <td>{r.expires_on ? date(r.expires_on) : "—"}</td><td><Status value={r.status} /></td>
                  <td className="num">{r.status === "ACTIVE" && <button className="btn text small" onClick={() => retire(r)}>{t("stops.retire")}</button>}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </div>
      )}</Loaded>
    </div>
  );
}
