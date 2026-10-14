import { useEffect, useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api, type BookingOption, type TripDetail } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { useChannel } from "../../channel";
import { CarrierName, ErrorBox, Field, Icon, Loaded, Spinner, useLoad } from "../../components/ui";
import { PassengerFields, blankPassenger, documentFor, namesFor, passengerValid, type PassengerDraft, type TravelDocs } from "./PassengerFields";
import { parseLegs, parsePicked, type JourneyKind } from "./journeyLinks";

// A journey booked in one go (owner's request, October 2026; migration 1121): one way, a round trip or several places
// one after the other, chosen trip by trip on the results page and checked out here: the same travellers on every
// trip, seats given side by side, paid at once from the wallet (or reserved to pay at the counter where the platform
// opened it). An agency books a group here too, split into bookings of four seats. Each trip becomes its own booking,
// all of the same journey; nothing is booked unless every trip is.

interface JourneyOut {
  journey_uid: string; kind: JourneyKind; status: string; replayed?: boolean;
  bookings: { leg: number; booking_ref: string; total: number; currency: string; status: string; pay_by?: string | null }[];
  totals: { currency: string; total: number }[];
}

export default function Journey() {
  const { t, time, date, station, money, currency } = useI18n();
  const { me } = useAuth();
  const ch = useChannel();
  const [params] = useSearchParams();
  const kind = (params.get("kind") ?? "ROUND_TRIP") as JourneyKind;
  const legs = parseLegs(params.get("legs"));
  const picked = parsePicked(params.get("picked"));
  const pax = Math.max(1, Number(params.get("pax") ?? 1));
  const trips = useLoad(() => Promise.all(picked.map((p) => api.get<TripDetail>(`/api/trips/${p.uid}`, { from_seq: p.from, to_seq: p.to }))),
    [params.get("picked")]);
  const countries = useLoad(() => api.get<{ countries: string[] }>("/api/ref").then((r) => r.countries));
  const options = useLoad<BookingOption[]>(() => (ch.agency || !me ? Promise.resolve([])
    : api.get<{ options: BookingOption[] }>("/api/payments/booking-options").then((r) => r.options)), [me, ch.agency]);
  const [people, setPeople] = useState<PassengerDraft[]>(() => Array.from({ length: pax }, () => blankPassenger()));
  const [docs, setDocs] = useState<Record<string, TravelDocs>>({});
  const [payWith, setPayWith] = useState<"WALLET" | "PAY_LATER">("WALLET");
  const [contact, setContact] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [done, setDone] = useState<JourneyOut | null>(null);
  const [key] = useState(() => crypto.randomUUID().replace(/-/g, ""));

  // the documents each nationality needs: those of the first international trip of the journey, where there is one
  const nationalities = useMemo(() => [...new Set(["SY", ...people.map((p) => p.nationality)])], [people]);
  useEffect(() => {
    if (!trips.data) return;
    const missing = nationalities.filter((n) => !docs[n]);
    if (missing.length === 0) return;
    Promise.all(missing.map(async (n) => {
      const all = await Promise.all(picked.map((p) => api.get<TravelDocs>(`/api/trips/${p.uid}/documents`, { from_seq: p.from, to_seq: p.to, nationality: n })));
      return [n, all.find((d) => d.international) ?? all[0]] as const;
    })).then((rows) => setDocs((d) => ({ ...d, ...Object.fromEntries(rows) }))).catch(() => undefined);
  }, [trips.data, nationalities.join(",")]);   // eslint-disable-line react-hooks/exhaustive-deps

  if (legs.length === 0 || picked.length !== legs.length) {
    return <div className="page"><div className="card"><ErrorBox error={{ message: t("jrn.incomplete") }} /></div></div>;
  }
  const docsKnown = nationalities.every((n) => docs[n]);
  const valid = docsKnown && people.every((p) => passengerValid(p, docs[p.nationality])) && (!ch.agency || /^\+?[0-9]{8,15}$/.test(contact.trim()));
  const payLater = options.data?.some((o) => o.code === "PAY_LATER");

  const book = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<JourneyOut>(ch.agency ? "/api/agency/journeys" : "/api/journeys", {
        kind, legs: picked.map((p) => ({ trip_uid: p.uid, from_seq: p.from, to_seq: p.to })),
        passengers: people.map((p) => ({ ...namesFor(p), ...documentFor(p, docs[p.nationality]), birth_date: p.birth_date || undefined })),
        idempotency_key: key, ...(ch.agency ? { contact_mobile: contact.trim() } : { pay_with: payWith }),
      });
      setDone(out);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (done) return (
    <div className={ch.staff ? "stack" : "page stack"}>
      <div className="card stack">
        <div className="row" style={{ gap: 10 }}><Icon name="check_circle" /><h2 style={{ margin: 0 }}>{t(done.status === "CONFIRMED" ? "jrn.booked" : "jrn.reserved")}</h2></div>
        <p className="muted" style={{ margin: 0 }}>{t(`jrn.kindDone.${done.kind}`, { n: done.bookings.length })}</p>
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("jrn.leg")}</th><th>{t("jrn.ref")}</th><th className="num">{t("common.total")}</th><th>{t("common.status")}</th></tr></thead>
          <tbody>{done.bookings.map((b) => (
            <tr key={b.booking_ref}><td>{t("jrn.legN", { n: b.leg })}</td>
              <td><Link className="mono" to={ch.link(`/booking/${b.booking_ref}`)}>{b.booking_ref}</Link></td>
              <td className="num">{money(b.total, false, b.currency)} {currency(b.currency)}</td><td>{t(`status.${b.status}`)}</td></tr>
          ))}</tbody>
        </table></div>
        <div className="row" style={{ gap: 16, flexWrap: "wrap" }}>
          {done.totals.map((x) => <strong key={x.currency}>{t("jrn.total")}: {money(x.total, false, x.currency)} {currency(x.currency)}</strong>)}
        </div>
      </div>
    </div>
  );

  return (
    <div className={ch.staff ? "stack" : "page stack"}>
      <div className="row between"><div>
        <h2 style={{ margin: 0 }}>{t(`jrn.title.${kind}`)}</h2>
        <p className="muted" style={{ margin: 0 }}>{t("jrn.sub", { n: legs.length, pax })}</p>
      </div></div>
      <Loaded state={trips}>{(details) => {
        const sums: Record<string, number> = {};
        details.forEach((d) => { sums[d.trip.currency] = (sums[d.trip.currency] ?? 0) + d.price * pax; });
        return (
          <>
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("jrn.trips")}</h3>
              {details.map((d, i) => {
                const a = d.stops.find((s) => s.seq === d.from_seq)!, b = d.stops.find((s) => s.seq === d.to_seq)!;
                const stops = d.stops.filter((s) => s.seq > d.from_seq && s.seq < d.to_seq && s.kind === "STATION").length;
                return (
                  <div key={d.trip.uid} className="journey-leg">
                    <span className="chip blue">{t("jrn.legN", { n: i + 1 })}</span>
                    <div className="grow stack tight">
                      <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                        <strong>{station(a.station_code, a.station_name)} → {station(b.station_code, b.station_name)}</strong>
                        <span className="chip outline mono">{d.trip.trip_code ?? d.trip.trip_no}</span>
                        <span className={`chip ${stops === 0 ? "green" : ""}`}>{stops === 0 ? t("results.direct") : t("results.stops", { n: stops })}</span>
                      </div>
                      <span className="small muted">
                        {date(a.sched_dep, { weekday: "long", day: "numeric", month: "long" })} · {time(a.sched_dep)} → {time(b.sched_arr)} · <CarrierName name={d.trip.carrier_name} uid={d.trip.carrier_uid} logo={d.trip.carrier_logo} />
                      </span>
                    </div>
                    <span className="text-nowrap">{money(d.price, false, d.trip.currency)} {currency(d.trip.currency)} × {pax}</span>
                  </div>
                );
              })}
              <div className="row between"><span className="muted small">{t("jrn.fareNote")}</span>
                <strong>{Object.entries(sums).map(([c, v]) => `${money(v, false, c)} ${currency(c)}`).join(" + ")}</strong></div>
            </div>
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("jrn.travellers", { n: pax })}</h3>
              <p className="small muted" style={{ margin: 0 }}>{t("jrn.travellersHint")}</p>
              {people.map((p, i) => (
                <fieldset key={i} className="stack" style={{ border: 0, padding: 0, margin: 0 }}>
                  <legend className="small"><strong>{t("common.passenger")} {i + 1}</strong></legend>
                  <PassengerFields value={p} countries={countries.data ?? ["SY"]} docs={docs[p.nationality]} bands={details[0].categories}
                                   travel={details[0].stops.find((s) => s.seq === details[0].from_seq)?.sched_dep.slice(0, 10)}
                                   onChange={(v) => setPeople((all) => all.map((x, j) => (j === i ? v : x)))} />
                </fieldset>
              ))}
            </div>
            <div className="card stack">
              {ch.agency ? (
                <Field label={t("jrn.contact")} hint={t("jrn.contactHint")}>
                  <input className="input ltr" value={contact} onChange={(e) => setContact(e.target.value)} inputMode="tel" />
                </Field>
              ) : (
                <div className="stack tight" role="radiogroup" aria-label={t("jrn.pay")}>
                  <strong>{t("jrn.pay")}</strong>
                  <label className="check"><input type="radio" checked={payWith === "WALLET"} onChange={() => setPayWith("WALLET")} />{t("jrn.payWallet")}</label>
                  {payLater && <label className="check"><input type="radio" checked={payWith === "PAY_LATER"} onChange={() => setPayWith("PAY_LATER")} />{t("jrn.payLater")}</label>}
                </div>
              )}
              <p className="small muted" style={{ margin: 0 }}>{t("jrn.allOrNothing")}</p>
              <ErrorBox error={error} />
              <button className="btn large" disabled={!valid || busy} onClick={book}>{busy ? <Spinner /> : <Icon name="check" />}{t("jrn.book", { n: legs.length })}</button>
            </div>
          </>
        );
      }}</Loaded>
    </div>
  );
}
