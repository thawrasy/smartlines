import { useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { api, type TripResult } from "../../api";
import { useI18n } from "../../i18n";
import { localDate, minutesBetween } from "../../dates";
import { CarrierName, Empty, ErrorBox, Icon, Spinner, useLoad } from "../../components/ui";
import { SearchForm, useSeatLimits } from "./Home";
import { useChannel } from "../../channel";
import { useAuth } from "../../auth";
import { ConnectionOptions } from "./Connections";
import { legsParam, parseLegs, parsePicked, pickedParam, rememberTrip, rememberedTrip, type JourneyKind } from "./journeyLinks";

type Stops = "all" | "direct" | "stops";

// The trips between two cities on a day, or, for a journey (owner's request, October 2026; 1121), the trips of one of
// its legs at a time, the trips chosen so far above: a trip that leaves before the chosen one arrives cannot be chosen.
// Every list shows all trips, direct trips only, or trips with stops only. Below them, the connections through a city on
// the way (1130): at once where no trip runs, on request otherwise.
export default function Results() {
  const { t, city, money, time, date, station, duration, currency } = useI18n();
  const [params, setParams] = useSearchParams();
  const [showConn, setShowConn] = useState(false);
  const nav = useNavigate();
  const ch = useChannel();
  const { me } = useAuth();
  const legs = parseLegs(params.get("legs"));
  const journey = legs.length > 0;
  const kind = (params.get("kind") ?? (journey ? "MULTI_CITY" : "ONE_WAY")) as JourneyKind;
  const picked = journey ? parsePicked(params.get("picked")).slice(0, legs.length - 1) : [];
  const leg = journey ? legs[picked.length] : null;
  const from = leg?.from ?? params.get("from") ?? "DAM", to = leg?.to ?? params.get("to") ?? "ALP";
  const on = leg?.on ?? params.get("on") ?? localDate(1), pax = Math.max(1, Number(params.get("pax") ?? 1));
  const stops = (params.get("stops") ?? "all") as Stops;
  const res = useLoad(() => api.get<{ trips: TripResult[] }>("/api/trips/search",
    { origin: from, destination: to, on, passengers: pax, stops: stops === "all" ? undefined : stops }), [from, to, on, pax, stops]);
  const set = (patch: Record<string, string | null>) => {
    const p = new URLSearchParams(params);
    Object.entries(patch).forEach(([k, v]) => (v === null ? p.delete(k) : p.set(k, v)));
    setParams(p);
  };
  const shift = (d: number) => {
    if (!journey) return set({ on: localDate(d, on) });
    set({ legs: legsParam(legs.map((l, i) => (i === picked.length ? { ...l, on: localDate(d, on) } : l))) });
  };
  // a carrier's counter sells its own trips only (the server checks it again)
  const trips = (res.data?.trips ?? []).filter((x) => !ch.counter || x.carrier_name === me?.company?.name);
  const previous = picked.length ? rememberedTrip(picked[picked.length - 1]) : null;
  // a group larger than one booking (an agency's) checks out as a journey even on one trip
  const { perBooking } = useSeatLimits();
  const asJourney = journey || (ch.agency && pax > perBooking);

  const choose = (trip: TripResult) => {
    rememberTrip(trip);
    const next = [...picked, { uid: trip.uid, from: trip.from_seq, to: trip.to_seq }];
    const all = journey ? legs : [{ from, to, on }];
    if (next.length >= all.length) {
      nav(ch.link(`/journey?kind=${journey ? kind : "ONE_WAY"}&legs=${legsParam(all)}&picked=${pickedParam(next)}&pax=${pax}`));
    } else {
      set({ picked: pickedParam(next) });
      window.scrollTo({ top: 0 });
    }
  };
  const form = <SearchForm key={`${from}${to}${on}${pax}${params.get("legs")}`}
                           initial={{ from: legs[0]?.from ?? from, to: legs[0]?.to ?? to, on: legs[0]?.on ?? on, pax, kind, legs }} />;

  return (
    <>
      {ch.staff ? (
        <div className="card">{form}</div>
      ) : (
        <section className="hero-band">
          <div className="hero-inner" style={{ paddingBlock: 24 }}>
            <div className="card hero">{form}</div>
          </div>
        </section>
      )}
      <div className={ch.staff ? "stack" : "page stack"} style={ch.staff ? { marginTop: 16 } : undefined}>
        {journey && (
          <div className="card stack tight" aria-label={t(`home.mode.${kind}`)}>
            <div className="row" style={{ gap: 8 }}><Icon name={kind === "ROUND_TRIP" ? "swap_horiz" : "multiple_stop"} />
              <strong>{t(`home.mode.${kind}`)}</strong><span className="muted small">{t("results.legOf", { n: picked.length + 1, of: legs.length })}</span></div>
            <ol className="journey-steps">
              {legs.map((l, i) => {
                const done = i < picked.length ? rememberedTrip(picked[i]) : null;
                return (
                  <li key={i} className={i === picked.length ? "on" : i < picked.length ? "done" : ""}>
                    <span className="chip blue">{t("jrn.legN", { n: i + 1 })}</span>
                    <span><strong>{city(l.from)} → {city(l.to)}</strong>{" · "}{date(`${l.on}T12:00:00Z`, { weekday: "short", day: "numeric", month: "short" })}</span>
                    {i < picked.length && (
                      <>
                        <span className="small muted">{done ? `${done.trip_code ?? done.trip_no} · ${time(done.departs_at)} → ${time(done.arrives_at)}` : t("results.chosen")}</span>
                        <button className="btn text small" onClick={() => set({ picked: pickedParam(picked.slice(0, i)) })}>{t("results.change")}</button>
                      </>
                    )}
                  </li>
                );
              })}
            </ol>
          </div>
        )}
        <div className="row between" style={{ flexWrap: "wrap", gap: 12 }}>
          <div>
            <h2>{t("results.title", { from: city(from), to: city(to) })}</h2>
            <p className="muted">{date(`${on}T12:00:00Z`, { weekday: "long", day: "numeric", month: "long" })} · {res.loading ? "…" : t("results.count", { n: trips.length })}</p>
          </div>
          <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
            <div className="segmented" role="radiogroup" aria-label={t("results.filter.label")}>
              {(["all", "direct", "stops"] as Stops[]).map((s) => (
                <button key={s} type="button" role="radio" aria-checked={stops === s} className={stops === s ? "on" : ""}
                        onClick={() => set({ stops: s === "all" ? null : s })}>{t(`results.filter.${s}`)}</button>
              ))}
            </div>
            <button className="btn outlined small" onClick={() => shift(-1)} disabled={on <= localDate(0) || (journey && picked.length > 0 && localDate(-1, on) < legs[picked.length - 1].on)}><Icon name="arrow_back" flip />{t("results.prevDay")}</button>
            <button className="btn outlined small" onClick={() => shift(1)}>{t("results.nextDay")}<Icon name="arrow_forward" flip /></button>
          </div>
        </div>
        <ErrorBox error={res.error} />
        {res.loading ? <Spinner /> : trips.length === 0 ? (
          <div className="card"><Empty title={t("results.none")} hint={t(stops === "all" ? "results.noneHint" : "results.noneFiltered")} /></div>
        ) : trips.map((trip) => {
          const mins = minutesBetween(trip.departs_at, trip.arrives_at);
          const tooEarly = !!previous && trip.departs_at < previous.arrives_at;
          const can = trip.bookable && !tooEarly;
          return (
            <div key={trip.uid} className="card trip-card">
              <div className="stack tight">
                <div className="row" style={{ gap: 8 }}>
                  <CarrierName name={trip.carrier_name} uid={trip.carrier_uid} logo={trip.carrier_logo} strong />
                  <span className="chip outline mono" title={trip.trip_no}>{trip.trip_code ?? trip.trip_no}</span>
                  {trip.stops_between === 0 ? <span className="chip green">{t("results.direct")}</span> : <span className="chip">{t("results.stops", { n: trip.stops_between })}</span>}
                  {trip.has_rest && <span className="chip wheat"><Icon name="restaurant" size={16} />{t("results.rest")}</span>}
                  {trip.returns_as && (
                    <span className="chip outline" title={trip.returns_as.same_vehicle !== false ? t("ret.title") : t("ret.other")}>
                      <Icon name="swap_calls" size={16} />{t("ret.returnsAs", { code: trip.returns_as.trip_code ?? "", time: time(trip.returns_as.departs_at) })}
                    </span>
                  )}
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
                {tooEarly && <span className="small" style={{ color: "var(--error)" }}>{t("results.tooEarly")}</span>}
                {can && asJourney ? (
                  <button className="btn" onClick={() => choose(trip)}>{t(journey && picked.length + 1 < legs.length ? "results.chooseNext" : "results.chooseTrip")}</button>
                ) : can ? (
                  <Link className="btn" to={ch.link(`/trip/${trip.uid}?from=${trip.from_seq}&to=${trip.to_seq}&pax=${pax}`)}>{t("results.choose")}</Link>
                ) : <button className="btn" disabled>{t("results.choose")}</button>}
              </div>
            </div>
          );
        })}
        {/* connections through a city on the way (1130): offered at once where no trip runs, on request otherwise;
            a carrier's counter sells its own trips only */}
        {!journey && !ch.counter && !res.loading && (trips.length === 0 || showConn
          ? <ConnectionOptions from={from} to={to} on={on} pax={pax} />
          : <button className="btn outlined" style={{ alignSelf: "flex-start" }} onClick={() => setShowConn(true)}><Icon name="airline_stops" />{t("conn.show")}</button>)}
      </div>
    </>
  );
}
