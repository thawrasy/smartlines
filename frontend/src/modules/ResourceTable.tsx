import { useEffect, useMemo, useState, type ReactNode } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Empty, ErrorBox, Field, Icon, Modal, Spinner, Status, useLoad, useToast } from "../components/ui";
import { useLabels } from "./labels";

export interface ColSpec { name: string; type: string; required: boolean; choices: string[] | null; ref: string | null; money: boolean }
export interface ResSpec {
  key: string; module: string; group: string; table: string; pk: string[]; list: ColSpec[]; form: ColSpec[];
  create: boolean; update: boolean; delete: boolean; actions: { name: string; when: Record<string, (string | null | boolean)[]> }[];
}
type Row = Record<string, unknown> & { _key: string };

const LONG_TEXT = /(description|comment|terms|reason|body|input|expected|note|address_text|content_desc|detail)$/;
const isRange = (t: string) => t.endsWith("range");
const isInt = (t: string) => ["smallint", "integer", "bigint"].includes(t);
const isNum = (t: string) => isInt(t) || t.startsWith("numeric") || t === "double precision" || t === "real";
const isJson = (t: string) => t === "jsonb" || t === "json";

/** Type of a column the spec does not list, read from its value (timestamps arrive as ISO strings). */
function guessType(v: unknown) {
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) return "timestamp with time zone";
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v)) return "date";
  if (typeof v === "number") return Number.isInteger(v) ? "bigint" : "numeric";
  return "text";
}

/** Shows one value of a record the way people read it. */
export function useCell() {
  const { money, date, dateTime, num, t } = useI18n();
  const L = useLabels();
  return (col: ColSpec, row: Record<string, unknown>): ReactNode => {
    const v = row[col.name];
    if (v === null || v === undefined || v === "") return <span className="muted">—</span>;
    if (col.ref) return String(row[`${col.name}__label`] ?? v);
    if (col.name === "status" || col.name === "state" || col.name === "compliance_state") return <Status value={String(v)} />;
    if (col.choices) return L.value(String(v));
    if (col.money && typeof v === "number") return money(v);
    if (typeof v === "boolean") return <Icon name={v ? "check_circle" : "cancel"} size={18} />;
    if (isRange(col.type) && Array.isArray(v)) {
      const f = (x: unknown) => (x ? (col.type === "daterange" ? date(`${x}T12:00:00Z`, { day: "numeric", month: "short", year: "numeric" }) : dateTime(String(x))) : "…");
      return `${f(v[0])} → ${f(v[1])}`;
    }
    if (col.type.startsWith("timestamp")) return dateTime(String(v));
    if (col.type === "date") return date(`${v}T12:00:00Z`, { day: "numeric", month: "short", year: "numeric" });
    if (Array.isArray(v)) return v.join(", ");
    if (typeof v === "object") return <span className="muted small ltr">{JSON.stringify(v).slice(0, 60)}</span>;
    if (typeof v === "number" && isNum(col.type)) return num(v);
    if (col.name === "uid") return <span className="ltr small muted">{String(v).slice(0, 8)}</span>;
    return String(v).length > 80 ? `${String(v).slice(0, 80)}…` : String(v) || t("common.optional");
  };
}

function RefInput({ res, col, value, label, onChange }: { res: string; col: ColSpec; value: unknown; label?: string; onChange: (v: unknown) => void }) {
  const { t } = useI18n();
  const [q, setQ] = useState("");
  const [opts, setOpts] = useState<{ id: number | string; label: string }[]>([]);
  useEffect(() => {
    let live = true;
    const id = setTimeout(() => {
      api.get<{ options: { id: number | string; label: string }[] }>(`/api/r/${res}/lookup/${col.name}`, { q: q || undefined })
        .then((d) => live && setOpts(d.options)).catch(() => live && setOpts([]));
    }, 250);
    return () => { live = false; clearTimeout(id); };
  }, [q, res, col.name]);
  const current = opts.find((o) => String(o.id) === String(value));
  return (
    <div className="stack tight">
      <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={`${t("common.search")}…`} />
      <select value={value === null || value === undefined ? "" : String(value)} onChange={(e) => onChange(e.target.value === "" ? null : e.target.value)}>
        <option value="">{label && !current && value ? label : "—"}</option>
        {opts.map((o) => <option key={String(o.id)} value={String(o.id)}>{o.label}</option>)}
      </select>
    </div>
  );
}

/** One form input, chosen from the column's database type. Money is entered in pounds and sent in minor units. */
export function FieldInput({ res, col, value, label, onChange }: { res: string; col: ColSpec; value: unknown; label?: string; onChange: (v: unknown) => void }) {
  const L = useLabels();
  const t = col.type;
  if (col.ref) return <RefInput res={res} col={col} value={value} label={label} onChange={onChange} />;
  if (col.choices) {
    return (
      <select value={value === null || value === undefined ? "" : String(value)} onChange={(e) => onChange(e.target.value || null)}>
        <option value="">—</option>
        {col.choices.map((c) => <option key={c} value={c}>{L.value(c)}</option>)}
      </select>
    );
  }
  if (t === "boolean") return <input type="checkbox" checked={value === true} onChange={(e) => onChange(e.target.checked)} style={{ width: 22, height: 22 }} />;
  if (isRange(t)) {
    const [a, b] = Array.isArray(value) ? value : [null, null];
    const kind = t === "daterange" ? "date" : "datetime-local";
    const norm = (x: unknown) => (x ? String(x).slice(0, kind === "date" ? 10 : 16) : "");
    return (
      <div className="row nowrap">
        <input type={kind} value={norm(a)} onChange={(e) => onChange([e.target.value || null, b ?? null])} />
        <span className="muted">→</span>
        <input type={kind} value={norm(b)} onChange={(e) => onChange([a ?? null, e.target.value || null])} />
      </div>
    );
  }
  if (t === "date") return <input type="date" value={value ? String(value).slice(0, 10) : ""} onChange={(e) => onChange(e.target.value || null)} />;
  if (t.startsWith("timestamp")) return <input type="datetime-local" value={value ? String(value).slice(0, 16) : ""} onChange={(e) => onChange(e.target.value ? new Date(e.target.value).toISOString() : null)} />;
  if (t.startsWith("time")) return <input type="time" value={value ? String(value).slice(0, 5) : ""} onChange={(e) => onChange(e.target.value || null)} />;
  if (col.money) {
    return <input type="number" min={0} step="0.01" dir="ltr" value={typeof value === "number" ? value / 100 : ""}
                  onChange={(e) => onChange(e.target.value === "" ? null : Math.round(Number(e.target.value) * 100))} />;
  }
  if (isNum(t)) return <input type="number" dir="ltr" step={isInt(t) ? 1 : "any"} value={value === null || value === undefined ? "" : String(value)} onChange={(e) => onChange(e.target.value === "" ? null : Number(e.target.value))} />;
  if (t.endsWith("[]")) {
    const text = Array.isArray(value) ? value.join(", ") : "";
    return <input dir="ltr" value={text} placeholder="A, B, C" onChange={(e) => onChange(e.target.value.trim() === "" ? [] : e.target.value.split(",").map((x) => x.trim()).filter(Boolean))} />;
  }
  if (isJson(t)) return <JsonInput value={value} onChange={onChange} />;
  if (LONG_TEXT.test(col.name)) return <textarea rows={3} value={value ? String(value) : ""} onChange={(e) => onChange(e.target.value)} />;
  return <input value={value === null || value === undefined ? "" : String(value)} onChange={(e) => onChange(e.target.value)} />;
}

function JsonInput({ value, onChange }: { value: unknown; onChange: (v: unknown) => void }) {
  const [text, setText] = useState(value === undefined || value === null ? "" : JSON.stringify(value, null, 1));
  const [bad, setBad] = useState(false);
  return (
    <textarea rows={4} dir="ltr" className={bad ? "invalid" : ""} value={text} onChange={(e) => {
      setText(e.target.value);
      if (e.target.value.trim() === "") { setBad(false); onChange(null); return; }
      try { onChange(JSON.parse(e.target.value)); setBad(false); } catch { setBad(true); }
    }} />
  );
}

export function RecordForm({ spec, initial, onSaved, onCancel, fixed }: { spec: ResSpec; initial?: Row; onSaved: (r: Row) => void; onCancel: () => void; fixed?: Record<string, string> }) {
  const { t, currency } = useI18n();
  const L = useLabels();
  const fields = spec.form.filter((c) => !fixed || !(c.name in fixed));
  const [values, setValues] = useState<Record<string, unknown>>(() => {
    const v: Record<string, unknown> = {};
    for (const c of fields) v[c.name] = initial ? initial[c.name] ?? null : null;
    return v;
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setBusy(true); setError(null);
    const body: Record<string, unknown> = { ...(initial ? {} : fixed ?? {}) };
    for (const c of fields) {
      const v = values[c.name];
      if (initial && JSON.stringify(v) === JSON.stringify(initial[c.name] ?? null)) continue;
      if (!initial && (v === null || v === "")) continue;
      body[c.name] = v;
    }
    try {
      const r = initial ? await api.patch<Row>(`/api/r/${spec.key}/${encodeURIComponent(initial._key)}`, body)
                        : await api.post<Row>(`/api/r/${spec.key}`, body);
      onSaved(r);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${initial ? t("common.edit") : t("common.create")}: ${L.res(spec.key)}`} onClose={onCancel} wide
           actions={<><button className="btn text" onClick={onCancel}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy} onClick={save}>{t("common.save")}</button></>}>
      <div className="grid cols-2">
        {fields.map((c) => (
          <Field key={c.name} label={`${L.field(c.name)}${c.required ? " *" : ""}`} hint={c.money ? currency() : undefined}>
            <FieldInput res={spec.key} col={c} value={values[c.name]} label={initial ? String(initial[`${c.name}__label`] ?? "") : undefined}
                        onChange={(v) => setValues((s) => ({ ...s, [c.name]: v }))} />
          </Field>
        ))}
      </div>
      <ErrorBox error={error} />
    </Modal>
  );
}

function RecordView({ spec, rowKey, onClose, onChanged }: { spec: ResSpec; rowKey: string; onClose: () => void; onChanged: () => void }) {
  const { t } = useI18n();
  const L = useLabels();
  const cell = useCell();
  const toast = useToast();
  const state = useLoad(() => api.get<Row>(`/api/r/${spec.key}/${encodeURIComponent(rowKey)}`), [rowKey]);
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const cols: ColSpec[] = useMemo(() => {
    if (!state.data) return [];
    const known = new Map([...spec.list, ...spec.form].map((c) => [c.name, c]));
    return Object.keys(state.data).filter((k) => k !== "_key" && !k.endsWith("__label"))
      .map((k) => known.get(k) ?? { name: k, type: guessType(state.data![k]), required: false, choices: null, ref: state.data![`${k}__label`] !== undefined ? k : null, money: false });
  }, [state.data, spec]);
  const row = state.data;
  const run = async (name: string) => {
    setError(null);
    try {
      await api.post(`/api/r/${spec.key}/${encodeURIComponent(rowKey)}/do/${name}`);
      toast(L.action(name)); state.reload(); onChanged();
    } catch (e) { setError(e); }
  };
  const remove = async () => {
    if (!confirm(t("common.confirmDelete"))) return;
    try { await api.del(`/api/r/${spec.key}/${encodeURIComponent(rowKey)}`); onChanged(); onClose(); } catch (e) { setError(e); }
  };
  const allowed = (a: ResSpec["actions"][number]) => !row || Object.entries(a.when).every(([c, vals]) => vals.includes(row[c] as string | null | boolean));
  return (
    <Modal title={L.res(spec.key)} onClose={onClose} wide actions={row && (
      <>
        {spec.delete && <button className="btn danger" onClick={remove}><Icon name="delete" />{t("common.delete")}</button>}
        {spec.actions.filter(allowed).map((a) => <button key={a.name} className="btn tonal" onClick={() => run(a.name)}>{L.action(a.name)}</button>)}
        {spec.update && spec.form.length > 0 && <button className="btn" onClick={() => setEditing(true)}><Icon name="edit" />{t("common.edit")}</button>}
      </>
    )}>
      {!row ? <Spinner /> : (
        <dl className="kv">
          {cols.map((c) => <div key={c.name}><dt>{L.field(c.name)}</dt><dd>{cell(c, { ...row, [`${c.name}__label`]: row[`${c.name}__label`] })}</dd></div>)}
        </dl>
      )}
      <ErrorBox error={error ?? state.error} />
      {editing && row && <RecordForm spec={spec} initial={row} onCancel={() => setEditing(false)}
                                     onSaved={() => { setEditing(false); state.reload(); onChanged(); toast(t("common.saved")); }} />}
    </Modal>
  );
}

/** List, search, create, open, edit and run the actions of one resource. */
export function ResourceTable({ res, fixed, title, sub, extra }: { res: string; fixed?: Record<string, string>; title?: string; sub?: string; extra?: ReactNode }) {
  const { t, num } = useI18n();
  const L = useLabels();
  const cell = useCell();
  const toast = useToast();
  const [q, setQ] = useState("");
  const [query, setQuery] = useState("");
  const [offset, setOffset] = useState(0);
  const [creating, setCreating] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const spec = useLoad(() => api.get<ResSpec>(`/api/r/${res}/_spec`), [res]);
  const params: Record<string, string | number | undefined> = { q: query || undefined, limit: 25, offset };
  for (const [k, v] of Object.entries(fixed ?? {})) params[`f_${k}`] = v;
  const rows = useLoad(() => api.get<{ rows: Row[]; total: number }>(`/api/r/${res}`, params), [res, query, offset, JSON.stringify(fixed)]);
  useEffect(() => { const id = setTimeout(() => { setQuery(q); setOffset(0); }, 300); return () => clearTimeout(id); }, [q]);
  if (spec.error) return <ErrorBox error={spec.error} />;
  if (!spec.data) return <Spinner />;
  const s = spec.data;
  const cols = s.list.filter((c) => !fixed || !(c.name in fixed));
  const total = rows.data?.total ?? 0;
  return (
    <div className="card flat stack" id={`res-${res}`} style={{ scrollMarginTop: 16 }}>
      <div className="row between">
        <div>
          <h3 style={{ margin: 0 }}>{title ?? L.res(res)}</h3>
          {sub && <p className="muted small" style={{ margin: "4px 0 0" }}>{sub}</p>}
        </div>
        <div className="row">
          <div className="search-box"><Icon name="search" size={18} /><input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t("common.search")} /></div>
          <button className="icon-btn" onClick={() => rows.reload()} title={t("common.refresh")}><Icon name="refresh" /></button>
          {extra}
          {s.create && s.form.length > 0 && <button className="btn small" onClick={() => setCreating(true)}><Icon name="add" />{t("common.add")}</button>}
        </div>
      </div>
      {rows.error ? <ErrorBox error={rows.error} /> : !rows.data ? <Spinner /> : rows.data.rows.length === 0 ? (
        <Empty icon="inventory_2" title={t("common.empty")} />
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead><tr>{cols.map((c) => <th key={c.name}>{L.field(c.name)}</th>)}</tr></thead>
            <tbody>
              {rows.data.rows.map((r) => (
                <tr key={r._key} onClick={() => setOpen(r._key)} style={{ cursor: "pointer" }}>
                  {cols.map((c) => <td key={c.name} className={c.money || isNum(c.type) ? "num" : undefined}>{cell(c, r)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {total > 25 && (
        <div className="row between small muted">
          <span>{num(offset + 1)}–{num(Math.min(offset + 25, total))} / {num(total)}</span>
          <div className="row">
            <button className="icon-btn" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - 25))}><Icon name="chevron_left" flip /></button>
            <button className="icon-btn" disabled={offset + 25 >= total} onClick={() => setOffset(offset + 25)}><Icon name="chevron_right" flip /></button>
          </div>
        </div>
      )}
      {creating && <RecordForm spec={s} fixed={fixed} onCancel={() => setCreating(false)}
                               onSaved={() => { setCreating(false); rows.reload(); toast(t("common.saved")); }} />}
      {open && <RecordView spec={s} rowKey={open} onClose={() => setOpen(null)} onChanged={() => rows.reload()} />}
    </div>
  );
}
