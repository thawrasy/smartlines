import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api, ApiError } from "../api";
import { useI18n } from "../i18n";
import { PageHead } from "../components/layout";
import { Empty, ErrorBox, Icon, Status, useLoad } from "../components/ui";

interface Tracking {
  tracking_no: string; status: string; created_at: string; eta: string | null; service: string; origin: string | null; destination: string | null; origin_code: string | null; destination_code: string | null;
  events: { milestone: string; ts: string; place: string | null; place_code: string | null }[];
}

/** Public parcel tracking: anyone with the tracking number sees status, places and times, never names or phone numbers. */
export default function Track() {
  const { no = "" } = useParams();
  const { t, dateTime, station, has } = useI18n();
  const nav = useNavigate();
  const [q, setQ] = useState(no);
  const state = useLoad(() => (no ? api.get<Tracking>(`/api/track/${encodeURIComponent(no)}`) : Promise.resolve(null)), [no]);
  const d = state.data;
  return (
    <div className="page narrow stack">
      <PageHead title={t("wf.track.title")} sub={t("wf.track.sub")} />
      <form className="card row nowrap" onSubmit={(e) => { e.preventDefault(); if (q.trim()) nav(`/track/${q.trim().toUpperCase()}`); }}>
        <input className="ltr mono" style={{ flex: 1, minWidth: 0 }} value={q} onChange={(e) => setQ(e.target.value)} placeholder="MS0000000000" aria-label={t("wf.track.number")} />
        <button className="btn"><Icon name="search" />{t("wf.track.go")}</button>
      </form>
      {/* only "no such parcel" says so; a busy or unreachable service says that, with a retry (review of 1.47.0, R-36) */}
      {no && state.error ? (state.error instanceof ApiError && state.error.status === 404
        ? <div className="card"><Empty icon="package_2" title={t("wf.track.notFound")} /></div>
        : <div className="card stack"><ErrorBox error={state.error} />
            <div><button type="button" className="btn outlined" onClick={state.reload}><Icon name="refresh" />{t("common.retry")}</button></div></div>) : null}
      {d && (
        <div className="card stack">
          <div className="row between">
            <div className="stack tight"><span className="mono ltr" style={{ fontSize: 20, fontWeight: 700 }}>{d.tracking_no}</span>
              <span className="muted small">{d.service} · {station(d.origin_code, d.origin ?? "")} → {station(d.destination_code, d.destination ?? "")}</span></div>
            <Status value={d.status} />
          </div>
          <ol className="track-steps">
            {d.events.map((e, i) => (
              <li key={i} className={i === 0 ? "now" : ""}>
                <strong>{has(`val.${e.milestone}`) ? t(`val.${e.milestone}`) : e.milestone}</strong>
                <span className="small muted">{dateTime(e.ts)}{e.place ? ` · ${station(e.place_code, e.place)}` : ""}</span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
}
