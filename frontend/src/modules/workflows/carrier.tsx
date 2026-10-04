import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

interface MarketLoad {
  uid: string; cargo_category: string; cargo_description: string; declared_weight_kg: number; packages: number | null;
  required_trailer_type: string | null; pickup_from: string; pickup_to: string; target_price: number | null; origin: string; destination: string; origin_code: string; destination_code: string;
  bids: number; my_bid: { id: number; price: number; status: string; valid_until: string } | null;
}

/** Carrier side of the freight marketplace: open loads, with one bid per company. */
export function FreightMarket() {
  const { t, money, dateTime, station, num, has } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ requests: MarketLoad[]; trucks: { id: number; plate_no: string }[] }>("/api/w/freight/market"));
  const [pick, setPick] = useState<MarketLoad | null>(null);
  const [price, setPrice] = useState("");
  const [hours, setHours] = useState("48");
  const [truck, setTruck] = useState("");
  const [error, setError] = useState<unknown>(null);
  const bid = async () => {
    if (!pick) return;
    setError(null);
    try {
      await api.post(`/api/w/freight/requests/${pick.uid}/bid`, { price: Math.round(Number(price) * 100), valid_hours: Number(hours),
                                                                  truck_vehicle_id: truck ? Number(truck) : null });
      toast(t("wf.market.done")); setPick(null); state.reload();
    } catch (e) { setError(e); }
  };
  const withdraw = async (id: number) => {
    try { await api.post(`/api/w/freight/bids/${id}/withdraw`); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <div className="row between"><h3>{t("wf.market.title")}</h3><button className="icon-btn" onClick={() => state.reload()} title={t("common.refresh")}><Icon name="refresh" /></button></div>
      <ErrorBox error={!pick ? error : null} />
      <Loaded state={state}>{(d) => d.requests.length === 0 ? <Empty icon="local_shipping" title={t("wf.market.none")} /> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("wf.market.route")}</th><th>{t("wf.load.description")}</th><th>{t("wf.load.weight")}</th><th>{t("wf.load.pickupFrom")}</th>
            <th>{t("wf.load.target")}</th><th>{t("wf.market.bids")}</th><th /></tr></thead>
          <tbody>{d.requests.map((r) => (
            <tr key={r.uid}>
              <td>{station(r.origin_code, r.origin)} → {station(r.destination_code, r.destination)}</td>
              <td><div>{r.cargo_description}</div><div className="small muted">{has(`wf.load.cat.${r.cargo_category}`) ? t(`wf.load.cat.${r.cargo_category}`) : r.cargo_category}
                {r.required_trailer_type ? ` · ${t(`val.${r.required_trailer_type}`)}` : ""}</div></td>
              <td className="num">{num(r.declared_weight_kg)} {t("wf.kg")}</td>
              <td>{dateTime(r.pickup_from)}</td>
              <td className="num">{r.target_price ? money(r.target_price) : "—"}</td>
              <td className="num">{num(r.bids)}</td>
              <td className="num">{r.my_bid ? (
                <div className="row nowrap" style={{ justifyContent: "flex-end" }}>
                  <span className="small">{money(r.my_bid.price)}</span><Status value={r.my_bid.status} />
                  {r.my_bid.status === "SUBMITTED" && <button className="btn text small" onClick={() => withdraw(r.my_bid!.id)}>{t("wf.market.withdraw")}</button>}
                </div>
              ) : <button className="btn small" onClick={() => { setPick(r); setPrice(r.target_price ? String(r.target_price / 100) : ""); setError(null); }}>{t("wf.market.bid")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {pick && (
        <Modal title={t("wf.market.bidOn", { route: `${station(pick.origin_code, pick.origin)} → ${station(pick.destination_code, pick.destination)}` })} onClose={() => setPick(null)}
               actions={<><button className="btn text" onClick={() => setPick(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={!(Number(price) > 0)} onClick={bid}>{t("wf.market.send")}</button></>}>
          <p className="muted">{pick.cargo_description} · {num(pick.declared_weight_kg)} {t("wf.kg")}</p>
          <div className="grid cols-2">
            <Field label={t("wf.market.price")}><input type="number" min="1" step="1000" value={price} onChange={(e) => setPrice(e.target.value)} autoFocus /></Field>
            <Field label={t("wf.market.validFor")}>
              <select value={hours} onChange={(e) => setHours(e.target.value)}>{[12, 24, 48, 72, 168].map((h) => <option key={h} value={h}>{t("wf.market.hours", { n: h })}</option>)}</select>
            </Field>
          </div>
          <Field label={t("wf.market.truck")} hint={t("common.optional")}>
            <select value={truck} onChange={(e) => setTruck(e.target.value)}><option value="">—</option>
              {(state.data?.trucks ?? []).map((x) => <option key={x.id} value={x.id}>{x.plate_no}</option>)}</select>
          </Field>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}
