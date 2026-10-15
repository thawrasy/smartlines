import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, useLoad, useToast } from "../../components/ui";
import { FieldSurveys } from "./FieldSurveys";
import { AreaMap } from "./AreaMap";
import { NameCorrections } from "./NameCorrections";

// The administrative geography (owner's request, October 2026; migration 1124): the governorates, districts,
// sub-districts, communities and city neighbourhoods of the United Nations' P-code workbook, loaded by the platform, and
// the communities opened for routes as cities of the network; the areas' boundaries from the same publisher and the
// places surveyed in the field, reviewed by a second person (1125).

interface Gov { pcode: string; name_en: string; name_ar: string; districts: number; sub_districts: number; communities: number; neighbourhoods: number; served: number }
interface Load { uid: string; publisher: string; content: string; file_name: string | null; valid_on: string | null; imported_at: string; imported_by: string | null; counts: Record<string, number> }
interface City { code: string; name: string; is_active: boolean; pcode: string | null; name_ar: string | null; stations: number }
interface Summary { governorates: Gov[]; loads: Load[]; cities: City[]; proposed: number }
interface Area { pcode: string; name_en: string; name_ar: string; level: number; areas: number; communities: number | null }
interface Place { pcode: string; name_en: string; name_ar: string; lat: number; lng: number; city_code: string | null; neighbourhoods: number }
interface Found { pcode: string; kind: string; name_en: string; name_ar: string; lat: number; lng: number; served: string | null;
  published_en: string | null; published_ar: string | null;
  city: { name_en: string; name_ar: string } | null; sub_district: { name_en: string; name_ar: string }; district: { name_en: string; name_ar: string };
  governorate: { name_en: string; name_ar: string } }

export function AdminGeography() {
  const { t, num, date, locale } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Summary>("/api/admin/geo", undefined, { signal }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [path, setPath] = useState<{ pcode: string; label: string }[]>([]);
  const [q, setQ] = useState("");
  const [found, setFound] = useState<Found[] | null>(null);
  const [serving, setServing] = useState<{ pcode: string; name: string } | null>(null);
  const [code, setCode] = useState("");
  const [asMap, setAsMap] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const shapes = useRef<HTMLInputElement>(null);
  const name = (x: { name_en: string; name_ar: string }) => (locale === "ar" ? x.name_ar : x.name_en);
  const parent = path.length ? path[path.length - 1].pcode : "SY";
  const level = useLoad((signal) => api.get<{ areas?: Area[]; places?: Place[] }>("/api/geo/areas", { parent }, { signal }), [parent]);

  const upload = async () => {
    const f = file.current?.files?.[0];
    if (!f) return;
    setBusy(true); setError(null);
    try {
      const form = new FormData();
      form.append("file", f);
      const out = await api.upload<{ already_loaded: boolean; counts: Record<string, number> }>("/api/admin/geo/import", form);
      toast(out.already_loaded ? t("geo.already") : t("geo.loaded", { n: out.counts.communities ?? 0 }));
      state.reload(); level.reload();
    } catch (e) { setError(e); } finally { setBusy(false); if (file.current) file.current.value = ""; }
  };
  const uploadBoundaries = async () => {
    const f = shapes.current?.files?.[0];
    if (!f) return;
    setBusy(true); setError(null);
    try {
      const form = new FormData();
      form.append("file", f);
      const out = await api.upload<{ already_loaded: boolean; counts: Record<string, number> }>("/api/admin/geo/boundaries", form);
      toast(out.already_loaded ? t("geo.already") : t("geo.shapesLoaded", { n: out.counts.updated ?? 0, out: out.counts.places_outside ?? 0 }));
      state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); if (shapes.current) shapes.current.value = ""; }
  };
  const search = async () => {
    setError(null);
    try { setFound((await api.get<{ places: Found[] }>("/api/geo/places", { q })).places); } catch (e) { setError(e); }
  };
  const serve = async () => {
    if (!serving) return;
    setError(null);
    try {
      const out = await api.post<{ city_code: string }>(`/api/admin/geo/places/${serving.pcode}/serve`, { code: code || undefined });
      toast(t("geo.served", { code: out.city_code })); setServing(null); state.reload(); level.reload(); if (found) void search();
    } catch (e) { setError(e); }
  };

  return (
    <div className="stack">
      <PageHead title={t("geo.title")} sub={t("geo.sub")} />
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => {
        const total = (k: keyof Gov) => d.governorates.reduce((s, g) => s + Number(g[k]), 0);
        return (
          <>
            <div className="grid cols-4">
              <Stat icon="map" label={t("geo.governorates")} value={num(d.governorates.length)} />
              <Stat icon="location_on" label={t("geo.subDistricts")} value={num(total("sub_districts"))} tone="blue" />
              <Stat icon="storefront" label={t("geo.communities")} value={num(total("communities"))} tone="wheat" />
              <Stat icon="directions_bus" label={t("geo.servedCities")} value={num(d.cities.filter((c) => c.pcode).length)} />
            </div>
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("geo.load")}</h3>
              <p className="small muted" style={{ margin: 0 }}>{t("geo.loadHint")}</p>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <input ref={file} type="file" accept=".xlsx" aria-label={t("geo.file")} />
                <button className="btn" disabled={busy} onClick={upload}><Icon name="upload_file" />{t("geo.loadBtn")}</button>
              </div>
              <p className="small muted" style={{ margin: 0 }}>{t("geo.shapesHint")}</p>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <input ref={shapes} type="file" accept=".geojson,.json" aria-label={t("geo.shapesFile")} />
                <button className="btn outlined" disabled={busy} onClick={uploadBoundaries}><Icon name="upload_file" />{t("geo.shapesBtn")}</button>
              </div>
              {d.loads.length > 0 && (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("geo.loadedAt")}</th><th>{t("geo.file")}</th><th>{t("geo.validOn")}</th><th className="num">{t("geo.communities")}</th><th className="num">{t("geo.changes")}</th></tr></thead>
                  <tbody>{d.loads.map((l) => (
                    <tr key={l.uid}><td>{date(l.imported_at)}<div className="small muted">{l.imported_by}</div></td><td className="small">{l.file_name ?? l.publisher}<div className="muted">{t(`geo.content.${l.content}`)}</div></td>
                      <td>{l.valid_on ? date(`${l.valid_on}T12:00:00Z`) : "—"}</td><td className="num">{l.content === "BOUNDARIES" ? "—" : num(l.counts.communities ?? 0)}</td>
                      <td className="num small">{l.content === "BOUNDARIES" ? t("geo.shapesLine", { n: l.counts.updated ?? 0, out: l.counts.places_outside ?? 0 })
                        : t("geo.changeLine", { a: l.counts.added ?? 0, u: l.counts.updated ?? 0, r: l.counts.retired ?? 0 })}</td></tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
            {d.governorates.length === 0 ? <div className="card"><Empty icon="map" title={t("geo.empty")} hint={t("geo.emptyHint")} /></div> : (
              <>
                <div className="card stack">
                  <div className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                    <Field label={t("geo.search")}><input className="input" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && q.trim().length >= 2 && search()} /></Field>
                    <button className="btn outlined" disabled={q.trim().length < 2} onClick={search}><Icon name="search" />{t("geo.find")}</button>
                  </div>
                  {found && (found.length === 0 ? <p className="muted small">{t("geo.noneFound")}</p> : (
                    <div className="table-wrap" tabIndex={0}><table className="table">
                      <thead><tr><th>{t("geo.place")}</th><th>{t("geo.where")}</th><th>{t("geo.code")}</th><th /></tr></thead>
                      <tbody>{found.map((p) => (
                        <tr key={p.pcode}><td><strong>{name(p)}</strong>{(locale === "ar" ? p.published_ar : p.published_en) && <div className="small muted">{t("geo.asPublished", { name: (locale === "ar" ? p.published_ar : p.published_en) ?? "" })}</div>}{p.kind === "NEIGHBOURHOOD" && p.city && <div className="small muted">{t("geo.neighbourhoodOf", { city: name(p.city) })}</div>}</td>
                          <td className="small">{name(p.sub_district)} · {name(p.district)} · {name(p.governorate)}</td>
                          <td className="mono small">{p.pcode}<div className="muted">{p.lat}, {p.lng}</div></td>
                          <td>{p.served ? <span className="chip green">{p.served}</span> : p.kind === "COMMUNITY"
                            && <button className="btn text small" onClick={() => { setServing({ pcode: p.pcode, name: name(p) }); setCode(""); }}>{t("geo.serve")}</button>}</td></tr>
                      ))}</tbody>
                    </table></div>
                  ))}
                </div>
                <div className="card stack">
                  <nav className="row small" aria-label={t("geo.browse")} style={{ gap: 6, flexWrap: "wrap" }}>
                    <button className="btn text small" onClick={() => setPath([])}>{t("geo.country")}</button>
                    {path.map((p, i) => <span key={p.pcode} className="row" style={{ gap: 6 }}>›<button className="btn text small" onClick={() => setPath(path.slice(0, i + 1))}>{p.label}</button></span>)}
                  </nav>
                  <div className="segmented" role="tablist" aria-label={t("geo.browse")} style={{ alignSelf: "flex-start" }}>
                    <button role="tab" aria-selected={!asMap} className={!asMap ? "on" : ""} onClick={() => setAsMap(false)}>{t("geo.asList")}</button>
                    <button role="tab" aria-selected={asMap} className={asMap ? "on" : ""} onClick={() => setAsMap(true)}>{t("geo.asMap")}</button>
                  </div>
                  {asMap ? <AreaMap pcode={parent} onOpen={(pcode, label) => setPath([...path, { pcode, label }])} /> : (
                  <Loaded state={level}>{(l) => l.areas ? (
                    <div className="table-wrap" tabIndex={0}><table className="table">
                      <thead><tr><th>{t(`geo.levelName.${l.areas[0]?.level ?? 1}`)}</th><th>{t("geo.code")}</th><th className="num">{t("geo.inside")}</th></tr></thead>
                      <tbody>{l.areas.map((a) => (
                        <tr key={a.pcode}><td><button className="btn text" onClick={() => setPath([...path, { pcode: a.pcode, label: name(a) }])}>{name(a)}</button></td>
                          <td className="mono small">{a.pcode}</td><td className="num">{num(a.level === 3 ? a.communities ?? 0 : a.areas)}</td></tr>
                      ))}</tbody>
                    </table></div>
                  ) : (
                    <div className="table-wrap" tabIndex={0}><table className="table">
                      <thead><tr><th>{t("geo.levelName.4")}</th><th>{t("geo.code")}</th><th>{t("geo.position")}</th><th className="num">{t("geo.neighbourhoods")}</th><th /></tr></thead>
                      <tbody>{(l.places ?? []).map((p) => (
                        <tr key={p.pcode}><td>{name(p)}</td><td className="mono small">{p.pcode}</td><td className="mono small">{p.lat}, {p.lng}</td>
                          <td className="num">{p.neighbourhoods || ""}</td>
                          <td>{p.city_code ? <span className="chip green">{p.city_code}</span>
                            : <button className="btn text small" onClick={() => { setServing({ pcode: p.pcode, name: name(p) }); setCode(""); }}>{t("geo.serve")}</button>}</td></tr>
                      ))}</tbody>
                    </table></div>
                  )}</Loaded>)}
                </div>
                <FieldSurveys waiting={d.proposed} onChange={() => { state.reload(); level.reload(); }} />
                <NameCorrections onChange={() => { level.reload(); if (found) void search(); }} />
              </>
            )}
          </>
        );
      }}</Loaded>
      {serving && (
        <Modal title={t("geo.serveTitle", { name: serving.name })} onClose={() => setServing(null)}
               actions={<button className="btn filled" disabled={!/^[A-Za-z]{3}$/.test(code)} onClick={serve}>{t("geo.serve")}</button>}>
          <div className="stack">
            <p className="small muted" style={{ margin: 0 }}>{t("geo.serveHint")}</p>
            <Field label={t("geo.cityCode")}><input className="input mono ltr" maxLength={3} value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
