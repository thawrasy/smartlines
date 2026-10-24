import { useMemo } from "react";
import { useI18n } from "../i18n";
import { Field } from "./ui";
import { COUNTRIES } from "./KycForm";

/** A person's name in parts (N4, 1149): the nationality first, then the parts its rules require, and the Latin name as in
 *  the passport. The server applies the same rules (identity.name_rules). */
export interface NameDraft {
  nationality: string; first_name: string; father_name: string; grandfather_name: string; last_name: string; mother_name: string;
  first_name_latin: string; father_name_latin: string; grandfather_name_latin: string; last_name_latin: string;
}
export type NameRules = Record<string, { required?: string[]; latin_required?: boolean } | boolean | number>;

export const blankName = (): NameDraft => ({
  nationality: "SY", first_name: "", father_name: "", grandfather_name: "", last_name: "", mother_name: "",
  first_name_latin: "", father_name_latin: "", grandfather_name_latin: "", last_name_latin: "",
});

const NAME_PART = /^\p{L}+(?:[ '\-.]\p{L}+)*\.?$/u;
const LATIN_PART = /^[A-Za-z][A-Za-z '.-]{0,59}$/;
const tidy = (s: string) => s.trim().replace(/\s+/g, " ");

function ruleFor(rules: NameRules | undefined, nationality: string) {
  const r = (rules?.[nationality] ?? rules?.OTHER) as { required?: string[]; latin_required?: boolean } | undefined;
  return r ?? (nationality === "SY" ? { required: ["first", "father", "last"], latin_required: false }
                                    : { required: ["first", "last"], latin_required: true });
}

/** The name as the API takes it: empty parts left out. */
export function nameBody(n: NameDraft) {
  const out: Record<string, string> = { nationality: n.nationality };
  for (const k of Object.keys(n) as (keyof NameDraft)[]) {
    if (k !== "nationality" && tidy(n[k])) out[k] = tidy(n[k]);
  }
  return out;
}

export function nameValid(n: NameDraft, rules?: NameRules) {
  const r = ruleFor(rules, n.nationality);
  const parts = ["first_name", "father_name", "grandfather_name", "last_name", "mother_name"] as const;
  const latin = ["first_name_latin", "father_name_latin", "grandfather_name_latin", "last_name_latin"] as const;
  if (parts.some((k) => tidy(n[k]) && !NAME_PART.test(tidy(n[k])))) return false;
  if (latin.some((k) => tidy(n[k]) && !LATIN_PART.test(tidy(n[k])))) return false;
  if ((r.required ?? []).some((p) => !tidy(n[`${p}_name` as keyof NameDraft]))) return false;
  return !r.latin_required || (!!tidy(n.first_name_latin) && !!tidy(n.last_name_latin));
}

export function NameFields({ value, onChange, rules, disabled }: {
  value: NameDraft; onChange: (n: NameDraft) => void; rules?: NameRules; disabled?: boolean;
}) {
  const { t, locale } = useI18n();
  const r = ruleFor(rules, value.nationality);
  const need = (p: string) => (r.required ?? []).includes(p);
  const set = (patch: Partial<NameDraft>) => onChange({ ...value, ...patch });
  const countries = useMemo(() => {
    const names = new Intl.DisplayNames([locale], { type: "region" });
    const rest = COUNTRIES.filter((c) => c !== "SY").map((c) => ({ code: c, name: names.of(c) ?? c }))
      .sort((a, b) => a.name.localeCompare(b.name, locale));
    return [{ code: "SY", name: names.of("SY") ?? "SY" }, ...rest];
  }, [locale]);
  const part = (key: keyof NameDraft, label: string, required: boolean, latin = false) => {
    const v = value[key];
    const bad = tidy(v) !== "" && !(latin ? LATIN_PART : NAME_PART).test(tidy(v));
    return (
      <Field label={required ? label : `${label} (${t("common.optional")})`}>
        <input className={latin ? "input ltr" : "input"} dir={latin ? "ltr" : undefined} lang={latin ? "en" : undefined} value={v}
               required={required} maxLength={60} autoComplete="off" aria-invalid={bad} disabled={disabled}
               onChange={(e) => set({ [key]: e.target.value } as Partial<NameDraft>)} />
      </Field>
    );
  };
  return (
    <div className="stack">
      <Field label={t("checkout.nationality")}>
        <select className="input" value={value.nationality} disabled={disabled} onChange={(e) => set({ nationality: e.target.value })}>
          {countries.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
        </select>
      </Field>
      <p className="small muted">{value.nationality === "SY" ? t("names.syrianHint") : t("names.foreignHint")}</p>
      <div className="grid cols-4">
        {part("first_name", t("checkout.firstName"), true)}
        {part("father_name", t("checkout.fatherName"), need("father"))}
        {part("grandfather_name", t("checkout.grandfatherName"), need("grandfather"))}
        {part("last_name", t("checkout.lastName"), need("last"))}
      </div>
      <div className="grid cols-4">
        {part("mother_name", t("names.motherName"), false)}
      </div>
      <fieldset className="stack tight" style={{ border: 0, padding: 0 }}>
        <legend className="small muted">{r.latin_required ? t("names.latinRequired") : t("names.latinOptional")}</legend>
        <div className="grid cols-4">
          {part("first_name_latin", t("names.firstLatin"), !!r.latin_required, true)}
          {part("father_name_latin", t("names.fatherLatin"), false, true)}
          {part("grandfather_name_latin", t("names.grandfatherLatin"), false, true)}
          {part("last_name_latin", t("names.lastLatin"), !!r.latin_required, true)}
        </div>
      </fieldset>
    </div>
  );
}
