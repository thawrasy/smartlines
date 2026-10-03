import { useMemo } from "react";
import { useI18n } from "../../i18n";
import { Field, Icon } from "../../components/ui";

// Names exactly as on the identity document. Syrian citizens: the four parts of the national ID.
// Other nationalities: given and family names as in the passport or ID; father's and grandfather's names
// only when the document carries them (many countries use two names). The API and the database apply
// the same rule.
export interface PassengerDraft {
  nationality: string; first_name: string; father_name: string; grandfather_name: string; last_name: string;
  more_names: boolean; id_type: string; id_last4: string;
}

export const blankPassenger = (): PassengerDraft => ({
  nationality: "SY", first_name: "", father_name: "", grandfather_name: "", last_name: "", more_names: false,
  id_type: "NATIONAL_ID", id_last4: "",
});

// Mirrors the API rule: letters in any script, single spaces, hyphens, apostrophes or dots between them
const NAME_PART = /^\p{L}+(?:[ '\-.]\p{L}+)*\.?$/u;
const tidy = (s: string) => s.trim().replace(/\s+/g, " ");
const validPart = (s: string) => NAME_PART.test(tidy(s)) && tidy(s).length <= 60;

export function namesFor(p: PassengerDraft) {
  const syrian = p.nationality === "SY";
  const middle = syrian || p.more_names;
  return {
    nationality: p.nationality,
    first_name: tidy(p.first_name),
    father_name: middle && tidy(p.father_name) ? tidy(p.father_name) : null,
    grandfather_name: middle && tidy(p.grandfather_name) ? tidy(p.grandfather_name) : null,
    last_name: tidy(p.last_name),
  };
}

export function passengerValid(p: PassengerDraft) {
  const n = namesFor(p);
  const optionalOk = (v: string | null) => v === null || validPart(v);
  if (!validPart(n.first_name) || !validPart(n.last_name) || !optionalOk(n.father_name) || !optionalOk(n.grandfather_name)) return false;
  if (p.nationality === "SY" && (!n.father_name || !n.grandfather_name)) return false;
  return !p.id_last4 || /^[0-9A-Za-z]{3,4}$/.test(p.id_last4);
}

export function PassengerFields({ value, onChange, countries }: { value: PassengerDraft; onChange: (p: PassengerDraft) => void; countries: string[] }) {
  const { t, locale } = useI18n();
  const syrian = value.nationality === "SY";
  const set = (patch: Partial<PassengerDraft>) => onChange({ ...value, ...patch });

  // Country names come from the browser's locale data, so no country list is translated by hand
  const options = useMemo(() => {
    const names = new Intl.DisplayNames([locale], { type: "region" });
    const rest = countries.filter((c) => c !== "SY").map((c) => ({ code: c, name: names.of(c) ?? c }))
      .sort((a, b) => a.name.localeCompare(b.name, locale));
    return [{ code: "SY", name: names.of("SY") ?? "SY" }, ...rest];
  }, [countries, locale]);

  const nameInput = (key: "first_name" | "father_name" | "grandfather_name" | "last_name", label: string, required: boolean) => {
    const v = value[key];
    const bad = v.trim() !== "" && !validPart(v);
    return (
      <Field label={required ? label : `${label} (${t("common.optional")})`}>
        <input className="input" value={v} required={required} maxLength={60} autoComplete="off" aria-invalid={bad}
               style={bad ? { borderColor: "var(--error)" } : undefined} onChange={(e) => set({ [key]: e.target.value } as Partial<PassengerDraft>)} />
      </Field>
    );
  };
  const preview = Object.values(namesFor(value)).slice(1).filter(Boolean).join(" ");

  return (
    <div className="stack">
      <div className="grid cols-3">
        <Field label={t("checkout.nationality")}>
          <select className="input" value={value.nationality}
                  onChange={(e) => set({ nationality: e.target.value, id_type: e.target.value === "SY" ? "NATIONAL_ID" : "PASSPORT", more_names: false })}>
            {options.map((o) => <option key={o.code} value={o.code}>{o.name}</option>)}
          </select>
        </Field>
        <Field label={t("checkout.idType")}>
          <select className="input" value={value.id_type} onChange={(e) => set({ id_type: e.target.value })}>
            {(syrian ? ["NATIONAL_ID", "PASSPORT"] : ["PASSPORT", "RESIDENCE", "NATIONAL_ID", "OTHER"]).map((k) =>
              <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
          </select>
        </Field>
        <Field label={`${t("checkout.idLast4")} (${t("common.optional")})`}>
          <input className="input ltr" inputMode="numeric" maxLength={4} value={value.id_last4} onChange={(e) => set({ id_last4: e.target.value.trim() })} />
        </Field>
      </div>

      <div className="alert info small"><Icon name="badge" size={20} /><span>{syrian ? t("checkout.syrianHint") : t("checkout.foreignHint")}</span></div>

      {syrian ? (
        <div className="grid cols-4">
          {nameInput("first_name", t("checkout.firstName"), true)}
          {nameInput("father_name", t("checkout.fatherName"), true)}
          {nameInput("grandfather_name", t("checkout.grandfatherName"), true)}
          {nameInput("last_name", t("checkout.lastName"), true)}
        </div>
      ) : (
        <div className="stack tight">
          <div className={`grid ${value.more_names ? "cols-4" : "cols-2"}`}>
            {nameInput("first_name", t("checkout.givenNames"), true)}
            {value.more_names && nameInput("father_name", t("checkout.fatherName"), false)}
            {value.more_names && nameInput("grandfather_name", t("checkout.grandfatherName"), false)}
            {nameInput("last_name", t("checkout.familyName"), true)}
          </div>
          <label className="check small">
            <input type="checkbox" checked={value.more_names} onChange={(e) => set({ more_names: e.target.checked })} />{t("checkout.moreNames")}
          </label>
        </div>
      )}

      {preview && <p className="small muted">{t("checkout.namePreview")}: <strong style={{ color: "var(--on-surface)" }}>{preview}</strong></p>}
    </div>
  );
}
