import { useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Empty, ErrorBox, Field, Loaded, Modal, useLoad, useToast } from "./ui";

// A record edited in place, with its history of changes (1170, 1171). The fields are listed by the page that opens
// it; the regulated ones need a reason, which the database keeps in the record's history with who changed it and when.

export interface EditField {
  key: string;
  label: string;
  kind?: "text" | "number" | "date" | "email" | "select";
  options?: { value: string; label: string }[];
  ltr?: boolean;
}
interface History { changed_at: string; field: string; old_value: string | null; new_value: string | null; reason: string | null; changed_by: string | null }

export function RecordEditor({ title, url, record, fields, regulated, onClose }: {
  title: string; url: string; record: string; fields: EditField[]; regulated: string[]; onClose: () => void;
}) {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Record<string, unknown>>(url), [url]);
  const [tab, setTab] = useState<"details" | "history">("details");
  const [f, setF] = useState<Record<string, string> | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const data = state.data?.[record] as Record<string, unknown> | undefined;
  const history = (state.data?.history ?? []) as History[];
  const base = data ? Object.fromEntries(fields.map((x) => [x.key, data[x.key] == null ? "" : String(data[x.key])])) : null;
  const form = f ?? base;
  const changed = form && base ? fields.map((x) => x.key).filter((k) => form[k] !== base[k]) : [];
  const needsReason = changed.some((k) => regulated.includes(k));
  const save = async () => {
    if (!form) return;
    setBusy(true); setError(null);
    try {
      const body: Record<string, unknown> = {};
      for (const k of changed) {
        const kind = fields.find((x) => x.key === k)?.kind;
        const v = form[k].trim();
        body[k] = kind === "number" ? (v ? Number(v) : null) : (v || null);
      }
      if (reason.trim()) body.reason = reason.trim();
      await api.patch(url, body);
      toast(t("common.saved")); setF(null); setReason(""); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={title} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.close")}</button>
             {tab === "details" && <button className="btn" disabled={busy || changed.length === 0 || (needsReason && reason.trim().length < 3)} onClick={save}>{t("common.save")}</button>}</>}>
      <div className="stack">
        <div className="row" role="tablist" style={{ gap: 8 }}>
          {(["details", "history"] as const).map((k) => (
            <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "tonal"} small`} onClick={() => setTab(k)}>{t(`edit.tab.${k}`)}</button>))}
        </div>
        <ErrorBox error={error} />
        <Loaded state={state}>{() => (<>
          {tab === "details" && form && (<>
            <div className="grid cols-3">{fields.map((x) => (
              <Field key={x.key} label={regulated.includes(x.key) ? `${x.label} *` : x.label}>
                {x.kind === "select"
                  ? <select className="input" value={form[x.key]} onChange={(e) => setF({ ...form, [x.key]: e.target.value })}>
                      {(x.options ?? []).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                  : <input className={`input${x.ltr || x.kind === "number" || x.kind === "date" || x.kind === "email" ? " ltr" : ""}`}
                           type={x.kind === "date" ? "date" : x.kind === "email" ? "email" : "text"} inputMode={x.kind === "number" ? "decimal" : undefined}
                           value={form[x.key]} onChange={(e) => setF({ ...form, [x.key]: e.target.value })} />}
              </Field>))}
            </div>
            <Field label={needsReason ? t("edit.reasonRequired") : t("edit.reason")} optional={!(needsReason)} hint={t("edit.regulatedHint")}>
              <input className="input" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </>)}
          {tab === "history" && (history.length === 0 ? <Empty icon="history" title={t("edit.noHistory")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("edit.when")}</th><th>{t("edit.field")}</th><th>{t("edit.before")}</th><th>{t("edit.after")}</th><th>{t("edit.reason")}</th><th>{t("edit.by")}</th></tr></thead>
              <tbody>{history.map((h, i) => (
                <tr key={i}><td className="small">{date(h.changed_at)}</td><td>{fields.find((x) => x.key === h.field)?.label ?? h.field}</td>
                  <td className="small">{h.old_value ?? "—"}</td><td className="small">{h.new_value ?? "—"}</td>
                  <td className="small">{h.reason ?? "—"}</td><td className="small ltr">{h.changed_by ?? "—"}</td></tr>))}</tbody>
            </table></div>))}
        </>)}</Loaded>
      </div>
    </Modal>
  );
}
