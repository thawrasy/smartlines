import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Carriers' ranges of trip numbers (owner's request N7, migration 1165): every carrier has the whole block of each
// trip type unless the platform narrows it here; the platform widens it again, which also answers the carrier's request.

interface Data { blocks: Record<string, { from: number; to: number }>;
  ranges: { company_uid: string; company: string; block: string; from_no: number; to_no: number; note: string | null; set_by: string | null; set_at: string; ended_at: string | null }[];
  requests: { uid: string; company_uid: string; company: string; block: string; note: string; status: string; requested_at: string; answer: string | null }[] }
interface Company { uid: string; legal_name: string; company_type: string }

export function AdminNumberRanges() {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Data>("/api/admin/number-ranges", undefined, { signal }));
  const companies = useLoad((signal) => api.get<{ companies: Company[] }>("/api/admin/companies", undefined, { signal }));
  const [form, setForm] = useState<{ company_uid: string; block: string; from_no: string; to_no: string; note: string; whole: boolean } | null>(null);
  const [declining, setDeclining] = useState<{ uid: string; answer: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, after: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); after(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const save = () => form && run(() => api.put("/api/admin/number-ranges", {
    company_uid: form.company_uid, block: form.block, note: form.note || undefined,
    ...(form.whole ? {} : { from_no: Number(form.from_no), to_no: Number(form.to_no) }) }), () => setForm(null));
  const open = (company_uid = "", block = "SCHEDULED") => { setError(null); setForm({ company_uid, block, from_no: "", to_no: "", note: "", whole: false }); };
  return (
    <div className="stack">
      <PageHead title={t("numbers.adminTitle")} sub={t("numbers.adminSub")}>
        <button className="btn" onClick={() => open()}><Icon name="tune" />{t("numbers.set")}</button>
      </PageHead>
      <Loaded state={state}>{(d) => (
        <>
          <div className="card row" style={{ gap: 8, flexWrap: "wrap" }}>
            <strong>{t("numbers.blocks")}:</strong>
            {Object.entries(d.blocks).map(([b, r]) => <span key={b} className="chip outline mono">{t(`numbers.block.${b}`)} {r.from}–{r.to}</span>)}
          </div>
          <div className="card stack"><h3 style={{ margin: 0 }}>{t("numbers.requests")}</h3>
            {d.requests.length === 0 ? <Empty icon="send" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("numbers.carrier")}</th><th>{t("numbers.blockCol")}</th><th>{t("numbers.note")}</th><th>{t("common.status")}</th><th /></tr></thead>
                <tbody>{d.requests.map((q) => (
                  <tr key={q.uid}><td>{q.company}<div className="small muted">{date(q.requested_at)}</div></td><td>{t(`numbers.block.${q.block}`)}</td>
                    <td className="small">{q.note}{q.answer && <div className="muted">{q.answer}</div>}</td><td>{t(`numbers.st.${q.status}`)}</td>
                    <td>{q.status === "OPEN" && <div className="row nowrap" style={{ gap: 4 }}>
                      <button className="btn text small" onClick={() => open(q.company_uid, q.block)}>{t("numbers.widen")}</button>
                      <button className="btn text small" onClick={() => { setError(null); setDeclining({ uid: q.uid, answer: "" }); }}>{t("numbers.decline")}</button></div>}</td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
          <div className="card stack"><h3 style={{ margin: 0 }}>{t("numbers.ranges")}</h3>
            {d.ranges.length === 0 ? <Empty icon="tune" title={t("numbers.noneSet")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("numbers.carrier")}</th><th>{t("numbers.blockCol")}</th><th>{t("numbers.range")}</th><th>{t("numbers.note")}</th><th>{t("numbers.by")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{d.ranges.map((r) => (
                  <tr key={`${r.company_uid}-${r.block}-${r.set_at}`}><td>{r.company}</td><td>{t(`numbers.block.${r.block}`)}</td>
                    <td className="mono">{r.from_no}–{r.to_no}</td><td className="small">{r.note ?? "—"}</td>
                    <td className="small">{r.set_by ?? "—"}<div className="muted">{date(r.set_at)}</div></td>
                    <td>{r.ended_at ? t("numbers.ended") : t("numbers.current")}</td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
        </>
      )}</Loaded>
      {form && (
        <Modal title={t("numbers.set")} onClose={() => setForm(null)}
               actions={<><button className="btn text" onClick={() => setForm(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !form.company_uid || (!form.whole && (!form.from_no || !form.to_no))} onClick={save}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("numbers.carrier")}>
              <select className="input" value={form.company_uid} onChange={(e) => setForm({ ...form, company_uid: e.target.value })}>
                <option value="">—</option>
                {companies.data?.companies.filter((c) => c.company_type === "CARRIER").map((c) => <option key={c.uid} value={c.uid}>{c.legal_name}</option>)}
              </select>
            </Field>
            <Field label={t("numbers.blockCol")}>
              <select className="input" value={form.block} onChange={(e) => setForm({ ...form, block: e.target.value })}>
                {["SCHEDULED", "INTL", "SHUTTLE", "CARGO", "EXTRA"].map((b) => <option key={b} value={b}>{t(`numbers.block.${b}`)}</option>)}
              </select>
            </Field>
            <label className="check"><input type="checkbox" checked={form.whole} onChange={(e) => setForm({ ...form, whole: e.target.checked })} />{t("numbers.whole")}</label>
            {!form.whole && <div className="grid cols-2">
              <Field label={t("numbers.from")}><input className="input ltr mono" inputMode="numeric" maxLength={4} value={form.from_no} onChange={(e) => setForm({ ...form, from_no: e.target.value.replace(/\D/g, "") })} /></Field>
              <Field label={t("numbers.to")}><input className="input ltr mono" inputMode="numeric" maxLength={4} value={form.to_no} onChange={(e) => setForm({ ...form, to_no: e.target.value.replace(/\D/g, "") })} /></Field>
            </div>}
            <Field label={t("numbers.note")}><input className="input" maxLength={500} value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
      {declining && (
        <Modal title={t("numbers.decline")} onClose={() => setDeclining(null)}
               actions={<><button className="btn text" onClick={() => setDeclining(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || declining.answer.trim().length < 3}
                         onClick={() => run(() => api.post(`/api/admin/number-ranges/requests/${declining.uid}/decline`, { answer: declining.answer }), () => setDeclining(null))}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("numbers.answer")}><textarea className="input" maxLength={500} value={declining.answer} onChange={(e) => setDeclining({ ...declining, answer: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
