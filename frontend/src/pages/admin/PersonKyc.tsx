import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";
import { KycSectionView, usePathLabel, useKycText, type Answers, type KycDefinition } from "../../components/KycForm";
import { KYC_TONE, type KycStatus } from "../carrier/Kyc";

// Drivers' and passengers' KYC files for the platform (owner's request N14, migration 1159). One compliance reviewer
// approves, returns or rejects a file, never the person who entered it; approval verifies the person. The identity
// document's number is shown masked; showing it needs a reason and is recorded.

interface Row {
  uid: string; subject_kind: "DRIVER" | "PASSENGER"; version: number; status: KycStatus; completeness: number; submitted_at: string | null;
  approved_at: string | null; review_due: string | null; person_uid: string; person_name: string; verification_status: string;
}
interface FileFull {
  uid: string; subject_kind: "DRIVER" | "PASSENGER"; version: number; status: KycStatus; answers: Answers; definition: KycDefinition;
  return_note: string | null; return_fields: string[]; decision_note: string | null; submitted_at: string | null; decided_at: string | null;
  approved_at: string | null; review_due: string | null; decided_by_email: string | null; form_version: number; may_decide: boolean;
  person: { uid: string; name: string; verification_status: string; email: string | null; id_no_last4: string | null };
  versions: { uid: string; version: number; status: KycStatus }[];
}

export function PersonFiles({ onOpen }: { onOpen: (uid: string) => void }) {
  const { t, date } = useI18n();
  const [status, setStatus] = useState<"WAITING" | "ALL" | "DUE">("WAITING");
  const [kind, setKind] = useState<"" | "DRIVER" | "PASSENGER">("");
  const state = useLoad(() => api.get<{ files: Row[] }>(`/api/admin/person-kyc?status=${status}${kind ? `&kind=${kind}` : ""}`), [status, kind]);
  return (
    <div className="stack">
      <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
        <div className="segmented" role="tablist" aria-label={t("kycadm.filter")}>
          {(["WAITING", "ALL", "DUE"] as const).map((s) => (
            <button key={s} role="tab" aria-selected={status === s} className={status === s ? "on" : ""} onClick={() => setStatus(s)}>{t(`kycadm.filterOf.${s}`)}</button>
          ))}
        </div>
        <select className="input" style={{ maxWidth: 220 }} aria-label={t("pkyc.kindLabel")} value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
          <option value="">{t("pkyc.kindAll")}</option>
          {(["DRIVER", "PASSENGER"] as const).map((k) => <option key={k} value={k}>{t(`pkyc.kind.${k}`)}</option>)}
        </select>
      </div>
      <div className="card">
        <Loaded state={state}>{({ files }) => files.length === 0 ? <Empty icon="badge" title={t("kycadm.none")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("pkyc.person")}</th><th>{t("pkyc.kindLabel")}</th><th>{t("kycadm.state")}</th><th>{t("kycadm.submitted")}</th>
              <th>{t("kycadm.reviewDue")}</th><th /></tr></thead>
            <tbody>{files.map((r) => (
              <tr key={r.uid}>
                <td style={{ minWidth: 180 }}>{r.person_name}<div className="small muted">{t(`pkyc.verification.${r.verification_status}`)}</div></td>
                <td>{t(`pkyc.kind.${r.subject_kind}`)}</td>
                <td><span className={`chip ${KYC_TONE[r.status]}`}>{t(`kyc.status.${r.status}`)}</span></td>
                <td className="small text-nowrap">{r.submitted_at ? date(r.submitted_at) : "—"}</td>
                <td className="small text-nowrap">{r.review_due ? date(`${r.review_due}T12:00:00Z`, { weekday: undefined, year: "numeric" }) : "—"}</td>
                <td><button className="btn text small" onClick={() => onOpen(r.uid)}><Icon name="open_in_new" />{t("kycadm.open")}</button></td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
    </div>
  );
}

export function PersonFileView({ uid, onBack }: { uid: string; onBack: () => void }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const text = useKycText();
  const state = useLoad(() => api.get<FileFull>(`/api/admin/person-kyc/${uid}`), [uid]);
  const pathLabel = usePathLabel(state.data?.definition ?? null);
  const [decision, setDecision] = useState<"APPROVE" | "RETURN" | "REJECT">("APPROVE");
  const [note, setNote] = useState("");
  const [fields, setFields] = useState<string[]>([]);
  const [reveal, setReveal] = useState<{ path: string; resolve: (v: string) => void } | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const onReveal = (path: string) => new Promise<string>((resolve) => { setReason(""); setReveal({ path, resolve }); });
  const doReveal = async () => {
    if (!reveal) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ value: string }>(`/api/admin/person-kyc/${uid}/reveal`, { path: reveal.path, reason });
      reveal.resolve(out.value); setReveal(null);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const decide = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ status: string }>(`/api/admin/person-kyc/${uid}/decide`,
        { decision, note: note || null, fields: decision === "RETURN" ? fields : [] });
      toast(t(`kycadm.done.${out.status}`)); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Loaded state={state}>{(f) => (
      <div className="stack">
        <button className="btn text" style={{ alignSelf: "flex-start" }} onClick={onBack}><Icon name="arrow_back" flip />{t("kycadm.back")}</button>
        <div className="card stack tight">
          <div className="row" style={{ gap: 10, flexWrap: "wrap" }}>
            <h2 style={{ margin: 0, fontSize: 20 }}>{f.person.name}</h2>
            <span className="chip outline">{t(`pkyc.kind.${f.subject_kind}`)}</span>
            <span className={`chip ${KYC_TONE[f.status]}`}>{t(`kyc.status.${f.status}`)}</span>
            <span className="chip">{t(`pkyc.verification.${f.person.verification_status}`)}</span>
          </div>
          <div className="small muted">{[f.person.email, t("kyc.versionOf", { v: f.version, form: f.form_version }),
            f.submitted_at ? t("kyc.submittedOn", { date: dateTime(f.submitted_at) }) : null].filter(Boolean).join(" · ")}</div>
          {f.decided_by_email && f.decided_at && <div className="small">{t("pkyc.decidedBy", { who: f.decided_by_email, date: dateTime(f.decided_at) })}</div>}
          {f.return_note && <div className="alert warn"><Icon name="warning" /><span>{f.return_note}</span></div>}
          {f.decision_note && <div className="small">{f.decision_note}</div>}
        </div>
        {f.definition.sections.map((s) => (
          <section key={s.key} className="card stack" aria-labelledby={`pk-h-${s.key}`}>
            <h3 id={`pk-h-${s.key}`} style={{ margin: 0 }}>{text.section(s)}</h3>
            <KycSectionView section={s} def={f.definition} answers={f.answers} readOnly onChange={() => undefined} errors={{}} missing={[]}
                            highlight={f.return_fields} onReveal={onReveal} />
          </section>
        ))}
        {f.may_decide && (
          <div className="card stack">
            <h2 style={{ margin: 0, fontSize: 18 }}>{t("pkyc.decideTitle")}</h2>
            <div className="row" role="radiogroup" aria-label={t("kycadm.decision")} style={{ gap: 16, flexWrap: "wrap" }}>
              {(["APPROVE", "RETURN", "REJECT"] as const).map((d) => (
                <label key={d} className="row" style={{ gap: 6 }}><input type="radio" name="pkyc-decision" checked={decision === d} onChange={() => setDecision(d)} />
                  {t(`kycadm.decisionOf.${d}`)}</label>
              ))}
            </div>
            {decision === "RETURN" && (
              <Field label={t("kycadm.fieldsToCorrect")}>
                <select className="input" multiple size={6} value={fields} onChange={(e) => setFields(Array.from(e.target.selectedOptions).map((o) => o.value))}>
                  {f.definition.sections.map((s) => (
                    <optgroup key={s.key} label={text.section(s)}>{s.fields.map((x) => <option key={x.key} value={x.key}>{text.field(x)}</option>)}</optgroup>
                  ))}
                </select>
              </Field>
            )}
            <Field label={decision === "APPROVE" ? t("kycadm.noteOptional") : t("kycadm.noteRequired")}>
              <textarea className="input" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)} />
            </Field>
            <ErrorBox error={reveal ? null : error} />
            <button className={`btn${decision === "REJECT" ? " danger" : ""}`} style={{ alignSelf: "flex-start" }} disabled={busy} onClick={decide}>
              <Icon name={decision === "APPROVE" ? "check" : decision === "RETURN" ? "undo" : "close"} />{t(`kycadm.decisionOf.${decision}`)}</button>
          </div>
        )}
        {!f.may_decide && <ErrorBox error={reveal ? null : error} />}
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
    )}</Loaded>
  );
}
