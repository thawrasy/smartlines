import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// The boarding photo policy (1086-1111), for platform staff with privacy.manage: the switch and its settings, the rules
// that require a photo, the changes to the policy, and the replacement of a photo on file. Every change passes the
// approval stages set by the platform; the one who asks is never one of them, and nothing changes before the last stage.

interface Settings {
  enabled: boolean; view_access: unknown; verify_every_days: unknown; enforce_from: unknown; identity_provider: unknown;
  kinds: { code: string; label: string; active: boolean; age_rule: string | null }[]; identity_card_min_age: number | null;
  approval_stages: string[]; data_requirements: { field_code: string; label: string; requirement: string }[];
}
interface Rule {
  uid: string; market: string | null; trip_scope: string | null; traveller_class: string | null; passenger_category: string | null;
  requirement: string; effective_from: string; effective_to: string | null; legal_basis: string; status: string; approvals: number;
  stages: string[] | null; retirement_reason: string | null; retirement_approvals: number; retirement_stages: string[] | null;
}
interface PolicyChange {
  uid: string; change_type: string; evidence_code: string | null; new_active: boolean | null; new_min_age: number | null;
  field_code: string | null; new_requirement: string | null; reason: string; legal_basis: string | null; legal_document_no: string | null;
  status: string; requested_at: string; requested_by: string; approvals: number; stages: string[] | null;
}
interface PhotoChange { uid: string; party_uid: string; requested_by: string; evidence_kind: string; status: string; reason: string; created_at: string }

type Tab = "settings" | "rules" | "policy" | "changes";
const SETTING_KEYS = ["photo.view_access", "photo.verify_every_days", "photo.enforce_from", "photo.identity_provider"] as const;

export function AdminPhotoPolicy() {
  const { t } = useI18n();
  const [tab, setTab] = useState<Tab>("settings");
  return (
    <div className="stack">
      <PageHead title={t("photo.title")} sub={t("photo.sub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {(["settings", "rules", "policy", "changes"] as Tab[]).map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`photo.tab.${v}`)}</button>
        ))}
      </div>
      {tab === "settings" && <PhotoSettings />}
      {tab === "rules" && <PhotoRules />}
      {tab === "policy" && <PolicyChanges />}
      {tab === "changes" && <PhotoChanges />}
    </div>
  );
}

function useRun() {
  const toast = useToast();
  const { t } = useI18n();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, done: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); toast(t("photo.sent")); done(); return true; } catch (e) { setError(e); return false; } finally { setBusy(false); }
  };
  return { busy, error, setError, run };
}

const show = (v: unknown) => (v == null ? "—" : typeof v === "string" ? v : JSON.stringify(v));

// A setting in plain terms: who may see the photo as chips, a provider by name, an empty value as a dash
function SettingValue({ value }: { value: unknown }) {
  const { t, has } = useI18n();
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return <span className="row" style={{ gap: 6, flexWrap: "wrap" }}>{Object.entries(value as Record<string, unknown>).map(([k, on]) => (
      <span key={k} className={`chip ${on ? "green" : "outline"}`}><Icon name={on ? "check" : "close"} size={16} />{has(`photo.viewer.${k}`) ? t(`photo.viewer.${k}`) : k}</span>))}</span>;
  }
  if (value == null || value === "NONE") return <span className="muted">{t("photo.noneSet")}</span>;
  return <span className="mono ltr">{show(value)}</span>;
}

// ------------------------------------------------------------------ the switch and its settings
function PhotoSettings() {
  const { t } = useI18n();
  const state = useLoad((signal) => api.get<Settings>("/api/admin/photos/evidence-kinds", undefined, { signal }));
  const { busy, error, run } = useRun();
  const [ask, setAsk] = useState<null | { kind: "feature" | "kind" | "age" | "field" | "setting" | "stages"; code?: string }>(null);
  const [f, setF] = useState({ reason: "", legal_basis: "", value: "", age: "", requirement: "REQUIRED", key: SETTING_KEYS[0] as string, stages: "CHECK,APPROVE" });
  const close = () => setAsk(null);
  const submit = (d: Settings) => {
    if (!ask) return;
    const calls: Record<string, () => Promise<unknown>> = {
      feature: () => api.post("/api/admin/photos/feature/changes", { enabled: !d.enabled, legal_basis: f.legal_basis, reason: f.reason }),
      kind: () => api.post(`/api/admin/photos/evidence-kinds/${ask.code}/changes`, { active: !d.kinds.find((k) => k.code === ask.code)?.active, reason: f.reason }),
      age: () => api.post("/api/admin/photos/identity-age/changes", { min_age: f.age === "" ? null : Number(f.age), reason: f.reason }),
      field: () => api.post(`/api/admin/photos/data-requirements/${ask.code}/changes`, { requirement: f.requirement, reason: f.reason }),
      setting: () => api.post("/api/admin/photos/settings/changes", { key: f.key, value: parseValue(f.value), reason: f.reason }),
      stages: () => api.put("/api/admin/photos/settings/approval-stages", { stages: f.stages.split(",").map((s) => s.trim()).filter(Boolean) }),
    };
    void run(calls[ask.kind], () => { close(); state.reload(); });
  };
  return (
    <Loaded state={state}>{(d) => (
      <div className="stack">
        <ErrorBox error={error} />
        <div className="card stack">
          <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
            <div><h3 style={{ margin: 0 }}>{t("photo.feature")}</h3><p className="small muted" style={{ margin: 0 }}>{t("photo.featureHint")}</p></div>
            <div className="row" style={{ gap: 8, alignItems: "center", flexWrap: "wrap" }}>
              <span className={`chip ${d.enabled ? "green" : ""}`}>{t(d.enabled ? "photo.on" : "photo.off")}</span>
              <button className="btn outlined" onClick={() => setAsk({ kind: "feature" })}>{t(d.enabled ? "photo.askOff" : "photo.askOn")}</button>
            </div>
          </div>
          <div className="small muted">{t("photo.stagesNow", { stages: d.approval_stages.map((s) => t(`photo.stage.${s}`)).join(" → ") })}
            {" "}<button className="btn text small" onClick={() => { setF({ ...f, stages: d.approval_stages.join(",") }); setAsk({ kind: "stages" }); }}>{t("photo.setStages")}</button></div>
        </div>
        <div className="card stack">
          <h3 style={{ margin: 0 }}>{t("photo.settings")}</h3>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <tbody>
              {SETTING_KEYS.map((k) => (
                <tr key={k}><td>{t(`photo.key.${k.split(".")[1]}`)}</td><td className="small"><SettingValue value={(d as unknown as Record<string, unknown>)[k.split(".")[1]]} /></td>
                  <td><button className="btn text small" onClick={() => { setF({ ...f, key: k, value: show((d as unknown as Record<string, unknown>)[k.split(".")[1]]) }); setAsk({ kind: "setting" }); }}>{t("photo.askChange")}</button></td></tr>
              ))}
              <tr><td>{t("photo.minAge")}</td><td>{d.identity_card_min_age ?? "—"}</td>
                <td><button className="btn text small" onClick={() => { setF({ ...f, age: d.identity_card_min_age?.toString() ?? "" }); setAsk({ kind: "age" }); }}>{t("photo.askChange")}</button></td></tr>
            </tbody>
          </table></div>
        </div>
        <div className="grid cols-2">
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("photo.kinds")}</h3>
            {d.kinds.map((k) => (
              <div key={k.code} className="row" style={{ justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                <span>{k.label} <span className="small muted mono ltr">{k.code}</span></span>
                <span className="row" style={{ gap: 6 }}><span className={`chip ${k.active ? "green" : ""}`}>{t(k.active ? "photo.accepted" : "photo.notAccepted")}</span>
                  <button className="btn text small" onClick={() => setAsk({ kind: "kind", code: k.code })}>{t("photo.askChange")}</button></span>
              </div>
            ))}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("photo.data")}</h3>
            {d.data_requirements.map((x) => (
              <div key={x.field_code} className="row" style={{ justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                <span>{x.label}</span>
                <span className="row" style={{ gap: 6 }}><span className="chip">{t(`photo.req.${x.requirement}`)}</span>
                  <button className="btn text small" onClick={() => { setF({ ...f, requirement: x.requirement === "REQUIRED" ? "OPTIONAL" : "REQUIRED" }); setAsk({ kind: "field", code: x.field_code }); }}>{t("photo.askChange")}</button></span>
              </div>
            ))}
          </div>
        </div>
        {ask && (
          <Modal title={t(`photo.ask.${ask.kind}`)} onClose={close}
                 actions={<><button className="btn text" onClick={close}>{t("common.cancel")}</button>
                   <button className="btn filled" disabled={busy || (ask.kind !== "stages" && f.reason.trim().length < 10) || (ask.kind === "feature" && !d.enabled && f.legal_basis.trim().length < 10)}
                           onClick={() => submit(d)}>{t(ask.kind === "stages" ? "common.save" : "photo.send")}</button></>}>
            <div className="stack">
              <ErrorBox error={error} />
              {ask.kind !== "stages" && <p className="small muted" style={{ margin: 0 }}>{t("photo.askHint")}</p>}
              {ask.kind === "feature" && <Field label={t("photo.legalBasis")}><input className="input" value={f.legal_basis} onChange={(e) => setF({ ...f, legal_basis: e.target.value })} /></Field>}
              {ask.kind === "age" && <Field label={t("photo.minAge")} hint={t("photo.minAgeHint")}><input className="input ltr" type="number" min={0} max={120} value={f.age} onChange={(e) => setF({ ...f, age: e.target.value })} /></Field>}
              {ask.kind === "field" && <Field label={t("photo.requirement")}>
                <select className="input" value={f.requirement} onChange={(e) => setF({ ...f, requirement: e.target.value })}>
                  <option value="REQUIRED">{t("photo.req.REQUIRED")}</option><option value="OPTIONAL">{t("photo.req.OPTIONAL")}</option></select></Field>}
              {ask.kind === "setting" && <Field label={t(`photo.key.${f.key.split(".")[1]}`)} hint={t("photo.valueHint")}>
                <input className="input mono ltr" value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} /></Field>}
              {ask.kind === "stages" && <Field label={t("photo.stagesLabel")} hint={t("photo.stagesHint")}>
                <input className="input mono ltr" value={f.stages} onChange={(e) => setF({ ...f, stages: e.target.value.toUpperCase() })} /></Field>}
              {ask.kind !== "stages" && <Field label={t("photo.reason")}><textarea className="input" rows={2} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>}
            </div>
          </Modal>
        )}
      </div>
    )}</Loaded>
  );
}

function parseValue(v: string): unknown {
  try { return JSON.parse(v); } catch { return v; }
}

// ------------------------------------------------------------------ the rules that require a photo
function PhotoRules() {
  const { t, date } = useI18n();
  const state = useLoad((signal) => api.get<{ rules: Rule[] }>("/api/admin/photos/rules", undefined, { signal }));
  const { busy, error, setError, run } = useRun();
  const blank = { market: "SY", trip_scope: "", traveller_class: "", passenger_category: "", requirement: "REQUIRED",
                  effective_from: new Date().toISOString().slice(0, 10), legal_basis: "" };
  const [f, setF] = useState(blank);
  const [open, setOpen] = useState(false);
  const [retiring, setRetiring] = useState<Rule | null>(null);
  const [reason, setReason] = useState("");
  const act = (r: Rule, path: string) => run(() => api.post(`/api/admin/photos/rules/${r.uid}/${path}`), () => state.reload());
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
        <p className="small muted" style={{ margin: 0 }}>{t("photo.rulesHint")}</p>
        <button className="btn" onClick={() => { setOpen(true); setError(null); }}><Icon name="add" />{t("photo.propose")}</button>
      </div>
      <ErrorBox error={error} />
      <Loaded state={state}>{({ rules }) => (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("photo.applies")}</th><th>{t("photo.requirement")}</th><th>{t("photo.from")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{rules.map((r) => (
            <tr key={r.uid}>
              <td className="small">{[r.market, r.trip_scope && t(`photo.scope.${r.trip_scope}`), r.traveller_class && t(`photo.class.${r.traveller_class}`), r.passenger_category].filter(Boolean).join(" · ") || t("photo.everyone")}
                <div className="muted">{r.legal_basis}</div></td>
              <td>{t(`photo.req.${r.requirement}`)}</td>
              <td>{date(`${r.effective_from}T12:00:00Z`)}</td>
              <td><Status value={r.status} /><div className="small muted">{r.status === "RETIRING"
                ? t("photo.approvals", { n: r.retirement_approvals, of: r.retirement_stages?.length ?? 0 })
                : r.status === "PROPOSED" ? t("photo.approvals", { n: r.approvals, of: r.stages?.length ?? 0 }) : ""}</div></td>
              <td className="row" style={{ gap: 4, justifyContent: "flex-end" }}>
                {r.status === "PROPOSED" && <><button className="btn text small" disabled={busy} onClick={() => act(r, "approve")}>{t("photo.approve")}</button>
                  <button className="btn text small" disabled={busy} onClick={() => act(r, "withdraw")}>{t("photo.withdraw")}</button></>}
                {r.status === "APPROVED" && <button className="btn text small" onClick={() => { setRetiring(r); setReason(""); }}>{t("photo.retire")}</button>}
                {r.status === "RETIRING" && <><button className="btn text small" disabled={busy} onClick={() => act(r, "retirement/approve")}>{t("photo.approve")}</button>
                  <button className="btn text small" disabled={busy} onClick={() => act(r, "retirement/reject")}>{t("photo.reject")}</button></>}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("photo.propose")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn filled" disabled={busy || f.legal_basis.trim().length < 3}
                         onClick={() => run(() => api.post("/api/admin/photos/rules", { ...f, market: f.market || undefined, trip_scope: f.trip_scope || undefined,
                           traveller_class: f.traveller_class || undefined, passenger_category: f.passenger_category || undefined }), () => { setOpen(false); setF(blank); state.reload(); })}>{t("photo.send")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("photo.market")}><input className="input mono ltr" maxLength={2} value={f.market} onChange={(e) => setF({ ...f, market: e.target.value.toUpperCase() })} /></Field>
              <Field label={t("photo.tripScope")}><select className="input" value={f.trip_scope} onChange={set("trip_scope")}>
                <option value="">{t("photo.any")}</option><option value="DOMESTIC">{t("photo.scope.DOMESTIC")}</option><option value="INTERNATIONAL">{t("photo.scope.INTERNATIONAL")}</option></select></Field>
              <Field label={t("photo.travellerClass")}><select className="input" value={f.traveller_class} onChange={set("traveller_class")}>
                <option value="">{t("photo.any")}</option>{["SYRIAN_CITIZEN", "FOREIGN", "TRANSIT"].map((c) => <option key={c} value={c}>{t(`photo.class.${c}`)}</option>)}</select></Field>
              <Field label={t("photo.category")}><select className="input" value={f.passenger_category} onChange={set("passenger_category")}>
                <option value="">{t("photo.any")}</option>{["ADULT", "CHILD", "INFANT", "STUDENT", "SENIOR", "DISABLED"].map((c) => <option key={c} value={c}>{c}</option>)}</select></Field>
              <Field label={t("photo.requirement")}><select className="input" value={f.requirement} onChange={set("requirement")}>
                {["REQUIRED", "OPTIONAL", "NOT_APPLICABLE"].map((c) => <option key={c} value={c}>{t(`photo.req.${c}`)}</option>)}</select></Field>
              <Field label={t("photo.from")}><input className="input ltr" type="date" value={f.effective_from} onChange={set("effective_from")} /></Field>
            </div>
            <Field label={t("photo.legalBasis")}><input className="input" value={f.legal_basis} onChange={set("legal_basis")} /></Field>
          </div>
        </Modal>
      )}
      {retiring && (
        <Modal title={t("photo.retire")} onClose={() => setRetiring(null)}
               actions={<button className="btn filled" disabled={busy || reason.trim().length < 10}
                                onClick={() => run(() => api.post(`/api/admin/photos/rules/${retiring.uid}/retirement`, { reason }), () => { setRetiring(null); state.reload(); })}>{t("photo.send")}</button>}>
          <div className="stack"><ErrorBox error={error} /><p className="small muted" style={{ margin: 0 }}>{t("photo.retireHint")}</p>
            <Field label={t("photo.reason")}><textarea className="input" rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ the changes to the policy, waiting for their stages
function PolicyChanges() {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const state = useLoad((signal) => api.get<{ changes: PolicyChange[] }>("/api/admin/photos/policy-changes", undefined, { signal }));
  const { busy, error, run } = useRun();
  const [approving, setApproving] = useState<PolicyChange | null>(null);
  const [doc, setDoc] = useState("");
  const what = (c: PolicyChange) => c.change_type === "EVIDENCE_KIND" ? `${c.evidence_code}: ${t(c.new_active ? "photo.accepted" : "photo.notAccepted")}`
    : c.change_type === "IDENTITY_MIN_AGE" ? `${t("photo.minAge")}: ${c.new_min_age ?? "—"}`
    : c.change_type === "FIELD_REQUIREMENT" ? `${c.field_code}: ${t(`photo.req.${c.new_requirement}`)}`
    : t(`photo.type.${c.change_type}`);
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("photo.policyHint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{({ changes }) => changes.length === 0 ? <p className="muted small">{t("photo.none")}</p> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("photo.change")}</th><th>{t("photo.reason")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{changes.map((c) => (
            <tr key={c.uid}>
              <td><strong>{what(c)}</strong><div className="small muted">{dateTime(c.requested_at)}</div></td>
              <td className="small">{c.reason}{c.legal_basis && <div className="muted">{c.legal_basis}</div>}{c.legal_document_no && <div className="muted mono">{c.legal_document_no}</div>}</td>
              <td><Status value={c.status} />{c.status === "PENDING" && <div className="small muted">{t("photo.approvals", { n: c.approvals, of: c.stages?.length ?? 0 })}</div>}</td>
              <td className="row" style={{ gap: 4, justifyContent: "flex-end" }}>{c.status === "PENDING" && (c.requested_by === me?.uid
                ? <span className="small muted">{t("photo.waitsOthers")}</span>
                : <><button className="btn text small" disabled={busy} onClick={() => { setApproving(c); setDoc(""); }}>{t("photo.approve")}</button>
                    <button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/admin/photos/policy-changes/${c.uid}/reject`), () => state.reload())}>{t("photo.reject")}</button></>)}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {approving && (
        <Modal title={t("photo.approve")} onClose={() => setApproving(null)}
               actions={<button className="btn filled" disabled={busy}
                                onClick={() => run(() => api.post(`/api/admin/photos/policy-changes/${approving.uid}/approve`, doc ? { document_no: doc } : {}), () => { setApproving(null); state.reload(); })}>{t("photo.approve")}</button>}>
          <div className="stack"><ErrorBox error={error} /><p className="small muted" style={{ margin: 0 }}>{t("photo.docHint")}</p>
            <Field label={t("photo.docNo")} optional><input className="input" value={doc} onChange={(e) => setDoc(e.target.value)} /></Field></div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ replacing a photo on file
function PhotoChanges() {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const state = useLoad((signal) => api.get<{ changes: PhotoChange[] }>("/api/admin/photos/changes", undefined, { signal }));
  const kinds = useLoad((signal) => api.get<Settings>("/api/admin/photos/evidence-kinds", undefined, { signal }));
  const { busy, error, setError, run } = useRun();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ party_uid: "", reason: "", evidence_kind: "" });
  const evidence = useRef<HTMLInputElement>(null);
  const photo = useRef<HTMLInputElement>(null);
  const send = () => {
    const ev = evidence.current?.files?.[0], ph = photo.current?.files?.[0];
    if (!ev || !ph) return;
    const form = new FormData();
    form.append("party_uid", f.party_uid.trim()); form.append("reason", f.reason); form.append("evidence_kind", f.evidence_kind);
    form.append("evidence", ev); form.append("new_photo", ph);
    void run(() => api.upload("/api/admin/photos/changes", form), () => { setOpen(false); state.reload(); });
  };
  const viewEvidence = async (c: PhotoChange) => {
    setError(null);
    try {
      const r = await fetch(`/api/admin/photos/changes/${c.uid}/evidence`, { credentials: "include", headers: { "X-Masslak-Client": "web" } });
      if (!r.ok) throw new Error(String(r.status));
      window.open(URL.createObjectURL(await r.blob()), "_blank", "noopener");
    } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
        <p className="small muted" style={{ margin: 0 }}>{t("photo.changesHint")}</p>
        <button className="btn" onClick={() => { setOpen(true); setError(null); }}><Icon name="add" />{t("photo.newChange")}</button>
      </div>
      <ErrorBox error={error} />
      <Loaded state={state}>{({ changes }) => changes.length === 0 ? <p className="muted small">{t("photo.none")}</p> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("photo.person")}</th><th>{t("photo.evidence")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{changes.map((c) => (
            <tr key={c.uid}>
              <td className="mono small">{c.party_uid.slice(0, 8)}<div className="muted">{dateTime(c.created_at)}</div></td>
              <td className="small">{c.evidence_kind}<div className="muted">{c.reason}</div></td>
              <td><Status value={c.status} /></td>
              <td className="row" style={{ gap: 4, justifyContent: "flex-end" }}>
                <button className="btn text small" onClick={() => viewEvidence(c)}>{t("photo.viewEvidence")}</button>
                {c.status === "PENDING" && (c.requested_by === me?.uid ? <span className="small muted">{t("photo.waitsOthers")}</span> : <>
                  <button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/admin/photos/changes/${c.uid}/approve`), () => state.reload())}>{t("photo.approve")}</button>
                  <button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/admin/photos/changes/${c.uid}/reject`), () => state.reload())}>{t("photo.reject")}</button></>)}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("photo.newChange")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn filled" disabled={busy || !/^[0-9a-f-]{36}$/.test(f.party_uid.trim()) || f.reason.trim().length < 10 || !f.evidence_kind} onClick={send}>{t("photo.send")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("photo.personUid")}><input className="input mono ltr" value={f.party_uid} onChange={(e) => setF({ ...f, party_uid: e.target.value })} /></Field>
            <Field label={t("photo.evidenceKind")}><select className="input" value={f.evidence_kind} onChange={(e) => setF({ ...f, evidence_kind: e.target.value })}>
              <option value="" />{(kinds.data?.kinds ?? []).filter((k) => k.active).map((k) => <option key={k.code} value={k.code}>{k.label}</option>)}</select></Field>
            <Field label={t("photo.evidenceFile")}><input ref={evidence} type="file" accept="image/*,application/pdf" /></Field>
            <Field label={t("photo.newPhoto")}><input ref={photo} type="file" accept="image/jpeg,image/png" /></Field>
            <Field label={t("photo.reason")}><textarea className="input" rows={2} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
