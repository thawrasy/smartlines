import { useEffect, useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Field } from "./ui";

// Pickers that go down one level at a time (owner's request N37, migration 1160): the governorate, then its cities of
// the network (main cities first), then the city's areas and neighbourhoods, then its stations. Each level lists what
// the one above allows (GET /api/geo/cascade). depth says how far down a screen goes.

export interface GeoChoice { governorate: string; city: string; area: string; station: string }
interface Named { name_en: string; name_ar: string }
interface Cascade {
  governorates: (Named & { pcode: string; cities: number })[];
  cities: (Named & { code: string; city_class: "MAIN" | "SECONDARY"; governorate: string | null })[];
  areas: (Named & { pcode: string; city_area_code: string | null; city_area_en: string | null; city_area_ar: string | null })[];
  stations: { uid: string; code: string; name: string; place: string | null }[];
}
export const NO_GEO: GeoChoice = { governorate: "", city: "", area: "", station: "" };

export function GeoCascade({ value, onChange, depth = "station", required }: {
  value: GeoChoice; onChange: (v: GeoChoice) => void; depth?: "city" | "area" | "station"; required?: boolean;
}) {
  const { t, locale, city: cityName } = useI18n();
  const [data, setData] = useState<Cascade | null>(null);
  useEffect(() => {
    const q = new URLSearchParams();
    if (value.governorate) q.set("governorate", value.governorate);
    if (value.city) q.set("city", value.city);
    if (value.area) q.set("area", value.area);
    let live = true;
    api.get<Cascade>(`/api/geo/cascade?${q}`).then((d) => { if (live) setData(d); }).catch(() => undefined);
    return () => { live = false; };
  }, [value.governorate, value.city, value.area]);
  const name = (x: Named) => (locale === "ar" ? x.name_ar : x.name_en);
  const main = data?.cities.filter((c) => c.city_class === "MAIN") ?? [];
  const other = data?.cities.filter((c) => c.city_class !== "MAIN") ?? [];
  const cityLabel = (c: Cascade["cities"][number]) => cityName(c.code) || name(c);
  return (
    <div className="grid cols-2">
      <Field label={t("geoc.governorate")}>
        <select className="input" value={value.governorate} onChange={(e) => onChange({ ...NO_GEO, governorate: e.target.value })}>
          <option value="">{t("geoc.allGovernorates")}</option>
          {data?.governorates.map((g) => <option key={g.pcode} value={g.pcode}>{name(g)}</option>)}
        </select>
      </Field>
      <Field label={t("geoc.city")}>
        <select className="input" value={value.city} required={required}
                onChange={(e) => onChange({ ...value, city: e.target.value, area: "", station: "" })}>
          <option value="">{t("geoc.chooseCity")}</option>
          {main.length > 0 && <optgroup label={t("geoc.main")}>{main.map((c) => <option key={c.code} value={c.code}>{cityLabel(c)}</option>)}</optgroup>}
          {other.length > 0 && <optgroup label={t("geoc.secondary")}>{other.map((c) => <option key={c.code} value={c.code}>{cityLabel(c)}</option>)}</optgroup>}
        </select>
      </Field>
      {depth !== "city" && (
        <Field label={t("geoc.area")}>
          <select className="input" value={value.area} disabled={!value.city || !data?.areas.length}
                  onChange={(e) => onChange({ ...value, area: e.target.value, station: "" })}>
            <option value="">{value.city && !data?.areas.length ? t("geoc.noAreas") : t("geoc.anyArea")}</option>
            {data?.areas.map((a) => (
              <option key={a.pcode} value={a.pcode}>
                {name(a)}{a.city_area_code ? ` (${locale === "ar" ? a.city_area_ar ?? "" : a.city_area_en ?? ""})` : ""}</option>
            ))}
          </select>
        </Field>
      )}
      {depth === "station" && (
        <Field label={t("geoc.station")}>
          <select className="input" value={value.station} disabled={!value.city} required={required}
                  onChange={(e) => onChange({ ...value, station: e.target.value })}>
            <option value="">{t("geoc.chooseStation")}</option>
            {data?.stations.map((s) => <option key={s.uid} value={s.uid}>{s.name} ({s.code})</option>)}
          </select>
        </Field>
      )}
    </div>
  );
}
