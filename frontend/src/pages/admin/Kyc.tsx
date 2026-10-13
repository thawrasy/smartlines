import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, ApiError } from "../../api";
import { useAuth } from "../../auth";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";
import { KycSectionView, sectionMissing, usePathLabel, useKycText, type Answers, type KycDefinition } from "../../components/KycForm";
import { KYC_TONE, KycDocuments, type KycDocument, type KycStatus } from "../carrier/Kyc";

// Companies' KYC files for the platform (owner's request, October 2026; migration 1118). Compliance, finance and tax
// review a submitted file in the order the settings give, one person per stage; a government authority's members
// decide its stages. A stage approves, returns the file with what to correct, or rejects it; compliance may set
// another risk level with its reason. Staff may capture a file from a company's paper form. Identity document and
// account numbers are shown masked; showing one needs a reason and is recorded. The form itself is versioned data,
// and its review stages, risk rules and gates are settings.

type Stage = { by: "COMPLIANCE" | "FINANCE" | "TAX" | "AUTHORITY"; authority?: string };
type Risk = "LOW" | "MEDIUM" | "HIGH" | "PROHIBITED";
interface Row {
  company_uid: string; company_name: string; company_logo: string | null; uid: string | null; version: number | null; status: KycStatus | null;
  completeness: number | null; risk_level: Risk | null; risk_score: number | null; waiting_for: Stage | null; may_decide: boolean;
  submitted_at: string | null; approved_at: string | null; review_due: string | null; form_version: number | null;
}
interface FileFull {
  uid: string; version: number; status: KycStatus; answers: Answers; completeness: number; round: number; step: number; review_stages: Stage[];
  risk_score: number | null; risk_level: Risk | null; risk_override: Risk | null; risk_override_reason: string | null;
  risk_factors: { code: string; points: number; level?: string }[]; return_note: string | null; return_fields: string[];
  submitted_at: string | null; approved_at: string | null; review_due: string | null; form_version: number; definition: KycDefinition;
  submitted_by_email: string | null; updated_by_email: string | null; updated_by_kind: string | null;
  company: { uid: string; name: string; logo: string | null; company_type: string };
  decisions: { round: number; step: number; stage: Stage; decision: string; note: string | null; fields: string[]; risk_override: Risk | null;
               decided_at: string; decided_by: string; authority: string | null }[];
  versions: { uid: string; version: number; status: KycStatus; submitted_at: string | null; approved_at: string | null; review_due: string | null; risk_level: Risk | null }[];
  waiting_for: Stage | null; may_decide: boolean; documents: KycDocument[]; missing: string[]; ubo_threshold_pct: number;
}
const RISK_TONE: Record<string, string> = { LOW: "green", MEDIUM: "wheat", HIGH: "red", PROHIBITED: "red" };

function useStageName() {
  const { t } = useI18n();
  // a label on its own ("Finance") or inside a sentence ("Your decision: finance stage")
  return (s: Stage | null, inSentence = false) => (!s ? "—" : inSentence
    ? (s.by === "AUTHORITY" ? t("kycadm.stageAuthority", { code: s.authority ?? "" }) : t(`kyc.stage.${s.by}`))
    : t(`kycadm.stageLabel.${s.by}`, { code: s.authority ?? "" }));
}

function RiskChip({ level }: { level: Risk | null }) {
  const { t } = useI18n();
  return level ? <span className={`chip ${RISK_TONE[level]}`}>{t(`kycadm.risk.${level}`)}</span> : <span className="muted">—</span>;
}

// ------------------------------------------------------------------ one file
function Decide({ f, onDone }: { f: FileFull; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const text = useKycText();
  const stageName = useStageName();
  const [decision, setDecision] = useState<"APPROVE" | "RETURN" | "REJECT">("APPROVE");
  const [note, setNote] = useState("");
  const [fields, setFields] = useState<string[]>([]);
  const [risk, setRisk] = useState<string>("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const compliance = f.waiting_for?.by === "COMPLIANCE";
  const go = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ status: string }>(`/api/admin/kyc/${f.uid}/decide`,
        { decision, note: note || null, fields: decision === "RETURN" ? fields : [], risk_level: compliance && risk ? risk : null });
      toast(t(`kycadm.done.${out.status}`)); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="card stack">
      <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.decideTitle", { stage: stageName(f.waiting_for, true) })}</h2>
      <div className="row" role="radiogroup" aria-label={t("kycadm.decision")} style={{ gap: 16, flexWrap: "wrap" }}>
        {(["APPROVE", "RETURN", "REJECT"] as const).map((d) => (
          <label key={d} className="row" style={{ gap: 6 }}><input type="radio" name="kyc-decision" checked={decision === d} onChange={() => setDecision(d)} />
            {t(`kycadm.decisionOf.${d}`)}</label>
        ))}
      </div>
      {compliance && (
        <Field label={t("kycadm.riskOverride")} hint={t("kycadm.riskOverrideHint")}>
          <select className="input" value={risk} onChange={(e) => setRisk(e.target.value)}>
            <option value="">{t("kycadm.keepRisk", { level: t(`kycadm.risk.${f.risk_level ?? "LOW"}`) })}</option>
            {(["LOW", "MEDIUM", "HIGH", "PROHIBITED"] as const).map((r) => <option key={r} value={r}>{t(`kycadm.risk.${r}`)}</option>)}
          </select>
        </Field>
      )}
      {decision === "RETURN" && (
        <Field label={t("kycadm.fieldsToCorrect")}>
          <select className="input" multiple size={8} value={fields} onChange={(e) => setFields(Array.from(e.target.selectedOptions).map((o) => o.value))}>
            {f.definition.sections.map((s) => (
              <optgroup key={s.key} label={text.section(s)}>
                {s.fields.map((x) => <option key={x.key} value={x.key}>{text.field(x)}</option>)}
              </optgroup>
            ))}
          </select>
        </Field>
      )}
      <Field label={decision === "APPROVE" && !risk ? t("kycadm.noteOptional") : t("kycadm.noteRequired")}>
        <textarea className="input" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)} />
      </Field>
      <ErrorBox error={error} />
      <div className="row" style={{ gap: 8 }}>
        <button className={`btn${decision === "REJECT" ? " danger" : ""}`} disabled={busy} onClick={go}>
          <Icon name={decision === "APPROVE" ? "check" : decision === "RETURN" ? "undo" : "close"} />{t(`kycadm.decisionOf.${decision}`)}</button>
      </div>
    </div>
  );
}

function FileView({ uid, onBack }: { uid: string; onBack: () => void }) {
  const { t, has, dateTime, date } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const text = useKycText();
  const stageName = useStageName();
  const state = useLoad(() => api.get<FileFull>(`/api/admin/kyc/${uid}`), [uid]);
  const pathLabel = usePathLabel(state.data?.definition ?? null);
  const [capture, setCapture] = useState(false);
  const [answers, setAnswers] = useState<Answers>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [missing, setMissing] = useState<string[] | null>(null);
  const [reveal, setReveal] = useState<{ path: string; resolve: (v: string) => void } | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { if (state.data) { setAnswers(state.data.answers); setErrors({}); setMissing(null); } }, [state.data]);
  const onReveal = (path: string) => new Promise<string>((resolve) => { setReason(""); setReveal({ path, resolve }); });
  const doReveal = async () => {
    if (!reveal) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ value: string }>(`/api/admin/kyc/${uid}/reveal`, { path: reveal.path, reason });
      reveal.resolve(out.value); setReveal(null);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const save = async (andSubmit: boolean) => {
    setBusy(true); setError(null);
    try {
      try {
        const out = await api.put<{ completeness: number; missing: string[]; answers: Answers }>(`/api/admin/kyc/${uid}`, { answers });
        setAnswers(out.answers); setErrors({}); setMissing(out.missing);
        if (!andSubmit) toast(t("kyc.saved", { n: out.completeness }));
      } catch (e) {
        if (e instanceof ApiError && e.code === "KYC_INVALID") setErrors((e.details?.errors as Record<string, string>) ?? {});
        throw e;
      }
      if (andSubmit) {
        try { await api.post(`/api/admin/kyc/${uid}/submit`); toast(t("kyc.submitted")); setCapture(false); state.reload(); } catch (e) {
          if (e instanceof ApiError && e.code === "KYC_INCOMPLETE") setMissing((e.details?.missing as string[]) ?? []);
          throw e;
        }
      }
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <Loaded state={state}>{(f) => {
      const editable = capture && (f.status === "DRAFT" || f.status === "RETURNED");
      const shownMissing = missing ?? f.missing;
      const level = f.risk_override ?? f.risk_level;
      return (
        <div className="stack">
          <button className="btn text" style={{ alignSelf: "flex-start" }} onClick={onBack}><Icon name="arrow_back" flip />{t("kycadm.back")}</button>
          <div className="card stack tight">
            <div className="row" style={{ gap: 10, flexWrap: "wrap", justifyContent: "space-between" }}>
              <CarrierName name={f.company.name} uid={f.company.uid} logo={f.company.logo} size="md" strong />
              <span className="row" style={{ gap: 8 }}>
                <span className={`chip ${KYC_TONE[f.status]}`}>{t(`kyc.status.${f.status}`)}</span><RiskChip level={level} />
              </span>
            </div>
            <dl className="kv">
              <dt>{t("kycadm.version")}</dt><dd>{t("kyc.versionOf", { v: f.version, form: f.form_version })}</dd>
              <dt>{t("kycadm.waiting")}</dt><dd>{f.waiting_for ? stageName(f.waiting_for) : "—"}</dd>
              <dt>{t("kycadm.submitted")}</dt><dd>{f.submitted_at ? `${dateTime(f.submitted_at)}${f.submitted_by_email ? ` · ${f.submitted_by_email}` : ""}` : "—"}</dd>
              <dt>{t("kycadm.reviewDue")}</dt><dd>{f.review_due ? date(`${f.review_due}T12:00:00Z`, { weekday: undefined, year: "numeric" }) : "—"}</dd>
              <dt>{t("kycadm.completeness")}</dt><dd>{f.completeness}%</dd>
              {f.updated_by_kind === "PLATFORM" && <><dt>{t("kycadm.captured")}</dt><dd>{f.updated_by_email}</dd></>}
            </dl>
          </div>
          <div className="grid cols-2" style={{ alignItems: "start" }}>
            <div className="card stack tight">
              <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.riskTitle")}</h2>
              {f.risk_level ? (
                <>
                  <div className="row" style={{ gap: 8 }}><RiskChip level={level} /><span className="small muted">{t("kycadm.score", { n: f.risk_score ?? 0 })}</span></div>
                  {f.risk_override && <div className="small">{t("kycadm.overridden", { from: t(`kycadm.risk.${f.risk_level}`) })}: {f.risk_override_reason}</div>}
                  {f.risk_factors.length === 0 ? <span className="small muted">{t("kycadm.noFactors")}</span> : (
                    <ul className="small" style={{ margin: 0, paddingInlineStart: 18 }}>
                      {f.risk_factors.map((x) => <li key={x.code}>{has(`kycadm.factor.${x.code}`) ? t(`kycadm.factor.${x.code}`) : x.code}
                        {` (+${x.points}${x.level ? ` · ${t(`kycadm.risk.${x.level}`)}` : ""})`}</li>)}
                    </ul>
                  )}
                </>
              ) : <span className="small muted">{t("kycadm.riskAtSubmit")}</span>}
            </div>
            <div className="card stack tight">
              <h2 style={{ margin: 0, fontSize: 18 }}>{t("kyc.documents")}</h2>
              <KycDocuments docs={f.documents} />
            </div>
          </div>
          {f.may_decide && <Decide f={f} onDone={() => state.reload()} />}
          {f.return_note && f.status === "RETURNED" && (
            <div className="alert warn"><Icon name="undo" /><div><strong>{t("kyc.returned")}</strong><div>{f.return_note}</div>
              {f.return_fields.length > 0 && <div className="small">{f.return_fields.map(pathLabel).join(t("common.listSep"))}</div>}</div></div>
          )}
          {(f.status === "DRAFT" || f.status === "RETURNED") && can("kyc.capture") && !capture && (
            <button className="btn tonal" style={{ alignSelf: "flex-start" }} onClick={() => setCapture(true)}><Icon name="edit" />{t("kycadm.capture")}</button>
          )}
          {shownMissing.length > 0 && (f.status === "DRAFT" || f.status === "RETURNED") && (
            <div className="alert info"><Icon name="info" /><div><strong>{t("kyc.missingTitle", { n: shownMissing.length })}</strong>
              <div className="small">{shownMissing.slice(0, 12).map(pathLabel).join(t("common.listSep"))}{shownMissing.length > 12 ? "…" : ""}</div></div></div>
          )}
          <nav className="kyc-sections" aria-label={t("kyc.sections")}>
            {f.definition.sections.map((s) => {
              const n = editable ? sectionMissing(s, shownMissing) : 0;
              return <a key={s.key} href={`#kyc-s-${s.key}`} className={`chip ${n > 0 ? "red" : "outline"}`}
                        onClick={(e) => { e.preventDefault(); document.getElementById(`kyc-s-${s.key}`)?.scrollIntoView({ behavior: "smooth" }); }}>
                {text.section(s)}{n > 0 ? ` (${n})` : ""}</a>;
            })}
          </nav>
          {f.definition.sections.map((s) => (
            <section key={s.key} id={`kyc-s-${s.key}`} className="card stack" aria-labelledby={`kyc-h-${s.key}`}>
              <h2 id={`kyc-h-${s.key}`} style={{ margin: 0, fontSize: 18 }}>{text.section(s)}</h2>
              {s.key === "ownership" && <p className="small muted" style={{ margin: 0 }}>{t("kyc.uboThreshold", { n: f.ubo_threshold_pct })}</p>}
              <KycSectionView section={s} def={f.definition} answers={editable ? answers : f.answers} readOnly={!editable}
                              onChange={setAnswers} errors={errors} missing={editable ? shownMissing : []} onReveal={editable ? undefined : onReveal}
                              highlight={f.return_fields} />
            </section>
          ))}
          {editable && (
            <div className="kyc-actions">
              <ErrorBox error={error} />
              <button className="btn text" disabled={busy} onClick={() => { setCapture(false); setAnswers(f.answers); }}>{t("common.cancel")}</button>
              <button className="btn tonal" disabled={busy} onClick={() => save(false)}><Icon name="save" />{t("kyc.save")}</button>
              <button className="btn" disabled={busy} onClick={() => save(true)}><Icon name="send" />{t("kyc.submit")}</button>
            </div>
          )}
          <div className="card stack tight">
            <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.history")}</h2>
            {f.decisions.length === 0 ? <span className="small muted">{t("kycadm.noDecisions")}</span> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("kycadm.when")}</th><th>{t("kycadm.stage")}</th><th>{t("kycadm.decision")}</th><th>{t("kycadm.by")}</th><th>{t("kycadm.note")}</th></tr></thead>
                <tbody>{f.decisions.map((d) => (
                  <tr key={`${d.round}-${d.step}`}>
                    <td className="small text-nowrap">{dateTime(d.decided_at)}</td><td>{stageName(d.stage)}</td>
                    <td><span className={`chip ${d.decision === "APPROVE" ? "green" : d.decision === "RETURN" ? "wheat" : "red"}`}>{t(`kycadm.decisionOf.${d.decision}`)}</span>
                      {d.risk_override && <div className="small">{t("kycadm.setLevel", { level: t(`kycadm.risk.${d.risk_override}`) })}</div>}</td>
                    <td className="small">{d.decided_by}</td>
                    <td className="small">{d.note ?? ""}{d.fields.length > 0 && <div className="muted">{d.fields.map(pathLabel).join(t("common.listSep"))}</div>}</td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
            {f.versions.length > 1 && (
              <div className="small muted">{t("kycadm.versions")}: {f.versions.map((x) => `${x.version} (${t(`kyc.status.${x.status}`)})`).join(t("common.listSep"))}</div>
            )}
          </div>
          {reveal && (
            <Modal title={t("kycadm.revealTitle")} onClose={() => setReveal(null)}
                   actions={<><button className="btn text" onClick={() => setReveal(null)}>{t("common.cancel")}</button>
                     <button className="btn" disabled={busy || reason.trim().length < 5} onClick={doReveal}><Icon name="visibility" />{t("kyc.show")}</button></>}>
              <p className="small" style={{ marginTop: 0 }}>{t("kycadm.revealHint", { field: pathLabel(reveal.path) })}</p>
              <Field label={t("kycadm.reason")}><textarea className="input" rows={2} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
              <ErrorBox error={error} />
            </Modal>
          )}
        </div>
      );
    }}</Loaded>
  );
}

// ------------------------------------------------------------------ the list
function Files({ onOpen }: { onOpen: (uid: string) => void }) {
  const { t, date } = useI18n();
  const { can } = useAuth();
  const stageName = useStageName();
  const [status, setStatus] = useState<"WAITING" | "ALL" | "OPEN" | "DUE" | "NONE">("WAITING");
  const state = useLoad(() => api.get<{ files: Row[] }>(`/api/admin/kyc?status=${status}`), [status]);
  const [error, setError] = useState<unknown>(null);
  const start = async (company: string) => {
    setError(null);
    try { const out = await api.post<{ uid: string }>(`/api/admin/kyc/companies/${company}/open`); onOpen(out.uid); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <div className="segmented" role="tablist" aria-label={t("kycadm.filter")} style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {(["WAITING", "ALL", "OPEN", "DUE", "NONE"] as const).map((s) => (
          <button key={s} role="tab" aria-selected={status === s} className={status === s ? "on" : ""} onClick={() => setStatus(s)}>{t(`kycadm.filterOf.${s}`)}</button>
        ))}
      </div>
      <ErrorBox error={error} />
      <div className="card">
        <Loaded state={state}>{({ files }) => files.length === 0 ? <Empty icon="policy" title={t("kycadm.none")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("kycadm.company")}</th><th>{t("kycadm.state")}</th><th>{t("kycadm.risk.title")}</th><th>{t("kycadm.waiting")}</th>
              <th>{t("kycadm.submitted")}</th><th>{t("kycadm.reviewDue")}</th><th /></tr></thead>
            <tbody>{files.map((r) => (
              <tr key={r.company_uid}>
                <td style={{ minWidth: 200 }}><CarrierName name={r.company_name} uid={r.company_uid} logo={r.company_logo} />
                  {r.version && <div className="small muted">{t("kyc.versionOf", { v: r.version, form: r.form_version ?? 1 })}{r.completeness !== null && r.status && ["DRAFT", "RETURNED"].includes(r.status) ? ` · ${r.completeness}%` : ""}</div>}</td>
                <td>{r.status ? <span className={`chip ${KYC_TONE[r.status]}`}>{t(`kyc.status.${r.status}`)}</span> : <span className="muted">{t("kycadm.noFile")}</span>}</td>
                <td><RiskChip level={r.risk_level} /></td>
                <td className="small">{r.waiting_for ? <>{stageName(r.waiting_for)}{r.may_decide && <div><span className="chip blue">{t("kycadm.yourTurn")}</span></div>}</> : "—"}</td>
                <td className="small text-nowrap">{r.submitted_at ? date(r.submitted_at) : "—"}</td>
                <td className="small text-nowrap">{r.review_due ? date(`${r.review_due}T12:00:00Z`, { weekday: undefined, year: "numeric" }) : "—"}</td>
                <td>{r.uid ? <button className="btn text small" onClick={() => onOpen(r.uid!)}><Icon name="open_in_new" />{t("kycadm.open")}</button>
                  : can("kyc.capture") && <button className="btn text small" onClick={() => start(r.company_uid)}><Icon name="add" />{t("kycadm.startFile")}</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ the form and the settings
interface FormVersion { version: number; status: "DRAFT" | "ACTIVE" | "RETIRED"; note: string | null; created_at: string; activated_at: string | null; files: number; definition?: KycDefinition }

function FormTab() {
  const { t, dateTime } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ active: FormVersion | null; draft: FormVersion | null; versions: FormVersion[] }>("/api/admin/kyc/form"));
  const [json, setJson] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const counts = (d?: KycDefinition) => d ? { sections: d.sections.length, fields: d.sections.reduce((n, s) => n + s.fields.length, 0) } : null;
  const save = async () => {
    setBusy(true); setError(null); setProblem(null);
    try {
      let definition: unknown;
      try { definition = JSON.parse(json); } catch { setProblem(t("kycadm.badJson")); return; }
      const out = await api.put<{ version: number }>("/api/admin/kyc/form", { definition, note: note || null });
      toast(t("kycadm.draftSaved", { v: out.version })); state.reload();
    } catch (e) { setError(e); if (e instanceof ApiError && e.code === "KYC_FORM_INVALID") setProblem(e.message); } finally { setBusy(false); }
  };
  const activate = async (v: number) => {
    setBusy(true); setError(null);
    try { await api.post(`/api/admin/kyc/form/${v}/activate`); toast(t("kycadm.activated", { v })); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Loaded state={state}>{(d) => (
      <div className="stack">
        <div className="card stack tight">
          <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.formInForce")}</h2>
          {d.active && <p className="small" style={{ margin: 0 }}>{t("kycadm.formSummary", { v: d.active.version, ...counts(d.active.definition)!,
            docs: d.active.definition?.documents?.length ?? 0, date: d.active.activated_at ? dateTime(d.active.activated_at) : "—" })}</p>}
          <p className="small muted" style={{ margin: 0 }}>{t("kycadm.formHint")}</p>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("kycadm.version")}</th><th>{t("kycadm.state")}</th><th>{t("kycadm.note")}</th><th>{t("kycadm.filesOf")}</th><th /></tr></thead>
            <tbody>{d.versions.map((v) => (
              <tr key={v.version}><td className="mono">{v.version}</td><td><span className={`chip ${v.status === "ACTIVE" ? "green" : v.status === "DRAFT" ? "wheat" : ""}`}>{t(`kycadm.formStatus.${v.status}`)}</span></td>
                <td className="small">{v.note ?? ""}</td><td className="num">{v.files}</td>
                <td>{v.status === "DRAFT" && can("kyc.settings") && <button className="btn text small" disabled={busy} onClick={() => activate(v.version)}><Icon name="check" />{t("kycadm.activate")}</button>}</td></tr>
            ))}</tbody>
          </table></div>
        </div>
        {can("kyc.settings") && (
          <div className="card stack">
            <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.editTitle")}</h2>
            <p className="small muted" style={{ margin: 0 }}>{t("kycadm.editHint")}</p>
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <button className="btn tonal small" onClick={() => setJson(JSON.stringify((d.draft ?? d.active)?.definition ?? {}, null, 2))}>
                <Icon name="edit" />{d.draft ? t("kycadm.loadDraft") : t("kycadm.loadActive")}</button>
            </div>
            <Field label={t("kycadm.definition")}>
              <textarea className="input mono" dir="ltr" rows={18} spellCheck={false} value={json} onChange={(e) => setJson(e.target.value)} />
            </Field>
            <Field label={t("kycadm.note")}><input className="input" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
            {problem && <div className="alert error" role="alert"><Icon name="error" /><span className="mono" dir="ltr">{problem}</span></div>}
            <ErrorBox error={problem ? null : error} />
            <button className="btn" style={{ alignSelf: "flex-start" }} disabled={busy || !json.trim()} onClick={save}><Icon name="save" />{t("kycadm.saveDraft")}</button>
          </div>
        )}
      </div>
    )}</Loaded>
  );
}

interface Settings {
  review_stages: Stage[]; risk_rules: unknown[]; risk_levels: { MEDIUM: number; HIGH: number }; review_months: { LOW: number; MEDIUM: number; HIGH: number };
  ubo_threshold_pct: number; documents_on_submit: boolean; required_before: string[]; distinct_reviewers: boolean; authorities: { code: string; name: string }[];
}

function SettingsTab() {
  const { t } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<Settings>("/api/admin/kyc/settings"));
  const [s, setS] = useState<Settings | null>(null);
  const [rules, setRules] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (state.data) { setS(state.data); setRules(JSON.stringify(state.data.risk_rules, null, 2)); } }, [state.data]);
  const editable = can("kyc.settings");
  const put = async (key: string, value: unknown) => {
    setBusy(true); setError(null);
    try { const out = await api.put<Settings>(`/api/admin/kyc/settings/${key}`, { value }); setS(out); toast(t("common.saved")); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const stageOptions = useMemo(() => s ? [{ by: "COMPLIANCE" }, { by: "FINANCE" }, { by: "TAX" }, ...s.authorities.map((a) => ({ by: "AUTHORITY", authority: a.code }))] as Stage[] : [], [s]);
  const stageKey = (x: Stage) => x.by === "AUTHORITY" ? `AUTHORITY:${x.authority}` : x.by;
  const stageName = useStageName();
  return (
    <Loaded state={state}>{() => !s ? null : (
      <div className="stack">
        <ErrorBox error={error} />
        <div className="card stack tight">
          <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.stagesTitle")}</h2>
          <p className="small muted" style={{ margin: 0 }}>{t("kycadm.stagesHint")}</p>
          {s.review_stages.map((st, i) => (
            <div key={i} className="row" style={{ gap: 8 }}>
              <span className="mono">{i + 1}.</span>
              <select className="input" aria-label={`${t("kycadm.stage")} ${i + 1}`} disabled={!editable} value={stageKey(st)}
                      onChange={(e) => setS({ ...s, review_stages: s.review_stages.map((x, j) => j === i ? stageOptions.find((o) => stageKey(o) === e.target.value)! : x) })}>
                {stageOptions.map((o) => <option key={stageKey(o)} value={stageKey(o)}>{stageName(o)}</option>)}
              </select>
              {editable && s.review_stages.length > 1 && <button className="icon-btn" aria-label={`${t("kycadm.removeStage")} ${i + 1}`} title={t("kycadm.removeStage")}
                onClick={() => setS({ ...s, review_stages: s.review_stages.filter((_, j) => j !== i) })}><Icon name="delete" /></button>}
            </div>
          ))}
          {editable && <div className="row" style={{ gap: 8 }}>
            <button className="btn tonal small" disabled={s.review_stages.length >= 6} onClick={() => setS({ ...s, review_stages: [...s.review_stages, { by: "TAX" }] })}><Icon name="add" />{t("kycadm.addStage")}</button>
            <button className="btn small" disabled={busy} onClick={() => put("review_stages", s.review_stages)}><Icon name="save" />{t("common.save")}</button>
          </div>}
        </div>
        <div className="card stack">
          <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.rulesTitle")}</h2>
          <div className="grid cols-2">
            <Field label={t("kycadm.levelMedium")}><input className="input" type="number" min={1} disabled={!editable} value={s.risk_levels.MEDIUM}
              onChange={(e) => setS({ ...s, risk_levels: { ...s.risk_levels, MEDIUM: Number(e.target.value) } })} /></Field>
            <Field label={t("kycadm.levelHigh")}><input className="input" type="number" min={2} disabled={!editable} value={s.risk_levels.HIGH}
              onChange={(e) => setS({ ...s, risk_levels: { ...s.risk_levels, HIGH: Number(e.target.value) } })} /></Field>
          </div>
          {editable && <button className="btn small" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={() => put("risk_levels", s.risk_levels)}><Icon name="save" />{t("common.save")}</button>}
          <div className="grid cols-2">
            {(["LOW", "MEDIUM", "HIGH"] as const).map((l) => (
              <Field key={l} label={t("kycadm.monthsFor", { level: t(`kycadm.risk.${l}`) })}><input className="input" type="number" min={1} max={60} disabled={!editable}
                value={s.review_months[l]} onChange={(e) => setS({ ...s, review_months: { ...s.review_months, [l]: Number(e.target.value) } })} /></Field>
            ))}
          </div>
          {editable && <button className="btn small" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={() => put("review_months", s.review_months)}><Icon name="save" />{t("common.save")}</button>}
          <Field label={t("kycadm.rules")} hint={t("kycadm.rulesHint")}>
            <textarea className="input mono" dir="ltr" rows={12} spellCheck={false} disabled={!editable} value={rules} onChange={(e) => setRules(e.target.value)} />
          </Field>
          {editable && <button className="btn small" style={{ alignSelf: "flex-start" }} disabled={busy}
            onClick={() => { try { put("risk_rules", JSON.parse(rules)); } catch { setError(new ApiError(422, "INVALID_SETTING", "json")); } }}><Icon name="save" />{t("common.save")}</button>}
        </div>
        <div className="card stack tight">
          <h2 style={{ margin: 0, fontSize: 18 }}>{t("kycadm.otherTitle")}</h2>
          <div className="row" style={{ gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
            <Field label={t("kycadm.uboThreshold")}><input className="input" type="number" min={5} max={50} disabled={!editable} value={s.ubo_threshold_pct}
              onChange={(e) => setS({ ...s, ubo_threshold_pct: Number(e.target.value) })} /></Field>
            {editable && <button className="btn small" disabled={busy} onClick={() => put("ubo_threshold_pct", s.ubo_threshold_pct)}><Icon name="save" />{t("common.save")}</button>}
          </div>
          <label className="row" style={{ gap: 8 }}><input type="checkbox" disabled={!editable || busy} checked={s.documents_on_submit}
            onChange={(e) => put("documents_on_submit", e.target.checked)} />{t("kycadm.documentsOnSubmit")}</label>
          <label className="row" style={{ gap: 8 }}><input type="checkbox" disabled={!editable || busy} checked={s.distinct_reviewers}
            onChange={(e) => put("distinct_reviewers", e.target.checked)} />{t("kycadm.distinctReviewers")}</label>
          <fieldset className="kyc-yesno"><legend>{t("kycadm.requiredBefore")}</legend>
            {(["PUBLISH_TRIPS", "PAYOUTS"] as const).map((g) => (
              <label key={g} className="row" style={{ gap: 8 }}><input type="checkbox" disabled={!editable || busy} checked={s.required_before.includes(g)}
                onChange={(e) => put("required_before", e.target.checked ? [...s.required_before, g] : s.required_before.filter((x) => x !== g))} />{t(`kycadm.gate.${g}`)}</label>
            ))}
          </fieldset>
        </div>
      </div>
    )}</Loaded>
  );
}

export function AdminKyc() {
  const { t } = useI18n();
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const file = params.get("file");
  const [tab, setTab] = useState<"files" | "form" | "settings">("files");
  const open = (uid: string | null) => setParams(uid ? { file: uid } : {});
  if (file) return <div className="stack"><PageHead title={t("kycadm.title")} /><FileView uid={file} onBack={() => open(null)} /></div>;
  return (
    <div className="stack">
      <PageHead title={t("kycadm.title")} sub={t("kycadm.sub")} />
      {can("kyc.view", "kyc.settings") && (
        <div className="segmented" role="tablist" aria-label={t("kycadm.title")} style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
          {(["files", "form", "settings"] as const).map((k) => (
            <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>{t(`kycadm.tab.${k}`)}</button>
          ))}
        </div>
      )}
      {tab === "files" ? <Files onOpen={open} /> : tab === "form" ? <FormTab /> : <SettingsTab />}
    </div>
  );
}
