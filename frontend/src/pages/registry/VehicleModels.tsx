import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

export interface VModel { uid: string; make_uid: string; name: string; vehicle_class: string; vehicle_type: string; seats_from: number | null;
                          seats_to: number | null; weight_class: string | null; production: string; confidence: string; status: string;
                          source?: string; notes?: string | null; entered_name?: string | null; reviewed_name?: string | null }
export interface VMake { uid: string; code: string; name_en: string; name_ar: string; country_code: string | null; status: string;
                         source?: string; entered_name?: string | null; reviewed_name?: string | null; models: VModel[] }
interface VRequest { uid: string; company_name: string; make: string; model_name: string; vehicle_type: string; seats: number | null;
                     note: string | null; status: string; decision_note: string | null; model: string | null; created_at: string; make_id?: never }

const TYPES = ["COACH", "MINIBUS", "CITY_BUS", "VAN", "TRAIN_SET", "OTHER"];

/** The platform's list of vehicle makes and models (owner's request N8, 1157): entries reviewed by a second person,
 *  the owner's table imported for review, and carriers' requests for a missing model. */
export function VehicleModels() {
  const { t, locale, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ makes: VMake[] }>("/api/admin/vehicle-models").then((r) => r.makes));
  const reqs = useLoad(() => api.get<{ requests: VRequest[] }>("/api/admin/vehicle-models/requests").then((r) => r.requests));
  const [filter, setFilter] = useState("");
  const [addMake, setAddMake] = useState(false);
  const [addModel, setAddModel] = useState<VMake | null>(null);
  const [decide, setDecide] = useState<VRequest | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const file = useRef<HTMLInputElement>(null);
  const act = async (fn: () => Promise<unknown>, done?: string) => {
    setBusy(true); setError(null);
    try { await fn(); if (done) toast(done); state.reload(); reqs.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const load = async (f: File) => {
    const form = new FormData();
    form.append("file", f);
    await act(async () => {
      const out = await api.upload<{ makes: number; models: number; skipped: number }>("/api/admin/vehicle-models/import", form);
      toast(t("vm.imported", { m: out.makes, n: out.models, s: out.skipped }));
    });
    if (file.current) file.current.value = "";
  };
  const review = (kind: "makes" | "models", uid: string, decision: "ACCEPT" | "REJECT") =>
    act(() => api.post(`/api/admin/vehicle-models/${kind}/${uid}/review`, { decision }), decision === "ACCEPT" ? t("reg.accepted") : t("reg.rejected"));
  const seats = (m: VModel) => m.vehicle_class === "TRUCK" ? (m.weight_class ? t(`vm.weight.${m.weight_class}`) : "—")
    : m.seats_from ? (m.seats_to && m.seats_to !== m.seats_from ? `${m.seats_from}–${m.seats_to}` : `${m.seats_from}`) : "—";
  return (
    <div className="stack">
      <div className="card">
        <div className="card-title" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3>{t("vm.title")}</h3>
          <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
            <input className="input" style={{ width: 200, maxWidth: "100%" }} aria-label={t("common.search")} placeholder={t("common.search")} value={filter} onChange={(e) => setFilter(e.target.value)} />
            <input ref={file} type="file" accept=".xlsx" hidden aria-label={t("reg.import")} onChange={(e) => e.target.files?.[0] && load(e.target.files[0])} />
            <button className="btn outlined small" disabled={busy} onClick={() => file.current?.click()}><Icon name="upload_file" />{t("reg.import")}</button>
            <button className="btn small" onClick={() => { setError(null); setAddMake(true); }}><Icon name="add" />{t("vm.addMake")}</button>
          </div>
        </div>
        <p className="small muted">{t("vm.hint")}</p>
        <ErrorBox error={!addMake && !addModel && !decide ? error : null} />
        <Loaded state={state}>{(makes) => {
          const q = filter.trim().toLowerCase();
          const shown = q ? makes.filter((k) => `${k.name_en} ${k.name_ar} ${k.models.map((m) => m.name).join(" ")}`.toLowerCase().includes(q)) : makes;
          return shown.length === 0 ? <Empty icon="directions_car" title={t("common.noData")} /> : (
            <div className="stack">{shown.map((k) => (
              <details key={k.uid} className="card flat">
                <summary className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
                  <span><b>{locale === "ar" ? k.name_ar : k.name_en}</b> <span className="muted small">{locale === "ar" ? k.name_en : k.name_ar} · {k.country_code ?? "—"} · {t("vm.count", { n: k.models.length })}</span></span>
                  <span className="row" style={{ gap: 4, flexWrap: "wrap" }}>
                    <Status value={k.status} />
                    {k.status === "PENDING_REVIEW" && <>
                      <button className="btn tonal small" disabled={busy} onClick={() => review("makes", k.uid, "ACCEPT")}>{t("reg.accept")}</button>
                      <button className="btn text small" disabled={busy} onClick={() => review("makes", k.uid, "REJECT")}>{t("admin.reject")}</button></>}
                    {(k.status === "ACTIVE" || k.status === "PENDING_REVIEW") &&
                      <button className="btn text small" onClick={() => { setError(null); setAddModel(k); }}><Icon name="add" />{t("vm.addModel")}</button>}
                  </span>
                </summary>
                {k.models.length > 0 && <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("vm.model")}</th><th>{t("vm.kind")}</th><th>{t("vm.seats")}</th><th>{t("vm.confidence")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                  <tbody>{k.models.map((m) => (
                    <tr key={m.uid}>
                      <td>{m.name}{m.source === "IMPORT" && <span className="chip small">{t("reg.fromFile")}</span>}
                        {m.notes && <div className="small muted">{m.notes}</div>}</td>
                      <td className="small">{t(`vm.class.${m.vehicle_class}`)}{m.vehicle_class !== "TRUCK" && <> · {t(`carrier.vtypes.${m.vehicle_type}`)}</>}
                        {m.production === "OLDER" && <div className="muted">{t("vm.older")}</div>}</td>
                      <td className="num">{seats(m)}</td>
                      <td className="small">{t(`vm.conf.${m.confidence}`)}</td>
                      <td><Status value={m.status} /></td>
                      <td><div className="row" style={{ gap: 4, flexWrap: "wrap" }}>
                        {m.status === "PENDING_REVIEW" && <>
                          <button className="btn tonal small" disabled={busy} onClick={() => review("models", m.uid, "ACCEPT")}>{t("reg.accept")}</button>
                          <button className="btn text small" disabled={busy} onClick={() => review("models", m.uid, "REJECT")}>{t("admin.reject")}</button></>}
                        {m.status === "ACTIVE" && <button className="btn text small" disabled={busy}
                          onClick={() => act(() => api.post(`/api/admin/vehicle-models/models/${m.uid}/retire`), t("common.saved"))}>{t("reg.retire")}</button>}
                      </div></td>
                    </tr>
                  ))}</tbody>
                </table></div>}
              </details>
            ))}</div>
          );
        }}</Loaded>
      </div>
      <div className="card">
        <div className="card-title"><h3>{t("vm.requests")}</h3></div>
        <Loaded state={reqs}>{(list) => list.length === 0 ? <Empty icon="directions_bus" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("vm.company")}</th><th>{t("vm.asked")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{list.map((r) => (
              <tr key={r.uid}>
                <td className="small">{dateTime(r.created_at)}</td><td>{r.company_name}</td>
                <td>{r.make} {r.model_name} <span className="small muted">· {t(`carrier.vtypes.${r.vehicle_type}`)}{r.seats ? ` · ${r.seats}` : ""}</span>
                  {r.note && <div className="small muted">{r.note}</div>}{r.model && <div className="small">→ {r.model}</div>}
                  {r.decision_note && <div className="small muted">{r.decision_note}</div>}</td>
                <td><Status value={r.status} /></td>
                <td>{r.status === "SUBMITTED" && <button className="btn tonal small" onClick={() => { setError(null); setDecide(r); }}>{t("vm.decide")}</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {addMake && <MakeForm onClose={() => setAddMake(false)} onDone={() => { setAddMake(false); state.reload(); }} />}
      {addModel && <ModelForm make={addModel} onClose={() => setAddModel(null)} onDone={() => { setAddModel(null); state.reload(); }} />}
      {decide && <DecideForm req={decide} makes={state.data ?? []} onClose={() => setDecide(null)} onDone={() => { setDecide(null); state.reload(); reqs.reload(); }} />}
    </div>
  );
}

function MakeForm({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({ name_en: "", name_ar: "", country_code: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/admin/vehicle-models/makes", { ...f, country_code: f.country_code.toUpperCase() || null }); onDone(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("vm.addMake")} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || f.name_en.length < 2 || f.name_ar.length < 2} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Field label={t("reg.f.name_en")}><input className="input" value={f.name_en} onChange={(e) => setF({ ...f, name_en: e.target.value })} /></Field>
        <Field label={t("reg.f.name_ar")}><input className="input" dir="rtl" value={f.name_ar} onChange={(e) => setF({ ...f, name_ar: e.target.value })} /></Field>
        <Field label={t("vm.country")} hint="DE, CN, TR…"><input className="input ltr" maxLength={2} value={f.country_code} onChange={(e) => setF({ ...f, country_code: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function ModelForm({ make, onClose, onDone }: { make: VMake; onClose: () => void; onDone: () => void }) {
  const { t, locale } = useI18n();
  const [f, setF] = useState({ name: "", vehicle_class: "BUS", vehicle_type: "COACH", seats_from: "", seats_to: "", weight_class: "", production: "CURRENT", confidence: "VERIFY", notes: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const truck = f.vehicle_class === "TRUCK";
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/admin/vehicle-models/models", { make_uid: make.uid, name: f.name, vehicle_class: f.vehicle_class,
        vehicle_type: truck ? "OTHER" : f.vehicle_type, seats_from: f.seats_from ? Number(f.seats_from) : null, seats_to: f.seats_to ? Number(f.seats_to) : null,
        weight_class: truck && f.weight_class ? f.weight_class : null, production: f.production, confidence: f.confidence, notes: f.notes || null });
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const sel = (k: keyof typeof f, opts: string[], label: (o: string) => string) => (
    <select className="input" value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })}>{opts.map((o) => <option key={o} value={o}>{label(o)}</option>)}</select>);
  return (
    <Modal title={`${t("vm.addModel")} · ${locale === "ar" ? make.name_ar : make.name_en}`} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !f.name.trim()} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div className="grid cols-2">
          <Field label={t("vm.model")}><input className="input ltr" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <Field label={t("vm.kind")}>{sel("vehicle_class", ["BUS", "TRUCK", "TRAIN", "CAR", "OTHER"], (o) => t(`vm.class.${o}`))}</Field>
          {!truck && <Field label={t("carrier.vtype")}>{sel("vehicle_type", TYPES, (o) => t(`carrier.vtypes.${o}`))}</Field>}
          {truck ? <Field label={t("vm.weightClass")}>{sel("weight_class", ["", "LIGHT", "MEDIUM", "HEAVY"], (o) => o ? t(`vm.weight.${o}`) : "—")}</Field> : <>
            <Field label={t("vm.seatsFrom")}><input className="input ltr" type="number" min={1} value={f.seats_from} onChange={(e) => setF({ ...f, seats_from: e.target.value })} /></Field>
            <Field label={t("vm.seatsTo")}><input className="input ltr" type="number" min={1} value={f.seats_to} onChange={(e) => setF({ ...f, seats_to: e.target.value })} /></Field></>}
          <Field label={t("vm.production")}>{sel("production", ["CURRENT", "OLDER"], (o) => t(`vm.prod.${o}`))}</Field>
          <Field label={t("vm.confidence")}>{sel("confidence", ["VERIFY", "MEDIUM", "HIGH"], (o) => t(`vm.conf.${o}`))}</Field>
        </div>
        <Field label={t("reg.f.notes")}><textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function DecideForm({ req, makes, onClose, onDone }: { req: VRequest; makes: VMake[]; onClose: () => void; onDone: () => void }) {
  const { t, locale } = useI18n();
  const [decision, setDecision] = useState<"APPROVE" | "MATCH" | "REJECT">("APPROVE");
  const [modelUid, setModelUid] = useState("");
  const [nameAr, setNameAr] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const knownMake = makes.some((k) => k.name_en.toLowerCase() === req.make.toLowerCase());
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/admin/vehicle-models/requests/${req.uid}/decide`, { decision, model_uid: decision === "MATCH" ? modelUid : null,
        make_name_ar: decision === "APPROVE" && nameAr ? nameAr : null, note: note.trim() || null });
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${t("vm.decide")} · ${req.make} ${req.model_name}`} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || (decision === "MATCH" && !modelUid) || (decision === "REJECT" && note.trim().length < 3)} onClick={save}>{t("common.confirm")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div className="segmented" role="radiogroup" aria-label={t("vm.decide")} style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
          {(["APPROVE", "MATCH", "REJECT"] as const).map((d) => (
            <button key={d} type="button" role="radio" aria-checked={decision === d} className={decision === d ? "on" : ""} onClick={() => setDecision(d)}>{t(`vm.d.${d}`)}</button>))}
        </div>
        {decision === "APPROVE" && <>
          <p className="small muted">{t("vm.approveNote")}</p>
          {!knownMake && <Field label={t("vm.makeNameAr")}><input className="input" dir="rtl" value={nameAr} onChange={(e) => setNameAr(e.target.value)} /></Field>}
        </>}
        {decision === "MATCH" && <Field label={t("vm.model")}>
          <select className="input" value={modelUid} onChange={(e) => setModelUid(e.target.value)}>
            <option value="">{t("finance.choose")}</option>
            {makes.flatMap((k) => k.models.filter((m) => m.status === "ACTIVE" || m.status === "PENDING_REVIEW").map((m) =>
              <option key={m.uid} value={m.uid}>{locale === "ar" ? k.name_ar : k.name_en} {m.name}</option>))}
          </select></Field>}
        <Field label={decision === "REJECT" ? t("common.reason") : t("reg.f.notes")}><textarea className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      </div>
    </Modal>
  );
}
