import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

interface Doc {
  uid: string; doc_type: string; owner_type: string; issuer: string | null; issue_date: string | null; expiry_date: string | null;
  review_note: string | null; created_at: string; file_name: string; mime_type: string; size_bytes: number; company_name: string;
  plate_no: string | null; status: string; days_left: number | null;
}

const kb = (n: number) => `${Math.max(1, Math.round(n / 1024)).toLocaleString("en")} KB`;

function Expiry({ d }: { d: Doc }) {
  const { t, date } = useI18n();
  if (!d.expiry_date) return <span className="muted">—</span>;
  const soon = d.days_left !== null && d.days_left <= 30;
  return (
    <span style={soon ? { color: "var(--error)" } : undefined}>
      {date(`${d.expiry_date}T12:00:00Z`, { day: "numeric", month: "short", year: "numeric" })}
      {soon && d.days_left !== null && d.days_left >= 0 && <div className="small">{t("documents.expiresIn", { n: d.days_left })}</div>}
    </span>
  );
}

// ------------------------------------------------------------------ carrier and agency staff
export function CompanyDocuments() {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ documents: Doc[]; types: string[] }>("/api/company/documents"));
  const vehicles = useLoad(() => (me?.portal === "OPERATOR" ? api.get<{ vehicles: { uid: string; plate_no: string }[] }>("/api/carrier/vehicles") : Promise.resolve({ vehicles: [] })), [me]);
  const blank = { doc_type: "CR", issuer: "", issue_date: "", expiry_date: "", vehicle_uid: "" };
  const [f, setF] = useState(blank);
  const [file, setFile] = useState<File | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const forVehicle = f.doc_type === "VEHICLE_REG" || f.doc_type === "INSURANCE_POLICY";
  const submit = async () => {
    if (!file) return;
    setBusy(true); setError(null);
    const form = new FormData();
    form.append("file", file);
    form.append("doc_type", f.doc_type);
    if (f.issuer) form.append("issuer", f.issuer);
    if (f.issue_date) form.append("issue_date", f.issue_date);
    if (f.expiry_date) form.append("expiry_date", f.expiry_date);
    if (forVehicle && f.vehicle_uid) form.append("vehicle_uid", f.vehicle_uid);
    try {
      await api.upload("/api/company/documents", form);
      setOpen(false); setF(blank); setFile(null); toast(t("documents.uploaded")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("documents.title")} sub={t("documents.sub")}>
        <button className="btn" onClick={() => { setOpen(true); setError(null); }}><Icon name="add" />{t("documents.upload")}</button>
      </PageHead>
      <Loaded state={state}>{({ documents }) => documents.length === 0 ? <div className="card"><Empty icon="fact_check" title={t("documents.none")} hint={t("documents.noneHint")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("documents.type")}</th><th>{t("documents.subject")}</th><th>{t("documents.issuer")}</th><th>{t("documents.expiry")}</th><th>{t("documents.file")}</th><th>{t("common.status")}</th></tr></thead>
          <tbody>{documents.map((d) => (
            <tr key={d.uid}>
              <td style={{ fontWeight: 500 }}>{t(`documents.types.${d.doc_type}`)}<div className="small muted">{dateTime(d.created_at)}</div></td>
              <td>{d.plate_no ? <span className="mono">{d.plate_no}</span> : t("documents.company")}</td>
              <td className="small">{d.issuer ?? "—"}</td>
              <td><Expiry d={d} /></td>
              <td className="small"><a href={`/api/company/documents/${d.uid}/file`}><Icon name="download" size={16} /> {kb(d.size_bytes)}</a></td>
              <td><Status value={d.status} />{d.review_note && <div className="small muted">{d.review_note}</div>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      <p className="small muted"><Icon name="shield" size={16} /> {t("documents.securityNote")}</p>
      {open && (
        <Modal title={t("documents.upload")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !file || (forVehicle && !f.vehicle_uid)} onClick={submit}>{t("documents.upload")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("documents.type")}>
              <select className="input" value={f.doc_type} onChange={set("doc_type")}>
                {(state.data?.types ?? []).map((k) => <option key={k} value={k}>{t(`documents.types.${k}`)}</option>)}
              </select>
            </Field>
            {forVehicle && me?.portal === "OPERATOR" && (
              <Field label={t("documents.vehicle")}>
                <select className="input" value={f.vehicle_uid} onChange={set("vehicle_uid")}>
                  <option value="" disabled>—</option>
                  {(vehicles.data?.vehicles ?? []).map((v) => <option key={v.uid} value={v.uid}>{v.plate_no}</option>)}
                </select>
              </Field>
            )}
            <Field label={`${t("documents.issuer")} (${t("common.optional")})`}><input className="input" value={f.issuer} onChange={set("issuer")} /></Field>
            <div className="grid cols-2">
              <Field label={`${t("documents.issued")} (${t("common.optional")})`}><input className="input ltr" type="date" value={f.issue_date} onChange={set("issue_date")} /></Field>
              <Field label={`${t("documents.expiry")} (${t("common.optional")})`}><input className="input ltr" type="date" value={f.expiry_date} onChange={set("expiry_date")} /></Field>
            </div>
            <Field label={t("documents.file")} hint={t("documents.fileHint")}>
              <input className="input" type="file" accept="application/pdf,image/png,image/jpeg" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
            </Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ platform review
export function AdminDocuments() {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const [status, setStatus] = useState("PENDING");
  const state = useLoad(() => api.get<{ documents: Doc[] }>("/api/admin/documents", { status }), [status]);
  const [reject, setReject] = useState<Doc | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const decide = async (d: Doc, decision: "APPROVE" | "REJECT", why?: string) => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/admin/documents/${d.uid}/decision`, { decision, note: why ?? null });
      setReject(null); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("documents.review")} sub={t("documents.reviewSub")}>
        <select className="input" style={{ width: 200 }} value={status} onChange={(e) => setStatus(e.target.value)}>
          {["PENDING", "APPROVED", "REJECTED"].map((s) => <option key={s} value={s}>{t(`status.${s}`)}</option>)}
        </select>
      </PageHead>
      <ErrorBox error={!reject ? error : null} />
      <Loaded state={state}>{({ documents }) => documents.length === 0 ? <div className="card"><Empty icon="fact_check" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("finance.company")}</th><th>{t("documents.type")}</th><th>{t("documents.subject")}</th><th>{t("documents.expiry")}</th><th>{t("documents.file")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{documents.map((d) => (
            <tr key={d.uid}>
              <td style={{ fontWeight: 500 }}>{d.company_name}<div className="small muted">{dateTime(d.created_at)}</div></td>
              <td>{t(`documents.types.${d.doc_type}`)}<div className="small muted">{d.issuer}</div></td>
              <td>{d.plate_no ? <span className="mono">{d.plate_no}</span> : t("documents.company")}</td>
              <td><Expiry d={d} /></td>
              <td className="small"><a href={`/api/admin/documents/${d.uid}/file`}><Icon name="download" size={16} /> {kb(d.size_bytes)}</a></td>
              <td><Status value={d.status} /></td>
              <td>{d.status === "PENDING" && <div className="row nowrap" style={{ gap: 4 }}>
                <button className="btn tonal small" disabled={busy} onClick={() => decide(d, "APPROVE")}>{t("admin.approve")}</button>
                <button className="btn text small" onClick={() => { setReject(d); setNote(""); setError(null); }}>{t("admin.reject")}</button>
              </div>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      <p className="small muted"><Icon name="shield" size={16} /> {t("documents.reviewNote")}</p>
      {reject && (
        <Modal title={`${t("admin.reject")} · ${t(`documents.types.${reject.doc_type}`)}`} onClose={() => setReject(null)}
               actions={<><button className="btn text" onClick={() => setReject(null)}>{t("common.cancel")}</button>
                 <button className="btn danger" disabled={busy || note.trim().length < 3} onClick={() => decide(reject, "REJECT", note.trim())}>{t("common.confirm")}</button></>}>
          <div className="stack"><ErrorBox error={error} /><Field label={t("common.reason")} hint={t("documents.reasonHint")}><textarea className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field></div>
        </Modal>
      )}
    </div>
  );
}
