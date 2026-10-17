import { useState } from "react";
import { useI18n } from "../i18n";
import { Icon } from "./ui";

// The KYC form drawn from its definition (owner's request, October 2026; migration 1118). The form is data: sections of
// fields with a type, option sets and the documents asked for. The labels of the built-in fields are in the locale
// files (kyc.s, kyc.f, kyc.c, kyc.o, kyc.h, kyc.d); a field the platform adds carries its own labels in English and
// Arabic. Values kept encrypted come back as {$enc, $k, $last4}: they are shown masked and sent back as they are to
// keep them, or replaced by a new value.

export type Label = { en: string; ar: string };
export interface KycField {
  key: string; type: string; required?: boolean; sensitive?: boolean; options?: string; min?: number; max?: number;
  min_rows?: number; columns?: KycField[]; details?: boolean; details_required?: boolean; hint?: boolean; accept?: boolean;
  label?: Label; help?: Label;
}
export interface KycSection { key: string; label?: Label; fields: KycField[] }
export interface KycDefinition {
  sections: KycSection[]; option_sets: Record<string, (string | { value: string; label: Label })[]>;
  documents?: { type: string; required: boolean }[];
}
export type Sealed = { $enc: string; $k: number; $last4: string };
export type Answers = Record<string, unknown>;
type Row = Record<string, unknown>;
type YesNo = { value?: boolean; details?: string };

// ISO 3166-1 alpha-2; the names come from the browser in the reader's language
export const COUNTRIES = ("SY LB JO IQ TR SA AE EG KW QA BH OM YE PS IR DZ MA TN LY SD AF AL AM AO AR AT AU AZ BA BD BE BG BR BY CA " +
  "CH CL CN CO CY CZ DE DK EE ES ET FI FR GB GE GR HR HU ID IE IL IN IS IT JP KE KG KR KZ LK LT LU LV MD ME MK MT MX MY NG NL NO NZ PH PK " +
  "PL PT RO RS RU SE SG SI SK SO TH TJ TM TZ UA UG US UZ VE VN ZA").split(" ");

export function isSealed(v: unknown): v is Sealed {
  return typeof v === "object" && v !== null && "$enc" in v;
}

export function useKycText() {
  const { t, has, locale, intl } = useI18n();
  const own = (l?: Label) => (l ? (locale === "ar" ? l.ar : l.en) : null);
  const regions = (() => { try { return new Intl.DisplayNames([intl], { type: "region" }); } catch { return null; } })();
  return {
    section: (s: KycSection) => own(s.label) ?? t(`kyc.s.${s.key}`),
    field: (f: KycField) => own(f.label) ?? t(`kyc.f.${f.key}`),
    column: (c: KycField) => own(c.label) ?? t(`kyc.c.${c.key}`),
    hint: (f: KycField) => own(f.help) ?? (f.hint ? t(`kyc.h.${f.key}`) : undefined),
    details: (f: KycField) => (has(`kyc.d.${f.key}`) ? t(`kyc.d.${f.key}`) : t("kyc.details")),
    option: (def: KycDefinition, set: string, v: string) => {
      const o = (def.option_sets[set] ?? []).find((x) => (typeof x === "string" ? x : x.value) === v);
      return (o && typeof o !== "string" && own(o.label)) || (has(`kyc.o.${set}.${v}`) ? t(`kyc.o.${set}.${v}`) : v);
    },
    country: (code: string) => (code && regions ? regions.of(code) ?? code : code),
  };
}

export function optionValues(def: KycDefinition, set?: string): string[] {
  return (set ? def.option_sets[set] ?? [] : []).map((o) => (typeof o === "string" ? o : o.value));
}

/** How many things a section still lacks, from the missing list (field keys, "table.row.column", "field.details"). */
export function sectionMissing(section: KycSection, missing: string[]): number {
  const keys = new Set(section.fields.map((f) => f.key));
  return missing.filter((m) => keys.has(m.split(".")[0])).length;
}

/** The label of a path of the missing list or of an error, for the summary above the form. */
export function usePathLabel(def: KycDefinition | null) {
  const text = useKycText();
  const { t } = useI18n();
  return (path: string) => {
    if (path.startsWith("doc:")) return t(`kyc.doc.${path.slice(4)}`);
    const [key, row, col] = path.split(".");
    const f = def?.sections.flatMap((s) => s.fields).find((x) => x.key === key);
    if (!f) return path;
    if (row === "details") return `${text.field(f)}: ${text.details(f)}`;
    const c = col && f.columns?.find((x) => x.key === col);
    return c ? `${text.field(f)} ${Number(row) + 1}: ${text.column(c)}` : text.field(f);
  };
}

function Value({ spec, def, v, path, onReveal }: {
  spec: KycField; def: KycDefinition; v: unknown; path: string; onReveal?: (path: string) => Promise<string>;
}) {
  const { t, money, date } = useI18n();
  const text = useKycText();
  const [shown, setShown] = useState<string | null>(null);
  if (v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0)) return <span className="muted">—</span>;
  if (isSealed(v)) {
    return (
      <span className="row" style={{ gap: 6, display: "inline-flex" }}>
        <span className="mono" dir="ltr">{shown ?? `•••• ${v.$last4}`}</span>
        {onReveal && shown === null && (
          <button type="button" className="btn text small" onClick={async () => { const out = await onReveal(path); if (out) setShown(out); }}>
            <Icon name="visibility" />{t("kyc.show")}</button>)}
      </span>
    );
  }
  switch (spec.type) {
    case "select": return <>{text.option(def, spec.options ?? "", String(v))}</>;
    case "multi": return <>{(v as string[]).map((x) => text.option(def, spec.options ?? "", x)).join(t("common.listSep"))}</>;
    case "country": return <>{text.country(String(v))}</>;
    case "money": return <>{money(Number(v))}</>;
    case "percent": return <>{`${v}%`}</>;
    case "date": return <>{date(`${v}T12:00:00Z`, { weekday: undefined, year: "numeric" })}</>;
    case "bool": return <>{v ? `✓ ${t("kyc.yes")}` : `✗ ${t("kyc.no")}`}</>;
    case "yesno": {
      const yn = v as YesNo;
      return <>{yn.value ? t("kyc.yes") : t("kyc.no")}{yn.value && yn.details ? <div className="small muted"><bdi>{yn.details}</bdi></div> : null}</>;
    }
    default: return <span style={{ whiteSpace: "pre-wrap" }}><bdi>{String(v)}</bdi></span>;
  }
}

function Input({ spec, def, v, onChange, label, invalid, id }: {
  spec: KycField; def: KycDefinition; v: unknown; onChange: (v: unknown) => void; label: string; invalid: boolean; id?: string;
}) {
  const { t, market } = useI18n();
  const text = useKycText();
  const scale = 10 ** (market.minor_unit ?? 2);
  const cls = `input${invalid ? " invalid" : ""}`;
  const common = { id, className: cls, "aria-label": id ? undefined : label, "aria-invalid": invalid || undefined };
  if (spec.sensitive && isSealed(v)) {
    return (
      <span className="row" style={{ gap: 6 }}>
        <span className="mono" dir="ltr">•••• {v.$last4}</span>
        <button type="button" className="btn text small" onClick={() => onChange("")}><Icon name="edit" />{t("kyc.change")}</button>
      </span>
    );
  }
  switch (spec.type) {
    case "textarea":
      return <textarea {...common} dir="auto" rows={3} maxLength={spec.max ?? 4000} value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "number": case "decimal": case "percent":
      return <input {...common} type="number" inputMode="decimal" step={spec.type === "number" ? 1 : "any"}
                    min={spec.type === "percent" ? 0 : spec.min} max={spec.type === "percent" ? 100 : spec.max}
                    value={v === undefined || v === null ? "" : String(v)}
                    onChange={(e) => onChange(e.target.value === "" ? null : Number(e.target.value))} />;
    case "money":
      return <input {...common} type="number" inputMode="decimal" min={0} step="any"
                    value={typeof v === "number" ? String(v / scale) : ""}
                    onChange={(e) => onChange(e.target.value === "" ? null : Math.round(Number(e.target.value) * scale))} />;
    case "date": return <input {...common} type="date" value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "time": return <input {...common} type="time" value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "email": return <input {...common} type="email" autoComplete="off" value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "phone": return <input {...common} type="tel" dir="ltr" value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "url": return <input {...common} type="url" dir="ltr" value={String(v ?? "")} onChange={(e) => onChange(e.target.value)} />;
    case "select": case "country": {
      const values = spec.type === "country" ? COUNTRIES : optionValues(def, spec.options);
      return (
        <select {...common} value={String(v ?? "")} onChange={(e) => onChange(e.target.value)}>
          <option value="">—</option>
          {values.map((x) => <option key={x} value={x}>{spec.type === "country" ? text.country(x) : text.option(def, spec.options ?? "", x)}</option>)}
        </select>
      );
    }
    case "bool":
      return <input type="checkbox" id={id} aria-label={id ? undefined : label} checked={v === true} onChange={(e) => onChange(e.target.checked)} />;
    default:
      return <input {...common} type="text" dir="auto" maxLength={spec.max ?? (spec.sensitive ? 100 : 300)} value={String(v ?? "")}
                    onChange={(e) => onChange(e.target.value)} />;
  }
}

function TableField({ f, def, rows, onChange, readOnly, problem, onReveal }: {
  f: KycField; def: KycDefinition; rows: Row[]; onChange: (rows: Row[]) => void; readOnly: boolean;
  problem: (path: string) => boolean; onReveal?: (path: string) => Promise<string>;
}) {
  const { t } = useI18n();
  const text = useKycText();
  const cols = f.columns ?? [];
  const blank = (): Row => ({});
  const shown = rows.length > 0 || readOnly ? rows : Array.from({ length: Math.max(f.min_rows ?? 1, 1) }, blank);
  const set = (i: number, key: string, v: unknown) => onChange(shown.map((r, j) => (j === i ? { ...r, [key]: v } : r)));
  return (
    <div className="stack tight">
      <div className="table-wrap" tabIndex={0}>
        <table className="table">
          <thead><tr><th className="num">#</th>{cols.map((c) => <th key={c.key}>{text.column(c)}{c.required && !readOnly ? " *" : ""}</th>)}{!readOnly && <th />}</tr></thead>
          <tbody>
            {shown.length === 0 && <tr><td colSpan={cols.length + 1} className="muted">—</td></tr>}
            {shown.map((r, i) => (
              <tr key={i}>
                <td className="num">{i + 1}</td>
                {cols.map((c) => (
                  <td key={c.key} style={{ minWidth: c.type === "bool" ? 64 : c.type === "number" || c.type === "percent" ? 96 : 150 }}>
                    {readOnly ? <Value spec={c} def={def} v={r[c.key]} path={`${f.key}.${i}.${c.key}`} onReveal={onReveal} />
                      : <Input spec={c} def={def} v={r[c.key]} onChange={(v) => set(i, c.key, v)} invalid={problem(`${f.key}.${i}.${c.key}`)}
                               label={`${text.column(c)} ${i + 1}`} />}
                  </td>
                ))}
                {!readOnly && <td><button type="button" className="icon-btn" title={t("kyc.removeRow")} aria-label={`${t("kyc.removeRow")} ${i + 1}`}
                                         onClick={() => onChange(shown.filter((_, j) => j !== i))}><Icon name="delete" /></button></td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!readOnly && <button type="button" className="btn tonal small" style={{ alignSelf: "flex-start" }} onClick={() => onChange([...shown, blank()])}>
        <Icon name="add" />{t("kyc.addRow")}</button>}
    </div>
  );
}

/** One section of the form: its fields to fill, or its answers to read. */
export function KycSectionView({ section, def, answers, onChange, readOnly, errors = {}, missing = [], onReveal, highlight = [] }: {
  section: KycSection; def: KycDefinition; answers: Answers; onChange?: (a: Answers) => void; readOnly: boolean;
  errors?: Record<string, string>; missing?: string[]; onReveal?: (path: string) => Promise<string>; highlight?: string[];
}) {
  const { t } = useI18n();
  const text = useKycText();
  const problem = (path: string) => path in errors || missing.includes(path);
  const set = (key: string, v: unknown) => onChange?.({ ...answers, [key]: v });
  return (
    <div className="kyc-grid">
      {section.fields.map((f) => {
        const v = answers[f.key];
        const id = `kyc-${f.key}`;
        const wide = f.type === "table" || f.type === "textarea" || f.type === "multi" || f.type === "yesno" || f.type === "bool";
        const err = errors[f.key] ?? (missing.includes(f.key) ? "required" : missing.includes(`${f.key}.details`) ? "details" : undefined);
        const flagged = highlight.includes(f.key);
        const label = text.field(f);
        return (
          <div key={f.key} className={`kyc-field${wide ? " wide" : ""}${flagged ? " flagged" : ""}`} data-field={f.key}>
            {f.type === "bool" && !readOnly ? (
              <label className="row" style={{ gap: 10, alignItems: "flex-start" }}>
                <Input spec={f} def={def} v={v} onChange={(x) => set(f.key, x)} label={label} invalid={Boolean(err)} />
                <span>{label}{f.required ? " *" : ""}</span>
              </label>
            ) : f.type === "yesno" && !readOnly ? (
              <fieldset className="kyc-yesno">
                <legend>{label}{f.required ? " *" : ""}</legend>
                <div className="row" style={{ gap: 16 }}>
                  {[true, false].map((b) => (
                    <label key={String(b)} className="row" style={{ gap: 6 }}>
                      <input type="radio" name={id} checked={(v as YesNo | undefined)?.value === b}
                             onChange={() => set(f.key, { ...(v as YesNo | undefined), value: b })} />
                      {b ? t("kyc.yes") : t("kyc.no")}
                    </label>
                  ))}
                </div>
                {f.details && (v as YesNo | undefined)?.value === true && (
                  <label className="field">
                    <span>{text.details(f)}{f.details_required ? " *" : ""}</span>
                    <textarea className={`input${err === "details" ? " invalid" : ""}`} dir="auto" rows={2} maxLength={1000}
                              value={(v as YesNo).details ?? ""} onChange={(e) => set(f.key, { ...(v as YesNo), details: e.target.value })} />
                  </label>
                )}
              </fieldset>
            ) : f.type === "multi" && !readOnly ? (
              <fieldset className="kyc-yesno">
                <legend>{label}{f.required ? " *" : ""}</legend>
                <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                  {optionValues(def, f.options).map((x) => {
                    const on = Array.isArray(v) && (v as string[]).includes(x);
                    return (
                      <label key={x} className={`chip-select row${on ? " on" : ""}`} style={{ gap: 6, padding: "0 10px" }}>
                        <input type="checkbox" checked={on}
                               onChange={() => set(f.key, on ? (v as string[]).filter((y) => y !== x) : [...((v as string[]) ?? []), x])} />
                        {text.option(def, f.options ?? "", x)}
                      </label>
                    );
                  })}
                </div>
              </fieldset>
            ) : f.type === "table" ? (
              <div className="stack tight">
                <span className="kyc-label">{label}{f.required && !readOnly ? " *" : ""}</span>
                {text.hint(f) && <small className="hint">{text.hint(f)}</small>}
                <TableField f={f} def={def} rows={Array.isArray(v) ? (v as Row[]) : []} onChange={(rows) => set(f.key, rows)} readOnly={readOnly}
                            problem={problem} onReveal={onReveal} />
              </div>
            ) : readOnly ? (
              <div className="stack tight">
                <span className="kyc-label">{label}</span>
                <Value spec={f} def={def} v={v} path={f.key} onReveal={onReveal} />
              </div>
            ) : (
              <label className="field" htmlFor={id}>
                <span>{label}{f.required ? " *" : ""}{f.type === "money" ? ` (${t("kyc.inCurrency")})` : ""}</span>
                <Input spec={f} def={def} v={v} onChange={(x) => set(f.key, x)} label={label} invalid={Boolean(err)} id={id} />
                {text.hint(f) && f.type !== "table" && <small className="hint">{text.hint(f)}</small>}
              </label>
            )}
            {err && !readOnly && <small className="kyc-error" role="alert">{t(`kyc.err.${err}`)}</small>}
          </div>
        );
      })}
    </div>
  );
}
