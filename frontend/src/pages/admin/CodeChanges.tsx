import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Codes that can be changed (owner's request N39, migration 1161): the platform previews every code a change touches
// (a governorate's districts and sub-districts, a city's stations), asks for it with a reason and a date, and another
// person approves it. The old codes stay as aliases, so what was recorded with them is still found.

type Kind = "AREA" | "PLACE" | "CITY" | "STATION";
interface Item { kind: Kind; old: string; new: string; name: string }
interface Plan { kind: Kind; old: string; new: string; items: Item[]; conflicts: { code: string; problem: string }[] }
interface Change { uid: string; kind: Kind; old_code: string; new_code: string; reason: string; source_document: string | null;
  effective_on: string; status: string; codes: number; plan: Item[]; requested_at: string; requested_by: string; decided_at: string | null;
  decided_by: string | null; decision_note: string | null; applied_at: string | null; failure: string | null; mine: boolean }
interface History { kind: Kind; code: string; old_codes: { code: string; valid_from: string | null; valid_to: string }[] }

const KINDS: Kind[] = ["AREA", "PLACE", "CITY", "STATION"];
const OPEN = ["PENDING", "APPROVED"];

export function CodeChanges({ onChange }: { onChange: () => void }) {
  const { t, date, num } = useI18n();
  const toast = useToast();
  const list = useLoad((signal) => api.get<{ changes: Change[] }>("/api/admin/geo/codes/changes", undefined, { signal }));
  const blank = { kind: "CITY" as Kind, code: "", new_code: "", reason: "", source_document: "", effective_on: "" };
  const [f, setF] = useState(blank);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [open, setOpen] = useState(false);
  const [deciding, setDeciding] = useState<Change | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [lookup, setLookup] = useState({ kind: "CITY" as Kind, code: "" });
  const [history, setHistory] = useState<History | null>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setF({ ...f, [k]: e.target.value }); if (k === "kind" || k === "code" || k === "new_code") setPlan(null);
  };
  const run = async (fn: () => Promise<void>) => {
    setBusy(true); setError(null);
    try { await fn(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const preview = () => run(async () => {
    setPlan(await api.post<Plan>("/api/admin/geo/codes/preview", { kind: f.kind, code: f.code.trim().toUpperCase(), new_code: f.new_code.trim().toUpperCase() }));
  });
  const ask = () => run(async () => {
    await api.post("/api/admin/geo/codes/changes", { kind: f.kind, code: f.code.trim().toUpperCase(), new_code: f.new_code.trim().toUpperCase(),
      reason: f.reason, source_document: f.source_document || undefined, effective_on: f.effective_on || undefined });
    toast(t("codes.asked")); setOpen(false); setF(blank); setPlan(null); list.reload();
  });
  const decide = (approve: boolean) => run(async () => {
    if (!deciding) return;
    const out = await api.post<{ status: string; failure: string | null }>(`/api/admin/geo/codes/changes/${deciding.uid}/decide`, { approve, note: note || undefined });
    toast(t(`codes.status.${out.status}`)); setDeciding(null); setNote(""); list.reload(); if (out.status === "APPLIED") onChange();
  });
  const cancel = (c: Change) => run(async () => {
    await api.post(`/api/admin/geo/codes/changes/${c.uid}/cancel`, {}); toast(t("codes.status.CANCELLED")); list.reload();
  });
  const find = () => run(async () => {
    setHistory(await api.get<History>(`/api/admin/geo/codes/history?kind=${lookup.kind}&code=${encodeURIComponent(lookup.code.trim().toUpperCase())}`));
  });
  const items = (rows: Item[]) => (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("codes.what")}</th><th>{t("codes.old")}</th><th>{t("codes.new")}</th></tr></thead>
      <tbody>{rows.map((i) => (
        <tr key={`${i.kind}-${i.old}`}><td>{t(`codes.kind.${i.kind}`)} <span className="small muted">{i.name}</span></td>
          <td className="mono">{i.old}</td><td className="mono"><strong>{i.new}</strong></td></tr>
      ))}</tbody>
    </table></div>
  );
  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
        <div>
          <h3 style={{ margin: 0 }}>{t("codes.title")}</h3>
          <p className="small muted" style={{ margin: 0 }}>{t("codes.hint")}</p>
        </div>
        <button className="btn outlined" onClick={() => setOpen(true)}><Icon name="edit" />{t("codes.add")}</button>
      </div>
      <ErrorBox error={error} />
      <Loaded state={list}>{({ changes }) => changes.length === 0 ? <Empty icon="code" title={t("codes.none")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("codes.what")}</th><th>{t("codes.old")}</th><th>{t("codes.new")}</th><th className="num">{t("codes.codes")}</th>
            <th>{t("codes.effective")}</th><th>{t("codes.state")}</th><th /></tr></thead>
          <tbody>{changes.map((c) => (
            <tr key={c.uid}>
              <td>{t(`codes.kind.${c.kind}`)}<div className="small muted">{c.reason}{c.source_document ? ` (${c.source_document})` : ""}</div></td>
              <td className="mono">{c.old_code}</td><td className="mono"><strong>{c.new_code}</strong></td>
              <td className="num">{num(c.codes)}</td><td>{date(c.effective_on)}</td>
              <td><span className="chip">{t(`codes.status.${c.status}`)}</span>
                <div className="small muted">{c.requested_by}{c.decided_by ? ` / ${c.decided_by}` : ""}</div>
                {c.decision_note && <div className="small muted">{c.decision_note}</div>}
                {c.failure && <div className="small" style={{ color: "var(--error)" }}>{c.failure}</div>}</td>
              <td className="row" style={{ gap: 4 }}>
                {c.status === "PENDING" && !c.mine && <button className="btn text small" onClick={() => setDeciding(c)}>{t("codes.decide")}</button>}
                {OPEN.includes(c.status) && c.mine && <button className="btn text small" disabled={busy} onClick={() => cancel(c)}>{t("codes.cancel")}</button>}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      <div className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "end" }}>
        <Field label={t("codes.kindLabel")}>
          <select className="input" value={lookup.kind} onChange={(e) => setLookup({ ...lookup, kind: e.target.value as Kind })}>
            {KINDS.map((k) => <option key={k} value={k}>{t(`codes.kind.${k}`)}</option>)}</select>
        </Field>
        <Field label={t("codes.findCode")}>
          <input className="input mono" value={lookup.code} onChange={(e) => setLookup({ ...lookup, code: e.target.value })} />
        </Field>
        <button className="btn outlined" disabled={busy || lookup.code.trim().length < 3} onClick={find}><Icon name="history" />{t("codes.history")}</button>
      </div>
      {history && (
        <p className="small" style={{ margin: 0 }}>
          {t("codes.now")} <strong className="mono">{history.code}</strong>
          {history.old_codes.length === 0 ? ` - ${t("codes.noOld")}` : history.old_codes.map((h) => (
            <span key={h.code}> · <span className="mono">{h.code}</span> {t("codes.until", { date: date(h.valid_to) })}</span>))}
        </p>
      )}
      {open && (
        <Modal title={t("codes.add")} onClose={() => setOpen(false)}>
          <div className="stack">
            <div className="grid cols-3">
              <Field label={t("codes.kindLabel")}>
                <select className="input" value={f.kind} onChange={set("kind")}>{KINDS.map((k) => <option key={k} value={k}>{t(`codes.kind.${k}`)}</option>)}</select>
              </Field>
              <Field label={t("codes.old")}><input className="input mono" value={f.code} onChange={set("code")} /></Field>
              <Field label={t("codes.new")}><input className="input mono" value={f.new_code} onChange={set("new_code")} /></Field>
            </div>
            <p className="small muted" style={{ margin: 0 }}>{t(`codes.rule.${f.kind}`)}</p>
            <button className="btn outlined" disabled={busy || !f.code || !f.new_code} onClick={preview}><Icon name="visibility" />{t("codes.preview")}</button>
            {plan && (
              <>
                {items(plan.items)}
                {plan.conflicts.length > 0
                  ? <div className="alert error">{plan.conflicts.map((c) => <div key={c.code}><span className="mono">{c.code}</span>: {t(`codes.problem.${c.problem}`)}</div>)}</div>
                  : <p className="small muted" style={{ margin: 0 }}>{t("codes.kept")}</p>}
              </>
            )}
            <Field label={t("codes.reason")}><input className="input" value={f.reason} onChange={set("reason")} /></Field>
            <div className="grid cols-2">
              <Field label={t("codes.source")}><input className="input" value={f.source_document} onChange={set("source_document")} /></Field>
              <Field label={t("codes.effective")}><input className="input" type="date" value={f.effective_on} onChange={set("effective_on")} /></Field>
            </div>
            <div className="row" style={{ justifyContent: "flex-end", gap: 8 }}>
              <button className="btn" disabled={busy || !plan || plan.conflicts.length > 0 || f.reason.trim().length < 5} onClick={ask}>{t("codes.ask")}</button>
            </div>
          </div>
        </Modal>
      )}
      {deciding && (
        <Modal title={t("codes.decide")} onClose={() => setDeciding(null)}>
          <div className="stack">
            <p style={{ margin: 0 }}>{t(`codes.kind.${deciding.kind}`)}: <span className="mono">{deciding.old_code}</span> → <strong className="mono">{deciding.new_code}</strong></p>
            <p className="small muted" style={{ margin: 0 }}>{deciding.reason}{deciding.source_document ? ` (${deciding.source_document})` : ""} · {t("codes.effective")} {date(deciding.effective_on)}</p>
            {items(deciding.plan)}
            <Field label={t("codes.note")}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
            <div className="row" style={{ justifyContent: "flex-end", gap: 8 }}>
              <button className="btn outlined" disabled={busy} onClick={() => decide(false)}>{t("codes.reject")}</button>
              <button className="btn" disabled={busy} onClick={() => decide(true)}>{t("codes.approve")}</button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
