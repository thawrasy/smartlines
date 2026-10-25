import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// The carrier's trip numbers (owner's request N7, migration 1165): its range in each block (the whole block unless the
// platform narrowed it) and its requests for a wider range.

interface Ranges { ranges: { block: string; from: number; to: number }[];
  requests: { uid: string; block: string; note: string; status: string; requested_at: string; answer: string | null }[] }

export function CarrierNumberRanges() {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Ranges>("/api/carrier/number-ranges", undefined, { signal }));
  const [asking, setAsking] = useState(false);
  const [ask, setAsk] = useState({ block: "SCHEDULED", note: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const send = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/carrier/number-ranges/requests", ask); setAsking(false); toast(t("numbers.asked")); state.reload(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="card stack">
      <div className="row between"><h3 style={{ margin: 0 }}>{t("numbers.mine")}</h3>
        <button className="btn outlined small" onClick={() => setAsking(true)}><Icon name="send" />{t("numbers.ask")}</button></div>
      <Loaded state={state}>{(d) => (
        <>
          <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
            {d.ranges.map((r) => <span key={r.block} className="chip outline mono">{t(`numbers.block.${r.block}`)} {r.from}–{r.to}</span>)}
          </div>
          {d.requests.length > 0 && (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("numbers.blockCol")}</th><th>{t("numbers.note")}</th><th>{t("common.status")}</th><th>{t("numbers.answer")}</th></tr></thead>
              <tbody>{d.requests.map((q) => (
                <tr key={q.uid}><td>{t(`numbers.block.${q.block}`)}<div className="small muted">{date(q.requested_at)}</div></td><td className="small">{q.note}</td>
                  <td>{t(`numbers.st.${q.status}`)}</td><td className="small">{q.answer ?? "—"}</td></tr>
              ))}</tbody>
            </table></div>
          )}
        </>
      )}</Loaded>
      {asking && (
        <Modal title={t("numbers.ask")} onClose={() => setAsking(false)}
               actions={<><button className="btn text" onClick={() => setAsking(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || ask.note.trim().length < 3} onClick={send}>{t("numbers.send")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("numbers.blockCol")}>
              <select className="input" value={ask.block} onChange={(e) => setAsk({ ...ask, block: e.target.value })}>
                {["SCHEDULED", "INTL", "SHUTTLE", "CARGO", "EXTRA"].map((b) => <option key={b} value={b}>{t(`numbers.block.${b}`)}</option>)}
              </select>
            </Field>
            <Field label={t("numbers.note")}><textarea className="input" maxLength={500} value={ask.note} onChange={(e) => setAsk({ ...ask, note: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
