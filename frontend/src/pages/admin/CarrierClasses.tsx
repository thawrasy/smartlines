import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Carrier classes and the state's price bands (owner's request N10, migration 1164): the platform keeps the classes the
// state gives carriers, each carrier's class on the state's document (a new class ends the one before, which stays as
// history) and the bands per class in money per km, for every vehicle or one type. Carrier prices are free while the
// switch is off; once on, a price outside the band is refused.

interface Klass { code: string; name_en: string; name_ar: string; criteria: string | null; status: string }
interface Assignment { company_uid: string; company: string; class_code: string; source_document: string; assigned_on: string; valid_until: string | null;
  assigned_at: string; assigned_by: string | null; ended_at: string | null }
interface Band { id: number; class_code: string; vehicle_type: string | null; currency: string; min_per_km: number | null; max_per_km: number | null;
  valid_from: string; source_document: string | null; status: string }
interface Data { enabled: boolean; classes: Klass[]; assignments: Assignment[]; bands: Band[] }
interface Company { uid: string; legal_name: string; company_type: string }

const TYPES = ["COACH", "MINIBUS", "CITY_BUS", "VAN", "TRAIN_SET", "OTHER"];

export function AdminCarrierClasses() {
  const { t, locale, money, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Data>("/api/admin/carrier-classes", undefined, { signal }));
  const companies = useLoad((signal) => api.get<{ companies: Company[] }>("/api/admin/companies", undefined, { signal }));
  const [form, setForm] = useState<"class" | "assign" | "band" | null>(null);
  const [cls, setCls] = useState({ code: "", name_en: "", name_ar: "", criteria: "" });
  const [asg, setAsg] = useState({ company_uid: "", class_code: "", source_document: "", assigned_on: "", valid_until: "" });
  const [band, setBand] = useState({ class_code: "", vehicle_type: "", min_per_km: "", max_per_km: "", valid_from: "", source_document: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); setForm(null); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const perKm = (v: string) => (v === "" ? undefined : Math.round(Number(v) * 100));
  const submit = () => run(() => {
    if (form === "class") return api.post("/api/admin/carrier-classes", { ...cls, criteria: cls.criteria || undefined });
    if (form === "assign") return api.post("/api/admin/carrier-classes/assign", { ...asg, assigned_on: asg.assigned_on || undefined, valid_until: asg.valid_until || undefined });
    return api.post("/api/admin/price-bands", { class_code: band.class_code, vehicle_type: band.vehicle_type || undefined, min_per_km: perKm(band.min_per_km),
      max_per_km: perKm(band.max_per_km), valid_from: band.valid_from || undefined, source_document: band.source_document || undefined });
  });
  const toggle = (enabled: boolean) => run(() => api.put("/api/admin/price-bands/settings", { enabled }));
  const name = (k: Klass) => (locale === "ar" ? k.name_ar : k.name_en);
  return (
    <div className="stack">
      <PageHead title={t("fares.classesTitle")} sub={t("fares.classesSub")}>
        <button className="btn outlined" onClick={() => setForm("class")}><Icon name="add" />{t("fares.addClass")}</button>
        <button className="btn outlined" onClick={() => setForm("assign")}><Icon name="badge" />{t("fares.assign")}</button>
        <button className="btn" onClick={() => setForm("band")}><Icon name="tune" />{t("fares.addBand")}</button>
      </PageHead>
      <Loaded state={state}>{(d) => (
        <>
          <div className="card row between">
            <div><strong>{t("fares.switch")}</strong><div className="small muted">{t(d.enabled ? "fares.switchOn" : "fares.switchOff")}</div></div>
            <button className={`btn${d.enabled ? " danger" : ""}`} disabled={busy} onClick={() => toggle(!d.enabled)}>{t(d.enabled ? "fares.turnOff" : "fares.turnOn")}</button>
          </div>
          <div className="card stack"><h3 style={{ margin: 0 }}>{t("fares.classes")}</h3>
            {d.classes.length === 0 ? <Empty icon="badge" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("fares.code")}</th><th>{t("fares.name")}</th><th>{t("fares.criteria")}</th></tr></thead>
                <tbody>{d.classes.map((k) => <tr key={k.code}><td className="mono">{k.code}</td><td>{name(k)}</td><td className="small">{k.criteria ?? "—"}</td></tr>)}</tbody>
              </table></div>)}
          </div>
          <div className="card stack"><h3 style={{ margin: 0 }}>{t("fares.bands")}</h3>
            {d.bands.length === 0 ? <Empty icon="tune" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("fares.class")}</th><th>{t("fares.vehicleType")}</th><th>{t("fares.minKm")}</th><th>{t("fares.maxKm")}</th><th>{t("fares.validFrom")}</th><th>{t("fares.document")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{d.bands.map((b) => (
                  <tr key={b.id}><td className="mono">{b.class_code}</td><td>{b.vehicle_type ? t(`fares.vt.${b.vehicle_type}`) : t("fares.anyVehicle")}</td>
                    <td className="mono">{b.min_per_km == null ? "—" : money(b.min_per_km)}</td><td className="mono">{b.max_per_km == null ? "—" : money(b.max_per_km)}</td>
                    <td>{date(b.valid_from)}</td><td className="small">{b.source_document ?? "—"}</td><td>{t(`fares.st.${b.status}`)}</td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
          <div className="card stack"><h3 style={{ margin: 0 }}>{t("fares.assignments")}</h3>
            {d.assignments.length === 0 ? <Empty icon="badge" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("fares.carrier")}</th><th>{t("fares.class")}</th><th>{t("fares.document")}</th><th>{t("fares.from")}</th><th>{t("fares.until")}</th><th>{t("fares.by")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{d.assignments.map((a) => (
                  <tr key={`${a.company_uid}-${a.assigned_at}`}><td>{a.company}</td><td className="mono">{a.class_code}</td><td className="small">{a.source_document}</td>
                    <td>{date(a.assigned_on)}</td><td>{a.valid_until ? date(a.valid_until) : "—"}</td><td className="small">{a.assigned_by ?? "—"}</td>
                    <td>{a.ended_at ? t("fares.ended") : t("fares.current")}</td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
        </>
      )}</Loaded>
      {form && (
        <Modal title={t(form === "class" ? "fares.addClass" : form === "assign" ? "fares.assign" : "fares.addBand")} onClose={() => setForm(null)}
               actions={<><button className="btn text" onClick={() => setForm(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy} onClick={submit}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            {form === "class" && <>
              <Field label={t("fares.code")}><input className="input mono" value={cls.code} onChange={(e) => setCls({ ...cls, code: e.target.value.toUpperCase() })} /></Field>
              <Field label={t("fares.nameEn")}><input className="input" value={cls.name_en} onChange={(e) => setCls({ ...cls, name_en: e.target.value })} /></Field>
              <Field label={t("fares.nameAr")}><input className="input" dir="rtl" value={cls.name_ar} onChange={(e) => setCls({ ...cls, name_ar: e.target.value })} /></Field>
              <Field label={t("fares.criteria")}><textarea className="input" value={cls.criteria} onChange={(e) => setCls({ ...cls, criteria: e.target.value })} /></Field>
            </>}
            {form === "assign" && <>
              <Field label={t("fares.carrier")}>
                <select className="input" value={asg.company_uid} onChange={(e) => setAsg({ ...asg, company_uid: e.target.value })}>
                  <option value="">—</option>
                  {companies.data?.companies.filter((c) => c.company_type === "CARRIER").map((c) => <option key={c.uid} value={c.uid}>{c.legal_name}</option>)}
                </select>
              </Field>
              <ClassPick value={asg.class_code} onChange={(v) => setAsg({ ...asg, class_code: v })} classes={state.data?.classes ?? []} name={name} />
              <Field label={t("fares.document")}><input className="input" value={asg.source_document} onChange={(e) => setAsg({ ...asg, source_document: e.target.value })} /></Field>
              <div className="grid cols-2">
                <Field label={t("fares.from")}><input className="input" type="date" value={asg.assigned_on} onChange={(e) => setAsg({ ...asg, assigned_on: e.target.value })} /></Field>
                <Field label={t("fares.until")}><input className="input" type="date" value={asg.valid_until} onChange={(e) => setAsg({ ...asg, valid_until: e.target.value })} /></Field>
              </div>
            </>}
            {form === "band" && <>
              <ClassPick value={band.class_code} onChange={(v) => setBand({ ...band, class_code: v })} classes={state.data?.classes ?? []} name={name} />
              <Field label={t("fares.vehicleType")}>
                <select className="input" value={band.vehicle_type} onChange={(e) => setBand({ ...band, vehicle_type: e.target.value })}>
                  <option value="">{t("fares.anyVehicle")}</option>
                  {TYPES.map((v) => <option key={v} value={v}>{t(`fares.vt.${v}`)}</option>)}
                </select>
              </Field>
              <div className="grid cols-2">
                <Field label={t("fares.minKm")}><input className="input mono" inputMode="decimal" value={band.min_per_km} onChange={(e) => setBand({ ...band, min_per_km: e.target.value })} /></Field>
                <Field label={t("fares.maxKm")}><input className="input mono" inputMode="decimal" value={band.max_per_km} onChange={(e) => setBand({ ...band, max_per_km: e.target.value })} /></Field>
              </div>
              <Field label={t("fares.validFrom")}><input className="input" type="date" value={band.valid_from} onChange={(e) => setBand({ ...band, valid_from: e.target.value })} /></Field>
              <Field label={t("fares.document")}><input className="input" value={band.source_document} onChange={(e) => setBand({ ...band, source_document: e.target.value })} /></Field>
            </>}
          </div>
        </Modal>
      )}
    </div>
  );
}

function ClassPick({ value, onChange, classes, name }: { value: string; onChange: (v: string) => void; classes: Klass[]; name: (k: Klass) => string }) {
  const { t } = useI18n();
  return (
    <Field label={t("fares.class")}>
      <select className="input" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">—</option>
        {classes.filter((k) => k.status === "ACTIVE").map((k) => <option key={k.code} value={k.code}>{k.code} · {name(k)}</option>)}
      </select>
    </Field>
  );
}
