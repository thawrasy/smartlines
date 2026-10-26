import { Link } from "react-router-dom";
import { useI18n } from "../i18n";
import { useChannel } from "../channel";
import { Icon } from "./ui";

// The return on the same vehicle (owner's decision, 1119): the trip that continues the traveller's on its day, the way
// back from where they get off to where they got on. The vehicle is the one planned for both; it may be replaced on the
// day, and the numbers stay.
export interface ReturnInfo {
  uid: string; trip_code: string | null; trip_no: string; from_seq: number; to_seq: number; departs_at: string; arrives_at: string;
  from_station: string; from_code: string; to_station: string; to_code: string; on_sale: boolean; same_vehicle: boolean | null;
}

export function ReturnTrip({ r, pax, journey }: { r: ReturnInfo; pax: number; journey?: string }) {
  const { t, time, date, station } = useI18n();
  const ch = useChannel();
  const same = r.same_vehicle !== false;
  return (
    <div className="card stack tight">
      <div className="row" style={{ gap: 8 }}><Icon name="swap_calls" /><h3 style={{ margin: 0 }}>{t(same ? "ret.title" : "ret.other")}</h3></div>
      <div>
        <span className="mono" style={{ fontWeight: 700 }}>{r.trip_code ?? r.trip_no}</span>
        {" · "}{date(r.departs_at, { weekday: "long", day: "numeric", month: "long" })} {time(r.departs_at)}
        {" · "}{station(r.from_code, r.from_station)} → {station(r.to_code, r.to_station)}
      </div>
      {same && <p className="small muted" style={{ margin: 0 }}>{t("ret.planned")}</p>}
      {r.on_sale ? (
        <Link className="btn tonal" style={{ alignSelf: "flex-start" }}
              to={ch.link(`/trip/${r.uid}?from=${r.from_seq}&to=${r.to_seq}&pax=${pax}${journey ? `&journey=${journey}` : ""}`)}>
          <Icon name="add" />{t("ret.book")}</Link>
      ) : <span className="small muted">{t("ret.closed")}</span>}
    </div>
  );
}
