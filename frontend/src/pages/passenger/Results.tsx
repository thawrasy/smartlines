import { Link, useSearchParams } from "react-router-dom";
import { api, type TripResult } from "../../api";
import { useI18n } from "../../i18n";
import { localDate, minutesBetween } from "../../dates";
import { Empty, ErrorBox, Icon, Spinner, useLoad } from "../../components/ui";
import { SearchForm } from "./Home";
import { useChannel } from "../../channel";
import { useAuth } from "../../auth";

export default function Results() {
  const { t, city, money, time, date, station, duration, currency } = useI18n();
  const [params, setParams] = useSearchParams();
  const ch = useChannel();
  const { me } = useAuth();
  const from = params.get("from") ?? "DAM", to = params.get("to") ?? "ALP";
  const on = params.get("on") ?? localDate(1), pax = Number(params.get("pax") ?? 1);
  const res = useLoad(() => api.get<{ trips: TripResult[] }>("/api/trips/search", { origin: from, destination: to, on, passengers: pax }), [from, to, on, pax]);
  const shift = (d: number) => { const p = new URLSearchParams(params); p.set("on", localDate(d, on)); setParams(p); };
  // a carrier's counter sells its own trips only (the server checks it again)
  const trips = (res.data?.trips ?? []).filter((x) => !ch.counter || x.carrier_name === me?.company?.name);

  return (
    <>
      {ch.staff ? (
        <div className="card"><SearchForm key={`${from}${to}${on}${pax}`} initial={{ from, to, on, pax }} /></div>
      ) : (
        <section className="hero-band">
          <div className="hero-inner" style={{ paddingBlock: 24 }}>
            <div className="card hero"><SearchForm key={`${from}${to}${on}${pax}`} initial={{ from, to, on, pax }} /></div>
          </div>
        </section>
      )}
      <div className={ch.staff ? "stack" : "page stack"} style={ch.staff ? { marginTop: 16 } : undefined}>
        <div className="row between">
          <div>
            <h2>{t("results.title", { from: city(from), to: city(to) })}</h2>
            <p className="muted">{date(`${on}T12:00:00Z`, { weekday: "long", day: "numeric", month: "long" })} · {res.loading ? "…" : t("results.count", { n: trips.length })}</p>
          </div>
          <div className="row" style={{ gap: 8 }}>
            <button className="btn outlined small" onClick={() => shift(-1)} disabled={on <= localDate(0)}><Icon name="arrow_back" flip />{t("results.prevDay")}</button>
            <button className="btn outlined small" onClick={() => shift(1)}>{t("results.nextDay")}<Icon name="arrow_forward" flip /></button>
          </div>
        </div>
        <ErrorBox error={res.error} />
        {res.loading ? <Spinner /> : trips.length === 0 ? (
          <div className="card"><Empty title={t("results.none")} hint={t("results.noneHint")} /></div>
        ) : trips.map((trip) => {
          const mins = minutesBetween(trip.departs_at, trip.arrives_at);
          return (
            <div key={trip.uid} className="card trip-card">
              <div className="stack tight">
                <div className="row" style={{ gap: 8 }}>
                  <span style={{ fontWeight: 600 }}>{trip.carrier_name}</span>
                  <span className="chip outline mono">{trip.trip_no}</span>
                  {trip.stops_between === 0 ? <span className="chip green">{t("results.direct")}</span> : <span className="chip">{t("results.stops", { n: trip.stops_between })}</span>}
                  {trip.has_rest && <span className="chip wheat"><Icon name="restaurant" size={16} />{t("results.rest")}</span>}
                </div>
                <div className="timeline" style={{ marginTop: 18 }}>
                  <div><div className="time">{time(trip.departs_at)}</div><div className="small muted">{station(trip.from_code, trip.from_station)}</div></div>
                  <div className="line"><span className="dur">{duration(mins)}</span></div>
                  <div style={{ textAlign: "end" }}><div className="time">{time(trip.arrives_at)}</div><div className="small muted">{station(trip.to_code, trip.to_station)}</div></div>
                </div>
              </div>
              <div className="stack tight" style={{ alignItems: "flex-end", minWidth: 190 }}>
                <div className="price">{money(trip.price, false, trip.currency)} <small>{currency(trip.currency)}</small></div>
                <span className="small muted">{t("results.perPassenger")}</span>
                <span className={`small ${trip.seats_left < 6 ? "" : "muted"}`} style={trip.seats_left < 6 ? { color: "var(--error)" } : undefined}>
                  <Icon name="event_seat" size={16} /> {trip.bookable ? t("results.seatsLeft", { n: trip.seats_left }) : t("results.soldOut")}
                </span>
                {trip.bookable ? (
                  <Link className="btn" to={ch.link(`/trip/${trip.uid}?from=${trip.from_seq}&to=${trip.to_seq}&pax=${pax}`)}>{t("results.choose")}</Link>
                ) : <button className="btn" disabled>{t("results.choose")}</button>}
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}
