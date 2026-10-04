import { useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Empty, Loaded, useLoad } from "../components/ui";
import type { ColSpec } from "./ResourceTable";
import { useCell } from "./ResourceTable";
import { useLabels } from "./labels";

interface Tile { id: string; res: string; value: number; money: boolean; tone: "" | "good" | "warn" | "bad" }
interface Breakdown { res: string; column: string; items: { value: string; count: number }[] }
interface Trend { res: string; column: string; points: { day: string; count: number }[] }
interface Recent { res: string; columns: ColSpec[]; rows: Record<string, unknown>[]; total: number }
interface DashData { tiles: Tile[]; breakdowns: Breakdown[]; trend: Trend | null; recent: Recent | null }

/** The first tab of every module: headline numbers, how records split by status, the last 30 days and the latest records. */
export function ModuleDashboard({ module, onOpen }: { module: string; onOpen: (res: string) => void }) {
  const { t } = useI18n();
  const state = useLoad(() => api.get<DashData>(`/api/m/${module}/dashboard`), [module]);
  return (
    <Loaded state={state}>{(d) => (
      d.tiles.length + d.breakdowns.length === 0 && !d.trend && !d.recent
        ? <div className="card"><Empty icon="monitoring" title={t("modules.nothingHere")} /></div>
        : (
          <div className="stack">
            {d.tiles.length > 0 && (
              <div className="dash-tiles">
                {d.tiles.map((x) => <TileCard key={x.id} tile={x} onOpen={onOpen} />)}
              </div>
            )}
            <div className="grid cols-2 dash-row">
              {d.trend && <TrendCard trend={d.trend} />}
              {d.breakdowns.map((b) => <BreakdownCard key={`${b.res}.${b.column}`} data={b} onOpen={onOpen} />)}
            </div>
            {d.recent && <RecentCard data={d.recent} onOpen={onOpen} />}
          </div>
        )
    )}</Loaded>
  );
}

function TileCard({ tile, onOpen }: { tile: Tile; onOpen: (res: string) => void }) {
  const { t, money, num } = useI18n();
  return (
    <button className={`stat dash-tile ${tile.tone}`} onClick={() => onOpen(tile.res)}>
      <span className="label">{t(`dash.${tile.id}`)}</span>
      <span className="value">
        {tile.money ? money(tile.value, false) : num(tile.value)}
        {tile.money && <small className="unit">{t("common.currency")}</small>}
      </span>
    </button>
  );
}

function BreakdownCard({ data, onOpen }: { data: Breakdown; onOpen: (res: string) => void }) {
  const { t, num } = useI18n();
  const L = useLabels();
  const max = Math.max(1, ...data.items.map((i) => i.count));
  const total = data.items.reduce((a, i) => a + i.count, 0);
  return (
    <div className="card dash-card">
      <div className="row between nowrap">
        <h3>{t("dash.byStatus", { name: L.res(data.res) })}</h3>
        <button className="btn text small" onClick={() => onOpen(data.res)}>{t("dash.open")}</button>
      </div>
      {data.items.length === 0 ? <p className="muted small">{t("common.empty")}</p> : (
        <div className="hbars" role="table" aria-label={t("dash.byStatus", { name: L.res(data.res) })}>
          {data.items.map((i) => (
            <div key={i.value} className="hbar" role="row" title={`${L.value(i.value)}: ${num(i.count)} (${Math.round((i.count / total) * 100)}%)`}>
              <span className="hbar-label" role="cell">{L.value(i.value)}</span>
              <span className="hbar-track" role="presentation"><span className="hbar-fill" style={{ width: `${(i.count / max) * 100}%` }} /></span>
              <span className="hbar-value" role="cell">{num(i.count)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function TrendCard({ trend }: { trend: Trend }) {
  const { t, num, date } = useI18n();
  const L = useLabels();
  const [hover, setHover] = useState<number | null>(null);
  const pts = trend.points;
  const max = Math.max(1, ...pts.map((p) => p.count));
  const total = pts.reduce((a, p) => a + p.count, 0);
  const W = 600, H = 160, gap = 2, bw = W / pts.length - gap;
  const day = (s: string) => date(`${s}T12:00:00Z`, { day: "numeric", month: "short" });
  const active = hover !== null ? pts[hover] : null;
  return (
    <div className="card dash-card">
      <div className="row between nowrap">
        <h3>{t("dash.trend", { name: L.res(trend.res) })}</h3>
        <span className="muted small">{active ? `${day(active.day)} · ${num(active.count)}` : t("dash.total30", { n: num(total) })}</span>
      </div>
      <svg className="trend" direction="ltr" viewBox={`0 0 ${W} ${H + 18}`} role="img" aria-label={t("dash.trend", { name: L.res(trend.res) })}
           onMouseLeave={() => setHover(null)}>
        <line x1="0" x2={W} y1={H} y2={H} className="trend-axis" />
        {pts.map((p, i) => {
          const h = p.count === 0 ? 0 : Math.max(3, (p.count / max) * (H - 8));
          const x = i * (bw + gap);
          return (
            <g key={p.day} onMouseEnter={() => setHover(i)}>
              <rect x={x} y={0} width={bw + gap} height={H} fill="transparent" />
              {h > 0 && <path className={`trend-bar${hover === i ? " on" : ""}`}
                              d={`M${x},${H} v${-(h - 3)} q0,-3 3,-3 h${bw - 6} q3,0 3,3 v${h - 3} z`} />}
            </g>
          );
        })}
        <text x="0" y={H + 14} className="trend-tick">{day(pts[0].day)}</text>
        <text x={W} y={H + 14} className="trend-tick" textAnchor="end">{day(pts[pts.length - 1].day)}</text>
      </svg>
    </div>
  );
}

function RecentCard({ data, onOpen }: { data: Recent; onOpen: (res: string) => void }) {
  const { t } = useI18n();
  const L = useLabels();
  const cell = useCell();
  return (
    <div className="card dash-card">
      <div className="row between nowrap">
        <h3>{t("dash.latest", { name: L.res(data.res) })}</h3>
        <button className="btn text small" onClick={() => onOpen(data.res)}>{t("dash.all", { n: data.total })}</button>
      </div>
      {data.rows.length === 0 ? <p className="muted small">{t("common.empty")}</p> : (
        <div className="table-wrap">
          <table className="table">
            <thead><tr>{data.columns.map((c) => <th key={c.name}>{L.field(c.name)}</th>)}</tr></thead>
            <tbody>{data.rows.map((r, i) => <tr key={i}>{data.columns.map((c) => <td key={c.name}>{cell(c, r)}</td>)}</tr>)}</tbody>
          </table>
        </div>
      )}
    </div>
  );
}
