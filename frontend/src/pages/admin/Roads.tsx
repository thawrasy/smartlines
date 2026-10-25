import { useMemo, useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, useLoad, useToast } from "../../components/ui";

// The roads guide (owner's request N38, migration 1162): the numbered roads (M5, P01, S101) and the places along them,
// loaded by the platform from the owner's workbook and checked against the United Nations geography. Junctions are
// worked out; each road carries how far it is verified (the owner's file, confirmed by carriers, approved by the
// authority), raised on a document by one person and approved by another. Carriers propose corrections; the platform
// reviews them. The network is drawn as plain SVG, no map tiles fetched from outside.

type Cls = "INTERNATIONAL" | "MAIN" | "SECONDARY" | "URBAN";
interface RoadRow { code: string; road_class: Cls; name_ar: string; name_en: string; regional_number: string | null; length_km: number | null;
  verification_status: string; points: number; governorates: string[] | null; start_en: string; start_ar: string; end_en: string; end_ar: string }
interface Point { seq: number; pcode: string; name_en: string; name_ar: string; lat: number; lng: number; km_from_previous: number; km_cumulative: number;
  is_border: boolean; note: string | null; sub_district_en: string; sub_district_ar: string; crossing_roads: string[] | null }
interface RoadDetail extends Omit<RoadRow, "points" | "governorates" | "start_en" | "start_ar" | "end_en" | "end_ar"> {
  note: string | null; source_file: string | null; source_loaded_at: string | null; points: Point[] }
interface MapData { roads: { code: string; road_class: Cls; line: [number, number][] }[]; junctions: { pcode: string; name_en: string; name_ar: string; roads: number; lat: number; lng: number }[] }
interface Correction { uid: string; road: string; seq: number | null; kind: string; place: string | null; place_en: string | null; place_ar: string | null;
  km: number | null; remark: string; status: string; proposed_at: string; proposed_by: string; company: string | null; reviewed_by: string | null;
  review_note: string | null; mine: boolean; current_place: string | null; current_km: number | null }
interface Verification { uid: string; road: string; from_status: string; to_status: string; document_ref: string; note: string | null; status: string;
  requested_at: string; requested_by: string; decided_by: string | null; decision_note: string | null; mine: boolean }

const COLOURS: Record<Cls, string> = { INTERNATIONAL: "var(--brand, #0b6e4f)", MAIN: "#c27c0e", SECONDARY: "#6b7280", URBAN: "#2563eb" };

export function AdminRoads() {
  return <RoadsGuide portal="PLATFORM" />;
}

export function CarrierRoads() {
  return <RoadsGuide portal="OPERATOR" />;
}

function RoadsGuide({ portal }: { portal: "PLATFORM" | "OPERATOR" }) {
  const { t, num } = useI18n();
  const toast = useToast();
  const platform = portal === "PLATFORM";
  const [cls, setCls] = useState("");
  const list = useLoad((signal) => api.get<{ roads: RoadRow[] }>(`/api/geo/roads${cls ? `?road_class=${cls}` : ""}`, undefined, { signal }), [cls]);
  const map = useLoad((signal) => api.get<MapData>("/api/geo/roads/map", undefined, { signal }));
  const [open, setOpen] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [report, setReport] = useState<{ counts: Record<string, unknown>; warnings: string[] } | null>(null);
  const [tick, setTick] = useState(0);
  const upload = async () => {
    const f = file.current?.files?.[0];
    if (!f) return;
    setBusy(true); setError(null); setReport(null);
    try {
      const fd = new FormData(); fd.append("file", f);
      const out = await api.upload<{ already_loaded: boolean; counts: Record<string, unknown>; warnings?: string[] }>("/api/admin/roads/import", fd);
      if (out.already_loaded) toast(t("roads.already")); else { setReport({ counts: out.counts, warnings: out.warnings ?? [] }); toast(t("roads.loaded")); }
      list.reload(); map.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("roads.title")} sub={t("roads.sub")} />
      <ErrorBox error={error} />
      <Loaded state={list}>{({ roads }) => (
        <>
          <div className="grid cols-4">
            <Stat icon="route" label={t("roads.roads")} value={num(roads.length)} />
            <Stat icon="location_on" label={t("roads.points")} value={num(roads.reduce((s, r) => s + Number(r.points), 0))} tone="blue" />
            <Stat icon="hub" label={t("roads.junctions")} value={num(map.data?.junctions.length ?? 0)} tone="wheat" />
            <Stat icon="verified" label={t("roads.verified")} value={num(roads.filter((r) => r.verification_status !== "OWNER_FILE").length)} />
          </div>
          {platform && (
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("roads.load")}</h3>
              <p className="small muted" style={{ margin: 0 }}>{t("roads.loadHint")}</p>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <input ref={file} type="file" accept=".xlsx" aria-label={t("roads.file")} />
                <button className="btn" disabled={busy} onClick={upload}><Icon name="upload_file" />{t("roads.loadBtn")}</button>
              </div>
              {report && (
                <div className="small">
                  <div>{t("roads.report", { roads: String(report.counts.roads), points: String(report.counts.points), junctions: String(report.counts.junctions) })}</div>
                  {report.warnings.length > 0 && (
                    <details><summary>{t("roads.warnings", { n: report.warnings.length })}</summary>
                      <ul style={{ margin: 0 }}>{report.warnings.map((w) => <li key={w} className="ltr">{w}</li>)}</ul></details>
                  )}
                </div>
              )}
            </div>
          )}
          {roads.length === 0 ? <Empty icon="route" title={t("roads.none")} hint={platform ? t("roads.noneHint") : undefined} /> : (
            <>
              {map.data && <NetworkMap data={map.data} selected={open} onPick={setOpen} />}
              <div className="card stack">
                <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
                  <h3 style={{ margin: 0 }}>{t("roads.list")}</h3>
                  <select className="input" style={{ maxWidth: 220 }} aria-label={t("roads.class")} value={cls} onChange={(e) => setCls(e.target.value)}>
                    <option value="">{t("roads.allClasses")}</option>
                    {(["INTERNATIONAL", "MAIN", "SECONDARY"] as Cls[]).map((c) => <option key={c} value={c}>{t(`roads.cls.${c}`)}</option>)}
                  </select>
                </div>
                <RoadTable roads={roads} onOpen={setOpen} />
              </div>
            </>
          )}
        </>
      )}</Loaded>
      {platform ? <PlatformQueues key={tick} onChange={() => { list.reload(); setTick(tick + 1); }} /> : <CarrierCorrections key={tick} />}
      {open && <RoadModal code={open} portal={portal} onClose={() => setOpen(null)} onChange={() => { list.reload(); setTick(tick + 1); }} />}
    </div>
  );
}

function RoadTable({ roads, onOpen }: { roads: RoadRow[]; onOpen: (code: string) => void }) {
  const { t, locale, num } = useI18n();
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("roads.number")}</th><th>{t("roads.name")}</th><th>{t("roads.fromTo")}</th><th className="num">{t("roads.km")}</th>
        <th className="num">{t("roads.points")}</th><th>{t("roads.verification")}</th></tr></thead>
      <tbody>{roads.map((r) => (
        <tr key={r.code}>
          <td><button className="btn text small mono" onClick={() => onOpen(r.code)}>{r.code}</button>
            {r.regional_number && <span className="small muted"> {r.regional_number}</span>}</td>
          <td>{locale === "ar" ? r.name_ar : r.name_en}<div className="small muted">{t(`roads.cls.${r.road_class}`)}</div></td>
          <td className="small">{locale === "ar" ? `${r.start_ar} ← ${r.end_ar}` : `${r.start_en} → ${r.end_en}`}</td>
          <td className="num">{r.length_km != null ? num(Number(r.length_km)) : ""}</td>
          <td className="num">{num(Number(r.points))}</td>
          <td><span className="chip">{t(`roads.ver.${r.verification_status}`)}</span></td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

function NetworkMap({ data, selected, onPick }: { data: MapData; selected: string | null; onPick: (code: string) => void }) {
  const { t, locale } = useI18n();
  const W = 760, H = 520, PAD = 16;
  const box = useMemo(() => {
    const pts = data.roads.flatMap((r) => r.line);
    const lats = pts.map((p) => p[1]), lngs = pts.map((p) => p[0]);
    const mid = (Math.min(...lats) + Math.max(...lats)) / 2, k = Math.cos((mid * Math.PI) / 180);
    const x0 = Math.min(...lngs) * k, x1 = Math.max(...lngs) * k, y0 = Math.min(...lats), y1 = Math.max(...lats);
    const s = Math.min((W - 2 * PAD) / Math.max(x1 - x0, 1e-6), (H - 2 * PAD) / Math.max(y1 - y0, 1e-6));
    return (lng: number, lat: number) => [PAD + (lng * k - x0) * s, H - PAD - (lat - y0) * s] as const;
  }, [data]);
  if (data.roads.length === 0) return null;
  return (
    <div className="card stack">
      <h3 style={{ margin: 0 }}>{t("roads.map")}</h3>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={t("roads.map")} style={{ width: "100%", height: "auto", background: "var(--surface-2, #f6f7f5)", borderRadius: 8 }}>
        {data.roads.map((r) => (
          <polyline key={r.code} points={r.line.map(([lng, lat]) => box(lng, lat).join(",")).join(" ")} fill="none"
                    stroke={COLOURS[r.road_class]} strokeWidth={selected === r.code ? 5 : r.road_class === "INTERNATIONAL" ? 3 : 2}
                    strokeOpacity={selected && selected !== r.code ? 0.35 : 0.9} style={{ cursor: "pointer" }} onClick={() => onPick(r.code)}>
            <title>{r.code}</title>
          </polyline>
        ))}
        {data.junctions.map((j) => {
          const [x, y] = box(Number(j.lng), Number(j.lat));
          return <circle key={j.pcode} cx={x} cy={y} r={2 + Number(j.roads)} fill="#fff" stroke="#111" strokeWidth={1}><title>{locale === "ar" ? j.name_ar : j.name_en}</title></circle>;
        })}
      </svg>
      <div className="row small" style={{ gap: 16, flexWrap: "wrap" }}>
        {(["INTERNATIONAL", "MAIN", "SECONDARY"] as Cls[]).map((c) => (
          <span key={c} className="row" style={{ gap: 6, alignItems: "center" }}><span style={{ width: 18, height: 3, background: COLOURS[c], display: "inline-block" }} />{t(`roads.cls.${c}`)}</span>
        ))}
      </div>
    </div>
  );
}

function RoadModal({ code, portal, onClose, onChange }: { code: string; portal: "PLATFORM" | "OPERATOR"; onClose: () => void; onChange: () => void }) {
  const { t, locale, num, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<RoadDetail>(`/api/geo/roads/${code}`, undefined, { signal }), [code]);
  const blank = { seq: "", kind: "REMARK", place: "", km: "", remark: "" };
  const [f, setF] = useState(blank);
  const [ver, setVer] = useState({ to_status: "CARRIER_CONFIRMED", document_ref: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const base = portal === "PLATFORM" ? "/api/admin/roads" : "/api/carrier/roads";
  const propose = async () => {
    setBusy(true); setError(null);
    try {
      await api.post(`${base}/${code}/corrections`, { kind: f.kind, remark: f.remark, seq: f.seq ? Number(f.seq) : undefined,
        place: f.kind === "PLACE" ? f.place.trim().toUpperCase() : undefined, km: f.kind === "DISTANCE" ? Number(f.km) : undefined });
      toast(t("roads.proposed")); setF(blank); onChange();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const verify = async () => {
    setBusy(true); setError(null);
    try { await api.post(`/api/admin/roads/${code}/verification`, { ...ver, note: ver.note || undefined }); toast(t("roads.verAsked")); onChange(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${t("roads.road")} ${code}`} onClose={onClose} wide>
      <Loaded state={state}>{(r) => (
        <div className="stack">
          <p style={{ margin: 0 }}><strong>{locale === "ar" ? r.name_ar : r.name_en}</strong> · {t(`roads.cls.${r.road_class}`)}
            {r.regional_number ? ` · ${r.regional_number}` : ""} · {r.length_km != null ? `${num(Number(r.length_km))} ${t("roads.kmUnit")}` : ""}</p>
          <p className="small muted" style={{ margin: 0 }}>{t(`roads.ver.${r.verification_status}`)}
            {r.source_file ? ` · ${r.source_file}` : ""}{r.source_loaded_at ? ` · ${date(r.source_loaded_at)}` : ""}</p>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th className="num">#</th><th>{t("roads.place")}</th><th>{t("roads.subDistrict")}</th><th className="num">{t("roads.fromPrev")}</th>
              <th className="num">{t("roads.fromStart")}</th><th>{t("roads.crossing")}</th></tr></thead>
            <tbody>{r.points.map((p) => (
              <tr key={p.seq}>
                <td className="num">{p.seq}</td>
                <td>{locale === "ar" ? p.name_ar : p.name_en} <span className="mono small muted">{p.pcode}</span>
                  {p.is_border && <span className="chip" style={{ marginInlineStart: 6 }}>{t("roads.border")}</span>}</td>
                <td className="small">{locale === "ar" ? p.sub_district_ar : p.sub_district_en}</td>
                <td className="num">{num(Number(p.km_from_previous))}</td><td className="num">{num(Number(p.km_cumulative))}</td>
                <td className="small mono">{(p.crossing_roads ?? []).join(" · ")}</td>
              </tr>
            ))}</tbody>
          </table></div>
          <ErrorBox error={error} />
          <div className="card stack">
            <h4 style={{ margin: 0 }}>{t("roads.propose")}</h4>
            <div className="grid cols-3">
              <Field label={t("roads.kind")}>
                <select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>
                  {["REMARK", "PLACE", "DISTANCE"].map((k) => <option key={k} value={k}>{t(`roads.ck.${k}`)}</option>)}</select>
              </Field>
              <Field label={t("roads.pointNo")}>
                <select className="input" value={f.seq} onChange={(e) => setF({ ...f, seq: e.target.value })}>
                  <option value="">{t("roads.wholeRoad")}</option>
                  {r.points.map((p) => <option key={p.seq} value={p.seq}>{p.seq}. {locale === "ar" ? p.name_ar : p.name_en}</option>)}</select>
              </Field>
              {f.kind === "PLACE" && <Field label={t("roads.newPlace")}><input className="input mono" value={f.place} onChange={(e) => setF({ ...f, place: e.target.value })} /></Field>}
              {f.kind === "DISTANCE" && <Field label={t("roads.newKm")}><input className="input" type="number" min={0} value={f.km} onChange={(e) => setF({ ...f, km: e.target.value })} /></Field>}
            </div>
            <Field label={t("roads.remark")}><input className="input" value={f.remark} onChange={(e) => setF({ ...f, remark: e.target.value })} /></Field>
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button className="btn" disabled={busy || f.remark.trim().length < 5} onClick={propose}>{t("roads.send")}</button>
            </div>
          </div>
          {portal === "PLATFORM" && (
            <div className="card stack">
              <h4 style={{ margin: 0 }}>{t("roads.verify")}</h4>
              <div className="grid cols-3">
                <Field label={t("roads.verification")}>
                  <select className="input" value={ver.to_status} onChange={(e) => setVer({ ...ver, to_status: e.target.value })}>
                    {["OWNER_FILE", "CARRIER_CONFIRMED", "AUTHORITY_APPROVED"].filter((s) => s !== r.verification_status)
                      .map((s) => <option key={s} value={s}>{t(`roads.ver.${s}`)}</option>)}</select>
                </Field>
                <Field label={t("roads.document")}><input className="input" value={ver.document_ref} onChange={(e) => setVer({ ...ver, document_ref: e.target.value })} /></Field>
                <Field label={t("roads.note")}><input className="input" value={ver.note} onChange={(e) => setVer({ ...ver, note: e.target.value })} /></Field>
              </div>
              <div className="row" style={{ justifyContent: "flex-end" }}>
                <button className="btn outlined" disabled={busy || ver.document_ref.trim().length < 3} onClick={verify}>{t("roads.askVerify")}</button>
              </div>
            </div>
          )}
        </div>
      )}</Loaded>
    </Modal>
  );
}

function CorrectionRows({ rows, onReview }: { rows: Correction[]; onReview?: (c: Correction) => void }) {
  const { t, locale, date } = useI18n();
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("roads.road")}</th><th>{t("roads.kind")}</th><th>{t("roads.proposal")}</th><th>{t("roads.state")}</th><th /></tr></thead>
      <tbody>{rows.map((c) => (
        <tr key={c.uid}>
          <td className="mono">{c.road}{c.seq ? ` #${c.seq}` : ""}</td>
          <td>{t(`roads.ck.${c.kind}`)}</td>
          <td className="small">
            {c.kind === "PLACE" && <div><span className="mono">{c.current_place}</span> → <strong className="mono">{c.place}</strong> {locale === "ar" ? c.place_ar : c.place_en}</div>}
            {c.kind === "DISTANCE" && <div>{c.current_km} → <strong>{c.km}</strong> {t("roads.kmUnit")}</div>}
            <div>{c.remark}</div>
            <div className="muted">{c.company ?? c.proposed_by} · {date(c.proposed_at)}</div>
          </td>
          <td><span className="chip">{t(`roads.cs.${c.status}`)}</span>{c.review_note && <div className="small muted">{c.review_note}</div>}</td>
          <td>{onReview && c.status === "PENDING" && !c.mine && <button className="btn text small" onClick={() => onReview(c)}>{t("roads.review")}</button>}</td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

function PlatformQueues({ onChange }: { onChange: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const corr = useLoad((signal) => api.get<{ corrections: Correction[] }>("/api/admin/roads/corrections", undefined, { signal }));
  const vers = useLoad((signal) => api.get<{ verifications: Verification[] }>("/api/admin/roads/verifications", undefined, { signal }));
  const [reviewing, setReviewing] = useState<Correction | null>(null);
  const [deciding, setDeciding] = useState<Verification | null>(null);
  const [note, setNote] = useState("");
  const [error, setError] = useState<unknown>(null);
  const act = async (url: string, body: object, done: () => void) => {
    setError(null);
    try { const out = await api.post<{ status: string }>(url, body); toast(t(`roads.cs.${out.status}`)); setNote(""); done(); corr.reload(); vers.reload(); onChange(); }
    catch (e) { setError(e); }
  };
  return (
    <>
      <ErrorBox error={error} />
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("roads.corrections")}</h3>
        <Loaded state={corr}>{({ corrections }) => corrections.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("roads.noCorrections")}</p>
          : <CorrectionRows rows={corrections} onReview={setReviewing} />}</Loaded>
      </div>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("roads.verifications")}</h3>
        <Loaded state={vers}>{({ verifications }) => verifications.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("roads.noVerifications")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("roads.road")}</th><th>{t("roads.verification")}</th><th>{t("roads.document")}</th><th>{t("roads.state")}</th><th /></tr></thead>
            <tbody>{verifications.map((v) => (
              <tr key={v.uid}>
                <td className="mono">{v.road}</td>
                <td className="small">{t(`roads.ver.${v.from_status}`)} → <strong>{t(`roads.ver.${v.to_status}`)}</strong></td>
                <td className="small">{v.document_ref}{v.note ? <div className="muted">{v.note}</div> : null}<div className="muted">{v.requested_by}</div></td>
                <td><span className="chip">{t(`roads.cs.${v.status}`)}</span>{v.decided_by && <div className="small muted">{v.decided_by}</div>}</td>
                <td>{v.status === "PENDING" && !v.mine && <button className="btn text small" onClick={() => setDeciding(v)}>{t("roads.review")}</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {reviewing && (
        <Modal title={t("roads.review")} onClose={() => setReviewing(null)}>
          <div className="stack">
            <CorrectionRows rows={[reviewing]} />
            <Field label={t("roads.reviewNote")}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
            <div className="row" style={{ justifyContent: "flex-end", gap: 8 }}>
              <button className="btn outlined" onClick={() => act(`/api/admin/roads/corrections/${reviewing.uid}/review`, { accept: false, note: note || undefined }, () => setReviewing(null))}>{t("roads.reject")}</button>
              <button className="btn" onClick={() => act(`/api/admin/roads/corrections/${reviewing.uid}/review`, { accept: true, note: note || undefined }, () => setReviewing(null))}>{t("roads.accept")}</button>
            </div>
          </div>
        </Modal>
      )}
      {deciding && (
        <Modal title={t("roads.review")} onClose={() => setDeciding(null)}>
          <div className="stack">
            <p style={{ margin: 0 }}><span className="mono">{deciding.road}</span>: {t(`roads.ver.${deciding.from_status}`)} → <strong>{t(`roads.ver.${deciding.to_status}`)}</strong></p>
            <p className="small muted" style={{ margin: 0 }}>{deciding.document_ref}</p>
            <Field label={t("roads.reviewNote")}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
            <div className="row" style={{ justifyContent: "flex-end", gap: 8 }}>
              <button className="btn outlined" onClick={() => act(`/api/admin/roads/verifications/${deciding.uid}/decide`, { approve: false, note: note || undefined }, () => setDeciding(null))}>{t("roads.reject")}</button>
              <button className="btn" onClick={() => act(`/api/admin/roads/verifications/${deciding.uid}/decide`, { approve: true, note: note || undefined }, () => setDeciding(null))}>{t("roads.approve")}</button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}

function CarrierCorrections() {
  const { t } = useI18n();
  const corr = useLoad((signal) => api.get<{ corrections: Correction[] }>("/api/carrier/roads/corrections", undefined, { signal }));
  return (
    <div className="card stack">
      <h3 style={{ margin: 0 }}>{t("roads.myCorrections")}</h3>
      <p className="small muted" style={{ margin: 0 }}>{t("roads.carrierHint")}</p>
      <Loaded state={corr}>{({ corrections }) => corrections.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("roads.noCorrections")}</p>
        : <CorrectionRows rows={corrections} />}</Loaded>
    </div>
  );
}
