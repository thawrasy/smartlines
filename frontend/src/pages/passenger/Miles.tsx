import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Loaded, useLoad } from "../../components/ui";

// The miles programme for members (owner's note 19, migration 1166): the partners corner, with promoted partners
// labelled, and the award tickets, shown and redeemed only once the platform turns redemption on.

interface Corner { promoted_display: boolean; partners: { id: number; name: string; partner_type: string; corner_note: string | null; promoted: boolean;
  points: number | null; amount: number | null; currency: string | null }[] }
interface Awards { redeemable: boolean; awards: { uid: string; from_code: string; from_name: string; to_code: string; to_name: string; miles: number;
  fee: number; reduced_amount: number; currency: string; carrier: string | null }[] }

export function MilesCorner() {
  const { t, money, station, num } = useI18n();
  const corner = useLoad((signal) => api.get<Corner>("/api/loyalty/corner", undefined, { signal }).catch(() => ({ promoted_display: false, partners: [] })));
  const awards = useLoad((signal) => api.get<Awards>("/api/loyalty/awards", undefined, { signal }).catch(() => ({ redeemable: false, awards: [] })));
  return (
    <>
      <Loaded state={corner}>{(c) => c.partners.length === 0 ? null : (
        <div className="card stack">
          <h3 style={{ margin: 0 }}>{t("miles.corner")}</h3>
          <div className="grid cols-2">{c.partners.map((p) => (
            <div key={p.id} className="card stack tight" style={{ boxShadow: "none" }}>
              <div className="row between"><strong>{p.name}</strong>
                {p.promoted && <span className="chip wheat">{t("miles.promoted")}</span>}</div>
              <span className="small muted">{t(`miles.type.${p.partner_type}`)}</span>
              {p.corner_note && <span className="small">{p.corner_note}</span>}
              {p.points != null && p.amount != null && <span className="small">{t("miles.rate", { points: num(p.points), amount: money(p.amount) })}</span>}
            </div>
          ))}</div>
        </div>
      )}</Loaded>
      <Loaded state={awards}>{(a) => a.awards.length === 0 ? null : (
        <div className="card stack">
          <h3 style={{ margin: 0 }}>{t("miles.awards")}</h3>
          {!a.redeemable && <p className="small muted" style={{ margin: 0 }}>{t("miles.awardsSoon")}</p>}
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("miles.trip")}</th><th>{t("miles.miles")}</th><th>{t("miles.fee")}</th><th>{t("miles.reduced")}</th></tr></thead>
            <tbody>{a.awards.map((x) => (
              <tr key={x.uid}><td>{station(x.from_code, x.from_name)} – {station(x.to_code, x.to_name)}{x.carrier && <div className="small muted">{x.carrier}</div>}</td>
                <td className="mono">{num(x.miles)}</td><td className="mono">{money(x.fee)}</td><td className="mono">{money(x.reduced_amount)}</td></tr>
            ))}</tbody>
          </table></div>
        </div>
      )}</Loaded>
    </>
  );
}
