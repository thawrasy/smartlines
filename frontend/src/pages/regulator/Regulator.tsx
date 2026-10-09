import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, Loaded, Stat, useLoad } from "../../components/ui";

interface Dash {
  carriers: number; carriers_pending: number; blocked_vehicles: number; open_alerts: number; open_cases: number;
  customer_funds: number; escrow_funds: number; on_time_pct: number | null;
  lines: { origin_city: string; dest_city: string; carriers: number; trips_7d: number; tickets: number }[];
}

export default function Regulator() {
  const { t, num, money, city, dir } = useI18n();
  const state = useLoad(() => api.get<Dash>("/api/regulator/dashboard"));
  const arrow = dir === "rtl" ? "←" : "→";
  return (
    <div className="stack">
      <PageHead title={t("regulator.title")} sub={t("regulator.subtitle")} />
      <Loaded state={state}>{(d) => {
        const max = Math.max(1, ...d.lines.map((l) => l.trips_7d));
        return (
          <>
            <div className="grid cols-4">
              <Stat icon="apartment" label={t("regulator.carriers")} value={num(d.carriers)} />
              <Stat icon="history" label={t("regulator.pending")} value={num(d.carriers_pending)} tone="wheat" />
              <Stat icon="block" label={t("regulator.blockedVehicles")} value={num(d.blocked_vehicles)} tone="red" />
              <Stat icon="schedule" label={t("regulator.onTime")} value={d.on_time_pct == null ? <span style={{ fontSize: 16 }}>{t("regulator.noOnTime")}</span> : `${d.on_time_pct}%`} tone="blue" />
              <Stat icon="warning" label={t("regulator.openAlerts")} value={num(d.open_alerts)} tone="red" />
              <Stat icon="support_agent" label={t("regulator.openCases")} value={num(d.open_cases)} tone="wheat" />
              <Stat icon="account_balance_wallet" label={t("regulator.customerFunds")} value={money(d.customer_funds)} />
              <Stat icon="lock" label={t("regulator.escrow")} value={money(d.escrow_funds)} tone="blue" />
            </div>
            <div className="card">
              <div className="card-title"><h3>{t("regulator.lines")}</h3></div>
              {d.lines.length === 0 ? <Empty title={t("common.noData")} /> : (
                <div className="bar-chart">
                  {d.lines.map((l) => (
                    <div key={l.origin_city + l.dest_city} className="bar-row">
                      <span>{city(l.origin_city)} {arrow} {city(l.dest_city)}</span>
                      <div className="bar-track"><div className="bar-fill" style={{ width: `${(100 * l.trips_7d) / max}%` }} /></div>
                      <span className="num small">{num(l.trips_7d)}</span>
                    </div>
                  ))}
                  <div className="table-wrap" tabIndex={0} style={{ marginTop: 12 }}><table className="table">
                    <thead><tr><th>{t("regulator.line")}</th><th className="num">{t("regulator.carriersOnLine")}</th><th className="num">{t("regulator.trips7d")}</th><th className="num">{t("regulator.tickets")}</th></tr></thead>
                    <tbody>{d.lines.map((l) => (
                      <tr key={l.origin_city + l.dest_city}><td>{city(l.origin_city)} {arrow} {city(l.dest_city)}</td><td className="num">{l.carriers}</td><td className="num">{l.trips_7d}</td><td className="num">{l.tickets}</td></tr>
                    ))}</tbody>
                  </table></div>
                </div>
              )}
            </div>
          </>
        );
      }}</Loaded>
    </div>
  );
}
