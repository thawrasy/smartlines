import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Routes of the network (owner's requests N11, N37, N38; migration 1163): the platform defines each route from one
// station to another, in versions: its stations in order (mandatory or not) and the road segments it follows, from which
// the distance and the governorates crossed come. One person proposes a version, another approves it; it takes effect
// on its date. Carriers run their services only on these routes and ask here for the routes the network lacks.

interface NetStop { seq: number; station_uid: string; station_code: string; station_name: string; subtype: string; city_code: string; km_from_start: number; mandatory: boolean }
interface NetRoute { uid: string; code: string; name_en: string; name_ar: string; version: number; distance_km: number; effective_from: string; stops: NetStop[] }
interface Version { uid: string; route_uid: string; code: string; name_en: string; name_ar: string; version: number; status: string; effective_from: string;
  distance_km: number; note: string | null; proposed_at: string; proposed_by: string; decided_by: string | null; decision_note: string | null; mine: boolean;
  stops: number; segments: number }
interface Detail { uid: string; code: string; name_en: string; name_ar: string; status: string;
  shown: { version: number; status: string; distance_km: number; stops: NetStop[];
    segments: { seq: number; road: string; from_seq: number; to_seq: number; km: number; from_en: string; from_ar: string; to_en: string; to_ar: string }[];
    governorates: { pcode: string; name_en: string | null; name_ar: string | null }[] } | null;
  versions: { uid: string; version: number; status: string; effective_from: string; distance_km: number; proposed_by: string; decided_by: string | null }[] }
interface Request { uid: string; company: string; from_station: string; from_code: string; to_station: string; to_code: string; via: string | null; note: string;
  status: string; requested_at: string; answer: string | null; route_code: string | null }
interface AdminStation { uid: string; code: string; name: string; status: string; city_code: string }
interface RoadRow { code: string; name_en: string; name_ar: string; points: number }

type StopRow = { station_uid: string; km: string; mandatory: boolean };
type SegRow = { road: string; from_seq: string; to_seq: string };

export function AdminNetworkRoutes() {
  const { t, locale, num, date } = useI18n();
  const toast = useToast();
  const routes = useLoad((signal) => api.get<{ routes: NetRoute[] }>("/api/network/routes", undefined, { signal }));
  const versions = useLoad((signal) => api.get<{ versions: Version[] }>("/api/admin/network/versions", undefined, { signal }));
  const requests = useLoad((signal) => api.get<{ requests: Request[] }>("/api/admin/network/requests", undefined, { signal }));
  const [form, setForm] = useState<{ route?: Detail } | null>(null);
  const [view, setView] = useState<string | null>(null);
  const [deciding, setDeciding] = useState<Version | null>(null);
  const [answering, setAnswering] = useState<Request | null>(null);
  const [note, setNote] = useState("");
  const [answer, setAnswer] = useState({ status: "DONE", answer: "", route_uid: "" });
  const [error, setError] = useState<unknown>(null);
  const reload = () => { routes.reload(); versions.reload(); requests.reload(); };
  const act = async (fn: () => Promise<{ status: string }>, done: () => void) => {
    setError(null);
    try { const out = await fn(); toast(t(`nroute.status.${out.status}`)); done(); reload(); } catch (e) { setError(e); }
  };
  const name = (x: { name_en: string; name_ar: string }) => (locale === "ar" ? x.name_ar : x.name_en);
  return (
    <div className="stack">
      <PageHead title={t("nroute.title")} sub={t("nroute.sub")}>
        <button className="btn" onClick={() => setForm({})}><Icon name="add" />{t("nroute.add")}</button>
      </PageHead>
      <ErrorBox error={error} />
      <Loaded state={routes}>{(d) => d.routes.length === 0 ? <div className="card"><Empty icon="route" title={t("nroute.none")} hint={t("nroute.noneHint")} /></div> : (
        <div className="card stack">
          <h3 style={{ margin: 0 }}>{t("nroute.inEffect")}</h3>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("nroute.code")}</th><th>{t("nroute.name")}</th><th>{t("nroute.stations")}</th><th className="num">{t("nroute.km")}</th><th>{t("nroute.version")}</th></tr></thead>
            <tbody>{d.routes.map((r) => (
              <tr key={r.uid}>
                <td><button className="btn text small mono" onClick={() => setView(r.uid)}>{r.code}</button></td>
                <td>{name(r)}</td>
                <td className="small">{r.stops.map((s) => `${s.station_name}${s.mandatory && s.seq > 1 && s.seq < r.stops.length ? " *" : ""}`).join(" · ")}</td>
                <td className="num">{num(Number(r.distance_km))}</td><td>v{r.version} · {date(r.effective_from)}</td>
              </tr>
            ))}</tbody>
          </table></div>
          <p className="small muted" style={{ margin: 0 }}>{t("nroute.mandatoryHint")}</p>
        </div>
      )}</Loaded>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("nroute.versions")}</h3>
        <Loaded state={versions}>{(d) => d.versions.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("nroute.noVersions")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("nroute.code")}</th><th>{t("nroute.version")}</th><th className="num">{t("nroute.km")}</th><th>{t("nroute.effective")}</th><th>{t("nroute.state")}</th><th /></tr></thead>
            <tbody>{d.versions.map((v) => (
              <tr key={v.uid}>
                <td className="mono">{v.code}<div className="small muted">{name(v)}</div></td>
                <td>v{v.version}<div className="small muted">{t("nroute.counts", { stops: v.stops, segments: v.segments })}</div></td>
                <td className="num">{num(Number(v.distance_km))}</td><td>{date(v.effective_from)}</td>
                <td><span className="chip">{t(`nroute.status.${v.status}`)}</span>
                  <div className="small muted">{v.proposed_by}{v.decided_by ? ` / ${v.decided_by}` : ""}</div>
                  {v.note && <div className="small muted">{v.note}</div>}{v.decision_note && <div className="small muted">{v.decision_note}</div>}</td>
                <td className="row" style={{ gap: 4 }}>
                  {v.status === "PENDING" && !v.mine && <button className="btn text small" onClick={() => setDeciding(v)}>{t("nroute.decide")}</button>}
                  {["PENDING", "APPROVED"].includes(v.status) && v.mine &&
                    <button className="btn text small" onClick={() => act(() => api.post(`/api/admin/network/versions/${v.uid}/withdraw`, {}), () => undefined)}>{t("nroute.withdraw")}</button>}
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("nroute.requests")}</h3>
        <Loaded state={requests}>{(d) => d.requests.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("nroute.noRequests")}</p> : (
          <RequestTable rows={d.requests} onAnswer={(r) => { setAnswering(r); setAnswer({ status: "DONE", answer: "", route_uid: "" }); }} />
        )}</Loaded>
      </div>
      {view && <RouteView uid={view} onClose={() => setView(null)} onNewVersion={(r) => { setView(null); setForm({ route: r }); }} />}
      {form && <VersionForm route={form.route} onClose={() => setForm(null)} onDone={() => { setForm(null); reload(); }} />}
      {deciding && (
        <Modal title={t("nroute.decide")} onClose={() => setDeciding(null)}>
          <div className="stack">
            <p style={{ margin: 0 }}><span className="mono">{deciding.code}</span> v{deciding.version} · {num(Number(deciding.distance_km))} {t("nroute.km")} · {date(deciding.effective_from)}</p>
            <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={() => setView(deciding.route_uid)}>{t("nroute.open")}</button>
            <Field label={t("nroute.note")}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
            <div className="row" style={{ justifyContent: "flex-end", gap: 8 }}>
              <button className="btn outlined" onClick={() => act(() => api.post(`/api/admin/network/versions/${deciding.uid}/decide`, { approve: false, note: note || undefined }), () => { setDeciding(null); setNote(""); })}>{t("nroute.reject")}</button>
              <button className="btn" onClick={() => act(() => api.post(`/api/admin/network/versions/${deciding.uid}/decide`, { approve: true, note: note || undefined }), () => { setDeciding(null); setNote(""); })}>{t("nroute.approve")}</button>
            </div>
          </div>
        </Modal>
      )}
      {answering && (
        <Modal title={t("nroute.answer")} onClose={() => setAnswering(null)}>
          <div className="stack">
            <RequestTable rows={[answering]} />
            <div className="grid cols-2">
              <Field label={t("nroute.state")}>
                <select className="input" value={answer.status} onChange={(e) => setAnswer({ ...answer, status: e.target.value })}>
                  <option value="DONE">{t("nroute.status.DONE")}</option><option value="DECLINED">{t("nroute.status.DECLINED")}</option></select>
              </Field>
              <Field label={t("nroute.routeOpened")}>
                <select className="input" value={answer.route_uid} onChange={(e) => setAnswer({ ...answer, route_uid: e.target.value })}>
                  <option value="">—</option>{routes.data?.routes.map((r) => <option key={r.uid} value={r.uid}>{r.code} {name(r)}</option>)}</select>
              </Field>
            </div>
            <Field label={t("nroute.answerText")}><input className="input" value={answer.answer} onChange={(e) => setAnswer({ ...answer, answer: e.target.value })} /></Field>
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button className="btn" disabled={answer.answer.trim().length < 3} onClick={() => act(() => api.post(`/api/admin/network/requests/${answering.uid}/answer`,
                { status: answer.status, answer: answer.answer, route_uid: answer.route_uid || undefined }), () => setAnswering(null))}>{t("common.save")}</button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}

export function RequestTable({ rows, onAnswer }: { rows: Request[]; onAnswer?: (r: Request) => void }) {
  const { t, date } = useI18n();
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("nroute.fromTo")}</th><th>{t("nroute.requestNote")}</th><th>{t("nroute.state")}</th><th /></tr></thead>
      <tbody>{rows.map((r) => (
        <tr key={r.uid}>
          <td>{r.from_station} → {r.to_station}<div className="small muted mono">{r.from_code} · {r.to_code}</div></td>
          <td className="small">{r.via && <div>{t("nroute.via")}: {r.via}</div>}<div>{r.note}</div><div className="muted">{r.company} · {date(r.requested_at)}</div></td>
          <td><span className="chip">{t(`nroute.status.${r.status}`)}</span>{r.answer && <div className="small muted">{r.answer}</div>}
            {r.route_code && <div className="small mono">{r.route_code}</div>}</td>
          <td>{onAnswer && r.status === "OPEN" && <button className="btn text small" onClick={() => onAnswer(r)}>{t("nroute.answer")}</button>}</td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

function RouteView({ uid, onClose, onNewVersion }: { uid: string; onClose: () => void; onNewVersion?: (r: Detail) => void }) {
  const { t, locale, num, date } = useI18n();
  const state = useLoad((signal) => api.get<Detail>(`/api/network/routes/${uid}`, undefined, { signal }), [uid]);
  return (
    <Modal title={t("nroute.route")} onClose={onClose} wide>
      <Loaded state={state}>{(r) => (
        <div className="stack">
          <p style={{ margin: 0 }}><strong className="mono">{r.code}</strong> · {locale === "ar" ? r.name_ar : r.name_en}</p>
          {r.shown && (
            <>
              <p className="small muted" style={{ margin: 0 }}>v{r.shown.version} · {t(`nroute.status.${r.shown.status}`)} · {num(Number(r.shown.distance_km))} {t("nroute.km")}
                {r.shown.governorates.length > 0 && ` · ${r.shown.governorates.map((g) => (locale === "ar" ? g.name_ar : g.name_en) ?? g.pcode).join(", ")}`}</p>
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th className="num">#</th><th>{t("nroute.station")}</th><th className="num">{t("nroute.kmFromStart")}</th><th>{t("nroute.mandatory")}</th></tr></thead>
                <tbody>{r.shown.stops.map((s) => (
                  <tr key={s.seq}><td className="num">{s.seq}</td><td>{s.station_name} <span className="mono small muted">{s.station_code}</span></td>
                    <td className="num">{num(Number(s.km_from_start))}</td><td>{s.mandatory ? t("common.yes") : "—"}</td></tr>
                ))}</tbody>
              </table></div>
              {r.shown.segments.length > 0 && (
                <div className="small">{t("nroute.roads")}: {r.shown.segments.map((g) => `${g.road} (${locale === "ar" ? g.from_ar : g.from_en} → ${locale === "ar" ? g.to_ar : g.to_en}, ${num(Number(g.km))} ${t("nroute.km")})`).join(" · ")}</div>
              )}
            </>
          )}
          <div className="small">{r.versions.map((v) => <div key={v.uid}>v{v.version} · {t(`nroute.status.${v.status}`)} · {date(v.effective_from)} · {v.proposed_by}{v.decided_by ? ` / ${v.decided_by}` : ""}</div>)}</div>
          {onNewVersion && <button className="btn outlined" style={{ alignSelf: "flex-start" }} onClick={() => onNewVersion(r)}><Icon name="edit" />{t("nroute.newVersion")}</button>}
        </div>
      )}</Loaded>
    </Modal>
  );
}

function VersionForm({ route, onClose, onDone }: { route?: Detail; onClose: () => void; onDone: () => void }) {
  const { t, locale } = useI18n();
  const toast = useToast();
  const stations = useLoad((signal) => api.get<{ stations: AdminStation[] }>("/api/admin/stations", undefined, { signal }));
  const roads = useLoad((signal) => api.get<{ roads: RoadRow[] }>("/api/geo/roads", undefined, { signal }));
  const initial: StopRow[] = route?.shown?.stops.map((s) => ({ station_uid: s.station_uid, km: String(s.km_from_start), mandatory: s.mandatory }))
    ?? [{ station_uid: "", km: "0", mandatory: true }, { station_uid: "", km: "", mandatory: true }];
  const [names, setNames] = useState({ name_en: route?.name_en ?? "", name_ar: route?.name_ar ?? "" });
  const [stops, setStops] = useState<StopRow[]>(initial);
  const [segs, setSegs] = useState<SegRow[]>(route?.shown?.segments.map((g) => ({ road: g.road, from_seq: String(g.from_seq), to_seq: String(g.to_seq) })) ?? []);
  const [extra, setExtra] = useState({ distance_km: route?.shown && !route.shown.segments.length ? String(route.shown.distance_km) : "", effective_from: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const setStop = (i: number, k: keyof StopRow, v: string | boolean) => setStops(stops.map((s, j) => (j === i ? { ...s, [k]: v } : s)));
  const setSeg = (i: number, k: keyof SegRow, v: string) => setSegs(segs.map((s, j) => (j === i ? { ...s, [k]: v } : s)));
  const save = async () => {
    setBusy(true); setError(null);
    const version = {
      effective_from: extra.effective_from || undefined, note: extra.note || undefined,
      distance_km: segs.length ? undefined : Number(extra.distance_km) || undefined,
      segments: segs.map((g) => ({ road: g.road, from_seq: Number(g.from_seq), to_seq: Number(g.to_seq) })),
      stops: stops.map((s, i) => ({ station_uid: s.station_uid, mandatory: s.mandatory, km: i === 0 || s.km === "" ? undefined : Number(s.km) })),
    };
    try {
      if (route) await api.post(`/api/admin/network/routes/${route.uid}/versions`, version);
      else await api.post("/api/admin/network/routes", { ...names, version });
      toast(t("nroute.proposed")); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={route ? `${t("nroute.newVersion")} ${route.code}` : t("nroute.add")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || stops.some((s) => !s.station_uid) || (!route && (names.name_en.length < 3 || names.name_ar.length < 3))} onClick={save}>{t("nroute.propose")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        {!route && (
          <div className="grid cols-2">
            <Field label={t("nroute.nameEn")}><input className="input" value={names.name_en} onChange={(e) => setNames({ ...names, name_en: e.target.value })} /></Field>
            <Field label={t("nroute.nameAr")}><input className="input" value={names.name_ar} onChange={(e) => setNames({ ...names, name_ar: e.target.value })} /></Field>
          </div>
        )}
        <strong>{t("nroute.stations")}</strong>
        <p className="small muted" style={{ margin: 0 }}>{t("nroute.stopsHint")}</p>
        {stops.map((s, i) => (
          <div key={i} className="grid" style={{ gridTemplateColumns: "2.5fr 1fr 1fr auto", alignItems: "end" }}>
            <Field label={`${i + 1}. ${t("nroute.station")}`}>
              <select className="input" value={s.station_uid} disabled={!!route && (i === 0 || i === stops.length - 1)} onChange={(e) => setStop(i, "station_uid", e.target.value)}>
                <option value="">—</option>{stations.data?.stations.filter((x) => x.status === "ACTIVE").map((x) => <option key={x.uid} value={x.uid}>{x.name} ({x.code})</option>)}</select>
            </Field>
            <Field label={t("nroute.kmFromStart")}><input className="input ltr" type="number" min={0} disabled={i === 0} value={i === 0 ? "0" : s.km} placeholder={segs.length ? t("nroute.fromRoads") : ""}
                                                         onChange={(e) => setStop(i, "km", e.target.value)} /></Field>
            <label className="row small" style={{ gap: 6, alignItems: "center" }}><input type="checkbox" checked={s.mandatory || i === 0 || i === stops.length - 1}
              disabled={i === 0 || i === stops.length - 1} onChange={(e) => setStop(i, "mandatory", e.target.checked)} />{t("nroute.mandatory")}</label>
            <button className="icon-btn" aria-label={t("common.remove")} disabled={i === 0 || i === stops.length - 1} onClick={() => setStops(stops.filter((_, j) => j !== i))}><Icon name="close" /></button>
          </div>
        ))}
        <button className="btn outlined" style={{ alignSelf: "flex-start" }} onClick={() => setStops([...stops.slice(0, -1), { station_uid: "", km: "", mandatory: false }, stops[stops.length - 1]])}>
          <Icon name="add" />{t("nroute.addStop")}</button>
        <strong>{t("nroute.roads")}</strong>
        <p className="small muted" style={{ margin: 0 }}>{t("nroute.roadsHint")}</p>
        {segs.map((g, i) => (
          <div key={i} className="grid" style={{ gridTemplateColumns: "2fr 1fr 1fr auto", alignItems: "end" }}>
            <Field label={`${i + 1}. ${t("nroute.road")}`}>
              <select className="input" value={g.road} onChange={(e) => setSeg(i, "road", e.target.value)}>
                <option value="">—</option>{roads.data?.roads.map((r) => <option key={r.code} value={r.code}>{r.code} {locale === "ar" ? r.name_ar : r.name_en}</option>)}</select>
            </Field>
            <Field label={t("nroute.fromPoint")}><input className="input ltr" type="number" min={1} value={g.from_seq} onChange={(e) => setSeg(i, "from_seq", e.target.value)} /></Field>
            <Field label={t("nroute.toPoint")}><input className="input ltr" type="number" min={1} value={g.to_seq} onChange={(e) => setSeg(i, "to_seq", e.target.value)} /></Field>
            <button className="icon-btn" aria-label={t("common.remove")} onClick={() => setSegs(segs.filter((_, j) => j !== i))}><Icon name="close" /></button>
          </div>
        ))}
        <button className="btn outlined" style={{ alignSelf: "flex-start" }} onClick={() => setSegs([...segs, { road: "", from_seq: "1", to_seq: "2" }])}><Icon name="add" />{t("nroute.addRoad")}</button>
        <div className="grid cols-3">
          {segs.length === 0 && <Field label={t("nroute.distance")}><input className="input ltr" type="number" min={1} value={extra.distance_km} onChange={(e) => setExtra({ ...extra, distance_km: e.target.value })} /></Field>}
          <Field label={t("nroute.effective")}><input className="input" type="date" value={extra.effective_from} onChange={(e) => setExtra({ ...extra, effective_from: e.target.value })} /></Field>
          <Field label={t("nroute.note")}><input className="input" value={extra.note} onChange={(e) => setExtra({ ...extra, note: e.target.value })} /></Field>
        </div>
      </div>
    </Modal>
  );
}
