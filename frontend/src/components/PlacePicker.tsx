import { useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Icon } from "./ui";

// Choosing a place of the administrative geography (1124, 1125): by its Arabic or English name or its code, or by a
// position (the places nearest to it). Used where a station is put in its place.

export interface PickedPlace {
  pcode: string; kind: string; name_en: string; name_ar: string; lat: number; lng: number; served: string | null;
  city: { name_en: string; name_ar: string } | null; sub_district: { name_en: string; name_ar: string };
  district: { name_en: string; name_ar: string }; governorate: { name_en: string; name_ar: string }; metres?: number;
}

export function PlacePicker({ value, onPick, label }: { value: PickedPlace | null; onPick: (p: PickedPlace | null) => void; label: string }) {
  const { t, locale, num } = useI18n();
  const [q, setQ] = useState("");
  const [found, setFound] = useState<PickedPlace[] | null>(null);
  const [error, setError] = useState(false);
  const name = (x: { name_en: string; name_ar: string }) => (locale === "ar" ? x.name_ar : x.name_en);
  const search = async () => {
    setError(false);
    const point = /^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(q);
    try {
      if (point) setFound((await api.get<{ places: PickedPlace[] }>("/api/geo/locate", { lat: point[1], lng: point[2] })).places);
      else setFound((await api.get<{ places: PickedPlace[] }>("/api/geo/places", { q: q.trim() })).places);
    } catch { setError(true); }
  };
  if (value) {
    return (
      <div className="field">
        <span>{label}</span>
        <div className="row" style={{ gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          <span className="chip green">{value.pcode}</span>
          <strong>{name(value)}</strong>
          <span className="small muted">{value.city ? `${name(value.city)} · ` : ""}{name(value.sub_district)} · {name(value.governorate)}</span>
          <button type="button" className="btn text small" onClick={() => { onPick(null); setFound(null); }}>{t("geo.change")}</button>
        </div>
      </div>
    );
  }
  return (
    <div className="field">
      <span>{label}</span>
      <div className="row" style={{ gap: 8 }}>
        <input className="input" value={q} aria-label={label} placeholder={t("geo.pickHint")} onChange={(e) => setQ(e.target.value)}
               onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); if (q.trim().length >= 2) void search(); } }} />
        <button type="button" className="btn outlined" disabled={q.trim().length < 2} onClick={search}><Icon name="search" />{t("geo.find")}</button>
      </div>
      {error && <small className="hint">{t("geo.noneFound")}</small>}
      {found && (found.length === 0 ? <small className="hint">{t("geo.noneFound")}</small> : (
        <ul className="stack" style={{ listStyle: "none", padding: 0, margin: "8px 0 0", gap: 4 }}>
          {found.slice(0, 8).map((p) => (
            <li key={p.pcode}>
              <button type="button" className="btn text" style={{ textAlign: "start", height: "auto" }} onClick={() => { onPick(p); setFound(null); }}>
                <span><strong>{name(p)}</strong> <span className="mono small">{p.pcode}</span>
                  <span className="small muted"> · {p.city ? `${name(p.city)} · ` : ""}{name(p.sub_district)} · {name(p.governorate)}
                    {p.metres != null ? ` · ${num(Math.round(p.metres))} ${t("geo.metres")}` : ""}</span></span>
              </button>
            </li>
          ))}
        </ul>
      ))}
    </div>
  );
}
