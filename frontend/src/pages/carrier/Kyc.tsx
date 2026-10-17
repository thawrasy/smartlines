import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api, ApiError } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Icon, Loaded, useLoad, useToast } from "../../components/ui";
import { KycSectionView, sectionMissing, usePathLabel, useKycText, type Answers, type KycDefinition } from "../../components/KycForm";

// The company's KYC file (owner's request, October 2026; migration 1118): who the company is, who owns and controls it,
// its licences, finances and taxes, how it operates, its fleet, staff and agents, what it expects, and its declarations.
// The company fills it here (or platform staff from its paper form), uploads the documents asked for on its documents
// page, and submits it once nothing is missing. The review stages (compliance, finance, and later the authorities) may
// return it with what to correct. An approved file is updated as a new version; the approved one stays in force.

export type KycStatus = "DRAFT" | "SUBMITTED" | "RETURNED" | "APPROVED" | "REJECTED" | "SUPERSEDED";
export interface KycDocument { type: string; required: boolean; status: string | null; expiry_date: string | null; uploaded_at: string | null }
interface CompanyFile {
  uid: string; version: number; status: KycStatus; answers: Answers; completeness: number; return_note: string | null;
  return_fields: string[]; submitted_at: string | null; approved_at: string | null; review_due: string | null; updated_at: string;
  form_version: number; waiting_for: string | null;
}
interface View {
  file: CompanyFile | null; missing: string[]; definition: KycDefinition | null; documents: KycDocument[]; ubo_threshold_pct: number;
  approved: { version: number; approved_at: string; review_due: string } | null;
}

export const KYC_TONE: Record<string, string> = { DRAFT: "", SUBMITTED: "wheat", RETURNED: "wheat", APPROVED: "green", REJECTED: "red", SUPERSEDED: "" };

export function KycDocuments({ docs, link }: { docs: KycDocument[]; link?: string }) {
  const { t, date } = useI18n();
  return (
    <div className="stack tight">
      {docs.map((d) => (
        <div key={d.type} className="row" style={{ justifyContent: "space-between", gap: 8, borderBottom: "1px solid var(--divider)", paddingBottom: 6 }}>
          <span>{t(`kyc.doc.${d.type}`)}{d.required ? " *" : ""}</span>
          <span className="row" style={{ gap: 6 }}>
            {d.expiry_date && <span className="small muted">{t("kyc.expires", { date: date(`${d.expiry_date}T12:00:00Z`, { weekday: undefined, year: "numeric" }) })}</span>}
            <span className={`chip ${d.status === "APPROVED" ? "green" : d.status === "PENDING" ? "wheat" : d.status ? "red" : d.required ? "red" : ""}`}>
              {t(`kyc.docStatus.${d.status ?? "NONE"}`)}</span>
          </span>
        </div>
      ))}
      {link && <Link to={link} className="btn text small" style={{ alignSelf: "flex-start" }}><Icon name="upload_file" />{t("kyc.uploadDocs")}</Link>}
    </div>
  );
}

export function CarrierKyc() {
  const { t, date, dateTime } = useI18n();
  const text = useKycText();
  const toast = useToast();
  const state = useLoad(() => api.get<View>("/api/carrier/kyc"));
  const [answers, setAnswers] = useState<Answers>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [missing, setMissing] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [dirty, setDirty] = useState(false);
  const pathLabel = usePathLabel(state.data?.definition ?? null);
  useEffect(() => { if (state.data?.file) { setAnswers(state.data.file.answers); setDirty(false); setErrors({}); } }, [state.data]);

  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true); setError(null);
    try { await fn(); if (ok) toast(ok); return true; } catch (e) { setError(e); return false; } finally { setBusy(false); }
  };
  const open = () => run(async () => { await api.post("/api/carrier/kyc/open"); state.reload(); });
  const save = async (quiet = false) => {
    const file = state.data!.file!;
    let ok = false;
    await run(async () => {
      try {
        const out = await api.put<{ completeness: number; missing: string[]; answers: Answers }>(`/api/carrier/kyc/${file.uid}`, { answers });
        setAnswers(out.answers); setErrors({}); setDirty(false); setMissing(out.missing); ok = true;
        if (!quiet) toast(t("kyc.saved", { n: out.completeness }));
      } catch (e) {
        if (e instanceof ApiError && e.code === "KYC_INVALID") setErrors((e.details?.errors as Record<string, string>) ?? {});
        throw e;
      }
    });
    return ok;
  };
  const submit = async () => {
    if (dirty && !(await save(true))) return;
    await run(async () => {
      try {
        await api.post(`/api/carrier/kyc/${state.data!.file!.uid}/submit`);
        toast(t("kyc.submitted")); setMissing(null); state.reload();
      } catch (e) {
        if (e instanceof ApiError && e.code === "KYC_INCOMPLETE") setMissing((e.details?.missing as string[]) ?? []);
        throw e;
      }
    });
  };

  return (
    <div className="stack">
      <PageHead title={t("kyc.title")} sub={t("kyc.sub")} />
      <Loaded state={state}>{(v) => {
        const def = v.definition;
        if (!def) return <Empty icon="policy" title={t("kyc.noForm")} />;
        if (!v.file) return (
          <div className="card"><Empty icon="policy" title={t("kyc.none")} hint={t("kyc.noneHint")}>
            <button className="btn" disabled={busy} onClick={open}><Icon name="add" />{t("kyc.start")}</button></Empty></div>
        );
        const f = v.file;
        const editable = f.status === "DRAFT" || f.status === "RETURNED";
        const shownMissing = missing ?? (editable ? v.missing : []);
        const docsMissing = shownMissing.filter((m) => m.startsWith("doc:"));
        return (
          <>
            <div className="card stack tight">
              <div className="row" style={{ gap: 10, flexWrap: "wrap" }}>
                <span className={`chip ${KYC_TONE[f.status]}`}>{t(`kyc.status.${f.status}`)}</span>
                <span className="small muted">{t("kyc.versionOf", { v: f.version, form: f.form_version })}</span>
                {f.waiting_for && <span className="small">{t("kyc.waitingFor", { stage: t(`kyc.stage.${f.waiting_for}`) })}</span>}
                {f.submitted_at && <span className="small muted">{t("kyc.submittedOn", { date: dateTime(f.submitted_at) })}</span>}
              </div>
              {editable && (
                <div className="stack tight">
                  <div className="row" style={{ justifyContent: "space-between" }}><span className="small">{t("kyc.complete", { n: f.completeness })}</span></div>
                  <div className="progress" role="progressbar" aria-valuenow={f.completeness} aria-valuemin={0} aria-valuemax={100}
                       aria-label={t("kyc.complete", { n: f.completeness })}><div style={{ width: `${f.completeness}%` }} /></div>
                </div>
              )}
              {v.approved && (
                <div className="alert ok"><Icon name="verified_user" /><span>{t("kyc.approvedInForce", {
                  v: v.approved.version, date: date(`${v.approved.review_due}T12:00:00Z`, { weekday: undefined, year: "numeric" }) })}</span></div>
              )}
              {f.status === "RETURNED" && f.return_note && (
                <div className="alert warn" role="status"><Icon name="warning" /><div>
                  <strong>{t("kyc.returned")}</strong><div>{f.return_note}</div>
                  {f.return_fields.length > 0 && <div className="small">{t("kyc.toCorrect")}: {f.return_fields.map(pathLabel).join(t("common.listSep"))}</div>}
                </div></div>
              )}
              {f.status === "REJECTED" && <div className="alert error"><Icon name="error" /><span>{t("kyc.rejected")}</span></div>}
              {(f.status === "APPROVED" || f.status === "REJECTED") && (
                <button className="btn tonal" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={open}><Icon name="edit" />{t("kyc.update")}</button>
              )}
              <p className="small muted" style={{ margin: 0 }}>{t("kyc.privacy")}</p>
            </div>

            <nav className="kyc-sections" aria-label={t("kyc.sections")}>
              {def.sections.map((s) => {
                const n = editable ? sectionMissing(s, shownMissing) : 0;
                return (
                  <a key={s.key} href={`#kyc-s-${s.key}`} className={`chip ${n > 0 ? "red" : "outline"}`}
                     onClick={(e) => { e.preventDefault(); document.getElementById(`kyc-s-${s.key}`)?.scrollIntoView({ behavior: "smooth" }); }}>
                    {text.section(s)}{n > 0 ? ` (${n})` : ""}</a>
                );
              })}
            </nav>

            {missing && missing.length > 0 && (
              <div className="alert error" role="alert"><Icon name="error" /><div>
                <strong>{t("kyc.missingTitle", { n: missing.length })}</strong>
                <div className="small">{missing.slice(0, 12).map(pathLabel).join(t("common.listSep"))}{missing.length > 12 ? "…" : ""}</div>
              </div></div>
            )}

            {def.sections.map((s) => (
              <section key={s.key} id={`kyc-s-${s.key}`} className="card stack" aria-labelledby={`kyc-h-${s.key}`}>
                <h2 id={`kyc-h-${s.key}`} style={{ margin: 0, fontSize: 18 }}>{text.section(s)}</h2>
                {s.key === "ownership" && <p className="small muted" style={{ margin: 0 }}>{t("kyc.uboThreshold", { n: v.ubo_threshold_pct })}</p>}
                <KycSectionView section={s} def={def} answers={editable ? answers : f.answers} readOnly={!editable}
                                onChange={(a) => { setAnswers(a); setDirty(true); }} errors={errors} missing={shownMissing}
                                highlight={f.status === "RETURNED" ? f.return_fields : []} />
              </section>
            ))}

            <section className="card stack" aria-labelledby="kyc-h-docs">
              <h2 id="kyc-h-docs" style={{ margin: 0, fontSize: 18 }}>{t("kyc.documents")}</h2>
              <p className="small muted" style={{ margin: 0 }}>{t("kyc.documentsHint")}</p>
              {docsMissing.length > 0 && <div className="alert warn"><Icon name="warning" /><span>{t("kyc.docsMissing", { n: docsMissing.length })}</span></div>}
              <KycDocuments docs={v.documents} link="/carrier/documents" />
            </section>

            {editable && (
              <div className="kyc-actions">
                <ErrorBox error={error} />
                <button className="btn tonal" disabled={busy} onClick={() => save()}><Icon name="save" />{t("kyc.save")}</button>
                <button className="btn" disabled={busy} onClick={submit}><Icon name="send" />{t("kyc.submit")}</button>
                {dirty && <span className="small muted">{t("kyc.unsaved")}</span>}
                {!dirty && f.updated_at && <span className="small muted">{t("kyc.lastSaved", { date: dateTime(f.updated_at) })}</span>}
              </div>
            )}
            {!editable && <ErrorBox error={error} />}
          </>
        );
      }}</Loaded>
    </div>
  );
}
