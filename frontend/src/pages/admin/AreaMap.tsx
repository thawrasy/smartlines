import { useMemo, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Loaded, useLoad } from "../../components/ui";

// The map of an area (1129): its boundary, the areas under it (each opens its own map), its places and the stations
// in it, drawn as plain SVG from the boundaries the platform loaded (1125); no map tiles are fetched from outside. Where
// no boundary is loaded, the areas are placed by the middle of their places. Positions are longitude and latitude,
// with the longitude shrunk by the cosine of the latitude so distances look right.

type Ring = number[][];
interface Geometry { type: "Polygon" | "MultiPolygon"; coordinates: Ring[] | Ring[][] }
interface Child { pcode: string; level: number; name_en: string; name_ar: string; lat: number | null; lng: number | null; boundary: Geometry | null }
interface MapPlace { pcode: string; kind: string; status: string; name_en: string; name_ar: string; lat: number; lng: number; city_code: string | null }
interface MapStation { code: string; name: string; lat: number; lng: number; status: string; station_class: string }
interface AreaMapData {
  area: { pcode: string; level: number; name_en: string | null; name_ar: string | null; boundary: Geometry | null };
  children: Child[]; places: MapPlace[]; stations: MapStation[];
}

const W = 760;
const H = 520;
const PAD = 16;

function polygons(g: Geometry | null): Ring[][] {
  if (!g) return [];
  return g.type === "Polygon" ? [g.coordinates as Ring[]] : (g.coordinates as Ring[][]);
}

export function AreaMap({ pcode, onOpen }: { pcode: string; onOpen: (pcode: string, label: string) => void }) {
  const { locale } = useI18n();
  const state = useLoad((signal) => api.get<AreaMapData>(`/api/admin/geo/areas/${pcode}/map`, undefined, { signal }), [pcode]);
  const [hover, setHover] = useState<string | null>(null);
  const name = (x: { name_en: string | null; name_ar: string | null }) => (locale === "ar" ? x.name_ar : x.name_en) ?? "";
  return (
    <Loaded state={state}>{(d) => <Drawing d={d} name={name} hover={hover} setHover={setHover} onOpen={onOpen} />}</Loaded>
  );
}

function Drawing({ d, name, hover, setHover, onOpen }: {
  d: AreaMapData; name: (x: { name_en: string | null; name_ar: string | null }) => string; hover: string | null;
  setHover: (s: string | null) => void; onOpen: (pcode: string, label: string) => void;
}) {
  const { t } = useI18n();
  const view = useMemo(() => {
    const pts: number[][] = [];
    for (const poly of polygons(d.area.boundary)) for (const ring of poly) pts.push(...ring);
    for (const c of d.children) {
      for (const poly of polygons(c.boundary)) for (const ring of poly) pts.push(...ring);
      if (c.lat != null && c.lng != null) pts.push([Number(c.lng), Number(c.lat)]);
    }
    for (const p of d.places) pts.push([Number(p.lng), Number(p.lat)]);
    for (const s of d.stations) pts.push([Number(s.lng), Number(s.lat)]);
    if (pts.length === 0) return null;
    let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
    for (const [x, y] of pts) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    const k = Math.cos(((y0 + y1) / 2) * Math.PI / 180);
    const spanX = Math.max((x1 - x0) * k, 0.01);
    const spanY = Math.max(y1 - y0, 0.01);
    const scale = Math.min((W - 2 * PAD) / spanX, (H - 2 * PAD) / spanY);
    const ox = (W - spanX * scale) / 2;
    const oy = (H - spanY * scale) / 2;
    const at = (lng: number, lat: number): [number, number] => [ox + (lng - x0) * k * scale, oy + (y1 - lat) * scale];
    const path = (g: Geometry | null) => polygons(g).map((poly) => poly.map((ring) =>
      ring.map(([x, y], i) => { const [px, py] = at(x, y); return `${i ? "L" : "M"}${px.toFixed(1)},${py.toFixed(1)}`; }).join("") + "Z").join("")).join("");
    return { at, path };
  }, [d]);

  if (!view) return <p className="small muted" style={{ margin: 0 }}>{t("geo.mapEmpty")}</p>;
  const label = hover ?? "";
  const drilling = d.area.level < 3;
  return (
    <div className="stack tight">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={t("geo.mapOf", { name: d.area.name_en ? name(d.area) : t("geo.country") })}
           style={{ width: "100%", height: "auto", background: "var(--surface-container)", borderRadius: 12 }}>
        {d.area.boundary && <path d={view.path(d.area.boundary)} fill="var(--primary-soft)" stroke="var(--primary)" strokeWidth={2} fillRule="evenodd" />}
        {d.children.map((c) => c.boundary ? (
          <path key={c.pcode} d={view.path(c.boundary)} fillRule="evenodd" tabIndex={drilling ? 0 : undefined} role={drilling ? "button" : undefined}
                aria-label={name(c)} fill={hover === name(c) ? "var(--primary-soft)" : "transparent"} stroke="var(--primary)" strokeWidth={0.8}
                style={{ cursor: drilling ? "pointer" : "default" }}
                onMouseEnter={() => setHover(name(c))} onMouseLeave={() => setHover(null)} onFocus={() => setHover(name(c))} onBlur={() => setHover(null)}
                onClick={() => drilling && onOpen(c.pcode, name(c))} onKeyDown={(e) => drilling && e.key === "Enter" && onOpen(c.pcode, name(c))}>
            <title>{name(c)}</title>
          </path>
        ) : null)}
        {d.children.filter((c) => !c.boundary && c.lat != null && c.lng != null).map((c) => {
          const [x, y] = view.at(Number(c.lng), Number(c.lat));
          return (
            <g key={c.pcode} tabIndex={drilling ? 0 : undefined} role={drilling ? "button" : undefined} aria-label={name(c)} style={{ cursor: drilling ? "pointer" : "default" }}
               onClick={() => drilling && onOpen(c.pcode, name(c))} onKeyDown={(e) => drilling && e.key === "Enter" && onOpen(c.pcode, name(c))}>
              <circle cx={x} cy={y} r={10} fill="var(--primary-soft)" stroke="var(--primary)" />
              <text x={x} y={y - 14} textAnchor="middle" fontSize={12} fill="currentColor">{name(c)}</text>
            </g>
          );
        })}
        {d.places.map((p) => {
          const [x, y] = view.at(Number(p.lng), Number(p.lat));
          const city = !!p.city_code;
          return (
            <circle key={p.pcode} cx={x} cy={y} r={city ? 5 : 2.5} fill={p.status === "PROPOSED" ? "var(--brand-gold)" : city ? "var(--success)" : "var(--on-surface-variant)"}
                    stroke="var(--surface)" strokeWidth={city ? 1.5 : 0.5} onMouseEnter={() => setHover(`${name(p)}${p.city_code ? ` (${p.city_code})` : ""}`)} onMouseLeave={() => setHover(null)}>
              <title>{`${name(p)} · ${p.pcode}${p.city_code ? ` · ${p.city_code}` : ""}`}</title>
            </circle>
          );
        })}
        {d.stations.map((s) => {
          const [x, y] = view.at(Number(s.lng), Number(s.lat));
          return (
            <rect key={s.code} x={x - 5} y={y - 5} width={10} height={10} rx={2} fill="var(--error)" stroke="var(--surface)" strokeWidth={1.5}
                  onMouseEnter={() => setHover(`${s.code} · ${s.name}`)} onMouseLeave={() => setHover(null)}>
              <title>{`${s.code} · ${s.name}`}</title>
            </rect>
          );
        })}
      </svg>
      <div className="row small" style={{ gap: 16, flexWrap: "wrap", alignItems: "center" }}>
        <span className="muted" aria-live="polite" style={{ minHeight: "1.2em", flex: 1 }}>{label || (drilling ? t("geo.mapHint") : "")}</span>
        <span className="row" style={{ gap: 4 }}><svg width={12} height={12} aria-hidden><circle cx={6} cy={6} r={5} fill="var(--success)" /></svg>{t("geo.mapCity")}</span>
        <span className="row" style={{ gap: 4 }}><svg width={12} height={12} aria-hidden><circle cx={6} cy={6} r={3} fill="var(--on-surface-variant)" /></svg>{t("geo.mapPlace")}</span>
        <span className="row" style={{ gap: 4 }}><svg width={12} height={12} aria-hidden><circle cx={6} cy={6} r={4} fill="var(--brand-gold)" /></svg>{t("geo.mapProposed")}</span>
        <span className="row" style={{ gap: 4 }}><svg width={12} height={12} aria-hidden><rect x={1} y={1} width={10} height={10} rx={2} fill="var(--error)" /></svg>{t("geo.mapStation")}</span>
      </div>
      {!d.area.boundary && d.children.every((c) => !c.boundary) && <p className="small muted" style={{ margin: 0 }}>{t("geo.mapNoShapes")}</p>}
    </div>
  );
}
