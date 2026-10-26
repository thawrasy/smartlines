import { useMemo, useState } from "react";
import { api } from "../../api";
import { fromMinor, toMinor, useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, useLoad, useToast } from "../../components/ui";

// Pricing and tax studio (owner's note of 25 October 2026). Taxes are shown as cards in plain terms, recorded with their
// rules in one guided form, put in force by a second officer and replaced by new versions; the price preview gives the
// receipt of a sale from the same engine as the e-invoices: fares, the taxes inside them, the platform fee, the payment
// fee and an agency's commission, and who receives what. A waiting tax can be tried in the preview before approval.

interface Band { dimension: string; from_value: number; to_value: number | null; rate: number | null; amount: number | null; mode: string }
interface Rule { seq: number; calc_method: string; rate: number | null; amount: number | null; base_type: string; base_include: string[];
  compound_mode: string; min_amount: number | null; max_amount: number | null; rounding_rule: string; applies_per: string; bands: Band[] }
interface Scheme { id: number; code: string; name: string; tax_type: string; treatment: string; scope: { products?: string[]; sellers?: string[]; origin_cities?: string[] };
  collected_by: string; version: number; status: string; valid_from: string; valid_to: string | null; jurisdiction: string; country_code: string;
  payable_to: string | null; created_by: string | null; approved_by: string | null; in_force: boolean; scheduled: boolean; rules: Rule[]; summary: string }
interface Jurisdiction { id: number; country_code: string; level: string; name: string }
interface TaxLine { code: string; tax_type: string; treatment: string; rate: number; base: number; amount: number; payable_to: string | null; tried: boolean; kind: string }
interface Receipt { currency: string; passengers: number; fare: number; fares_total: number; ticket_net: number; ticket_taxes: TaxLine[];
  platform_fee: number; platform_fee_net: number; platform_fee_taxes: TaxLine[]; payment_fee: number; payment_fee_absorbed: number;
  payment_fee_label: string | null; agency_commission: number; total_paid: number; total_tax: number; shares: { who: string; amount: number }[];
  no_funds: boolean; tried: string[]; commissions: CommissionLine[]; traveller_commission: number }
interface CommissionLine { code: string; name: string; type: string; payer: string; receiver: string; base_type: string; base: number; amount: number; tried: boolean }
interface CRule { seq: number; calc_method: string; rate: number | null; amount: number | null; min_amount: number | null; max_amount: number | null; bands: Band[] }
interface Commission { id: number; code: string; name: string | null; type: string; funded_by: string; payer: string; receiver: string; base_type: string;
  scope: { channels?: string[] }; version: number; status: string; valid_from: string; valid_to: string | null; created_by: string | null;
  approved_by: string | null; in_force: boolean; scheduled: boolean; rules: CRule[] }

type Phase = "FORCE" | "WAITING" | "SCHEDULED" | "ENDED";
const phaseOf = (s: Scheme): Phase => s.status === "PENDING" ? "WAITING" : s.scheduled ? "SCHEDULED" : s.in_force ? "FORCE" : "ENDED";
const SHARE_COLOUR: Record<string, string> = { CARRIER: "var(--primary)", AGENCY: "var(--brand-gold)", PLATFORM: "var(--brand-navy)",
  TAX: "var(--tertiary)", PAYMENT: "var(--outline)", REFERRER: "var(--success)" };

export function PricingStudio() {
  const { t } = useI18n();
  const [tab, setTab] = useState<"taxes" | "commissions" | "preview">("taxes");
  const [tryIds, setTryIds] = useState<number[]>([]);
  const [tryC, setTryC] = useState<number[]>([]);
  const comms = useLoad((signal) => api.get<{ schemes: Commission[] }>("/api/admin/pricing/commissions", undefined, { signal }).then((r) => r.schemes));
  const state = useLoad((signal) => api.get<{ jurisdictions: Jurisdiction[]; schemes: Scheme[] }>("/api/admin/pricing/taxes", undefined, { signal }));
  return (
    <div className="stack">
      <PageHead title={t("ps.title")} sub={t("ps.sub")} />
      <div className="segmented" role="tablist" aria-label={t("ps.title")} style={{ alignSelf: "flex-start" }}>
        {(["taxes", "commissions", "preview"] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>
            <Icon name={k === "taxes" ? "request_quote" : k === "commissions" ? "handshake" : "receipt_long"} size={18} />{t(`ps.tab.${k}`)}</button>))}
      </div>
      {tab === "commissions" ? <Loaded state={comms}>{(cs) => <Commissions schemes={cs} reload={comms.reload}
          onTry={(id) => { setTryC((x) => x.includes(id) ? x : [...x, id]); setTab("preview"); }} />}</Loaded>
        : <Loaded state={state}>{(d) => tab === "taxes"
          ? <Taxes data={d} reload={state.reload} onTry={(id) => { setTryIds((x) => x.includes(id) ? x : [...x, id]); setTab("preview"); }} />
          : <Preview schemes={d.schemes} tryIds={tryIds} setTryIds={setTryIds} commissions={comms.data ?? []} tryC={tryC} setTryC={setTryC} />}</Loaded>}
    </div>
  );
}

// ------------------------------------------------------------------ taxes
function Taxes({ data, reload, onTry }: { data: { jurisdictions: Jurisdiction[]; schemes: Scheme[] }; reload: () => void; onTry: (id: number) => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const { me } = useAuth();
  const [filter, setFilter] = useState<Phase | "ALL">("ALL");
  const [editing, setEditing] = useState<{ from?: Scheme } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const count = (p: Phase) => data.schemes.filter((s) => phaseOf(s) === p).length;
  const shown = data.schemes.filter((s) => filter === "ALL" ? phaseOf(s) !== "ENDED" : phaseOf(s) === filter);
  const act = async (s: Scheme, what: "approve" | "withdraw" | "retire") => {
    setError(null);
    try { await api.post(`/api/admin/pricing/taxes/${s.id}/${what}`, {}); toast(t(`ps.done.${what}`)); reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <div className="grid cols-4">
        <Stat icon="verified" label={t("ps.phase.FORCE")} value={count("FORCE")} />
        <Stat icon="pending_actions" tone="wheat" label={t("ps.phase.WAITING")} value={count("WAITING")} />
        <Stat icon="event_repeat" tone="blue" label={t("ps.phase.SCHEDULED")} value={count("SCHEDULED")} />
        <Stat icon="history" label={t("ps.phase.ENDED")} value={count("ENDED")} />
      </div>
      <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
        <div className="row" role="group" aria-label={t("ps.filter")} style={{ gap: 6, flexWrap: "wrap" }}>
          {(["ALL", "FORCE", "WAITING", "SCHEDULED", "ENDED"] as const).map((p) => (
            <button key={p} type="button" aria-pressed={filter === p} className={`chip chip-select${filter === p ? " on" : ""}`}
                    onClick={() => setFilter(p)}>{p === "ALL" ? t("ps.current") : t(`ps.phase.${p}`)}</button>))}
        </div>
        <button className="btn" onClick={() => setEditing({})}><Icon name="add" />{t("ps.newTax")}</button>
      </div>
      <ErrorBox error={error} />
      {shown.length === 0 ? <Empty icon="request_quote" title={t("ps.none")} hint={t("ps.noneHint")} /> : (
        <div className="grid cols-3">{shown.map((s) => {
          const phase = phaseOf(s);
          const mine = s.created_by === me?.email;
          return (
            <article key={s.id} className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
                <div><div className="ltr mono small muted">{s.code} · v{s.version}</div><h3 style={{ margin: "2px 0 0" }}>{s.name}</h3></div>
                <span className={`chip ${phase === "FORCE" ? "green" : phase === "WAITING" ? "wheat" : phase === "SCHEDULED" ? "blue" : "outline"}`}>{t(`ps.phase.${phase}`)}</span>
              </div>
              <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                <span className="chip outline">{t(`ps.type.${s.tax_type}`)}</span>
                {s.treatment !== "STANDARD" && <span className="chip outline">{t(`ps.treat.${s.treatment}`)}</span>}
                <span className="chip outline">{s.country_code}</span>
              </div>
              <div style={{ fontFamily: "var(--font-display)", fontSize: 26, fontWeight: 700, color: "var(--brand-navy)" }}>
                <RuleSummary s={s} /></div>
              <dl className="small" style={{ margin: 0, display: "grid", gridTemplateColumns: "auto 1fr", gap: "4px 12px" }}>
                <dt className="muted">{t("ps.appliesTo")}</dt><dd style={{ margin: 0 }}><ScopeText s={s} /></dd>
                <dt className="muted">{t("ps.period")}</dt><dd style={{ margin: 0 }}><Period from={s.valid_from} to={s.valid_to} /></dd>
                {s.payable_to && <><dt className="muted">{t("ps.payableTo")}</dt><dd style={{ margin: 0 }}>{s.payable_to}</dd></>}
                <dt className="muted">{t("ps.fourEyes")}</dt><dd style={{ margin: 0 }} className="ltr">{s.created_by ?? "—"}{s.approved_by ? ` → ${s.approved_by}` : ""}</dd>
              </dl>
              <div className="row" style={{ gap: 6, flexWrap: "wrap", marginTop: "auto" }}>
                {phase === "WAITING" && <button className="btn small" disabled={mine} title={mine ? t("ps.notYours") : undefined} onClick={() => act(s, "approve")}><Icon name="check" />{t("ps.approve")}</button>}
                {phase === "WAITING" && <button className="btn tonal small" onClick={() => onTry(s.id)}><Icon name="receipt_long" />{t("ps.try")}</button>}
                {phase === "WAITING" && <button className="btn text small" onClick={() => act(s, "withdraw")}>{t("ps.withdraw")}</button>}
                {(phase === "FORCE" || phase === "SCHEDULED") && <button className="btn tonal small" onClick={() => setEditing({ from: s })}><Icon name="edit" />{t("ps.newVersion")}</button>}
                {(phase === "FORCE" || phase === "SCHEDULED") && <button className="btn text small" onClick={() => act(s, "retire")}>{t("ps.retire")}</button>}
              </div>
            </article>);
        })}</div>)}
      {editing && <SchemeForm from={editing.from} jurisdictions={data.jurisdictions} known={data.schemes}
                              onClose={() => setEditing(null)} onDone={() => { setEditing(null); reload(); }} />}
    </div>
  );
}

function RuleSummary({ s }: { s: Scheme }) {
  const { t, money } = useI18n();
  if (s.treatment !== "STANDARD") return <>{t(`ps.treat.${s.treatment}`)}</>;
  return <>{s.rules.map((r, i) => (
    <span key={i}>{i > 0 && " + "}{r.calc_method === "PERCENT" ? `${r.rate}%` : r.calc_method === "FIXED"
      ? `${money(r.amount ?? 0)} / ${t(`ps.per.${r.applies_per}`)}` : t("ps.bandsN", { n: r.bands.length })}
      {r.base_type === "TAXES" && <span className="small muted"> {t("ps.ofTaxes", { codes: r.base_include.join(", ") })}</span>}</span>))}</>;
}

function ScopeText({ s }: { s: Scheme }) {
  const { t } = useI18n();
  const parts = [
    s.scope.products?.length ? s.scope.products.map((p) => t(`ps.product.${p}`)).join(", ") : t("ps.allProducts"),
    s.scope.sellers?.length ? s.scope.sellers.map((p) => t(`ps.seller.${p}`)).join(", ") : null,
    s.scope.origin_cities?.length ? t("ps.fromCities", { cities: s.scope.origin_cities.join(", ") }) : null,
  ].filter(Boolean);
  return <>{parts.join(" · ")}</>;
}

function Period({ from, to }: { from: string; to: string | null }) {
  const { t, date } = useI18n();
  return <>{date(from)} → {to ? date(to) : t("ps.openEnded")}</>;
}

// ------------------------------------------------------------------ the guided form
type RuleDraft = { calc_method: string; rate: string; amount: string; base_type: string; base_include: string[]; applies_per: string;
  min_amount: string; max_amount: string; rounding: string; bands: { from_value: string; to_value: string; rate: string }[]; band_dimension: string; band_mode: string };
const emptyRule = (): RuleDraft => ({ calc_method: "PERCENT", rate: "", amount: "", base_type: "FARE", base_include: [], applies_per: "TICKET",
  min_amount: "", max_amount: "", rounding: "HALF_UP", bands: [{ from_value: "0", to_value: "", rate: "" }], band_dimension: "AMOUNT", band_mode: "WHOLE" });

function SchemeForm({ from, jurisdictions, known, onClose, onDone }: { from?: Scheme; jurisdictions: Jurisdiction[]; known: Scheme[];
  onClose: () => void; onDone: () => void }) {
  const { t, money } = useI18n();
  const toast = useToast();
  const [step, setStep] = useState(0);
  const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const [f, setF] = useState({
    code: from?.code ?? "", name: from?.name ?? "", jurisdiction_id: String(jurisdictions.find((j) => j.country_code === from?.country_code)?.id ?? jurisdictions.find((j) => j.country_code === "SY")?.id ?? jurisdictions[0]?.id ?? ""),
    tax_type: from?.tax_type ?? "VAT", treatment: from?.treatment ?? "STANDARD", collected_by: from?.collected_by ?? "PLATFORM",
    valid_from: from ? tomorrow : new Date().toISOString().slice(0, 10), valid_to: "",
    products: from?.scope.products ?? [], sellers: from?.scope.sellers ?? [], origin_cities: (from?.scope.origin_cities ?? []).join(", "),
  });
  const [rules, setRules] = useState<RuleDraft[]>(from?.rules.length ? from.rules.map((r) => ({
    calc_method: r.calc_method, rate: r.rate != null ? String(r.rate) : "", amount: r.amount != null ? String(fromMinor(r.amount)) : "", base_type: r.base_type,
    base_include: r.base_include, applies_per: r.applies_per, min_amount: r.min_amount != null ? String(fromMinor(r.min_amount)) : "",
    max_amount: r.max_amount != null ? String(fromMinor(r.max_amount)) : "", rounding: r.rounding_rule,
    bands: r.bands.length ? r.bands.map((b) => ({ from_value: String(b.dimension === "AMOUNT" ? fromMinor(b.from_value) : b.from_value),
      to_value: b.to_value != null ? String(b.dimension === "AMOUNT" ? fromMinor(b.to_value) : b.to_value) : "", rate: b.rate != null ? String(b.rate) : "" }))
      : [{ from_value: "0", to_value: "", rate: "" }], band_dimension: r.bands[0]?.dimension ?? "AMOUNT", band_mode: r.bands[0]?.mode ?? "WHOLE" })) : [emptyRule()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: string, v: unknown) => setF((x) => ({ ...x, [k]: v }));
  const setRule = (i: number, k: keyof RuleDraft, v: unknown) => setRules((rs) => rs.map((r, j) => j === i ? { ...r, [k]: v } : r));
  const minor = (v: string) => (v.trim() ? toMinor(v) : null);
  const otherCodes = useMemo(() => [...new Set(known.filter((s) => s.status !== "RETIRED" && s.code !== f.code).map((s) => s.code))], [known, f.code]);
  const body = () => ({
    code: f.code.trim().toUpperCase(), name: f.name.trim(), jurisdiction_id: Number(f.jurisdiction_id), tax_type: f.tax_type, treatment: f.treatment,
    collected_by: f.collected_by, valid_from: f.valid_from, valid_to: f.valid_to || null, products: f.products, sellers: f.sellers,
    origin_cities: f.origin_cities.split(",").map((c) => c.trim().toUpperCase()).filter(Boolean), from_id: from?.id ?? null,
    rules: f.treatment !== "STANDARD" ? [] : rules.map((r) => ({
      calc_method: r.calc_method, rate: r.calc_method === "PERCENT" ? Number(r.rate) : null, amount: r.calc_method === "FIXED" ? minor(r.amount) : null,
      base_type: r.base_type, base_include: r.base_include, applies_per: r.applies_per, min_amount: minor(r.min_amount), max_amount: minor(r.max_amount),
      rounding: r.rounding, compound_mode: "ADD",
      bands: r.calc_method !== "TIERED" ? [] : r.bands.map((b) => ({ dimension: r.band_dimension, mode: r.band_mode,
        from_value: r.band_dimension === "AMOUNT" ? (minor(b.from_value) ?? 0) : Number(b.from_value || 0),
        to_value: b.to_value.trim() ? (r.band_dimension === "AMOUNT" ? minor(b.to_value) : Number(b.to_value)) : null, rate: Number(b.rate) })),
    })),
  });
  const save = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/admin/pricing/taxes", body()); toast(t("ps.sentForApproval")); onDone(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const steps = [t("ps.step.basics"), t("ps.step.scope"), t("ps.step.rules"), t("ps.step.review")];
  const basicsOk = /^[A-Z][A-Z0-9_-]{1,29}$/.test(f.code.trim().toUpperCase()) && f.name.trim().length >= 2 && !!f.jurisdiction_id && !!f.valid_from;
  const rulesOk = f.treatment !== "STANDARD" || rules.every((r) => r.calc_method === "PERCENT" ? r.rate !== "" : r.calc_method === "FIXED" ? r.amount !== ""
    : r.bands.every((b) => b.rate !== "")) && rules.every((r) => r.base_type === "FARE" || r.base_include.length > 0);
  const toggle = (k: "products" | "sellers", v: string) => set(k, (f[k] as string[]).includes(v) ? (f[k] as string[]).filter((x) => x !== v) : [...(f[k] as string[]), v]);
  return (
    <Modal title={from ? t("ps.newVersionOf", { code: from.code, v: from.version + 1 }) : t("ps.newTax")} onClose={onClose} wide
           actions={<>
             <button className="btn text" onClick={step === 0 ? onClose : () => setStep(step - 1)}>{step === 0 ? t("common.cancel") : t("common.back")}</button>
             {step < 3 ? <button className="btn" disabled={(step === 0 && !basicsOk) || (step === 2 && !rulesOk)} onClick={() => setStep(step + 1)}>{t("common.next")}</button>
               : <button className="btn" disabled={busy || !basicsOk || !rulesOk} onClick={save}><Icon name="send" />{t("ps.submit")}</button>}</>}>
      <div className="stack">
        <ol className="row" aria-label={t("ps.steps")} style={{ listStyle: "none", padding: 0, margin: 0, gap: 8, flexWrap: "wrap" }}>
          {steps.map((s, i) => <li key={s} className={`chip ${i === step ? "blue" : i < step ? "green" : "outline"}`} aria-current={i === step ? "step" : undefined}>{i + 1}. {s}</li>)}
        </ol>
        <ErrorBox error={error} />
        {step === 0 && <div className="grid cols-3">
          <Field label={t("ps.code")} hint={t("ps.codeHint")}><input className="input ltr" value={f.code} disabled={!!from} onChange={(e) => set("code", e.target.value.toUpperCase())} /></Field>
          <Field label={t("ps.name")}><input className="input" value={f.name} onChange={(e) => set("name", e.target.value)} /></Field>
          <Field label={t("ps.jurisdiction")}><select className="input" value={f.jurisdiction_id} onChange={(e) => set("jurisdiction_id", e.target.value)}>
            {jurisdictions.map((j) => <option key={j.id} value={j.id}>{j.country_code} · {j.name}</option>)}</select></Field>
          <Field label={t("ps.taxType")}><select className="input" value={f.tax_type} onChange={(e) => set("tax_type", e.target.value)}>
            {["VAT", "SALES", "LEVY", "FEE", "STAMP", "WITHHOLDING", "OTHER"].map((x) => <option key={x} value={x}>{t(`ps.type.${x}`)}</option>)}</select></Field>
          <Field label={t("ps.treatment")} hint={t(`ps.treatHint.${f.treatment}`)}><select className="input" value={f.treatment} onChange={(e) => set("treatment", e.target.value)}>
            {["STANDARD", "ZERO", "EXEMPT", "OUT_OF_SCOPE", "REVERSE"].map((x) => <option key={x} value={x}>{t(`ps.treat.${x}`)}</option>)}</select></Field>
          <Field label={t("ps.collectedBy")}><select className="input" value={f.collected_by} onChange={(e) => set("collected_by", e.target.value)}>
            {["PLATFORM", "CARRIER", "AUTHORITY"].map((x) => <option key={x} value={x}>{t(`ps.collector.${x}`)}</option>)}</select></Field>
          <Field label={t("ps.validFrom")} hint={from ? t("ps.versionHint") : undefined}><input className="input ltr" type="date" min={new Date().toISOString().slice(0, 10)} value={f.valid_from} onChange={(e) => set("valid_from", e.target.value)} /></Field>
          <Field label={t("ps.validTo")} optional><input className="input ltr" type="date" value={f.valid_to} onChange={(e) => set("valid_to", e.target.value)} /></Field>
        </div>}
        {step === 1 && <div className="stack">
          <p className="small muted">{t("ps.scopeHint")}</p>
          <div><div className="small" style={{ marginBottom: 6 }}>{t("ps.products")}</div><div className="row" style={{ gap: 6 }}>
            {["TICKET", "BOOKING_FEE"].map((p) => <button key={p} type="button" aria-pressed={f.products.includes(p)} className={`chip chip-select${f.products.includes(p) ? " on" : ""}`} onClick={() => toggle("products", p)}>{t(`ps.product.${p}`)}</button>)}</div></div>
          <div><div className="small" style={{ marginBottom: 6 }}>{t("ps.sellers")}</div><div className="row" style={{ gap: 6 }}>
            {["CARRIER", "PLATFORM"].map((p) => <button key={p} type="button" aria-pressed={f.sellers.includes(p)} className={`chip chip-select${f.sellers.includes(p) ? " on" : ""}`} onClick={() => toggle("sellers", p)}>{t(`ps.seller.${p}`)}</button>)}</div></div>
          <Field label={t("ps.originCities")} hint={t("ps.originCitiesHint")}><input className="input ltr" value={f.origin_cities} onChange={(e) => set("origin_cities", e.target.value)} /></Field>
        </div>}
        {step === 2 && (f.treatment !== "STANDARD" ? <div className="alert info"><Icon name="info" /><span>{t("ps.noRulesNeeded")}</span></div> : <div className="stack">
          {rules.map((r, i) => (
            <fieldset key={i} className="card" style={{ border: "1px solid var(--outline-variant)" }}>
              <legend className="small" style={{ padding: "0 6px" }}>{t("ps.rule")} {i + 1}</legend>
              <div className="grid cols-3">
                <Field label={t("ps.method")}><select className="input" value={r.calc_method} onChange={(e) => setRule(i, "calc_method", e.target.value)}>
                  {["PERCENT", "FIXED", "TIERED"].map((x) => <option key={x} value={x}>{t(`ps.methodName.${x}`)}</option>)}</select></Field>
                {r.calc_method === "PERCENT" && <Field label={t("ps.rate")}><input className="input ltr" inputMode="decimal" value={r.rate} onChange={(e) => setRule(i, "rate", e.target.value)} /></Field>}
                {r.calc_method === "FIXED" && <Field label={t("ps.amount")}><input className="input ltr" inputMode="decimal" value={r.amount} onChange={(e) => setRule(i, "amount", e.target.value)} /></Field>}
                {r.calc_method !== "TIERED" && <Field label={t("ps.appliesPer")}><select className="input" value={r.applies_per} onChange={(e) => setRule(i, "applies_per", e.target.value)}>
                  {["TICKET", "BOOKING", "PASSENGER"].map((x) => <option key={x} value={x}>{t(`ps.per.${x}`)}</option>)}</select></Field>}
                <Field label={t("ps.base")}><select className="input" value={r.base_type} onChange={(e) => setRule(i, "base_type", e.target.value)}>
                  <option value="FARE">{t("ps.baseFare")}</option><option value="TAXES">{t("ps.baseTaxes")}</option></select></Field>
                {(r.base_type === "TAXES" || otherCodes.length > 0) && <div className="field"><span>{r.base_type === "TAXES" ? t("ps.leviedOn") : t("ps.alsoOn")}</span>
                  <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>{otherCodes.map((c) => (
                    <button key={c} type="button" aria-pressed={r.base_include.includes(c)} className={`chip chip-select ltr${r.base_include.includes(c) ? " on" : ""}`}
                            onClick={() => setRule(i, "base_include", r.base_include.includes(c) ? r.base_include.filter((x) => x !== c) : [...r.base_include, c])}>{c}</button>))}
                    {otherCodes.length === 0 && <span className="small muted">{t("ps.noOtherTaxes")}</span>}</div></div>}
                <Field label={t("ps.min")} optional><input className="input ltr" inputMode="decimal" value={r.min_amount} onChange={(e) => setRule(i, "min_amount", e.target.value)} /></Field>
                <Field label={t("ps.max")} optional><input className="input ltr" inputMode="decimal" value={r.max_amount} onChange={(e) => setRule(i, "max_amount", e.target.value)} /></Field>
                <Field label={t("ps.rounding")}><select className="input" value={r.rounding} onChange={(e) => setRule(i, "rounding", e.target.value)}>
                  {["HALF_UP", "HALF_EVEN", "DOWN", "UP"].map((x) => <option key={x} value={x}>{t(`ps.round.${x}`)}</option>)}</select></Field>
              </div>
              {r.calc_method === "TIERED" && <div className="stack" style={{ marginTop: 12 }}>
                <div className="grid cols-3">
                  <Field label={t("ps.bandBy")}><select className="input" value={r.band_dimension} onChange={(e) => setRule(i, "band_dimension", e.target.value)}>
                    <option value="AMOUNT">{t("ps.bandAmount")}</option><option value="DISTANCE">{t("ps.bandDistance")}</option></select></Field>
                  <Field label={t("ps.bandMode")} hint={t(`ps.bandModeHint.${r.band_mode}`)}><select className="input" value={r.band_mode} onChange={(e) => setRule(i, "band_mode", e.target.value)}>
                    <option value="WHOLE">{t("ps.bandWhole")}</option><option value="MARGINAL">{t("ps.bandMarginal")}</option></select></Field>
                </div>
                <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("ps.from")}</th><th>{t("ps.to")}</th><th>{t("ps.rate")}</th><th /></tr></thead>
                  <tbody>{r.bands.map((b, k) => (
                    <tr key={k}>{(["from_value", "to_value", "rate"] as const).map((col) => (
                      <td key={col}><input className="input ltr" inputMode="decimal" aria-label={t(col === "from_value" ? "ps.from" : col === "to_value" ? "ps.to" : "ps.rate")}
                                           placeholder={col === "to_value" ? "∞" : ""} value={b[col]}
                                           onChange={(e) => setRule(i, "bands", r.bands.map((x, m) => m === k ? { ...x, [col]: e.target.value } : x))} /></td>))}
                      <td>{r.bands.length > 1 && <button className="btn text small" aria-label={t("common.remove")} onClick={() => setRule(i, "bands", r.bands.filter((_, m) => m !== k))}><Icon name="close" /></button>}</td></tr>))}</tbody></table></div>
                <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={() => setRule(i, "bands", [...r.bands, { from_value: r.bands[r.bands.length - 1]?.to_value ?? "", to_value: "", rate: "" }])}><Icon name="add" />{t("ps.addBand")}</button>
              </div>}
              {rules.length > 1 && <button className="btn text small" onClick={() => setRules(rules.filter((_, j) => j !== i))}><Icon name="delete" />{t("ps.removeRule")}</button>}
            </fieldset>))}
          <button className="btn tonal" style={{ alignSelf: "flex-start" }} onClick={() => setRules([...rules, emptyRule()])}><Icon name="add" />{t("ps.addRule")}</button>
        </div>)}
        {step === 3 && <div className="stack">
          <div className="alert info"><Icon name="policy" /><span>{t("ps.reviewHint")}</span></div>
          <dl className="grid cols-2" style={{ margin: 0 }}>
            <div><dt className="small muted">{t("ps.code")}</dt><dd className="ltr" style={{ margin: 0 }}><b>{f.code}</b>{from ? ` · v${from.version + 1}` : ""}</dd></div>
            <div><dt className="small muted">{t("ps.name")}</dt><dd style={{ margin: 0 }}>{f.name}</dd></div>
            <div><dt className="small muted">{t("ps.taxType")}</dt><dd style={{ margin: 0 }}>{t(`ps.type.${f.tax_type}`)} · {t(`ps.treat.${f.treatment}`)}</dd></div>
            <div><dt className="small muted">{t("ps.period")}</dt><dd style={{ margin: 0 }}><Period from={f.valid_from} to={f.valid_to || null} /></dd></div>
          </dl>
          {f.treatment === "STANDARD" && <ul style={{ margin: 0, paddingInlineStart: 18 }}>{rules.map((r, i) => (
            <li key={i}>{r.calc_method === "PERCENT" ? `${r.rate}% ${r.base_type === "TAXES" ? t("ps.ofTaxes", { codes: r.base_include.join(", ") }) : t("ps.ofFare")}`
              : r.calc_method === "FIXED" ? `${money(minor(r.amount) ?? 0)} / ${t(`ps.per.${r.applies_per}`)}` : t("ps.bandsN", { n: r.bands.length })}
              {r.base_type === "FARE" && r.base_include.length > 0 && ` + ${r.base_include.join(", ")}`}</li>))}</ul>}
        </div>}
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ the price preview
function Preview({ schemes, tryIds, setTryIds, commissions, tryC, setTryC }: { schemes: Scheme[]; tryIds: number[]; setTryIds: (x: number[]) => void;
  commissions: Commission[]; tryC: number[]; setTryC: (x: number[]) => void }) {
  const { t, money } = useI18n();
  const opts = useLoad((signal) => api.get<{ methods: { code: string; name: string }[]; countries: string[]; cities: { code: string; name: string; country_code: string }[];
    platform_fee: number; no_funds: boolean }>(
    "/api/admin/pricing/preview-options", undefined, { signal }));
  const [f, setF] = useState({ fare: "11000", passengers: "1", country: "SY", origin_city: "", distance_km: "", at: "", method: "", commission: "0", channel: "" });
  const [r, setR] = useState<Receipt | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const waiting = schemes.filter((s) => s.status === "PENDING");
  const waitingC = commissions.filter((c) => c.status === "PENDING");
  const run = async () => {
    setBusy(true); setError(null);
    try {
      setR(await api.post<Receipt>("/api/admin/pricing/preview", {
        fare: toMinor(f.fare), passengers: Number(f.passengers) || 1, country: f.country, origin_city: f.origin_city || null,
        distance_km: f.distance_km ? Number(f.distance_km) : null, at: f.at || null, method: f.method || null,
        agency_commission_bp: Math.round(Number(f.commission || 0) * 100), try_ids: tryIds,
        channel: f.channel || null, try_commission_ids: tryC }));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const input = (k: keyof typeof f, label: string, type = "text") => (
    <Field label={label}><input className="input ltr" type={type} inputMode={type === "text" ? "decimal" : undefined} value={f[k]} onChange={(e) => set(k, e.target.value)} /></Field>);
  return (
    <div className="grid cols-2" style={{ alignItems: "start" }}>
      <section className="card stack" aria-labelledby="ps-ask">
        <h3 id="ps-ask" style={{ margin: 0 }}><Icon name="tune" /> {t("ps.askTitle")}</h3>
        <p className="small muted" style={{ margin: 0 }}>{t("ps.askHint")}</p>
        <div className="grid cols-2">
          {input("fare", t("ps.fare"))}{input("passengers", t("ps.passengers"))}
          <Loaded state={opts}>{(o) => (<>
            <Field label={t("ps.country")}><select className="input" value={f.country} onChange={(e) => set("country", e.target.value)}>
              {[...new Set(["SY", ...o.countries])].map((c) => <option key={c} value={c}>{c}</option>)}</select></Field>
            <Field label={t("ps.payMethod")}><select className="input" value={f.method} onChange={(e) => set("method", e.target.value)}>
              <option value="">{t("ps.noMethod")}</option>{o.methods.map((m) => <option key={m.code} value={m.code}>{m.name}</option>)}</select></Field>
            <Field label={t("ps.originCity")}><select className="input" value={f.origin_city} onChange={(e) => set("origin_city", e.target.value)}>
              <option value="">{t("ps.anyCity")}</option>{o.cities.filter((c) => c.country_code === f.country).map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select></Field>
          </>)}</Loaded>
          {input("distance_km", t("ps.distance"))}
          {input("at", t("ps.at"), "date")}{input("commission", t("ps.commission"))}
          <Field label={t("pc.channel")}><select className="input" value={f.channel} onChange={(e) => set("channel", e.target.value)}>
            <option value="">{t("pc.anyChannel")}</option>{["WEB", "AGENCY", "COUNTER", "API"].map((c) => <option key={c} value={c}>{t(`pc.channelName.${c}`)}</option>)}</select></Field>
        </div>
        {waiting.length > 0 && <div className="field"><span>{t("ps.tryWaiting")}</span><div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
          {waiting.map((s) => <button key={s.id} type="button" aria-pressed={tryIds.includes(s.id)} className={`chip chip-select ltr${tryIds.includes(s.id) ? " on" : ""}`}
                                      onClick={() => setTryIds(tryIds.includes(s.id) ? tryIds.filter((x) => x !== s.id) : [...tryIds, s.id])}>{s.code} v{s.version}</button>)}</div></div>}
        {waitingC.length > 0 && <div className="field"><span>{t("pc.tryWaiting")}</span><div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
          {waitingC.map((c) => <button key={c.id} type="button" aria-pressed={tryC.includes(c.id)} className={`chip chip-select ltr${tryC.includes(c.id) ? " on" : ""}`}
                                       onClick={() => setTryC(tryC.includes(c.id) ? tryC.filter((x) => x !== c.id) : [...tryC, c.id])}>{c.code} v{c.version}</button>)}</div></div>}
        <button className="btn" style={{ alignSelf: "flex-start" }} disabled={busy || !(Number(f.fare) > 0)} onClick={run}><Icon name="calculate" />{t("ps.calculate")}</button>
        <ErrorBox error={error} />
      </section>
      <section className="card stack" aria-live="polite" aria-labelledby="ps-receipt">
        <h3 id="ps-receipt" style={{ margin: 0 }}><Icon name="receipt_long" /> {t("ps.receipt")}</h3>
        {!r ? <Empty icon="receipt_long" title={t("ps.receiptEmpty")} /> : (<>
          {r.tried.length > 0 && <div className="alert info"><Icon name="science" /><span>{t("ps.triedNote", { codes: r.tried.join(", ") })}</span></div>}
          <table className="table"><tbody>
            <tr><th scope="row">{t("ps.faresLine", { n: r.passengers })}</th><td className="num">{money(r.fares_total, true, r.currency)}</td></tr>
            <tr className="small"><td style={{ paddingInlineStart: 24 }}>{t("ps.carrierNet")}</td><td className="num">{money(r.ticket_net, true, r.currency)}</td></tr>
            {r.ticket_taxes.map((x) => <TaxRow key={x.code} x={x} currency={r.currency} />)}
            <tr><th scope="row">{t("ps.platformFee")}</th><td className="num">{money(r.platform_fee, true, r.currency)}</td></tr>
            {r.platform_fee_taxes.map((x) => <TaxRow key={`f${x.code}`} x={x} currency={r.currency} />)}
            {r.traveller_commission > 0 && <tr><th scope="row">{t("pc.travellerPays")}</th><td className="num">{money(r.traveller_commission, true, r.currency)}</td></tr>}
            {r.payment_fee > 0 && <tr><th scope="row">{t("ps.paymentFee")}</th><td className="num">{money(r.payment_fee, true, r.currency)}</td></tr>}
            {r.payment_fee_absorbed > 0 && <tr className="small"><td>{t("ps.feeAbsorbed")}</td><td className="num">{money(r.payment_fee_absorbed, true, r.currency)}</td></tr>}
            <tr style={{ borderTop: "2px solid var(--outline)" }}><th scope="row" style={{ fontSize: 16 }}>{t("ps.totalPaid")}</th>
              <td className="num" style={{ fontSize: 18, fontWeight: 700 }}>{money(r.total_paid, true, r.currency)}</td></tr>
            {r.agency_commission > 0 && <tr className="small"><td>{t("ps.agencyCommission")}</td><td className="num">{money(r.agency_commission, true, r.currency)}</td></tr>}
            {r.commissions.map((c) => (
              <tr key={c.code} className="small"><td>
                <span className="ltr mono">{c.code}</span> · {c.name}{c.tried && <span className="chip wheat" style={{ marginInlineStart: 6 }}>{t("ps.triedChip")}</span>}
                <div className="muted">{t(`ps.who.${c.payer === "TRAVELLER" ? "TRAVELLER" : c.payer}`)} → {t(`ps.who.${c.receiver}`)} · {t("ps.onBase", { base: money(c.base, true, r.currency) })}</div>
              </td><td className="num">{money(c.amount, true, r.currency)}</td></tr>))}
          </tbody></table>
          {r.no_funds && <p className="small muted">{t("ps.noFunds")}</p>}
          <h4 style={{ margin: "8px 0 0" }}>{t("ps.whoGets")}</h4>
          <div role="img" aria-label={r.shares.filter((s) => s.amount !== 0).map((s) => `${t(`ps.who.${s.who}`)} ${money(s.amount, true, r.currency)}`).join(", ")}
               style={{ display: "flex", height: 14, borderRadius: 7, overflow: "hidden", background: "var(--surface-container)" }}>
            {r.shares.filter((s) => s.amount > 0).map((s) => <div key={s.who} style={{ width: `${(s.amount / r.total_paid) * 100}%`, background: SHARE_COLOUR[s.who] }} />)}
          </div>
          <ul className="row" style={{ listStyle: "none", padding: 0, margin: 0, gap: 14, flexWrap: "wrap" }}>
            {r.shares.filter((s) => s.amount !== 0).map((s) => <li key={s.who} className="small row" style={{ gap: 6, alignItems: "center" }}>
              <span aria-hidden="true" style={{ width: 10, height: 10, borderRadius: 3, background: SHARE_COLOUR[s.who], display: "inline-block" }} />
              {t(`ps.who.${s.who}`)} <b className="mono">{money(s.amount, true, r.currency)}</b>
              <span className="muted">({((s.amount / r.total_paid) * 100).toFixed(1)}%)</span></li>)}
          </ul>
        </>)}
      </section>
    </div>
  );
}

function TaxRow({ x, currency }: { x: TaxLine; currency: string }) {
  const { t, money } = useI18n();
  return (
    <tr className="small">
      <td style={{ paddingInlineStart: 24 }}>
        <span className="ltr mono">{x.code}</span> · {x.treatment !== "STANDARD" ? t(`ps.treat.${x.treatment}`)
          : x.kind === "PERCENT" ? `${x.rate}%` : `${t(`ps.kind.${x.kind}`)} (≈ ${x.rate.toFixed(2)}%)`}
        {x.payable_to && <span className="muted"> → {x.payable_to}</span>}{x.tried && <span className="chip wheat" style={{ marginInlineStart: 6 }}>{t("ps.triedChip")}</span>}
        <div className="muted">{t("ps.onBase", { base: money(x.base, true, currency) })}</div>
      </td>
      <td className="num">{money(x.amount, true, currency)}</td>
    </tr>
  );
}


// ------------------------------------------------------------------ commission schemes (1175)
function Commissions({ schemes, reload, onTry }: { schemes: Commission[]; reload: () => void; onTry: (id: number) => void }) {
  const { t, money } = useI18n();
  const toast = useToast();
  const { me } = useAuth();
  const [filter, setFilter] = useState<Phase | "ALL">("ALL");
  const [editing, setEditing] = useState<{ from?: Commission } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const phase = (c: Commission): Phase => c.status === "PENDING" ? "WAITING" : c.scheduled ? "SCHEDULED" : c.in_force ? "FORCE" : "ENDED";
  const count = (p: Phase) => schemes.filter((c) => phase(c) === p).length;
  const shown = schemes.filter((c) => filter === "ALL" ? phase(c) !== "ENDED" : phase(c) === filter);
  const act = async (c: Commission, what: "approve" | "withdraw" | "retire") => {
    setError(null);
    try { await api.post(`/api/admin/pricing/commissions/${c.id}/${what}`, {}); toast(t(`ps.done.${what}`)); reload(); } catch (e) { setError(e); }
  };
  const ruleText = (r: CRule) => r.calc_method === "PERCENT" ? `${r.rate}%` : r.calc_method === "FIXED" ? `${money(r.amount ?? 0)} / ${t("ps.per.BOOKING")}`
    : t("ps.bandsN", { n: r.bands.length });
  return (
    <div className="stack">
      <p className="muted" style={{ margin: 0 }}>{t("pc.sub")}</p>
      <div className="grid cols-4">
        <Stat icon="verified" label={t("ps.phase.FORCE")} value={count("FORCE")} />
        <Stat icon="pending_actions" tone="wheat" label={t("ps.phase.WAITING")} value={count("WAITING")} />
        <Stat icon="event_repeat" tone="blue" label={t("ps.phase.SCHEDULED")} value={count("SCHEDULED")} />
        <Stat icon="history" label={t("ps.phase.ENDED")} value={count("ENDED")} />
      </div>
      <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
        <div className="row" role="group" aria-label={t("ps.filter")} style={{ gap: 6, flexWrap: "wrap" }}>
          {(["ALL", "FORCE", "WAITING", "SCHEDULED", "ENDED"] as const).map((p) => (
            <button key={p} type="button" aria-pressed={filter === p} className={`chip chip-select${filter === p ? " on" : ""}`}
                    onClick={() => setFilter(p)}>{p === "ALL" ? t("ps.current") : t(`ps.phase.${p}`)}</button>))}
        </div>
        <button className="btn" onClick={() => setEditing({})}><Icon name="add" />{t("pc.new")}</button>
      </div>
      <ErrorBox error={error} />
      {shown.length === 0 ? <Empty icon="handshake" title={t("pc.none")} hint={t("pc.noneHint")} /> : (
        <div className="grid cols-3">{shown.map((c) => {
          const ph = phase(c);
          const mine = c.created_by === me?.email;
          return (
            <article key={c.id} className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
                <div><div className="ltr mono small muted">{c.code} · v{c.version}</div><h3 style={{ margin: "2px 0 0" }}>{c.name ?? c.code}</h3></div>
                <span className={`chip ${ph === "FORCE" ? "green" : ph === "WAITING" ? "wheat" : ph === "SCHEDULED" ? "blue" : "outline"}`}>{t(`ps.phase.${ph}`)}</span>
              </div>
              <div className="row" style={{ gap: 8, alignItems: "center", flexWrap: "wrap" }} aria-label={t("pc.flow")}>
                <span className="chip outline">{t(`ps.who.${c.payer}`)}</span><Icon name="arrow_forward" size={18} />
                <span className="chip blue">{t(`ps.who.${c.receiver}`)}</span>
              </div>
              <div style={{ fontFamily: "var(--font-display)", fontSize: 26, fontWeight: 700, color: "var(--brand-navy)" }}>
                {c.rules.length ? c.rules.map(ruleText).join(" + ") : "—"} <span className="small muted">{t(`pc.base.${c.base_type}`)}</span></div>
              <dl className="small" style={{ margin: 0, display: "grid", gridTemplateColumns: "auto 1fr", gap: "4px 12px" }}>
                <dt className="muted">{t("pc.kind")}</dt><dd style={{ margin: 0 }}>{t(`pc.type.${c.type}`)}</dd>
                <dt className="muted">{t("pc.channels")}</dt><dd style={{ margin: 0 }}>{c.scope.channels?.length ? c.scope.channels.map((x) => t(`pc.channelName.${x}`)).join(", ") : t("pc.anyChannel")}</dd>
                <dt className="muted">{t("ps.period")}</dt><dd style={{ margin: 0 }}><Period from={c.valid_from} to={c.valid_to} /></dd>
                <dt className="muted">{t("ps.fourEyes")}</dt><dd style={{ margin: 0 }} className="ltr">{c.created_by ?? "—"}{c.approved_by ? ` → ${c.approved_by}` : ""}</dd>
              </dl>
              <div className="row" style={{ gap: 6, flexWrap: "wrap", marginTop: "auto" }}>
                {ph === "WAITING" && <button className="btn small" disabled={mine} title={mine ? t("ps.notYours") : undefined} onClick={() => act(c, "approve")}><Icon name="check" />{t("ps.approve")}</button>}
                {ph === "WAITING" && <button className="btn tonal small" onClick={() => onTry(c.id)}><Icon name="receipt_long" />{t("ps.try")}</button>}
                {ph === "WAITING" && <button className="btn text small" onClick={() => act(c, "withdraw")}>{t("ps.withdraw")}</button>}
                {(ph === "FORCE" || ph === "SCHEDULED") && <button className="btn tonal small" onClick={() => setEditing({ from: c })}><Icon name="edit" />{t("ps.newVersion")}</button>}
                {(ph === "FORCE" || ph === "SCHEDULED") && <button className="btn text small" onClick={() => act(c, "retire")}>{t("ps.retire")}</button>}
              </div>
            </article>);
        })}</div>)}
      {editing && <CommissionForm from={editing.from} onClose={() => setEditing(null)} onDone={() => { setEditing(null); reload(); }} />}
    </div>
  );
}

const RECEIVER_OF: Record<string, string> = { PLATFORM: "PLATFORM", INTERMEDIARY: "AGENCY", SUB_AGENT: "AGENCY", OVERRIDE: "AGENCY", PAYMENT: "PAYMENT", REFERRAL: "REFERRER" };
const PAYER_OF: Record<string, string> = { CARRIER: "CARRIER", PLATFORM: "PLATFORM", CHANNEL: "AGENCY", CUSTOMER: "TRAVELLER" };

function CommissionForm({ from, onClose, onDone }: { from?: Commission; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const [f, setF] = useState({ code: from?.code ?? "", name: from?.name ?? "", type: from?.type ?? "INTERMEDIARY", funded_by: from?.funded_by ?? "CARRIER",
    base_type: from?.base_type ?? "FARE", channels: from?.scope.channels ?? [] as string[], valid_from: from ? tomorrow : new Date().toISOString().slice(0, 10), valid_to: "" });
  const [rules, setRules] = useState(from?.rules.length ? from.rules.map((r) => ({ calc_method: r.calc_method, rate: r.rate != null ? String(r.rate) : "",
    amount: r.amount != null ? String(fromMinor(r.amount)) : "", min: r.min_amount != null ? String(fromMinor(r.min_amount)) : "", max: r.max_amount != null ? String(fromMinor(r.max_amount)) : "",
    mode: r.bands[0]?.mode ?? "WHOLE", bands: r.bands.map((b) => ({ from: String(fromMinor(b.from_value)), to: b.to_value != null ? String(fromMinor(b.to_value)) : "", rate: b.rate != null ? String(b.rate) : "" })) }))
    : [{ calc_method: "PERCENT", rate: "", amount: "", min: "", max: "", mode: "WHOLE", bands: [{ from: "0", to: "", rate: "" }] }]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: string, v: unknown) => setF((x) => ({ ...x, [k]: v }));
  const setRule = (i: number, k: string, v: unknown) => setRules((rs) => rs.map((r, j) => j === i ? { ...r, [k]: v } : r));
  const minor = (v: string) => (v.trim() ? toMinor(v) : null);
  const same = RECEIVER_OF[f.type] === PAYER_OF[f.funded_by];
  const ok = /^[A-Z][A-Z0-9_-]{1,29}$/.test(f.code) && f.name.trim().length >= 2 && !same && rules.every((r) =>
    r.calc_method === "PERCENT" ? r.rate !== "" : r.calc_method === "FIXED" ? r.amount !== "" : r.bands.every((b) => b.rate !== ""));
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/admin/pricing/commissions", { code: f.code, name: f.name.trim(), type: f.type, funded_by: f.funded_by, base_type: f.base_type,
        channels: f.channels, valid_from: f.valid_from, valid_to: f.valid_to || null, from_id: from?.id ?? null,
        rules: rules.map((r) => ({ calc_method: r.calc_method, rate: r.calc_method === "PERCENT" ? Number(r.rate) : null,
          amount: r.calc_method === "FIXED" ? minor(r.amount) : null, min_amount: minor(r.min), max_amount: minor(r.max),
          bands: r.calc_method !== "TIERED" ? [] : r.bands.map((b) => ({ dimension: "AMOUNT", mode: r.mode, from_value: minor(b.from) ?? 0, to_value: minor(b.to), rate: Number(b.rate) })) })) });
      toast(t("ps.sentForApproval")); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const sel = (k: string, label: string, opts: string[], prefix: string) => (
    <Field label={label}><select className="input" value={(f as Record<string, unknown>)[k] as string} onChange={(e) => set(k, e.target.value)}>
      {opts.map((x) => <option key={x} value={x}>{t(`${prefix}.${x}`)}</option>)}</select></Field>);
  return (
    <Modal title={from ? t("ps.newVersionOf", { code: from.code, v: from.version + 1 }) : t("pc.new")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !ok} onClick={save}><Icon name="send" />{t("ps.submit")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div className="grid cols-3">
          <Field label={t("ps.code")} hint={t("ps.codeHint")}><input className="input ltr" value={f.code} disabled={!!from} onChange={(e) => set("code", e.target.value.toUpperCase())} /></Field>
          <Field label={t("ps.name")}><input className="input" value={f.name} onChange={(e) => set("name", e.target.value)} /></Field>
          {sel("type", t("pc.kind"), ["INTERMEDIARY", "SUB_AGENT", "OVERRIDE", "PLATFORM", "PAYMENT", "REFERRAL"], "pc.type")}
          {sel("funded_by", t("pc.paidBy"), ["CARRIER", "PLATFORM", "CHANNEL", "CUSTOMER"], "pc.funded")}
          {sel("base_type", t("pc.baseLabel"), ["FARE", "NET", "FEE"], "pc.base")}
          <Field label={t("ps.validFrom")}><input className="input ltr" type="date" min={new Date().toISOString().slice(0, 10)} value={f.valid_from} onChange={(e) => set("valid_from", e.target.value)} /></Field>
        </div>
        <div className={`alert ${same ? "error" : "info"}`}><Icon name={same ? "error" : "info"} />
          <span>{same ? t("pc.samePerson") : t("pc.flowText", { payer: t(`ps.who.${PAYER_OF[f.funded_by]}`), receiver: t(`ps.who.${RECEIVER_OF[f.type]}`) })}</span></div>
        <div><div className="small" style={{ marginBottom: 6 }}>{t("pc.channels")} <span className="muted">({t("pc.channelsHint")})</span></div>
          <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>{["WEB", "AGENCY", "COUNTER", "API"].map((c) => (
            <button key={c} type="button" aria-pressed={f.channels.includes(c)} className={`chip chip-select${f.channels.includes(c) ? " on" : ""}`}
                    onClick={() => set("channels", f.channels.includes(c) ? f.channels.filter((x) => x !== c) : [...f.channels, c])}>{t(`pc.channelName.${c}`)}</button>))}</div></div>
        {rules.map((r, i) => (
          <fieldset key={i} className="card" style={{ border: "1px solid var(--outline-variant)" }}>
            <legend className="small" style={{ padding: "0 6px" }}>{t("ps.rule")} {i + 1}</legend>
            <div className="grid cols-3">
              <Field label={t("ps.method")}><select className="input" value={r.calc_method} onChange={(e) => setRule(i, "calc_method", e.target.value)}>
                {["PERCENT", "FIXED", "TIERED"].map((x) => <option key={x} value={x}>{t(`ps.methodName.${x}`)}</option>)}</select></Field>
              {r.calc_method === "PERCENT" && <Field label={t("ps.rate")}><input className="input ltr" inputMode="decimal" value={r.rate} onChange={(e) => setRule(i, "rate", e.target.value)} /></Field>}
              {r.calc_method === "FIXED" && <Field label={t("pc.perBooking")}><input className="input ltr" inputMode="decimal" value={r.amount} onChange={(e) => setRule(i, "amount", e.target.value)} /></Field>}
              {r.calc_method === "TIERED" && <Field label={t("ps.bandMode")} hint={t(`ps.bandModeHint.${r.mode}`)}><select className="input" value={r.mode} onChange={(e) => setRule(i, "mode", e.target.value)}>
                <option value="WHOLE">{t("ps.bandWhole")}</option><option value="MARGINAL">{t("ps.bandMarginal")}</option></select></Field>}
              <Field label={t("ps.min")} optional><input className="input ltr" inputMode="decimal" value={r.min} onChange={(e) => setRule(i, "min", e.target.value)} /></Field>
              <Field label={t("ps.max")} optional><input className="input ltr" inputMode="decimal" value={r.max} onChange={(e) => setRule(i, "max", e.target.value)} /></Field>
            </div>
            {r.calc_method === "TIERED" && <div className="stack" style={{ marginTop: 8 }}>
              <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("ps.from")}</th><th>{t("ps.to")}</th><th>{t("ps.rate")}</th><th /></tr></thead>
                <tbody>{r.bands.map((b, k) => <tr key={k}>{(["from", "to", "rate"] as const).map((col) => (
                  <td key={col}><input className="input ltr" inputMode="decimal" aria-label={t(col === "from" ? "ps.from" : col === "to" ? "ps.to" : "ps.rate")} placeholder={col === "to" ? "∞" : ""}
                                       value={b[col]} onChange={(e) => setRule(i, "bands", r.bands.map((x, m) => m === k ? { ...x, [col]: e.target.value } : x))} /></td>))}
                  <td>{r.bands.length > 1 && <button className="btn text small" aria-label={t("common.remove")} onClick={() => setRule(i, "bands", r.bands.filter((_, m) => m !== k))}><Icon name="close" /></button>}</td></tr>)}</tbody></table></div>
              <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={() => setRule(i, "bands", [...r.bands, { from: r.bands[r.bands.length - 1]?.to ?? "", to: "", rate: "" }])}><Icon name="add" />{t("ps.addBand")}</button>
            </div>}
            {rules.length > 1 && <button className="btn text small" onClick={() => setRules(rules.filter((_, j) => j !== i))}><Icon name="delete" />{t("ps.removeRule")}</button>}
          </fieldset>))}
        <button className="btn tonal" style={{ alignSelf: "flex-start" }} onClick={() => setRules([...rules, { calc_method: "PERCENT", rate: "", amount: "", min: "", max: "", mode: "WHOLE", bands: [{ from: "0", to: "", rate: "" }] }])}><Icon name="add" />{t("ps.addRule")}</button>
      </div>
    </Modal>
  );
}
