import { useMemo } from "react";
import { useI18n } from "../../i18n";
import { Field, Icon } from "../../components/ui";
import type { Category, CategoryFare, FamilyMember } from "../../api";

// Names exactly as on the identity document. Syrian citizens: the four parts of the national ID.
// Other nationalities: given and family names as in the passport or ID; father's and grandfather's names
// only when the document carries them (many countries use two names). The API and the database apply
// the same rule.
export interface PassengerDraft {
  nationality: string; first_name: string; father_name: string; grandfather_name: string; last_name: string;
  more_names: boolean; id_type: string; id_last4: string;
  id_no: string; passport_expiry: string;          // international trips only
  birth_date: string;                              // decides adult, child or infant on the travel date (4.19)
  family_member_uid: string;                       // filled from the family register (4.20); the server uses the register
  stored_doc: boolean;                             // the register holds the document number (encrypted): no need to type it
  lap: boolean;                                    // an infant on an adult's lap, without a seat
}

/** Documents a nationality needs on the trip (GET /api/trips/{uid}/documents). */
export interface TravelDocs {
  international: boolean; destination: string | null; transit: string[]; docs: string[]; passport_min_days: number;
  exception: boolean; notes: string[]; departs: string;
}

const addDays = (iso: string, n: number) => { const d = new Date(`${iso}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const minPassportExpiry = (req: TravelDocs) => addDays(req.departs, req.passport_min_days);

export const blankPassenger = (lap = false): PassengerDraft => ({
  nationality: "SY", first_name: "", father_name: "", grandfather_name: "", last_name: "", more_names: false,
  id_type: "NATIONAL_ID", id_last4: "", id_no: "", passport_expiry: "", birth_date: "", family_member_uid: "", stored_doc: false, lap,
});

/** A traveller filled from the family register: names, nationality, date of birth and document type as registered. */
export function fromMember(m: FamilyMember, lap = false): PassengerDraft {
  return {
    nationality: m.nationality, first_name: m.first_name, father_name: m.father_name ?? "", grandfather_name: m.grandfather_name ?? "",
    last_name: m.last_name, more_names: !!(m.father_name || m.grandfather_name) && m.nationality !== "SY",
    id_type: m.id_type ?? (m.nationality === "SY" ? "NATIONAL_ID" : "PASSPORT"), id_last4: m.id_last4 ?? "", id_no: "",
    passport_expiry: m.passport_expiry ?? "", birth_date: m.birth_date, family_member_uid: m.uid, stored_doc: !!m.id_last4, lap,
  };
}

/** Completed years on a day, as the API counts them. */
export function ageOn(birth: string, day: string) {
  const [by, bm, bd] = birth.split("-").map(Number), [y, m, d] = day.split("-").map(Number);
  return y - by - (m < bm || (m === bm && d < bd) ? 1 : 0);
}

/** The category the API will apply, or null when it cannot be known yet (no date of birth). */
export function categoryOf(p: PassengerDraft, bands: CategoryFare[], travel: string): Category | null {
  if (!p.birth_date) return p.lap ? null : "ADULT";
  const age = ageOn(p.birth_date, travel);
  const hit = (["INFANT", "CHILD", "ADULT"] as Category[]).find((c) => {
    const b = bands.find((x) => x.category === c);
    return b && age >= b.min_age && (b.max_age === null || age < b.max_age);
  });
  return hit ?? "ADULT";
}

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

/** The document part of a passenger on an international trip: an accepted type, the full number, a valid passport. */
export function documentValid(p: PassengerDraft, req?: TravelDocs) {
  if (!req?.international) return true;
  if (p.stored_doc && req.docs.includes(p.id_type)) return true;     // the register's document is copied by the server
  if (!req.docs.includes(p.id_type) || !/^[0-9A-Za-z \-/]{4,24}$/.test(p.id_no.trim())) return false;
  return p.id_type !== "PASSPORT" || (!!p.passport_expiry && p.passport_expiry >= minPassportExpiry(req));
}

export function documentFor(p: PassengerDraft, req?: TravelDocs) {
  if (p.stored_doc && !p.id_no.trim()) return { id_type: p.id_type };
  if (!req?.international) return { id_type: p.id_type, id_last4: p.id_last4 || null };
  return { id_type: p.id_type, id_no: p.id_no.trim(), passport_expiry: p.id_type === "PASSPORT" ? p.passport_expiry : null };
}

export function passengerValid(p: PassengerDraft, req?: TravelDocs) {
  if (!documentValid(p, req)) return false;
  if (p.lap && !p.birth_date) return false;
  const n = namesFor(p);
  const optionalOk = (v: string | null) => v === null || validPart(v);
  if (!validPart(n.first_name) || !validPart(n.last_name) || !optionalOk(n.father_name) || !optionalOk(n.grandfather_name)) return false;
  if (p.nationality === "SY" && (!n.father_name || !n.grandfather_name)) return false;
  return !p.id_last4 || /^[0-9A-Za-z]{3,4}$/.test(p.id_last4);
}

export function PassengerFields({ value, onChange, countries, docs, bands, travel }: {
  value: PassengerDraft; onChange: (p: PassengerDraft) => void; countries: string[]; docs?: TravelDocs; bands?: CategoryFare[]; travel?: string;
}) {
  const { t, locale, date, money } = useI18n();
  const intl = !!docs?.international;
  const locked = !!value.family_member_uid;
  const cat = bands && travel ? categoryOf(value, bands, travel) : null;
  const band = cat ? bands?.find((b) => b.category === cat) : undefined;
  const lapNotInfant = value.lap && cat !== null && cat !== "INFANT";
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
        <input className="input" value={v} required={required} maxLength={60} autoComplete="off" aria-invalid={bad} readOnly={locked}
               style={bad ? { borderColor: "var(--error)" } : undefined} onChange={(e) => set({ [key]: e.target.value } as Partial<PassengerDraft>)} />
      </Field>
    );
  };
  const preview = Object.values(namesFor(value)).slice(1).filter(Boolean).join(" ");

  return (
    <div className="stack">
      {locked && <div className="alert ok small"><Icon name="diversity_3" size={20} /><span>{t("family.fromRegister")}</span></div>}
      <div className="grid cols-3">
        <Field label={value.lap ? t("pax.birthDate") : `${t("pax.birthDate")} (${t("pax.birthHint")})`}>
          <input className="input ltr" type="date" value={value.birth_date} max={travel} readOnly={locked} required={value.lap}
                 aria-invalid={lapNotInfant} onChange={(e) => set({ birth_date: e.target.value })} />
        </Field>
        <Field label={t("pax.category")}>
          <div className="row" style={{ minHeight: 40 }}>
            {cat ? <span className={`chip ${cat === "ADULT" ? "outline" : "green"}`}>{t(`pax.cat.${cat}`)}{band ? ` · ${money(band.fare)}` : ""}</span>
                 : <span className="muted small">{t("pax.categoryUnknown")}</span>}
            {value.lap && <span className="chip outline"><Icon name="child_care" size={16} />{t("pax.onLap")}</span>}
          </div>
        </Field>
      </div>
      {lapNotInfant && <div className="alert error small"><Icon name="warning" size={20} /><span>{t("errors.SEAT_REQUIRED")}</span></div>}
      <div className="grid cols-3">
        <Field label={t("checkout.nationality")}>
          <select className="input" value={value.nationality} disabled={locked}
                  onChange={(e) => set({ nationality: e.target.value, id_type: intl || e.target.value !== "SY" ? "PASSPORT" : "NATIONAL_ID", more_names: false })}>
            {options.map((o) => <option key={o.code} value={o.code}>{o.name}</option>)}
          </select>
        </Field>
        <Field label={t("checkout.idType")}>
          <select className="input" value={value.id_type} onChange={(e) => set({ id_type: e.target.value })}>
            {(intl ? docs!.docs : syrian ? ["NATIONAL_ID", "PASSPORT"] : ["PASSPORT", "RESIDENCE", "NATIONAL_ID", "OTHER"]).map((k) =>
              <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
          </select>
        </Field>
        {value.stored_doc && !value.id_no ? (
          <Field label={t("checkout.docNumber")}>
            <input className="input ltr" readOnly value={`•••• ${value.id_last4}`} />
          </Field>
        ) : intl ? (
          <Field label={t("checkout.docNumber")}>
            <input className="input ltr" required maxLength={24} autoComplete="off" value={value.id_no}
                   aria-invalid={value.id_no !== "" && !/^[0-9A-Za-z \-/]{4,24}$/.test(value.id_no.trim())}
                   onChange={(e) => set({ id_no: e.target.value })} />
          </Field>
        ) : (
          <Field label={`${t("checkout.idLast4")} (${t("common.optional")})`}>
            <input className="input ltr" inputMode="numeric" maxLength={4} value={value.id_last4} onChange={(e) => set({ id_last4: e.target.value.trim() })} />
          </Field>
        )}
      </div>
      {intl && value.id_type === "PASSPORT" && (
        <div className="grid cols-3">
          <Field label={t("checkout.passportExpiry")} hint={t("checkout.passportMin", { date: date(`${minPassportExpiry(docs!)}T12:00:00Z`, { day: "numeric", month: "long", year: "numeric" }) })}>
            <input className="input ltr" type="date" required min={minPassportExpiry(docs!)} value={value.passport_expiry}
                   aria-invalid={value.passport_expiry !== "" && value.passport_expiry < minPassportExpiry(docs!)}
                   onChange={(e) => set({ passport_expiry: e.target.value })} />
          </Field>
        </div>
      )}

      {intl && docs!.exception && (
        <div className="alert ok small"><Icon name="verified" size={20} />
          <span>{t("checkout.exceptionHint", { docs: docs!.docs.map((k) => t(`checkout.idTypes.${k}`)).join(t("checkout.or")) })}
            {docs!.notes.length > 0 && <> {docs!.notes.join(" ")}</>}</span>
        </div>
      )}
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
