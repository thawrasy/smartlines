import { useMemo, useState } from "react";
import { api, ApiError } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Spinner, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";

// ---------------------------------------------------------------- types
type ColType = "text" | "int" | "money" | "date" | "datetime" | "bool" | "num" | "pct";
interface Spec { columns?: string[]; filters?: unknown[][]; group_by?: string[]; totals?: string[][]; sort?: string[][] }
interface CatalogReport { code: string; category: string; dataset: string; aggregate: boolean; chart: string; period: boolean; title: string; description: string; spec: Spec }
interface DsCol { key: string; label: string; type: ColType; group: boolean; filter: boolean; agg: boolean; values: string }
interface Dataset { key: string; category: string; title: string; date_col: string; columns: DsCol[] }
interface Saved { uid: string; name: string; description: string | null; dataset: string; spec: Spec; shared: boolean; mine: boolean }
interface Catalog { reports: CatalogReport[]; datasets: Dataset[]; categories: Record<string, string>; saved: Saved[]; can_custom: boolean; can_schedule: boolean }
interface OutCol { key: string; label: string; type: ColType; values: string; agg: string }
interface RunResult { columns: OutCol[]; rows: Record<string, unknown>[]; labels: Record<string, Record<string, string>>; totals: Record<string, number>; truncated: boolean; period: string; duration_ms: number }
interface Schedule { uid: string; report_code: string | null; definition_name: string | null; frequency: string; format: string; recipients: string[]; next_run_at: string; last_run_at: string | null; active: boolean }

/** What to run: a catalog report, a saved custom report, or an unsaved spec from the builder. */
type Target = { kind: "code"; report: CatalogReport } | { kind: "saved"; saved: Saved } | { kind: "adhoc"; dataset: string; spec: Spec; title: string };

const FORMATS: { f: string; icon: IconName; label: string }[] = [
  { f: "PDF", icon: "picture_as_pdf", label: "PDF" }, { f: "XLSX", icon: "table_chart", label: "Excel" },
  { f: "CSV", icon: "description", label: "CSV" }, { f: "TXT", icon: "data_table", label: "TXT" }, { f: "JSON", icon: "description", label: "JSON" },
];
const CAT_ICON: Record<string, IconName> = {
  sales: "confirmation_number", operations: "directions_bus", finance: "payments", shipping: "local_shipping", services: "apps",
  fleet: "directions_car", international: "public", platform: "apartment", security: "shield",
};
const iso = (d: Date) => d.toISOString().slice(0, 10);
const daysAgo = (n: number) => iso(new Date(Date.now() - n * 86400000));

// ---------------------------------------------------------------- page
export function ReportsPage() {
  const { t, locale } = useI18n();
  const state = useLoad(() => api.get<Catalog>("/api/reports/catalog", { locale }), [locale]);
  const [tab, setTab] = useState<"catalog" | "saved" | "builder" | "schedules">("catalog");
  const [target, setTarget] = useState<Target | null>(null);
  const [draft, setDraft] = useState<{ dataset: string; spec: Spec } | null>(null);
  const open = (x: Target) => { setTarget(x); window.scrollTo({ top: 0 }); };
  const customize = (dataset: string, spec: Spec) => { setDraft({ dataset, spec }); setTarget(null); setTab("builder"); };
  return (
    <div className="stack">
      <PageHead title={t("rpt.title")} sub={t("rpt.sub")} />
      <Loaded state={state}>{(cat) => (
        <>
          {target ? (
            <ReportView target={target} cat={cat} onBack={() => setTarget(null)} onCustomize={customize} onSaved={state.reload} />
          ) : (
            <>
              <div className="segmented" role="tablist" style={{ alignSelf: "flex-start" }}>
                {(["catalog", "saved", ...(cat.can_custom ? ["builder"] : []), ...(cat.can_schedule ? ["schedules"] : [])] as typeof tab[]).map((v) => (
                  <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`rpt.tab.${v}`)}</button>
                ))}
              </div>
              {tab === "catalog" && <CatalogList cat={cat} onOpen={(r) => open({ kind: "code", report: r })} />}
              {tab === "saved" && <SavedList cat={cat} onOpen={(s) => open({ kind: "saved", saved: s })} onChanged={state.reload} />}
              {tab === "builder" && cat.can_custom && <Builder cat={cat} initial={draft} onRun={(x) => open(x)} onSaved={() => { state.reload(); setTab("saved"); }} />}
              {tab === "schedules" && cat.can_schedule && <Schedules cat={cat} />}
            </>
          )}
        </>
      )}</Loaded>
    </div>
  );
}

function CatalogList({ cat, onOpen }: { cat: Catalog; onOpen: (r: CatalogReport) => void }) {
  const { t } = useI18n();
  const [q, setQ] = useState("");
  const groups = useMemo(() => {
    const m = new Map<string, CatalogReport[]>();
    for (const r of cat.reports) {
      if (q && !`${r.title} ${r.description}`.toLowerCase().includes(q.toLowerCase())) continue;
      m.set(r.category, [...(m.get(r.category) ?? []), r]);
    }
    return [...m.entries()];
  }, [cat, q]);
  return (
    <div className="stack">
      <div className="card row" style={{ gap: 12 }}>
        <Icon name="search" />
        <input className="input" style={{ flex: 1 }} placeholder={t("rpt.search")} value={q} onChange={(e) => setQ(e.target.value)} />
        <span className="small muted">{t("rpt.count", { n: cat.reports.length })}</span>
      </div>
      {groups.length === 0 && <div className="card"><Empty icon="summarize" title={t("rpt.none")} /></div>}
      {groups.map(([category, list]) => (
        <section key={category} className="stack" style={{ gap: 10 }}>
          <h3 className="row" style={{ gap: 8 }}><Icon name={CAT_ICON[category] ?? "summarize"} />{cat.categories[category] ?? category}</h3>
          <div className="grid cols-3">
            {list.map((r) => (
              <button key={r.code} className="card report-card" onClick={() => onOpen(r)} style={{ textAlign: "start", cursor: "pointer" }}>
                <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
                  <strong>{r.title}</strong>
                  <Icon name={r.chart ? "bar_chart" : "table_chart"} />
                </div>
                <p className="small muted" style={{ margin: "6px 0 0" }}>{r.description}</p>
                <div className="row" style={{ gap: 6, marginTop: 10 }}>
                  <span className="chip outline">{r.aggregate ? t("rpt.kind.summary") : t("rpt.kind.list")}</span>
                  {!r.period && <span className="chip outline">{t("rpt.allTime")}</span>}
                </div>
              </button>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

function SavedList({ cat, onOpen, onChanged }: { cat: Catalog; onOpen: (s: Saved) => void; onChanged: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [error, setError] = useState<unknown>(null);
  const archive = async (s: Saved) => {
    try { await api.del(`/api/reports/definitions/${s.uid}`); toast(t("rpt.archived")); onChanged(); } catch (e) { setError(e); }
  };
  if (cat.saved.length === 0) return <div className="card"><Empty icon="save" title={t("rpt.noSaved")} hint={cat.can_custom ? t("rpt.noSavedHint") : undefined} /></div>;
  return (
    <div className="card stack">
      <ErrorBox error={error} />
      <div className="table-wrap"><table className="table">
        <thead><tr><th>{t("rpt.name")}</th><th>{t("rpt.dataset")}</th><th>{t("rpt.sharing")}</th><th /></tr></thead>
        <tbody>{cat.saved.map((s) => (
          <tr key={s.uid}>
            <td><strong>{s.name}</strong>{s.description && <div className="small muted">{s.description}</div>}</td>
            <td>{cat.datasets.find((d) => d.key === s.dataset)?.title ?? s.dataset}</td>
            <td>{s.shared ? <span className="chip blue">{t("rpt.shared")}</span> : <span className="chip outline">{t("rpt.private")}</span>}</td>
            <td className="num"><div className="row nowrap" style={{ justifyContent: "flex-end" }}>
              <button className="btn small" onClick={() => onOpen(s)}><Icon name="play_arrow" />{t("rpt.open")}</button>
              {s.mine && <button className="btn text small" onClick={() => archive(s)}>{t("rpt.archive")}</button>}
            </div></td>
          </tr>
        ))}</tbody>
      </table></div>
    </div>
  );
}

// ---------------------------------------------------------------- one report: period, preview, export
function ReportView({ target, cat, onBack, onCustomize, onSaved }: {
  target: Target; cat: Catalog; onBack: () => void; onCustomize: (dataset: string, spec: Spec) => void; onSaved: () => void;
}) {
  const { t, locale } = useI18n();
  const toast = useToast();
  const usesPeriod = target.kind === "code" ? target.report.period : true;
  const [from, setFrom] = useState(daysAgo(30));
  const [to, setTo] = useState(iso(new Date()));
  const [allTime, setAllTime] = useState(!usesPeriod);
  const [res, setRes] = useState<RunResult | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [scheduling, setScheduling] = useState(false);
  const title = target.kind === "code" ? target.report.title : target.kind === "saved" ? target.saved.name : target.title;
  const description = target.kind === "code" ? target.report.description : target.kind === "saved" ? target.saved.description ?? "" : "";
  const chart = target.kind === "code" ? target.report.chart : "";
  const body = () => ({
    ...(target.kind === "code" ? { code: target.report.code } : target.kind === "saved" ? { definition: target.saved.uid } : { dataset: target.dataset, spec: target.spec }),
    params: allTime ? { all_time: true } : { from, to }, locale,
  });
  const run = async () => {
    setBusy("run"); setError(null);
    try { setRes(await api.post<RunResult>("/api/reports/run", body())); } catch (e) { setError(e); } finally { setBusy(null); }
  };
  const download = async (format: string) => {
    setBusy(format); setError(null);
    try {
      const r = await fetch("/api/reports/export", {
        method: "POST", credentials: "same-origin", headers: { "X-Masslak-Client": "web", "Content-Type": "application/json" },
        body: JSON.stringify({ ...body(), format }),
      });
      if (!r.ok) {
        const err = (await r.json().catch(() => null))?.error ?? {};
        throw new ApiError(r.status, err.code ?? "SERVER_ERROR", err.message ?? r.statusText, err);
      }
      const blob = await r.blob();
      const name = /filename="([^"]+)"/.exec(r.headers.get("content-disposition") ?? "")?.[1] ?? `report.${format.toLowerCase()}`;
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      toast(t("rpt.downloaded", { name }));
    } catch (e) { setError(e); } finally { setBusy(null); }
  };
  const presets: [string, () => void][] = [
    ["today", () => { setFrom(iso(new Date())); setTo(iso(new Date())); }],
    ["d7", () => { setFrom(daysAgo(6)); setTo(iso(new Date())); }],
    ["d30", () => { setFrom(daysAgo(29)); setTo(iso(new Date())); }],
    ["month", () => { const d = new Date(); setFrom(iso(new Date(d.getFullYear(), d.getMonth(), 1, 12))); setTo(iso(d)); }],
    ["year", () => { const d = new Date(); setFrom(`${d.getFullYear()}-01-01`); setTo(iso(d)); }],
  ];
  const specOf = (): [string, Spec] | null => target.kind === "code" ? [target.report.dataset, target.report.spec]
    : target.kind === "saved" ? [target.saved.dataset, target.saved.spec] : [target.dataset, target.spec];
  return (
    <div className="stack report-view">
      <div className="card stack no-print">
        <div className="row" style={{ justifyContent: "space-between", gap: 12, flexWrap: "wrap" }}>
          <div>
            <button className="btn text small" onClick={onBack} style={{ paddingInline: 0 }}><Icon name="arrow_back" flip={locale === "ar"} />{t("rpt.back")}</button>
            <h2 style={{ margin: "4px 0" }}>{title}</h2>
            {description && <p className="muted" style={{ margin: 0 }}>{description}</p>}
          </div>
          <div className="row" style={{ gap: 8 }}>
            {cat.can_custom && specOf() && <button className="btn outlined small" onClick={() => { const s = specOf(); if (s) onCustomize(s[0], s[1]); }}><Icon name="tune" />{t("rpt.customize")}</button>}
            {cat.can_schedule && target.kind !== "adhoc" && <button className="btn outlined small" onClick={() => setScheduling(true)}><Icon name="schedule_send" />{t("rpt.schedule")}</button>}
          </div>
        </div>
        <div className="row" style={{ gap: 12, alignItems: "flex-end", flexWrap: "wrap" }}>
          {usesPeriod && !allTime && (<>
            <Field label={t("rpt.from")}><input type="date" className="input" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></Field>
            <Field label={t("rpt.to")}><input type="date" className="input" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></Field>
            <div className="row" style={{ gap: 6, paddingBottom: 4 }}>
              {presets.map(([k, f]) => <button key={k} className="chip outline" style={{ cursor: "pointer" }} onClick={f}>{t(`rpt.preset.${k}`)}</button>)}
            </div>
          </>)}
          {usesPeriod && <label className="row small" style={{ gap: 6, paddingBottom: 10 }}><input type="checkbox" checked={allTime} onChange={(e) => setAllTime(e.target.checked)} />{t("rpt.allTime")}</label>}
          <button className="btn" onClick={run} disabled={!!busy} style={{ marginInlineStart: "auto" }}>
            {busy === "run" ? <Spinner /> : <Icon name="play_arrow" />}{t("rpt.run")}
          </button>
        </div>
        <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
          <span className="small muted">{t("rpt.exportAs")}</span>
          {FORMATS.map((x) => (
            <button key={x.f} className="btn tonal small" disabled={!!busy} onClick={() => download(x.f)} title={t(`rpt.fmt.${x.f}`)}>
              {busy === x.f ? <Spinner /> : <Icon name={x.icon} />}{x.label}
            </button>
          ))}
          <button className="btn text small" onClick={() => window.print()} disabled={!res}><Icon name="print" />{t("rpt.print")}</button>
        </div>
        <ErrorBox error={error} />
      </div>
      {res ? <ResultTable res={res} title={title} chart={chart} /> : (
        <div className="card no-print"><Empty icon="insert_chart" title={t("rpt.pressRun")} hint={t("rpt.pressRunHint")} /></div>
      )}
      {scheduling && <ScheduleModal target={target} onClose={() => setScheduling(false)} onDone={() => { setScheduling(false); onSaved(); toast(t("rpt.scheduled")); }} />}
    </div>
  );
}

function useCell() {
  const { t, money, date, time } = useI18n();
  return (c: OutCol, v: unknown, labels: Record<string, Record<string, string>>) => {
    if (v === null || v === undefined || v === "") return "—";
    switch (c.type) {
      case "money": return money(Number(v));
      case "int": return Number(v).toLocaleString("en-US");
      case "num": return Number(v).toLocaleString("en-US", { maximumFractionDigits: 2 });
      case "pct": return `${Number(v).toFixed(1)}%`;
      case "date": return date(`${String(v).slice(0, 10)}T12:00:00Z`, { weekday: undefined, year: "numeric" });
      case "datetime": return `${date(String(v), { weekday: undefined })} ${time(String(v))}`;
      case "bool": return v ? t("rpt.yes") : t("rpt.no");
      default: return labels[c.key]?.[String(v)] ?? String(v);
    }
  };
}

function ResultTable({ res, title, chart }: { res: RunResult; title: string; chart: string }) {
  const { t } = useI18n();
  const cell = useCell();
  const numeric = (c: OutCol) => ["money", "int", "num", "pct"].includes(c.type);
  const groups = res.columns.filter((c) => !c.agg);
  const measure = res.columns.find((c) => c.agg && numeric(c) && c.agg !== "count") ?? res.columns.find((c) => c.agg);
  const max = measure ? Math.max(1, ...res.rows.map((r) => Number(r[measure.key]) || 0)) : 1;
  return (
    <div className="stack">
      <div className="print-only print-head"><h2>{title}</h2><p>{res.period}</p></div>
      {chart && measure && res.rows.length > 0 && (
        <div className="card stack no-print">
          <h3 style={{ margin: 0 }}>{measure.label}</h3>
          <div className="stack" style={{ gap: 6 }}>
            {res.rows.slice(0, 15).map((r, i) => {
              const v = Number(r[measure.key]) || 0;
              return (
                <div key={i} className="row" style={{ gap: 10 }}>
                  <span className="small" style={{ width: 170, flexShrink: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                    {groups.map((g) => cell(g, r[g.key], res.labels)).join(" → ")}
                  </span>
                  <div style={{ flex: 1, background: "var(--surface-container)", borderRadius: 8, height: 18 }}>
                    <div style={{ width: `${(100 * v) / max}%`, minWidth: v ? 4 : 0, height: "100%", borderRadius: 8, background: "var(--primary)" }} />
                  </div>
                  <span className="small mono" style={{ width: 120, textAlign: "end" }}>{cell(measure, v, res.labels)}</span>
                </div>
              );
            })}
          </div>
        </div>
      )}
      <div className="card stack">
        <div className="row small muted" style={{ justifyContent: "space-between" }}>
          <span>{t("rpt.period")}: {res.period}</span>
          <span>{t("rpt.rows", { n: res.rows.length })}{res.truncated ? ` · ${t("rpt.truncated")}` : ""} · {res.duration_ms} ms</span>
        </div>
        {res.rows.length === 0 ? <Empty icon="summarize" title={t("rpt.empty")} /> : (
          <div className="table-wrap"><table className="table report-table">
            <thead><tr>{res.columns.map((c) => <th key={c.key} className={numeric(c) ? "num" : ""}>{c.label}</th>)}</tr></thead>
            <tbody>{res.rows.map((r, i) => (
              <tr key={i}>{res.columns.map((c) => <td key={c.key} className={numeric(c) ? "num mono" : c.key.endsWith("_no") || c.key === "booking_ref" ? "mono" : ""}>{cell(c, r[c.key], res.labels)}</td>)}</tr>
            ))}</tbody>
            {Object.keys(res.totals).length > 0 && (
              <tfoot><tr>{res.columns.map((c, i) => (
                <td key={c.key} className={numeric(c) ? "num mono" : ""}><strong>{c.key in res.totals ? cell(c, res.totals[c.key], res.labels) : i === 0 ? t("rpt.total") : ""}</strong></td>
              ))}</tr></tfoot>
            )}
          </table></div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- builder
const OPS: Record<string, string[]> = {
  text: ["eq", "ne", "contains", "starts", "in", "is_null", "not_null"], int: ["eq", "ne", "gt", "gte", "lt", "lte", "between"],
  money: ["eq", "gt", "gte", "lt", "lte", "between"], num: ["eq", "gt", "gte", "lt", "lte", "between"], pct: ["gt", "gte", "lt", "lte", "between"],
  date: ["eq", "gt", "gte", "lt", "lte", "between"], datetime: ["gte", "lte", "between"], bool: ["eq"],
};
const AGGS = ["sum", "avg", "min", "max", "count_distinct"];
interface Filter { col: string; op: string; value: string; value2: string }

function Builder({ cat, initial, onRun, onSaved }: { cat: Catalog; initial: { dataset: string; spec: Spec } | null; onRun: (t: Target) => void; onSaved: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [dsKey, setDsKey] = useState(initial?.dataset ?? cat.datasets[0]?.key ?? "");
  const ds = cat.datasets.find((d) => d.key === dsKey);
  const [mode, setMode] = useState<"list" | "summary">(initial?.spec.group_by?.length ? "summary" : "list");
  const [columns, setColumns] = useState<string[]>(initial?.spec.columns ?? ds?.columns.slice(0, 6).map((c) => c.key) ?? []);
  const [groupBy, setGroupBy] = useState<string[]>(initial?.spec.group_by ?? []);
  const [totals, setTotals] = useState<string[][]>(initial?.spec.totals ?? [["count", "*"]]);
  const [filters, setFilters] = useState<Filter[]>((initial?.spec.filters ?? []).map((f) => ({
    col: String(f[0]), op: String(f[1]), value: Array.isArray(f[2]) ? String(f[2][0] ?? "") : String(f[2] ?? ""), value2: Array.isArray(f[2]) ? String(f[2][1] ?? "") : "" })));
  const [sort, setSort] = useState<string[]>(initial?.spec.sort?.[0] ?? []);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<unknown>(null);
  if (!ds) return <div className="card"><Empty icon="summarize" title={t("rpt.none")} /></div>;
  const colOf = (k: string) => ds.columns.find((c) => c.key === k);
  const changeDataset = (k: string) => {
    const d = cat.datasets.find((x) => x.key === k);
    setDsKey(k); setColumns(d?.columns.slice(0, 6).map((c) => c.key) ?? []); setGroupBy([]); setTotals([["count", "*"]]); setFilters([]); setSort([]);
  };
  const spec = (): Spec => {
    const f = filters.filter((x) => x.col && x.op).map((x) => {
      if (x.op === "is_null" || x.op === "not_null") return [x.col, x.op];
      if (x.op === "between") return [x.col, x.op, [x.value, x.value2]];
      if (x.op === "in") return [x.col, x.op, x.value.split(",").map((s) => s.trim()).filter(Boolean)];
      if (colOf(x.col)?.type === "bool") return [x.col, x.op, x.value === "true"];
      return [x.col, x.op, x.value];
    });
    const s = sort.length === 2 ? [sort] : [];
    return mode === "list" ? { columns, filters: f, sort: s } : { group_by: groupBy, totals, filters: f, sort: s };
  };
  const valid = mode === "list" ? columns.length > 0 : groupBy.length > 0 && totals.length > 0;
  const sortKeys = mode === "list" ? columns.map((k) => ({ key: k, label: colOf(k)?.label ?? k }))
    : [...groupBy.map((k) => ({ key: k, label: colOf(k)?.label ?? k })), ...totals.map(([fn, k]) => ({ key: `${fn}__${k}`, label: k === "*" ? t("rpt.agg.count") : `${t(`rpt.agg.${fn}`)}: ${colOf(k)?.label ?? k}` }))];
  return (
    <div className="stack">
      <div className="card stack">
        <div className="grid cols-3">
          <Field label={t("rpt.dataset")}>
            <select value={dsKey} onChange={(e) => changeDataset(e.target.value)}>
              {cat.datasets.map((d) => <option key={d.key} value={d.key}>{d.title} · {t(`rpt.ds.${d.key}`)}</option>)}
            </select>
          </Field>
          <Field label={t("rpt.layout")}>
            <div className="segmented" role="tablist">
              {(["list", "summary"] as const).map((m) => <button key={m} role="tab" aria-selected={mode === m} className={mode === m ? "on" : ""} onClick={() => setMode(m)}>{t(`rpt.kind.${m}`)}</button>)}
            </div>
          </Field>
        </div>
        {mode === "list" ? (
          <Field label={t("rpt.columns")} hint={t("rpt.columnsHint")}>
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              {ds.columns.map((c) => (
                <label key={c.key} className={`chip-select row nowrap${columns.includes(c.key) ? " on" : ""}`} style={{ padding: "0 12px", gap: 6 }}>
                  <input type="checkbox" checked={columns.includes(c.key)} onChange={(e) => setColumns(e.target.checked ? [...columns, c.key] : columns.filter((x) => x !== c.key))} />{c.label}
                </label>
              ))}
            </div>
          </Field>
        ) : (
          <div className="grid cols-2">
            <Field label={t("rpt.groupBy")} hint={t("rpt.groupByHint")}>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                {ds.columns.filter((c) => c.group).map((c) => (
                  <label key={c.key} className={`chip-select row nowrap${groupBy.includes(c.key) ? " on" : ""}`} style={{ padding: "0 12px", gap: 6 }}>
                    <input type="checkbox" checked={groupBy.includes(c.key)} disabled={!groupBy.includes(c.key) && groupBy.length >= 4}
                           onChange={(e) => setGroupBy(e.target.checked ? [...groupBy, c.key] : groupBy.filter((x) => x !== c.key))} />{c.label}
                  </label>
                ))}
              </div>
            </Field>
            <Field label={t("rpt.totals")}>
              <div className="stack" style={{ gap: 6 }}>
                {totals.map(([fn, k], i) => (
                  <div key={i} className="row" style={{ gap: 6 }}>
                    <select value={k === "*" ? "count" : fn} onChange={(e) => setTotals(totals.map((x, j) => j === i ? (e.target.value === "count" ? ["count", "*"] : [e.target.value, k === "*" ? ds.columns.find((c) => c.agg)?.key ?? "" : k]) : x))}>
                      <option value="count">{t("rpt.agg.count")}</option>
                      {AGGS.map((a) => <option key={a} value={a}>{t(`rpt.agg.${a}`)}</option>)}
                    </select>
                    {k !== "*" && (
                      <select value={k} onChange={(e) => setTotals(totals.map((x, j) => j === i ? [fn, e.target.value] : x))}>
                        {ds.columns.filter((c) => fn === "count_distinct" || ((fn === "min" || fn === "max") ? true : c.agg)).map((c) => <option key={c.key} value={c.key}>{c.label}</option>)}
                      </select>
                    )}
                    <button className="btn text small" onClick={() => setTotals(totals.filter((_, j) => j !== i))} aria-label={t("rpt.archive")}><Icon name="close" /></button>
                  </div>
                ))}
                {totals.length < 8 && <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={() => setTotals([...totals, ["sum", ds.columns.find((c) => c.agg)?.key ?? ""]])}><Icon name="add" />{t("rpt.addTotal")}</button>}
              </div>
            </Field>
          </div>
        )}
        <Field label={t("rpt.filters")}>
          <div className="stack" style={{ gap: 6 }}>
            {filters.map((f, i) => {
              const c = colOf(f.col);
              const ops = OPS[c?.type ?? "text"];
              const set = (patch: Partial<Filter>) => setFilters(filters.map((x, j) => j === i ? { ...x, ...patch } : x));
              const inputType = c?.type === "date" ? "date" : c?.type === "datetime" ? "datetime-local" : ["int", "money", "num", "pct"].includes(c?.type ?? "") ? "number" : "text";
              return (
                <div key={i} className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                  <select value={f.col} onChange={(e) => set({ col: e.target.value, op: OPS[colOf(e.target.value)?.type ?? "text"][0], value: "", value2: "" })}>
                    {ds.columns.filter((x) => x.filter).map((x) => <option key={x.key} value={x.key}>{x.label}</option>)}
                  </select>
                  <select value={f.op} onChange={(e) => set({ op: e.target.value })}>{ops.map((o) => <option key={o} value={o}>{t(`rpt.op.${o}`)}</option>)}</select>
                  {c?.type === "bool" ? (
                    <select value={f.value} onChange={(e) => set({ value: e.target.value })}><option value="true">{t("rpt.yes")}</option><option value="false">{t("rpt.no")}</option></select>
                  ) : !["is_null", "not_null"].includes(f.op) && (
                    <input className="input" type={inputType} value={f.value} onChange={(e) => set({ value: e.target.value })} placeholder={f.op === "in" ? t("rpt.commaList") : ""} style={{ width: 180 }} />
                  )}
                  {f.op === "between" && <input className="input" type={inputType} value={f.value2} onChange={(e) => set({ value2: e.target.value })} style={{ width: 180 }} />}
                  <button className="btn text small" onClick={() => setFilters(filters.filter((_, j) => j !== i))} aria-label={t("rpt.archive")}><Icon name="close" /></button>
                </div>
              );
            })}
            {filters.length < 20 && <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={() => {
              const c = ds.columns.find((x) => x.filter)!;
              setFilters([...filters, { col: c.key, op: OPS[c.type][0], value: "", value2: "" }]);
            }}><Icon name="filter_alt" />{t("rpt.addFilter")}</button>}
          </div>
        </Field>
        <div className="grid cols-3">
          <Field label={t("rpt.sortBy")}>
            <select value={sort[0] ?? ""} onChange={(e) => setSort(e.target.value ? [e.target.value, sort[1] ?? "desc"] : [])}>
              <option value="">{t("rpt.defaultSort")}</option>
              {sortKeys.map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}
            </select>
          </Field>
          {sort[0] && <Field label={t("rpt.direction")}>
            <select value={sort[1]} onChange={(e) => setSort([sort[0], e.target.value])}><option value="desc">{t("rpt.desc")}</option><option value="asc">{t("rpt.asc")}</option></select>
          </Field>}
        </div>
        <ErrorBox error={error} />
        <div className="row" style={{ gap: 8, justifyContent: "flex-end" }}>
          <button className="btn outlined" disabled={!valid} onClick={() => setSaving(true)}><Icon name="save" />{t("rpt.save")}</button>
          <button className="btn" disabled={!valid} onClick={() => onRun({ kind: "adhoc", dataset: dsKey, spec: spec(), title: `${t("rpt.custom")} · ${ds.title}` })}><Icon name="play_arrow" />{t("rpt.preview")}</button>
        </div>
      </div>
      {saving && <SaveModal dataset={dsKey} spec={spec()} onClose={() => setSaving(false)} onDone={() => { setSaving(false); toast(t("rpt.saved")); onSaved(); }} onError={setError} />}
    </div>
  );
}

function SaveModal({ dataset, spec, onClose, onDone, onError }: { dataset: string; spec: Spec; onClose: () => void; onDone: () => void; onError: (e: unknown) => void }) {
  const { t } = useI18n();
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [shared, setShared] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try { await api.post("/api/reports/definitions", { name, description: description || null, dataset, spec, shared }); onDone(); }
    catch (e) { setError(e); onError(e); }
  };
  return (
    <Modal title={t("rpt.saveTitle")} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={name.trim().length < 3} onClick={save}>{t("rpt.save")}</button></>}>
      <Field label={t("rpt.name")}><input className="input" value={name} maxLength={120} onChange={(e) => setName(e.target.value)} /></Field>
      <Field label={t("rpt.description")} hint={t("common.optional")}><input className="input" value={description} maxLength={500} onChange={(e) => setDescription(e.target.value)} /></Field>
      <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={shared} onChange={(e) => setShared(e.target.checked)} />{t("rpt.shareWithTeam")}</label>
      <ErrorBox error={error} />
    </Modal>
  );
}

// ---------------------------------------------------------------- schedules
function ScheduleModal({ target, onClose, onDone }: { target: Target; onClose: () => void; onDone: () => void }) {
  const { t, locale } = useI18n();
  const { me } = useAuth();
  const [frequency, setFrequency] = useState("WEEKLY");
  const [format, setFormat] = useState("PDF");
  const [lang, setLang] = useState(locale);
  const [recipients, setRecipients] = useState(me?.email ?? "");
  const [error, setError] = useState<unknown>(null);
  // a report with personal or financial data needs explicit consent; it then goes by a short-lived link (audit T3-05)
  const [sensitive, setSensitive] = useState(false);
  const [consent, setConsent] = useState(false);
  const save = async () => {
    try {
      await api.post("/api/reports/schedules", {
        ...(target.kind === "code" ? { code: target.report.code } : target.kind === "saved" ? { definition: target.saved.uid } : {}),
        frequency, format, locale: lang, recipients: recipients.split(/[,\s]+/).filter(Boolean), confirm_sensitive: consent,
      });
      onDone();
    } catch (e) {
      if (e instanceof Error && "code" in e && (e as { code: string }).code === "REPORT_CONSENT_REQUIRED") { setSensitive(true); setError(null); return; }
      setError(e);
    }
  };
  return (
    <Modal title={t("rpt.scheduleTitle")} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={!recipients.trim() || (sensitive && !consent)} onClick={save}><Icon name="schedule_send" />{t("rpt.schedule")}</button></>}>
      <div className="grid cols-3">
        <Field label={t("rpt.frequency")}><select value={frequency} onChange={(e) => setFrequency(e.target.value)}>
          {["DAILY", "WEEKLY", "MONTHLY"].map((f) => <option key={f} value={f}>{t(`rpt.freq.${f}`)}</option>)}</select></Field>
        <Field label={t("rpt.format")}><select value={format} onChange={(e) => setFormat(e.target.value)}>
          {["PDF", "XLSX", "CSV", "TXT"].map((f) => <option key={f} value={f}>{t(`rpt.fmt.${f}`)}</option>)}</select></Field>
        <Field label={t("rpt.language")}><select value={lang} onChange={(e) => setLang(e.target.value as typeof lang)}>
          <option value="ar">{t("lang.ar")}</option><option value="en">{t("lang.en")}</option></select></Field>
      </div>
      <Field label={t("rpt.recipients")} hint={t("rpt.recipientsHint")}><input className="input" value={recipients} onChange={(e) => setRecipients(e.target.value)} /></Field>
      <p className="small muted">{t("rpt.scheduleNote")}</p>
      {sensitive && <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />{t("rpt.sensitiveConsent")}</label>}
      <ErrorBox error={error} />
    </Modal>
  );
}

function Schedules({ cat }: { cat: Catalog }) {
  const { t, date, time } = useI18n();
  const state = useLoad(() => api.get<{ schedules: Schedule[] }>("/api/reports/schedules"));
  const [error, setError] = useState<unknown>(null);
  const stop = async (s: Schedule) => { try { await api.del(`/api/reports/schedules/${s.uid}`); state.reload(); } catch (e) { setError(e); } };
  const nameOf = (s: Schedule) => s.definition_name ?? cat.reports.find((r) => r.code === s.report_code)?.title ?? s.report_code ?? "";
  return (
    <div className="card stack">
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => d.schedules.length === 0 ? <Empty icon="schedule_send" title={t("rpt.noSchedules")} hint={t("rpt.noSchedulesHint")} /> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("rpt.report")}</th><th>{t("rpt.frequency")}</th><th>{t("rpt.format")}</th><th>{t("rpt.recipients")}</th><th>{t("rpt.nextRun")}</th><th /></tr></thead>
          <tbody>{d.schedules.map((s) => (
            <tr key={s.uid}>
              <td><strong>{nameOf(s)}</strong></td>
              <td>{t(`rpt.freq.${s.frequency}`)}</td>
              <td>{s.format}</td>
              <td className="small">{s.recipients.join(", ")}</td>
              <td className="small">{s.active ? `${date(s.next_run_at)} ${time(s.next_run_at)}` : <span className="chip outline">{t("rpt.stopped")}</span>}</td>
              <td className="num">{s.active && <button className="btn text small" onClick={() => stop(s)}>{t("rpt.stop")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}
