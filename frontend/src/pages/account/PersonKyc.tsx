import { useEffect, useState } from "react";
import { api, ApiError } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Icon, Loaded, useLoad, useToast } from "../../components/ui";
import { KycSectionView, usePathLabel, useKycText, type Answers, type KycDefinition } from "../../components/KycForm";
import { KYC_TONE, type KycStatus } from "../carrier/Kyc";

// A driver's or passenger's own KYC file (owner's request N14, migration 1159): who they are, where they live, and their
// declarations. One reviewer of the platform verifies it. What a verified person may do that others may not is the
// platform's setting, shown here when it asks for anything.

interface PersonFile {
  uid: string; version: number; status: KycStatus; answers: Answers; completeness: number; return_note: string | null;
  return_fields: string[]; decision_note: string | null; submitted_at: string | null; approved_at: string | null;
  review_due: string | null; updated_at: string; form_version: number;
}
interface View {
  kind: "DRIVER" | "PASSENGER"; file: PersonFile | null; missing: string[]; definition: KycDefinition | null;
  verification_status: string; verified: boolean; required_before: string[];
}

export function PersonKyc() {
  const { t, date, dateTime } = useI18n();
  const toast = useToast();
  const text = useKycText();
  const state = useLoad(() => api.get<View>("/api/account/kyc"));
  const [answers, setAnswers] = useState<Answers>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [missing, setMissing] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [dirty, setDirty] = useState(false);
  const pathLabel = usePathLabel(state.data?.definition ?? null);
  useEffect(() => { if (state.data?.file) { setAnswers(state.data.file.answers); setDirty(false); setErrors({}); } }, [state.data]);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); return true; } catch (e) { setError(e); return false; } finally { setBusy(false); }
  };
  const open = () => run(async () => { await api.post("/api/account/kyc/open"); state.reload(); });
  const save = async (quiet = false) => run(async () => {
    try {
      const out = await api.put<{ completeness: number; missing: string[]; answers: Answers }>(`/api/account/kyc/${state.data!.file!.uid}`, { answers });
      setAnswers(out.answers); setErrors({}); setDirty(false); setMissing(out.missing);
      if (!quiet) toast(t("kyc.saved", { n: out.completeness }));
    } catch (e) {
      if (e instanceof ApiError && e.code === "KYC_INVALID") setErrors((e.details?.errors as Record<string, string>) ?? {});
      throw e;
    }
  });
  const submit = async () => {
    if (dirty && !(await save(true))) return;
    await run(async () => {
      try {
        await api.post(`/api/account/kyc/${state.data!.file!.uid}/submit`);
        toast(t("kyc.submitted")); setMissing(null); state.reload();
      } catch (e) {
        if (e instanceof ApiError && e.code === "KYC_INCOMPLETE") setMissing((e.details?.missing as string[]) ?? []);
        throw e;
      }
    });
  };

  return (
    <div className="stack">
      <PageHead title={t("pkyc.title")} sub={t("pkyc.sub")} />
      <Loaded state={state}>{(v) => {
        const def = v.definition;
        const unlocks = v.required_before.length > 0 && (
          <div className={`alert ${v.verified ? "ok" : "info"}`}><Icon name={v.verified ? "verified_user" : "info"} />
            <span>{t(v.verified ? "pkyc.unlocked" : "pkyc.needed", { what: v.required_before.map((a) => t(`pkyc.action.${a}`)).join(t("common.listSep")) })}</span></div>
        );
        if (!def) return <Empty icon="badge" title={t("kyc.noForm")} />;
        if (!v.file) return (
          <div className="card stack">{unlocks}<Empty icon="badge" title={t("pkyc.none")} hint={t("pkyc.noneHint")}>
            <button className="btn" disabled={busy} onClick={open}><Icon name="add" />{t("kyc.start")}</button></Empty>
            <ErrorBox error={error} /></div>
        );
        const f = v.file;
        const editable = f.status === "DRAFT" || f.status === "RETURNED";
        const shownMissing = missing ?? (editable ? v.missing : []);
        return (
          <>
            <div className="card stack tight">
              <div className="row" style={{ gap: 10, flexWrap: "wrap" }}>
                <span className={`chip ${KYC_TONE[f.status]}`}>{t(`kyc.status.${f.status}`)}</span>
                <span className={`chip ${v.verified ? "green" : "outline"}`}>{t(`pkyc.verification.${v.verification_status}`)}</span>
                {f.submitted_at && <span className="small muted">{t("kyc.submittedOn", { date: dateTime(f.submitted_at) })}</span>}
              </div>
              {unlocks}
              {f.status === "APPROVED" && f.review_due && (
                <div className="alert ok"><Icon name="verified_user" /><span>{t("pkyc.approved", {
                  date: date(`${f.review_due}T12:00:00Z`, { weekday: undefined, year: "numeric" }) })}</span></div>
              )}
              {f.status === "RETURNED" && f.return_note && (
                <div className="alert warn" role="status"><Icon name="warning" /><div>
                  <strong>{t("kyc.returned")}</strong><div>{f.return_note}</div>
                  {f.return_fields.length > 0 && <div className="small">{t("kyc.toCorrect")}: {f.return_fields.map(pathLabel).join(t("common.listSep"))}</div>}
                </div></div>
              )}
              {f.status === "REJECTED" && <div className="alert error"><Icon name="error" /><span>{f.decision_note ?? t("kyc.rejected")}</span></div>}
              {(f.status === "APPROVED" || f.status === "REJECTED") && (
                <button className="btn tonal" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={open}><Icon name="edit" />{t("kyc.update")}</button>
              )}
              <p className="small muted" style={{ margin: 0 }}>{t("pkyc.privacy")}</p>
            </div>

            {missing && missing.length > 0 && (
              <div className="alert error" role="alert"><Icon name="error" /><div>
                <strong>{t("kyc.missingTitle", { n: missing.length })}</strong>
                <div className="small">{missing.slice(0, 12).map(pathLabel).join(t("common.listSep"))}</div>
              </div></div>
            )}

            {def.sections.map((s) => (
              <section key={s.key} className="card stack" aria-labelledby={`pkyc-h-${s.key}`}>
                <h2 id={`pkyc-h-${s.key}`} style={{ margin: 0, fontSize: 18 }}>{text.section(s)}</h2>
                <KycSectionView section={s} def={def} answers={editable ? answers : f.answers} readOnly={!editable}
                                onChange={(a) => { setAnswers(a); setDirty(true); }} errors={errors} missing={shownMissing}
                                highlight={f.status === "RETURNED" ? f.return_fields : []} />
              </section>
            ))}

            {editable && (
              <div className="kyc-actions">
                <ErrorBox error={error} />
                <button className="btn tonal" disabled={busy} onClick={() => save()}><Icon name="save" />{t("kyc.save")}</button>
                <button className="btn" disabled={busy} onClick={submit}><Icon name="send" />{t("kyc.submit")}</button>
                {dirty && <span className="small muted">{t("kyc.unsaved")}</span>}
              </div>
            )}
            {!editable && <ErrorBox error={error} />}
          </>
        );
      }}</Loaded>
    </div>
  );
}
