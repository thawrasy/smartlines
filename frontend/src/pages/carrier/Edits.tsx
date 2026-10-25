import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// Records are edited, and every edit is kept (owner's note, 1170). A vehicle's plate, chassis and engine numbers, and
// a person's names, birth date and national number, change only with a reason; a saved licence is corrected through a
// request that two people of the platform review and approve; a renewal is a new licence.

interface VehicleDetail {
  vehicle: { uid: string; plate_no: string; chassis_no: string; machine_no: string | null; vehicle_type: string; make: string | null; model: string | null;
    manufacture_year: number | null; passenger_seats: number; cargo_capacity_kg: number | null; fuel_tank_l: number | null; ownership_type: string;
    status: string; block_reason: string | null };
  licences: Licence[];
  history: { changed_at: string; field: string; old_value: string | null; new_value: string | null; reason: string | null; changed_by: string | null }[];
}
interface Licence { uid: string; license_type: string; license_no: string; issuer: string; issue_date: string; expiry_date: string; status: string }

const REGULATED = ["plate_no", "chassis_no", "machine_no"];
const HELD = ["BLOCKED", "IMPOUNDED"];

export function VehicleEditor({ uid, onClose }: { uid: string; onClose: () => void }) {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<VehicleDetail>(`/api/carrier/vehicles/${uid}`), [uid]);
  const [tab, setTab] = useState<"details" | "licences" | "history">("details");
  const [f, setF] = useState<Record<string, string> | null>(null);
  const [reason, setReason] = useState("");
  const [lic, setLic] = useState({ license_type: "INSPECTION", license_no: "", issuer: "", issue_date: "", expiry_date: "" });
  const [fixing, setFixing] = useState<Licence | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const v = state.data?.vehicle;
  const form = f ?? (v ? {
    plate_no: v.plate_no, chassis_no: v.chassis_no, machine_no: v.machine_no ?? "", vehicle_type: v.vehicle_type, make: v.make ?? "", model: v.model ?? "",
    manufacture_year: v.manufacture_year ? String(v.manufacture_year) : "", cargo_capacity_kg: v.cargo_capacity_kg != null ? String(v.cargo_capacity_kg) : "",
    fuel_tank_l: v.fuel_tank_l != null ? String(v.fuel_tank_l) : "", ownership_type: v.ownership_type, status: v.status } : null);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => form && setF({ ...form, [k]: e.target.value });
  const original = (k: string) => {
    if (!v) return "";
    const o = (v as unknown as Record<string, unknown>)[k];
    return o == null ? "" : String(o);
  };
  const changed = form ? Object.keys(form).filter((k) => form[k] !== original(k)) : [];
  const needsReason = changed.some((k) => REGULATED.includes(k));
  const act = async (fn: () => Promise<unknown>, after: () => void = () => undefined) => {
    setBusy(true); setError(null);
    try { await fn(); after(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const save = () => form && act(() => {
    const body: Record<string, unknown> = {};
    for (const k of changed) {
      const val = form[k].trim();
      body[k] = ["manufacture_year", "cargo_capacity_kg", "fuel_tank_l"].includes(k) ? (val ? Number(val) : null) : (val || null);
    }
    if (reason.trim()) body.reason = reason.trim();
    return api.patch(`/api/carrier/vehicles/${uid}`, body);
  }, () => { setF(null); setReason(""); });
  return (
    <Modal title={v ? t("edit.vehicleTitle", { plate: v.plate_no }) : t("edit.vehicle")} onClose={onClose} wide
           actions={<>
             <button className="btn text" onClick={onClose}>{t("common.close")}</button>
             {tab === "details" && <button className="btn" disabled={busy || changed.length === 0 || (needsReason && reason.trim().length < 3)} onClick={save}>{t("common.save")}</button>}
           </>}>
      <div className="stack">
        <div className="row" role="tablist" style={{ gap: 8 }}>
          {(["details", "licences", "history"] as const).map((k) => (
            <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "tonal"} small`} onClick={() => { setTab(k); setError(null); }}>{t(`edit.tab.${k}`)}</button>))}
        </div>
        <ErrorBox error={error} />
        <Loaded state={state}>{(d) => (<>
          {tab === "details" && form && (<>
            {HELD.includes(d.vehicle.status) && <div className="alert info"><Icon name="info" /><span>{t("edit.held", { reason: d.vehicle.block_reason ?? "—" })}</span></div>}
            <div className="grid cols-3">
              <Field label={t("carrier.plate")}><input className="input ltr" value={form.plate_no} onChange={set("plate_no")} /></Field>
              <Field label={t("carrier.chassis")}><input className="input ltr" value={form.chassis_no} onChange={set("chassis_no")} /></Field>
              <Field label={t("edit.machineNo")}><input className="input ltr" value={form.machine_no} onChange={set("machine_no")} /></Field>
              <Field label={t("carrier.vtype")}>
                <select className="input" value={form.vehicle_type} onChange={set("vehicle_type")}>
                  {["COACH", "MINIBUS", "CITY_BUS", "VAN"].map((k) => <option key={k} value={k}>{t(`carrier.vtypes.${k}`)}</option>)}
                </select></Field>
              <Field label={t("carrier.make")}><input className="input" value={form.make} onChange={set("make")} /></Field>
              <Field label={t("carrier.model")}><input className="input" value={form.model} onChange={set("model")} /></Field>
              <Field label={t("carrier.year")}><input className="input ltr" inputMode="numeric" maxLength={4} value={form.manufacture_year} onChange={set("manufacture_year")} /></Field>
              <Field label={t("edit.cargoKg")}><input className="input ltr" inputMode="numeric" value={form.cargo_capacity_kg} onChange={set("cargo_capacity_kg")} /></Field>
              <Field label={t("edit.fuelTank")}><input className="input ltr" inputMode="numeric" value={form.fuel_tank_l} onChange={set("fuel_tank_l")} /></Field>
              <Field label={t("edit.ownership")}>
                <select className="input" value={form.ownership_type} onChange={set("ownership_type")}>
                  {["OWNED", "LEASED"].map((k) => <option key={k} value={k}>{t(`edit.own.${k}`)}</option>)}
                </select></Field>
              <Field label={t("common.status")}>
                <select className="input" value={form.status} onChange={set("status")} disabled={HELD.includes(d.vehicle.status)}>
                  {(HELD.includes(d.vehicle.status) ? [d.vehicle.status] : ["ACTIVE", "OUT_OF_SERVICE", "RETIRED"]).map((k) => <option key={k} value={k}>{t(`edit.vstatus.${k}`)}</option>)}
                </select></Field>
            </div>
            <Field label={needsReason ? t("edit.reasonRequired") : `${t("edit.reason")} (${t("common.optional")})`} hint={t("edit.reasonHint")}>
              <input className="input" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </>)}
          {tab === "licences" && (<>
            {d.licences.length === 0 ? <Empty icon="badge" title={t("crew.noLicences")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("crew.licType")}</th><th>{t("crew.licNo")}</th><th>{t("crew.validity")}</th><th>{t("common.status")}</th><th /></tr></thead>
                <tbody>{d.licences.map((l) => (
                  <tr key={l.uid}><td>{t(`edit.lic.${l.license_type}`)}</td><td className="mono ltr small">{l.license_no}<div className="muted">{l.issuer}</div></td>
                    <td className="small ltr">{l.issue_date} → {l.expiry_date}</td><td><Status value={l.status} /></td>
                    <td><button className="btn text small" onClick={() => { setError(null); setFixing(l); }}>{t("edit.correct")}</button></td></tr>))}</tbody>
              </table></div>)}
            <div className="card stack" style={{ gap: 8 }}>
              <strong>{t("edit.addLicence")}</strong>
              <div className="grid cols-3">
                <Field label={t("crew.licType")}>
                  <select className="input" value={lic.license_type} onChange={(e) => setLic({ ...lic, license_type: e.target.value })}>
                    {["TRANSPORT", "INSPECTION", "INSURANCE", "OTHER"].map((k) => <option key={k} value={k}>{t(`edit.lic.${k}`)}</option>)}
                  </select></Field>
                <Field label={t("crew.licNo")}><input className="input ltr" value={lic.license_no} onChange={(e) => setLic({ ...lic, license_no: e.target.value })} /></Field>
                <Field label={t("crew.issuer")}><input className="input" value={lic.issuer} onChange={(e) => setLic({ ...lic, issuer: e.target.value })} /></Field>
                <Field label={t("crew.issueDate")}><input className="input ltr" type="date" value={lic.issue_date} onChange={(e) => setLic({ ...lic, issue_date: e.target.value })} /></Field>
                <Field label={t("crew.expiryDate")}><input className="input ltr" type="date" value={lic.expiry_date} onChange={(e) => setLic({ ...lic, expiry_date: e.target.value })} /></Field>
              </div>
              <div><button className="btn tonal" disabled={busy || lic.license_no.trim().length < 3 || lic.issuer.trim().length < 2 || !lic.issue_date || !lic.expiry_date}
                onClick={() => act(() => api.post(`/api/carrier/vehicles/${uid}/licences`, lic), () => setLic({ ...lic, license_no: "", issue_date: "", expiry_date: "" }))}>
                <Icon name="add" />{t("edit.addLicence")}</button></div>
              <div className="small muted">{t("edit.renewHint")}</div>
            </div>
          </>)}
          {tab === "history" && (d.history.length === 0 ? <Empty icon="history" title={t("edit.noHistory")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("edit.when")}</th><th>{t("edit.field")}</th><th>{t("edit.before")}</th><th>{t("edit.after")}</th><th>{t("edit.reason")}</th><th>{t("edit.by")}</th></tr></thead>
              <tbody>{d.history.map((h, i) => (
                <tr key={i}><td className="small">{date(h.changed_at)}</td><td>{t(`edit.f.${h.field}`)}</td>
                  <td className="small ltr">{h.old_value ?? "—"}</td><td className="small ltr">{h.new_value ?? "—"}</td>
                  <td className="small">{h.reason ?? "—"}</td><td className="small ltr">{h.changed_by ?? "—"}</td></tr>))}</tbody>
            </table></div>))}
        </>)}</Loaded>
      </div>
      {fixing && <LicenceCorrection licence={fixing} onClose={() => setFixing(null)} />}
    </Modal>
  );
}

/** A correction of a saved licence: it waits for two people of the platform, then the licence carries it. */
export function LicenceCorrection({ licence, onClose }: { licence: Licence; onClose: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [f, setF] = useState({ license_no: licence.license_no, issuer: licence.issuer, issue_date: licence.issue_date, expiry_date: licence.expiry_date, reason: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const changes = (Object.keys(f) as (keyof typeof f)[]).filter((k) => k !== "reason" && f[k] !== (licence as unknown as Record<string, string>)[k]);
  const send = async () => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/carrier/licences/${licence.uid}/change-request`,
        { ...Object.fromEntries(changes.map((k) => [k, f[k].trim()])), reason: f.reason.trim() });
      toast(t("edit.correctionSent")); onClose();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("edit.correctTitle", { no: licence.license_no })} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || changes.length === 0 || f.reason.trim().length < 3} onClick={send}>{t("edit.sendCorrection")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <p className="small muted" style={{ margin: 0 }}>{t("edit.correctHint")}</p>
        <div className="grid cols-2">
          <Field label={t("crew.licNo")}><input className="input ltr" value={f.license_no} onChange={(e) => setF({ ...f, license_no: e.target.value })} /></Field>
          <Field label={t("crew.issuer")}><input className="input" value={f.issuer} onChange={(e) => setF({ ...f, issuer: e.target.value })} /></Field>
          <Field label={t("crew.issueDate")}><input className="input ltr" type="date" value={f.issue_date} onChange={(e) => setF({ ...f, issue_date: e.target.value })} /></Field>
          <Field label={t("crew.expiryDate")}><input className="input ltr" type="date" value={f.expiry_date} onChange={(e) => setF({ ...f, expiry_date: e.target.value })} /></Field>
        </div>
        <Field label={t("edit.reasonRequired")}><input className="input" maxLength={500} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

interface CrewPerson { uid: string; first_name: string | null; father_name: string | null; grandfather_name: string | null; last_name: string | null;
  mother_name: string | null; birth_date: string | null; id_no_last4: string | null; crew_type: string; license_class: string | null; status: string }

const IDENTITY = ["first_name", "father_name", "grandfather_name", "last_name", "mother_name", "national_id", "birth_date"];

export function CrewEditor({ uid, onClose }: { uid: string; onClose: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<CrewPerson>(`/api/carrier/crew/${uid}`), [uid]);
  const [f, setF] = useState<Record<string, string> | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const p = state.data;
  const base: Record<string, string> | null = p ? {
    first_name: p.first_name ?? "", father_name: p.father_name ?? "", grandfather_name: p.grandfather_name ?? "", last_name: p.last_name ?? "",
    mother_name: p.mother_name ?? "", birth_date: p.birth_date ?? "", national_id: "", mobile: "", crew_type: p.crew_type,
    license_class: p.license_class ?? "", status: p.status } : null;
  const form = f ?? base;
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => form && setF({ ...form, [k]: e.target.value });
  const changed = form && base ? Object.keys(form).filter((k) => form[k] !== base[k]) : [];
  const needsReason = changed.some((k) => IDENTITY.includes(k));
  const save = async () => {
    if (!form) return;
    setBusy(true); setError(null);
    try {
      const body: Record<string, unknown> = Object.fromEntries(changed.map((k) => [k, form[k].trim() || null]));
      if (reason.trim()) body.reason = reason.trim();
      await api.patch(`/api/carrier/crew/${uid}`, body);
      toast(t("common.saved")); onClose();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("edit.crewTitle")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || changed.length === 0 || (needsReason && reason.trim().length < 3)} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Loaded state={state}>{(d) => form && (<>
          <div className="grid cols-3">
            <Field label={t("crew.first")}><input className="input" value={form.first_name} onChange={set("first_name")} /></Field>
            <Field label={t("crew.father")}><input className="input" value={form.father_name} onChange={set("father_name")} /></Field>
            <Field label={t("crew.grandfather")}><input className="input" value={form.grandfather_name} onChange={set("grandfather_name")} /></Field>
            <Field label={t("crew.last")}><input className="input" value={form.last_name} onChange={set("last_name")} /></Field>
            <Field label={t("crew.mother")}><input className="input" value={form.mother_name} onChange={set("mother_name")} /></Field>
            <Field label={t("crew.birthDate")}><input className="input ltr" type="date" value={form.birth_date} onChange={set("birth_date")} /></Field>
            <Field label={t("crew.nationalId")} hint={d.id_no_last4 ? t("edit.nationalIdKept", { last4: d.id_no_last4 }) : t("crew.nationalIdHint")}>
              <input className="input ltr" autoComplete="off" value={form.national_id} onChange={set("national_id")} /></Field>
            <Field label={`${t("common.mobile")} (${t("common.optional")})`}><input className="input ltr" value={form.mobile} onChange={set("mobile")} /></Field>
            <Field label={t("crew.kind")}>
              <select className="input" value={form.crew_type} onChange={set("crew_type")}>
                {["DRIVER", "HOST", "ASSISTANT"].map((k) => <option key={k} value={k}>{t(`crew.kinds.${k}`)}</option>)}
              </select></Field>
            <Field label={t("carrier.licenseClass")}><input className="input ltr" value={form.license_class} onChange={set("license_class")} /></Field>
            <Field label={t("common.status")}>
              <select className="input" value={form.status} onChange={set("status")} disabled={d.status === "BLOCKED"}>
                {(d.status === "BLOCKED" ? ["BLOCKED"] : ["ACTIVE", "LEFT"]).map((k) => <option key={k} value={k}>{t(`edit.cstatus.${k}`)}</option>)}
              </select></Field>
          </div>
          <Field label={needsReason ? t("edit.reasonRequired") : `${t("edit.reason")} (${t("common.optional")})`} hint={t("edit.crewReasonHint")}>
            <input className="input" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        </>)}</Loaded>
      </div>
    </Modal>
  );
}
