import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, useLoad, useToast } from "../../components/ui";

type Order = "TOTAL" | "MEAN" | "CALLS" | "READS";
interface Statement {
  queryid: string; role_name: string | null; calls: number; total_ms: number; mean_ms: number; max_ms: number; rows: number;
  shared_blks_read: number; hit_ratio: number | null; query: string;
}
const ORDERS: Order[] = ["TOTAL", "MEAN", "CALLS", "READS"];

/** The statements that cost the database most (pg_stat_statements, 1077), to choose indexes from measurements. */
export default function Statements() {
  const { t, num } = useI18n();
  const toast = useToast();
  const [order, setOrder] = useState<Order>("TOTAL");
  const [minCalls, setMinCalls] = useState(1);
  const [error, setError] = useState<unknown>(null);
  const state = useLoad((signal) => api.get<{ enabled: boolean; statements: Statement[] }>(
    "/api/security/statements", { order, min_calls: minCalls, limit: 50 }, { signal }), [order, minCalls]);
  const ms = (v: number) => num(Math.round(v * 10) / 10);
  const reset = async () => {
    if (!window.confirm(t("security.stmt.resetConfirm"))) return;
    setError(null);
    try { await api.post("/api/security/statements/reset", {}); toast(t("security.stmt.resetDone")); state.reload(); }
    catch (e) { setError(e); }
  };

  return (
    <div className="stack">
      <PageHead title={t("security.stmt.title")} sub={t("security.stmt.sub")}>
        <button className="btn outlined" onClick={state.reload}><Icon name="refresh" />{t("common.refresh")}</button>
        <button className="btn outlined" onClick={reset}><Icon name="autorenew" />{t("security.stmt.reset")}</button>
      </PageHead>
      <ErrorBox error={error} />
      <div className="grid cols-2">
        <Field label={t("security.stmt.order")}>
          <select className="input" value={order} onChange={(e) => setOrder(e.target.value as Order)}>
            {ORDERS.map((o) => <option key={o} value={o}>{t(`security.stmt.orders.${o}`)}</option>)}
          </select>
        </Field>
        <Field label={t("security.stmt.minCalls")}>
          <input className="input" type="number" min={1} value={minCalls} onChange={(e) => setMinCalls(Math.max(1, Number(e.target.value) || 1))} />
        </Field>
      </div>
      <Loaded state={state}>{({ enabled, statements }) => !enabled ? (
        <Empty icon="monitoring" title={t("security.stmt.off")} hint={t("security.stmt.offHint")} />
      ) : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("security.stmt.calls")}</th><th>{t("security.stmt.total")}</th><th>{t("security.stmt.mean")}</th>
            <th>{t("security.stmt.max")}</th><th>{t("security.stmt.reads")}</th><th>{t("security.stmt.hit")}</th><th>{t("security.stmt.text")}</th></tr></thead>
          <tbody>{statements.map((s) => (
            <tr key={s.queryid}><td>{num(s.calls)}</td><td>{ms(s.total_ms)}</td><td>{ms(s.mean_ms)}</td><td>{ms(s.max_ms)}</td>
              <td>{num(s.shared_blks_read)}</td><td>{s.hit_ratio == null ? "—" : `${num(Math.round(s.hit_ratio * 1000) / 10)}%`}</td>
              <td className="mono small ltr" style={{ maxWidth: 560, whiteSpace: "pre-wrap", wordBreak: "break-word" }}>{s.query}</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}
