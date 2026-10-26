import { api } from "../api";
import { useI18n } from "../i18n";
import { useLoad } from "./ui";

// The colour and axle lists the platform keeps (1174): a colour or an axle arrangement is picked, never typed, so one
// colour is not entered under several spellings and an axle count is always one the standards know.

export interface Colour { code: string; name_en: string; name_ar: string; hex: string | null }
export interface Axle { code: string; kind: "VEHICLE" | "TRAILER"; axles: number; driven_axles: number | null; name_en: string; name_ar: string }
export interface RefLists { colours: Colour[]; axle_configs: Axle[]; trailer_axles: Axle[] }

export function useRefLists() {
  return useLoad((signal) => api.get<RefLists>("/api/fleet/lists", undefined, { signal }));
}

export function Swatch({ hex, size = 14 }: { hex: string | null | undefined; size?: number }) {
  // two-tone (no single swatch) shows a split dot
  const fill = hex ?? "linear-gradient(135deg, var(--on-surface) 50%, var(--surface) 50%)";
  return <span aria-hidden="true" style={{ display: "inline-block", width: size, height: size, borderRadius: "50%", background: fill,
    border: "1px solid var(--outline)", verticalAlign: "middle", flex: "none" }} />;
}

export function ColourName({ code, colours }: { code: string | null | undefined; colours: Colour[] }) {
  const { locale } = useI18n();
  if (!code) return <>—</>;
  const c = colours.find((x) => x.code === code);
  return <span className="row" style={{ gap: 6, display: "inline-flex", alignItems: "center" }}>
    <Swatch hex={c?.hex} />{c ? (locale === "ar" ? c.name_ar : c.name_en) : code}</span>;
}

/** Colours as swatches to pick from; one choice, or none. */
export function ColourPicker({ value, onChange, colours, label }: { value: string; onChange: (code: string) => void; colours: Colour[]; label: string }) {
  const { t, locale } = useI18n();
  return (
    <div role="radiogroup" aria-label={label} className="row" style={{ gap: 6, flexWrap: "wrap" }}>
      <button type="button" role="radio" aria-checked={value === ""} className={`chip chip-select${value === "" ? " on" : ""}`}
              onClick={() => onChange("")}>{t("lists.noColour")}</button>
      {colours.map((c) => (
        <button key={c.code} type="button" role="radio" aria-checked={value === c.code} className={`chip chip-select${value === c.code ? " on" : ""}`}
                style={{ gap: 6 }} onClick={() => onChange(c.code)}>
          <Swatch hex={c.hex} />{locale === "ar" ? c.name_ar : c.name_en}</button>))}
    </div>
  );
}

/** An axle arrangement from the list: the code (6x4, T3) with its name. */
export function AxleSelect({ value, onChange, axles, label }: { value: string; onChange: (code: string) => void; axles: Axle[]; label: string }) {
  const { t, locale } = useI18n();
  return (
    <select className="input" aria-label={label} value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">{t("finance.choose")}</option>
      {axles.map((a) => <option key={a.code} value={a.code}>{a.kind === "VEHICLE" ? `${a.code} · ` : ""}{locale === "ar" ? a.name_ar : a.name_en}</option>)}
    </select>
  );
}
