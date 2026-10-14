import { useMemo, useState } from "react";
import { api, newKey, type TripResult } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";
import { localDate } from "../../dates";
import { useCities } from "../passenger/Home";

// Charter (owner's request, October 2026; migration 1123). A carrier hires out a vehicle apart from its trips (a coach,
// a minibus, a van) or its scheduled trips whole or in blocks of seats, to tourism companies and, by special request, to
// travellers, on its own terms. The customer asks; the carrier prices; the customer pays into escrow; the carrier is paid
// once the service is done, less the platform's commission. Amounts are entered in whole units and kept in minor units.

type Kind = "VEHICLE" | "WHOLE_TRIP";
type Basis = "PER_DAY" | "PER_KM" | "PER_TRIP" | "PER_SEAT" | "ON_REQUEST";
type Audience = "AGENCY" | "PASSENGER";
const VEHICLES = ["COACH", "MINIBUS", "VAN", "CITY_BUS"] as const;

export interface Offer {
  uid: string; kind: Kind; title: string; vehicle_type: string | null; seats: number | null; vehicles: number; partial_seats: boolean;
  min_seats: number | null; audience: Audience[]; price_basis: Basis; price: number | null; currency: string; notice_hours: number;
  cancel_before_hours: number; cancel_refund_pct: number; with_driver: boolean; policy: string; status: string; base_city: string | null;
  carrier_name: string; carrier_uid: string; carrier_logo: string | null;
}
interface Terms { title: string; price_basis: Basis; price: number | null; currency: string; cancel_before_hours: number; cancel_refund_pct: number; policy: string }
export interface CharterRequest {
  uid: string; ref: string; kind: Kind; status: string; requester_kind: Audience; contact_name: string; contact_mobile: string;
  note: string | null; created_at: string; starts_at: string | null; ends_at: string | null; passengers: number | null; vehicles: number | null;
  itinerary: string | null; from_city: string | null; to_city: string | null; trip_uid: string | null; trip_no: string | null;
  trip_code: string | null; seats: number | null; whole: boolean | null; trip_departs_at: string | null; trip_from: string | null;
  trip_to: string | null; price: number | null; currency: string | null; valid_until: string | null; quote_note: string | null;
  paid_at: string | null; refunded_amount: number | null; closed_reason: string | null; vehicle_plate: string | null;
  terms: Terms; carrier_name: string; carrier_uid: string; carrier_logo: string | null; agency_name: string | null;
  seats_held: number; estimate: number | null;
}

const toMinor = (v: string | number) => Math.round(Number(v || 0) * 100);
const iso = (local: string) => (local ? new Date(local).toISOString() : "");

/** What the request is for, in one line. */
function What({ r }: { r: CharterRequest }) {
  const { t, city, date, time } = useI18n();
  if (r.kind === "VEHICLE") {
    return (
      <span className="stack tight">
        <strong>{city(r.from_city ?? "")} → {city(r.to_city ?? "")}</strong>
        <span className="small muted">{r.starts_at && `${date(r.starts_at, { day: "numeric", month: "short" })} ${time(r.starts_at)}`} → {r.ends_at && `${date(r.ends_at, { day: "numeric", month: "short" })} ${time(r.ends_at)}`} · {t("chr.paxN", { n: r.passengers ?? 0 })} · {t("chr.vehiclesN", { n: r.vehicles ?? 1 })}</span>
      </span>
    );
  }
  return (
    <span className="stack tight">
      <strong><span className="chip outline mono">{r.trip_code ?? r.trip_no}</span> {r.whole ? t("chr.wholeTrip") : t("chr.blockOf", { n: r.seats ?? 0 })}</strong>
      <span className="small muted">{r.trip_departs_at && `${date(r.trip_departs_at, { weekday: "short", day: "numeric", month: "short" })} ${time(r.trip_departs_at)}`}{r.seats_held ? ` · ${t("chr.held", { n: r.seats_held })}` : ""}</span>
    </span>
  );
}

function Price({ r }: { r: CharterRequest }) {
  const { t, money } = useI18n();
  if (r.price != null && r.currency) return <strong className="text-nowrap">{money(r.price, true, r.currency)}</strong>;
  if (r.estimate != null) return <span className="muted text-nowrap" title={t("chr.estimateHint")}>≈ {money(r.estimate, true, r.terms.currency)}</span>;
  return <span className="muted">{t("chr.onRequest")}</span>;
}

/** The offer's price as the carrier states it. */
function OfferPrice({ o }: { o: Pick<Offer, "price" | "price_basis" | "currency"> }) {
  const { t, money } = useI18n();
  if (o.price == null) return <span>{t("chr.basis.ON_REQUEST")}</span>;
  return <span>{money(o.price, true, o.currency)} <span className="muted small">{t(`chr.basisPer.${o.price_basis}`)}</span></span>;
}

function Refunds({ o }: { o: { cancel_before_hours: number; cancel_refund_pct: number } }) {
  const { t } = useI18n();
  return <span className="small muted">{t("chr.refundRule", { pct: o.cancel_refund_pct, h: o.cancel_before_hours })}</span>;
}

// ------------------------------------------------------------------ the customer: a tourism company or a traveller
type Who = "agency" | "traveller";
interface CustomerCalls {
  offers: (kind: Kind | "", signal: AbortSignal) => Promise<{ offers: Offer[] }>;
  requests: (signal: AbortSignal) => Promise<{ requests: CharterRequest[] }>;
  ask: (body: unknown) => Promise<unknown>;
  act: (uid: string, what: "accept" | "withdraw" | "cancel", body?: unknown) => Promise<unknown>;
  travellers: (uid: string) => Promise<Travellers>;
  name: (uid: string, body: unknown) => Promise<Travellers>;
  unname: (uid: string, ticket: string) => Promise<Travellers>;
}
// each channel's own addresses, written out in full
const CALLS: Record<Who, CustomerCalls> = {
  agency: {
    offers: (kind, signal) => api.get("/api/agency/charter/offers", kind ? { kind } : undefined, { signal }),
    requests: (signal) => api.get("/api/agency/charter/requests", undefined, { signal }),
    ask: (body) => api.post("/api/agency/charter/requests", body),
    act: (uid, what, body) => api.post(`/api/agency/charter/requests/${uid}/${what}`, body),
    travellers: (uid) => api.get(`/api/agency/charter/requests/${uid}/travellers`),
    name: (uid, body) => api.post(`/api/agency/charter/requests/${uid}/travellers`, body),
    unname: (uid, ticket) => api.del(`/api/agency/charter/requests/${uid}/travellers/${ticket}`),
  },
  traveller: {
    offers: (kind, signal) => api.get("/api/charter/offers", kind ? { kind } : undefined, { signal }),
    requests: (signal) => api.get("/api/charter/requests", undefined, { signal }),
    ask: (body) => api.post("/api/charter/requests", body),
    act: (uid, what, body) => api.post(`/api/charter/requests/${uid}/${what}`, body),
    travellers: (uid) => api.get(`/api/charter/requests/${uid}/travellers`),
    name: (uid, body) => api.post(`/api/charter/requests/${uid}/travellers`, body),
    unname: (uid, ticket) => api.del(`/api/charter/requests/${uid}/travellers/${ticket}`),
  },
};

/** Offers and requests of a customer: a tourism company (its portal) or a traveller (the website). */
export function CustomerCharter({ who }: { who: Who }) {
  const calls = CALLS[who];
  const { t } = useI18n();
  const [tab, setTab] = useState<"offers" | "requests">("offers");
  const [kind, setKind] = useState<Kind | "">("");
  const offers = useLoad((signal) => calls.offers(kind, signal), [kind]);
  const requests = useLoad((signal) => calls.requests(signal));
  const [asking, setAsking] = useState<Offer | null>(null);
  const agency = who === "agency";
  return (
    <div className={agency ? "stack" : "page stack"}>
      <PageHead title={t("chr.title")} sub={t(agency ? "chr.subAgency" : "chr.subTraveller")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start" }}>
        {(["offers", "requests"] as const).map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>
            {t(`chr.tab.${v}`)}{v === "requests" && requests.data ? ` (${requests.data.requests.length})` : ""}
          </button>
        ))}
      </div>
      {tab === "offers" ? (
        <>
          <div className="segmented" role="radiogroup" aria-label={t("chr.kindLabel")} style={{ alignSelf: "flex-start" }}>
            {(["", "VEHICLE", "WHOLE_TRIP"] as const).map((k) => (
              <button key={k || "all"} role="radio" aria-checked={kind === k} className={kind === k ? "on" : ""} onClick={() => setKind(k)}>
                {t(k ? `chr.kind.${k}` : "chr.kindAll")}
              </button>
            ))}
          </div>
          <Loaded state={offers}>{(d) => d.offers.length === 0 ? (
            <div className="card"><Empty icon="airport_shuttle" title={t("chr.noOffers")} hint={t("chr.noOffersHint")} /></div>
          ) : (
            <div className="grid cols-2">
              {d.offers.map((o) => (
                <div key={o.uid} className="card stack">
                  <div className="row between" style={{ gap: 8, flexWrap: "wrap" }}>
                    <CarrierName name={o.carrier_name} uid={o.carrier_uid} logo={o.carrier_logo} strong />
                    <span className="chip blue"><Icon name={o.kind === "VEHICLE" ? "airport_shuttle" : "directions_bus"} size={16} />{t(`chr.kind.${o.kind}`)}</span>
                  </div>
                  <h3 style={{ margin: 0 }}>{o.title}</h3>
                  <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                    {o.vehicle_type && <span className="chip">{t(`chr.vehicle.${o.vehicle_type}`)} · {t("chr.seatsN", { n: o.seats ?? 0 })}</span>}
                    {o.kind === "VEHICLE" && o.vehicles > 1 && <span className="chip">{t("chr.vehiclesN", { n: o.vehicles })}</span>}
                    {o.kind === "WHOLE_TRIP" && <span className="chip">{o.partial_seats ? t("chr.blocksFrom", { n: o.min_seats ?? 1 }) : t("chr.wholeOnly")}</span>}
                    {o.with_driver && <span className="chip green">{t("chr.withDriver")}</span>}
                    {o.notice_hours > 0 && <span className="chip outline">{t("chr.notice", { h: o.notice_hours })}</span>}
                  </div>
                  <OfferPrice o={o} />
                  <Refunds o={o} />
                  <details><summary className="small">{t("chr.policy")}</summary><p className="small" style={{ whiteSpace: "pre-wrap" }}>{o.policy}</p></details>
                  <button className="btn" style={{ alignSelf: "flex-start" }} onClick={() => setAsking(o)}><Icon name="request_quote" />{t("chr.ask")}</button>
                </div>
              ))}
            </div>
          )}</Loaded>
        </>
      ) : (
        <CustomerRequests calls={calls} state={requests} />
      )}
      {asking && <AskModal calls={calls} offer={asking} onClose={() => setAsking(null)} onDone={() => { setAsking(null); requests.reload(); setTab("requests"); }} />}
    </div>
  );
}

function AskModal({ calls, offer, onClose, onDone }: { calls: CustomerCalls; offer: Offer; onClose: () => void; onDone: () => void }) {
  const { t, money, time, station } = useI18n();
  const toast = useToast();
  const { me } = useAuth();
  const cities = useCities();
  const [key] = useState(newKey);
  const [f, setF] = useState({
    contact_name: me?.portal === "PASSENGER" ? me.name : "", contact_mobile: "", note: "", from_city: offer.base_city ?? "DAM", to_city: "",
    starts: "", ends: "", passengers: 1, vehicles: 1, itinerary: "", on: localDate(Math.max(1, Math.ceil(offer.notice_hours / 24))),
    whole: !offer.partial_seats, seats: offer.min_seats ?? 1,
  });
  const [trip, setTrip] = useState<TripResult | null>(null);
  const [trips, setTrips] = useState<TripResult[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const set = (patch: Partial<typeof f>) => setF((x) => ({ ...x, ...patch }));
  const vehicle = offer.kind === "VEHICLE";
  const days = f.starts && f.ends ? Math.max(1, Math.ceil((new Date(f.ends).getTime() - new Date(f.starts).getTime()) / 86400000)) : 1;
  const estimate = offer.price == null || offer.price_basis === "PER_KM" ? null
    : vehicle ? offer.price * f.vehicles * (offer.price_basis === "PER_DAY" ? days : 1)
    : offer.price_basis === "PER_SEAT" ? offer.price * (f.whole && trip ? trip.seats_left : f.seats) : offer.price;
  const find = async () => {
    setError(null); setTrips(null); setTrip(null);
    try {
      const r = await api.get<{ trips: TripResult[] }>("/api/trips/search", { origin: f.from_city, destination: f.to_city, on: f.on });
      setTrips(r.trips.filter((x) => x.carrier_uid === offer.carrier_uid));
    } catch (e) { setError(e); }
  };
  const ok = /^\+?[0-9]{8,15}$/.test(f.contact_mobile.trim()) && f.contact_name.trim().length >= 2 && (vehicle
    ? !!f.from_city && !!f.to_city && !!f.starts && !!f.ends && f.ends > f.starts && f.passengers >= 1
    : !!trip && (f.whole || f.seats >= (offer.min_seats ?? 1)));
  const send = async () => {
    setBusy(true); setError(null);
    try {
      const common = { offer_uid: offer.uid, contact_name: f.contact_name.trim(), contact_mobile: f.contact_mobile.trim(), note: f.note.trim() || undefined, idempotency_key: key };
      await calls.ask(vehicle
        ? { ...common, from_city: f.from_city, to_city: f.to_city, starts_at: iso(f.starts), ends_at: iso(f.ends), passengers: f.passengers,
            vehicles: f.vehicles, itinerary: f.itinerary.trim() || undefined }
        : { ...common, trip_uid: trip!.uid, from_seq: trip!.from_seq, to_seq: trip!.to_seq, whole: f.whole, seats: f.whole ? undefined : f.seats });
      toast(t("chr.asked"));
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const citySelect = (value: string, onChange: (v: string) => void, label: string) => (
    <Field label={label}>
      <select className="input" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="" disabled>{t("home.selectCity")}</option>
        {cities.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
      </select>
    </Field>
  );
  return (
    <Modal title={t("chr.askTitle", { title: offer.title })} onClose={onClose} wide
           actions={<button className="btn filled" disabled={!ok || busy} onClick={send}><Icon name="send" />{t("chr.send")}</button>}>
      <div className="stack">
        <div className="row" style={{ gap: 8, flexWrap: "wrap" }}><CarrierName name={offer.carrier_name} uid={offer.carrier_uid} logo={offer.carrier_logo} /><OfferPrice o={offer} /></div>
        {vehicle ? (
          <div className="grid cols-2">
            {citySelect(f.from_city, (v) => set({ from_city: v }), t("chr.from"))}
            {citySelect(f.to_city, (v) => set({ to_city: v }), t("chr.to"))}
            <Field label={t("chr.starts")} hint={offer.notice_hours ? t("chr.notice", { h: offer.notice_hours }) : undefined}>
              <input className="input" type="datetime-local" value={f.starts} onChange={(e) => set({ starts: e.target.value })} />
            </Field>
            <Field label={t("chr.ends")}><input className="input" type="datetime-local" value={f.ends} min={f.starts} onChange={(e) => set({ ends: e.target.value })} /></Field>
            <Field label={t("chr.passengers")} hint={t("chr.seatsPer", { n: offer.seats ?? 0 })}>
              <input className="input" type="number" min={1} max={999} value={f.passengers} onChange={(e) => set({ passengers: Math.max(1, Number(e.target.value) || 1) })} />
            </Field>
            <Field label={t("chr.vehiclesAsked")} hint={t("chr.vehiclesOf", { n: offer.vehicles })}>
              <input className="input" type="number" min={1} max={offer.vehicles} value={f.vehicles} onChange={(e) => set({ vehicles: Math.min(offer.vehicles, Math.max(1, Number(e.target.value) || 1)) })} />
            </Field>
            <Field label={t("chr.itinerary")}><textarea className="input" rows={2} maxLength={1000} value={f.itinerary} onChange={(e) => set({ itinerary: e.target.value })} /></Field>
          </div>
        ) : (
          <div className="stack">
            <div className="grid cols-3">
              {citySelect(f.from_city, (v) => set({ from_city: v }), t("chr.from"))}
              {citySelect(f.to_city, (v) => set({ to_city: v }), t("chr.to"))}
              <Field label={t("chr.day")}><input className="input" type="date" value={f.on} min={localDate(0)} onChange={(e) => set({ on: e.target.value })} /></Field>
            </div>
            <button className="btn outlined" style={{ alignSelf: "flex-start" }} disabled={!f.from_city || !f.to_city || f.from_city === f.to_city} onClick={find}>
              <Icon name="search" />{t("chr.findTrips")}
            </button>
            {trips && (trips.length === 0 ? <p className="muted small">{t("chr.noTrips")}</p> : (
              <div className="stack tight" role="radiogroup" aria-label={t("chr.trip")}>
                {trips.map((x) => (
                  <label key={x.uid} className="check">
                    <input type="radio" name="charter-trip" checked={trip?.uid === x.uid} onChange={() => setTrip(x)} />
                    <span className="chip outline mono">{x.trip_code ?? x.trip_no}</span>
                    {time(x.departs_at)} {station(x.from_code, x.from_station)} → {time(x.arrives_at)} {station(x.to_code, x.to_station)}
                    <span className="muted small">· {t("results.seatsLeft", { n: x.seats_left })}</span>
                  </label>
                ))}
              </div>
            ))}
            {trip && (
              <div className="row" style={{ gap: 16, flexWrap: "wrap", alignItems: "flex-end" }}>
                <label className="check"><input type="checkbox" checked={f.whole} disabled={!offer.partial_seats} onChange={(e) => set({ whole: e.target.checked })} />{t("chr.wholeTrip")}</label>
                {!f.whole && (
                  <Field label={t("chr.seats")} hint={t("chr.blocksFrom", { n: offer.min_seats ?? 1 })}>
                    <input className="input" type="number" min={offer.min_seats ?? 1} max={trip.seats_left} value={f.seats}
                           onChange={(e) => set({ seats: Math.min(trip.seats_left, Math.max(1, Number(e.target.value) || 1)) })} />
                  </Field>
                )}
              </div>
            )}
          </div>
        )}
        <div className="grid cols-2">
          <Field label={t("chr.contactName")}><input className="input" value={f.contact_name} onChange={(e) => set({ contact_name: e.target.value })} /></Field>
          <Field label={t("chr.contactMobile")}><input className="input ltr" inputMode="tel" value={f.contact_mobile} onChange={(e) => set({ contact_mobile: e.target.value })} /></Field>
        </div>
        <Field label={t("chr.note")}><textarea className="input" rows={2} maxLength={500} value={f.note} onChange={(e) => set({ note: e.target.value })} /></Field>
        {estimate != null && <div className="alert info small"><Icon name="info" />{t("chr.estimateIs", { amount: money(estimate, true, offer.currency) })}</div>}
        <Refunds o={offer} />
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function CustomerRequests({ calls, state }: { calls: CustomerCalls; state: ReturnType<typeof useLoad<{ requests: CharterRequest[] }>> }) {
  const { t, date, time } = useI18n();
  const toast = useToast();
  const [error, setError] = useState<unknown>(null);
  const [cancelling, setCancelling] = useState<CharterRequest | null>(null);
  const [naming, setNaming] = useState<CharterRequest | null>(null);
  const [reason, setReason] = useState("");
  const act = async (r: CharterRequest, what: "accept" | "withdraw") => {
    setError(null);
    try { await calls.act(r.uid, what); toast(t(what === "accept" ? "chr.paid" : "chr.withdrawn")); state.reload(); }
    catch (e) { setError(e); }
  };
  const cancel = async () => {
    if (!cancelling) return;
    setError(null);
    try { await calls.act(cancelling.uid, "cancel", { reason }); toast(t("chr.cancelled")); setCancelling(null); state.reload(); }
    catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => d.requests.length === 0 ? <Empty icon="request_quote" title={t("chr.noRequests")} hint={t("chr.noRequestsHint")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("chr.ref")}</th><th>{t("chr.carrier")}</th><th>{t("chr.what")}</th><th>{t("common.status")}</th><th>{t("chr.price")}</th><th /></tr></thead>
          <tbody>{d.requests.map((r) => (
            <tr key={r.uid}>
              <td className="mono">{r.ref}</td>
              <td><CarrierName name={r.carrier_name} uid={r.carrier_uid} logo={r.carrier_logo} /></td>
              <td><What r={r} /></td>
              <td><Status value={r.status} />{r.status === "QUOTED" && r.valid_until && <div className="small muted">{t("chr.validUntil", { at: `${date(r.valid_until, { day: "numeric", month: "short" })} ${time(r.valid_until)}` })}</div>}</td>
              <td><Price r={r} />{r.quote_note && <div className="small muted">{r.quote_note}</div>}{r.refunded_amount != null && <div className="small">{t("chr.refunded")}</div>}</td>
              <td className="row" style={{ gap: 6, justifyContent: "flex-end" }}>
                {r.status === "QUOTED" && <button className="btn filled small" onClick={() => act(r, "accept")}><Icon name="payments" />{t("chr.acceptPay")}</button>}
                {["REQUESTED", "QUOTED"].includes(r.status) && <button className="btn text small" onClick={() => act(r, "withdraw")}>{t("chr.withdraw")}</button>}
                {r.status === "CONFIRMED" && r.kind === "WHOLE_TRIP" && <button className="btn outlined small" onClick={() => setNaming(r)}><Icon name="badge" />{t("chr.travellers")}</button>}
                {r.status === "CONFIRMED" && <button className="btn text small" onClick={() => { setCancelling(r); setReason(""); }}>{t("chr.cancel")}</button>}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {naming && <TravellersModal r={naming} load={() => calls.travellers(naming.uid)} name={(body) => calls.name(naming.uid, body)}
                                  unname={(ticket) => calls.unname(naming.uid, ticket)} onClose={() => setNaming(null)} />}
      {cancelling && (
        <Modal title={t("chr.cancelTitle", { ref: cancelling.ref })} onClose={() => setCancelling(null)}
               actions={<button className="btn filled" disabled={reason.trim().length < 3} onClick={cancel}>{t("chr.cancel")}</button>}>
          <div className="stack">
            <Refunds o={cancelling.terms} />
            <Field label={t("chr.reason")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ the travellers on a block of seats (1126)
interface Seat { seat_no: number; ticket_no: string | null; ticket_status: string | null; full_name: string | null; nationality: string | null;
  category: string | null; id_type: string | null; id_no_last4: string | null }
interface Travellers { ref: string; status: string; booking_ref: string | null; seats: Seat[]; named: number }
const PERSON = { nationality: "SY", first_name: "", father_name: "", grandfather_name: "", last_name: "", id_type: "NATIONAL_ID", id_no: "", seat_no: "" };

/** The seats a trip charter holds and who travels on each: named by the customer, read by the carrier. Each name is a
 * ticket of the trip, on its manifest; a name taken off frees the seat in the block. */
function TravellersModal({ r, load, name, unname, onClose }: { r: CharterRequest; load: () => Promise<Travellers>;
  name?: (body: unknown) => Promise<Travellers>; unname?: (ticket: string) => Promise<Travellers>; onClose: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => load(), [r.uid]);
  const [p, setP] = useState(PERSON);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof PERSON) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setP({ ...p, [k]: e.target.value });
  const syrian = p.nationality === "SY";
  const ready = p.first_name.trim() && p.last_name.trim() && (!syrian || (p.father_name.trim() && p.grandfather_name.trim()));
  const add = async () => {
    if (!name) return;
    setBusy(true); setError(null);
    try {
      await name({ travellers: [{ nationality: p.nationality, first_name: p.first_name, father_name: p.father_name || undefined,
        grandfather_name: p.grandfather_name || undefined, last_name: p.last_name, id_type: p.id_no ? p.id_type : undefined,
        id_no: p.id_no || undefined, seat_no: p.seat_no ? Number(p.seat_no) : undefined }] });
      toast(t("chr.travellerAdded")); setP(PERSON); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const remove = async (ticket: string) => {
    if (!unname) return;
    setError(null);
    try { await unname(ticket); toast(t("chr.travellerRemoved")); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("chr.travellersOf", { ref: r.ref })} onClose={onClose} wide>
      <div className="stack">
        <ErrorBox error={error} />
        <p className="small muted" style={{ margin: 0 }}>{t(name ? "chr.travellersHint" : "chr.travellersCarrier")}</p>
        <Loaded state={state}>{(d) => (
          <>
            <div className="row small" style={{ gap: 12 }}>
              <span>{t("chr.namedOf", { n: d.named, of: d.seats.length })}</span>
              {d.booking_ref && <span className="mono">{t("chr.bookingRef", { ref: d.booking_ref })}</span>}
            </div>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("chr.seat")}</th><th>{t("chr.traveller")}</th><th>{t("chr.ticket")}</th><th /></tr></thead>
              <tbody>{d.seats.map((x) => (
                <tr key={x.seat_no}><td className="mono">{x.seat_no}</td>
                  <td>{x.full_name ?? <span className="muted">{t("chr.unnamed")}</span>}{x.id_no_last4 && <div className="small muted">{x.id_type} ···{x.id_no_last4}</div>}</td>
                  <td className="mono small">{x.ticket_no ?? "—"}</td>
                  <td>{unname && x.ticket_no && x.ticket_status === "ISSUED" &&
                    <button className="btn text small" onClick={() => remove(x.ticket_no!)}>{t("chr.takeOff")}</button>}</td></tr>
              ))}</tbody>
            </table></div>
            {name && d.named < d.seats.length && (
              <div className="card stack" style={{ padding: 12 }}>
                <strong>{t("chr.addTraveller")}</strong>
                <div className="grid cols-3">
                  <Field label={t("chr.nationality")}><input className="input mono ltr" maxLength={2} value={p.nationality} onChange={(e) => setP({ ...p, nationality: e.target.value.toUpperCase() })} /></Field>
                  <Field label={t("chr.seat")}>
                    <select className="input" value={p.seat_no} onChange={set("seat_no")}>
                      <option value="">{t("chr.anySeat")}</option>
                      {d.seats.filter((x) => !x.ticket_no).map((x) => <option key={x.seat_no} value={x.seat_no}>{x.seat_no}</option>)}
                    </select>
                  </Field>
                  <Field label={t("chr.idNo")}><input className="input ltr" value={p.id_no} onChange={set("id_no")} /></Field>
                </div>
                <div className="grid cols-4">
                  <Field label={t("chr.firstName")}><input className="input" value={p.first_name} onChange={set("first_name")} /></Field>
                  <Field label={syrian ? t("chr.fatherName") : `${t("chr.fatherName")} (${t("common.optional")})`}><input className="input" value={p.father_name} onChange={set("father_name")} /></Field>
                  <Field label={syrian ? t("chr.grandfatherName") : `${t("chr.grandfatherName")} (${t("common.optional")})`}><input className="input" value={p.grandfather_name} onChange={set("grandfather_name")} /></Field>
                  <Field label={t("chr.lastName")}><input className="input" value={p.last_name} onChange={set("last_name")} /></Field>
                </div>
                <div className="row" style={{ justifyContent: "flex-end" }}>
                  <button className="btn filled" disabled={busy || !ready} onClick={add}><Icon name="person_add" />{t("chr.addTraveller")}</button>
                </div>
              </div>
            )}
          </>
        )}</Loaded>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ the carrier
const BLANK = {
  kind: "VEHICLE" as Kind, title: "", vehicle_type: "COACH", seats: 45, vehicles: 1, partial_seats: true, min_seats: 10,
  audience: ["AGENCY"] as Audience[], price_basis: "PER_DAY" as Basis, price: "", currency: "", notice_hours: 48,
  cancel_before_hours: 48, cancel_refund_pct: 100, with_driver: true, base_city: "", policy: "",
};

export function CarrierCharter() {
  const { t } = useI18n();
  const [tab, setTab] = useState<"requests" | "offers">("requests");
  return (
    <div className="stack">
      <PageHead title={t("chr.carrierTitle")} sub={t("chr.carrierSub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start" }}>
        {(["requests", "offers"] as const).map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`chr.tab.${v}`)}</button>
        ))}
      </div>
      {tab === "requests" ? <CarrierRequests /> : <CarrierOffers />}
    </div>
  );
}

function CarrierOffers() {
  const { t, money, market } = useI18n();
  const toast = useToast();
  const cities = useCities();
  const state = useLoad((signal) => api.get<{ offers: Offer[] }>("/api/carrier/charter/offers", undefined, { signal }));
  const [f, setF] = useState<typeof BLANK | null>(null);
  const [editing, setEditing] = useState<Offer | null>(null);
  const [error, setError] = useState<unknown>(null);
  const set = (patch: Partial<typeof BLANK>) => setF((x) => (x ? { ...x, ...patch } : x));
  const save = async () => {
    if (!f) return;
    setError(null);
    try {
      if (editing) {
        await api.patch(`/api/carrier/charter/offers/${editing.uid}`, {
          title: f.title, vehicles: f.vehicles, audience: f.audience, price: f.price_basis === "ON_REQUEST" ? undefined : toMinor(f.price),
          notice_hours: f.notice_hours, cancel_before_hours: f.cancel_before_hours, cancel_refund_pct: f.cancel_refund_pct, policy: f.policy });
      } else {
        await api.post("/api/carrier/charter/offers", {
          ...f, price: f.price_basis === "ON_REQUEST" ? null : toMinor(f.price), base_city: f.base_city || null,
          vehicle_type: f.kind === "VEHICLE" ? f.vehicle_type : null, seats: f.kind === "VEHICLE" ? f.seats : null,
          min_seats: f.kind === "WHOLE_TRIP" && f.partial_seats ? f.min_seats : null });
      }
      toast(t("common.saved")); setF(null); setEditing(null); state.reload();
    } catch (e) { setError(e); }
  };
  const status = async (o: Offer, s: string) => {
    setError(null);
    try { await api.patch(`/api/carrier/charter/offers/${o.uid}`, { status: s }); state.reload(); } catch (e) { setError(e); }
  };
  const bases: Basis[] = f?.kind === "WHOLE_TRIP" ? ["PER_SEAT", "PER_TRIP", "ON_REQUEST"] : ["PER_DAY", "PER_KM", "PER_TRIP", "ON_REQUEST"];
  const valid = !!f && f.title.trim().length >= 3 && f.policy.trim().length >= 10 && f.audience.length > 0
    && (f.price_basis === "ON_REQUEST" || Number(f.price) > 0);
  return (
    <div className="card stack">
      <div className="row between"><p className="small muted" style={{ margin: 0 }}>{t("chr.offersHint")}</p>
        <button className="btn" onClick={() => { setEditing(null); setF({ ...BLANK, currency: market.currency }); }}><Icon name="add" />{t("chr.newOffer")}</button></div>
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => d.offers.length === 0 ? <Empty icon="airport_shuttle" title={t("chr.noOwnOffers")} hint={t("chr.noOwnOffersHint")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("chr.offer")}</th><th>{t("chr.audience")}</th><th>{t("chr.price")}</th><th>{t("chr.terms")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{d.offers.map((o) => (
            <tr key={o.uid}>
              <td><strong>{o.title}</strong><div className="small muted">{t(`chr.kind.${o.kind}`)}{o.vehicle_type ? ` · ${t(`chr.vehicle.${o.vehicle_type}`)} · ${t("chr.seatsN", { n: o.seats ?? 0 })} × ${o.vehicles}` : ""}</div></td>
              <td>{o.audience.map((a) => <span key={a} className="chip">{t(`chr.aud.${a}`)}</span>)}</td>
              <td><OfferPrice o={o} /></td>
              <td><Refunds o={o} /><div className="small muted">{t("chr.notice", { h: o.notice_hours })}</div></td>
              <td><Status value={o.status} /></td>
              <td className="row" style={{ gap: 6, justifyContent: "flex-end" }}>
                <button className="btn text small" onClick={() => { setEditing(o); setF({ ...BLANK, ...o, price: o.price != null ? String(o.price / 100) : "", vehicle_type: o.vehicle_type ?? "COACH",
                  seats: o.seats ?? 45, min_seats: o.min_seats ?? 10, base_city: o.base_city ?? "" }); }}>{t("common.edit")}</button>
                {o.status === "ACTIVE" ? <button className="btn text small" onClick={() => status(o, "PAUSED")}>{t("chr.pause")}</button>
                  : <button className="btn text small" onClick={() => status(o, "ACTIVE")}>{t("chr.resume")}</button>}
                <button className="btn text small" onClick={() => status(o, "ARCHIVED")}>{t("chr.archive")}</button>
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {f && (
        <Modal title={t(editing ? "chr.editOffer" : "chr.newOffer")} onClose={() => { setF(null); setEditing(null); }} wide
               actions={<button className="btn filled" disabled={!valid} onClick={save}>{t("common.save")}</button>}>
          <div className="stack">
            {!editing && (
              <div className="segmented" role="radiogroup" aria-label={t("chr.kindLabel")} style={{ alignSelf: "flex-start" }}>
                {(["VEHICLE", "WHOLE_TRIP"] as Kind[]).map((k) => (
                  <button key={k} role="radio" aria-checked={f.kind === k} className={f.kind === k ? "on" : ""}
                          onClick={() => set({ kind: k, price_basis: k === "VEHICLE" ? "PER_DAY" : "PER_SEAT" })}>{t(`chr.kind.${k}`)}</button>
                ))}
              </div>
            )}
            <div className="grid cols-2">
              <Field label={t("chr.offerTitle")}><input className="input" maxLength={80} value={f.title} onChange={(e) => set({ title: e.target.value })} /></Field>
              {f.kind === "VEHICLE" && !editing && (
                <Field label={t("chr.vehicleType")}>
                  <select className="input" value={f.vehicle_type} onChange={(e) => set({ vehicle_type: e.target.value })}>
                    {VEHICLES.map((v) => <option key={v} value={v}>{t(`chr.vehicle.${v}`)}</option>)}
                  </select>
                </Field>
              )}
              {f.kind === "VEHICLE" && !editing && <Field label={t("chr.seats")}><input className="input" type="number" min={1} max={99} value={f.seats} onChange={(e) => set({ seats: Number(e.target.value) })} /></Field>}
              {f.kind === "VEHICLE" && <Field label={t("chr.vehiclesHave")}><input className="input" type="number" min={1} max={500} value={f.vehicles} onChange={(e) => set({ vehicles: Number(e.target.value) })} /></Field>}
              {f.kind === "WHOLE_TRIP" && !editing && (
                <label className="check"><input type="checkbox" checked={f.partial_seats} onChange={(e) => set({ partial_seats: e.target.checked })} />{t("chr.allowBlocks")}</label>
              )}
              {f.kind === "WHOLE_TRIP" && f.partial_seats && !editing && (
                <Field label={t("chr.minSeats")}><input className="input" type="number" min={1} max={99} value={f.min_seats} onChange={(e) => set({ min_seats: Number(e.target.value) })} /></Field>
              )}
              {!editing && (
                <Field label={t("chr.basisLabel")}>
                  <select className="input" value={f.price_basis} onChange={(e) => set({ price_basis: e.target.value as Basis })}>
                    {bases.map((b) => <option key={b} value={b}>{t(`chr.basis.${b}`)}</option>)}
                  </select>
                </Field>
              )}
              {f.price_basis !== "ON_REQUEST" && (
                <Field label={t("chr.priceIn", { cur: f.currency })}><input className="input" type="number" min={1} step="any" value={f.price} onChange={(e) => set({ price: e.target.value })} /></Field>
              )}
              <Field label={t("chr.noticeHours")}><input className="input" type="number" min={0} max={2160} value={f.notice_hours} onChange={(e) => set({ notice_hours: Number(e.target.value) })} /></Field>
              <Field label={t("chr.cancelBefore")}><input className="input" type="number" min={0} max={2160} value={f.cancel_before_hours} onChange={(e) => set({ cancel_before_hours: Number(e.target.value) })} /></Field>
              <Field label={t("chr.cancelRefund")}><input className="input" type="number" min={0} max={100} value={f.cancel_refund_pct} onChange={(e) => set({ cancel_refund_pct: Number(e.target.value) })} /></Field>
              {!editing && (
                <Field label={t("chr.baseCity")}>
                  <select className="input" value={f.base_city} onChange={(e) => set({ base_city: e.target.value })}>
                    <option value="">—</option>
                    {cities.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
                  </select>
                </Field>
              )}
            </div>
            <fieldset className="row" style={{ gap: 16, border: 0, padding: 0, margin: 0 }}>
              <legend className="small"><strong>{t("chr.audience")}</strong></legend>
              {(["AGENCY", "PASSENGER"] as Audience[]).map((a) => (
                <label key={a} className="check"><input type="checkbox" checked={f.audience.includes(a)}
                       onChange={(e) => set({ audience: e.target.checked ? [...f.audience, a] : f.audience.filter((x) => x !== a) })} />{t(`chr.aud.${a}`)}</label>
              ))}
              {!editing && <label className="check"><input type="checkbox" checked={f.with_driver} onChange={(e) => set({ with_driver: e.target.checked })} />{t("chr.withDriver")}</label>}
            </fieldset>
            <Field label={t("chr.policy")} hint={t("chr.policyHint")}><textarea className="input" rows={4} maxLength={2000} value={f.policy} onChange={(e) => set({ policy: e.target.value })} /></Field>
            {f.price_basis !== "ON_REQUEST" && Number(f.price) > 0 && <span className="small muted">{money(toMinor(f.price), true, f.currency)} {t(`chr.basisPer.${f.price_basis}`)}</span>}
            <ErrorBox error={error} />
          </div>
        </Modal>
      )}
    </div>
  );
}

function CarrierRequests() {
  const { t, money } = useI18n();
  const toast = useToast();
  const [filter, setFilter] = useState<"open" | "CONFIRMED" | "all">("open");
  const state = useLoad((signal) => api.get<{ requests: CharterRequest[] }>("/api/carrier/charter/requests",
    filter === "CONFIRMED" ? { status: "CONFIRMED" } : undefined, { signal }), [filter]);
  const vehicles = useLoad((signal) => api.get<{ vehicles: { uid: string; plate_no: string; vehicle_type: string; passenger_seats: number; status: string }[] }>(
    "/api/carrier/vehicles", undefined, { signal }).then((r) => r.vehicles.filter((v) => v.status === "ACTIVE")));
  const [pricing, setPricing] = useState<CharterRequest | null>(null);
  const [q, setQ] = useState({ price: "", valid_hours: 48, note: "", vehicle_uid: "" });
  const [closing, setClosing] = useState<{ r: CharterRequest; how: "decline" | "cancel" } | null>(null);
  const [listing, setListing] = useState<CharterRequest | null>(null);
  const [naming, setNaming] = useState<CharterRequest | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const rows = useMemo(() => (state.data?.requests ?? []).filter((r) => filter !== "open" || ["REQUESTED", "QUOTED"].includes(r.status)), [state.data, filter]);
  const run = async (fn: () => Promise<unknown>, done: string) => {
    setError(null);
    try { await fn(); toast(t(done)); state.reload(); return true; } catch (e) { setError(e); return false; }
  };
  return (
    <div className="card stack">
      <div className="segmented" role="radiogroup" aria-label={t("common.status")} style={{ alignSelf: "flex-start" }}>
        {(["open", "CONFIRMED", "all"] as const).map((v) => (
          <button key={v} role="radio" aria-checked={filter === v} className={filter === v ? "on" : ""} onClick={() => setFilter(v)}>{t(`chr.filter.${v}`)}</button>
        ))}
      </div>
      <ErrorBox error={error} />
      <Loaded state={state}>{() => rows.length === 0 ? <Empty icon="request_quote" title={t("chr.noIncoming")} hint={t("chr.noIncomingHint")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("chr.ref")}</th><th>{t("chr.customer")}</th><th>{t("chr.what")}</th><th>{t("common.status")}</th><th>{t("chr.price")}</th><th /></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.uid}>
              <td className="mono">{r.ref}<div className="small muted">{r.terms.title}</div></td>
              <td>{r.agency_name ?? r.contact_name}<div className="small muted ltr">{r.contact_mobile}</div>
                <span className="chip">{t(`chr.aud.${r.requester_kind}`)}</span></td>
              <td><What r={r} />{r.itinerary && <div className="small">{r.itinerary}</div>}{r.note && <div className="small muted">“{r.note}”</div>}
                {r.vehicle_plate && <div className="small"><Icon name="directions_bus" size={14} /> {r.vehicle_plate}</div>}</td>
              <td><Status value={r.status} /></td>
              <td><Price r={r} /></td>
              <td className="row" style={{ gap: 6, justifyContent: "flex-end", flexWrap: "wrap" }}>
                {["REQUESTED", "QUOTED"].includes(r.status) && <>
                  <button className="btn filled small" onClick={() => { setPricing(r); setQ({ price: r.price != null ? String(r.price / 100) : r.estimate != null ? String(r.estimate / 100) : "", valid_hours: 48, note: "", vehicle_uid: "" }); }}>
                    <Icon name="request_quote" />{t(r.status === "QUOTED" ? "chr.reprice" : "chr.priceIt")}</button>
                  <button className="btn text small" onClick={() => { setClosing({ r, how: "decline" }); setReason(""); }}>{t("chr.decline")}</button>
                </>}
                {r.status === "CONFIRMED" && r.kind === "VEHICLE" && <button className="btn text small" onClick={() => setNaming(r)}>{t("chr.nameVehicle")}</button>}
                {r.status === "CONFIRMED" && r.kind === "WHOLE_TRIP" && <button className="btn text small" onClick={() => setListing(r)}>{t("chr.travellers")}</button>}
                {r.status === "CONFIRMED" && <button className="btn small" onClick={() => run(() => api.post(`/api/carrier/charter/requests/${r.uid}/complete`), "chr.completed")}>{t("chr.done")}</button>}
                {r.status === "CONFIRMED" && <button className="btn text small" onClick={() => { setClosing({ r, how: "cancel" }); setReason(""); }}>{t("chr.cancel")}</button>}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {pricing && (
        <Modal title={t("chr.priceTitle", { ref: pricing.ref })} onClose={() => setPricing(null)}
               actions={<button className="btn filled" disabled={!(Number(q.price) > 0)} onClick={async () => {
                 if (await run(() => api.post(`/api/carrier/charter/requests/${pricing.uid}/quote`, { price: toMinor(q.price), valid_hours: q.valid_hours,
                   note: q.note.trim() || undefined, vehicle_uid: q.vehicle_uid || undefined }), "chr.priced")) setPricing(null);
               }}>{t("chr.sendPrice")}</button>}>
          <div className="stack">
            <What r={pricing} />
            {pricing.estimate != null && <span className="small muted">{t("chr.estimateIs", { amount: money(pricing.estimate, true, pricing.terms.currency) })}</span>}
            <div className="grid cols-2">
              <Field label={t("chr.priceIn", { cur: pricing.terms.currency })}><input className="input" type="number" min={1} step="any" value={q.price} onChange={(e) => setQ({ ...q, price: e.target.value })} /></Field>
              <Field label={t("chr.validHours")}><input className="input" type="number" min={1} max={168} value={q.valid_hours} onChange={(e) => setQ({ ...q, valid_hours: Number(e.target.value) })} /></Field>
              {pricing.kind === "VEHICLE" && (
                <Field label={t("chr.vehicleLabel")}>
                  <select className="input" value={q.vehicle_uid} onChange={(e) => setQ({ ...q, vehicle_uid: e.target.value })}>
                    <option value="">{t("chr.vehicleLater")}</option>
                    {(vehicles.data ?? []).map((v) => <option key={v.uid} value={v.uid}>{v.plate_no} · {v.passenger_seats}</option>)}
                  </select>
                </Field>
              )}
            </div>
            <Field label={t("chr.quoteNote")}><input className="input" maxLength={500} value={q.note} onChange={(e) => setQ({ ...q, note: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
      {naming && (
        <Modal title={t("chr.nameVehicle")} onClose={() => setNaming(null)}>
          <div className="stack">
            {(vehicles.data ?? []).map((v) => (
              <button key={v.uid} className="btn outlined" onClick={async () => {
                if (await run(() => api.post(`/api/carrier/charter/requests/${naming.uid}/vehicle`, { vehicle_uid: v.uid }), "common.saved")) setNaming(null);
              }}>{v.plate_no} · {t(`chr.vehicle.${v.vehicle_type}`)} · {t("chr.seatsN", { n: v.passenger_seats })}</button>
            ))}
          </div>
        </Modal>
      )}
      {listing && <TravellersModal r={listing} load={() => api.get<Travellers>(`/api/carrier/charter/requests/${listing.uid}/travellers`)}
                                   onClose={() => setListing(null)} />}
      {closing && (
        <Modal title={t(closing.how === "decline" ? "chr.declineTitle" : "chr.cancelTitle", { ref: closing.r.ref })} onClose={() => setClosing(null)}
               actions={<button className="btn filled" disabled={reason.trim().length < 3} onClick={async () => {
                 if (await run(() => api.post(`/api/carrier/charter/requests/${closing.r.uid}/${closing.how}`, { reason: reason.trim() }),
                   closing.how === "decline" ? "chr.declined" : "chr.cancelled")) setClosing(null);
               }}>{t(closing.how === "decline" ? "chr.decline" : "chr.cancel")}</button>}>
          <div className="stack">
            {closing.how === "cancel" && <div className="alert info small"><Icon name="info" />{t("chr.carrierCancelNote")}</div>}
            <Field label={t("chr.reason")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ the platform
interface Limits { max_seats: number; family_max_seats: number; agency_group: number; basis: string | null; set_at: string | null }

/** Booking rules: the seats booked at once (1122) and charter oversight (1123). */
export function AdminBookingRules() {
  const { t } = useI18n();
  const { can } = useAuth();
  const tabs = [...(can("policy.matrix") ? ["limits"] : []), ...(can("report.platform", "policy.matrix") ? ["charter"] : [])] as ("limits" | "charter")[];
  const [tab, setTab] = useState(tabs[0] ?? "charter");
  return (
    <div className="stack">
      <PageHead title={t("rules.title")} sub={t("rules.sub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start" }}>
        {tabs.map((v) => <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`rules.tab.${v}`)}</button>)}
      </div>
      {tab === "limits" ? <SeatLimits /> : <PlatformCharter />}
    </div>
  );
}

function SeatLimits() {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Limits>("/api/admin/booking/seat-limits", undefined, { signal }));
  const [f, setF] = useState<{ max_seats: number; family_max_seats: number; agency_group: number; basis: string } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const v = f ?? (state.data ? { ...state.data, basis: "" } : null);
  const set = (patch: Partial<NonNullable<typeof v>>) => v && setF({ ...v, ...patch });
  const save = async () => {
    if (!v) return;
    setError(null);
    try { await api.put("/api/admin/booking/seat-limits", v); toast(t("common.saved")); setF(null); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("rules.limitsHint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => v && (
        <div className="stack">
          <div className="grid cols-3">
            <Stat icon="event_seat" label={t("rules.maxSeats")} value={d.max_seats} />
            <Stat icon="family_restroom" label={t("rules.familyMax")} value={d.family_max_seats} tone="wheat" />
            <Stat icon="groups" label={t("rules.agencyGroup")} value={d.agency_group} tone="blue" />
          </div>
          {d.basis && <p className="small muted" style={{ margin: 0 }}>{t("rules.lastSet", { basis: d.basis, at: d.set_at ? date(d.set_at) : "" })}</p>}
          <div className="grid cols-3">
            <Field label={t("rules.maxSeats")} hint={t("rules.maxSeatsHint")}><input className="input" type="number" min={1} max={20} value={v.max_seats} onChange={(e) => set({ max_seats: Number(e.target.value) })} /></Field>
            <Field label={t("rules.familyMax")} hint={t("rules.familyMaxHint")}><input className="input" type="number" min={1} max={20} value={v.family_max_seats} onChange={(e) => set({ family_max_seats: Number(e.target.value) })} /></Field>
            <Field label={t("rules.agencyGroup")} hint={t("rules.agencyGroupHint")}><input className="input" type="number" min={1} max={60} value={v.agency_group} onChange={(e) => set({ agency_group: Number(e.target.value) })} /></Field>
          </div>
          <Field label={t("rules.basis")} hint={t("rules.basisHint")}><input className="input" maxLength={160} value={v.basis} onChange={(e) => set({ basis: e.target.value })} /></Field>
          <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!f || v.basis.trim().length < 3} onClick={save}>{t("common.save")}</button>
        </div>
      )}</Loaded>
    </div>
  );
}

function PlatformCharter() {
  const { t } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ requests: CharterRequest[]; active_offers: number; carriers: number }>("/api/admin/charter/requests", undefined, { signal }));
  const commission = useLoad((signal) => (can("policy.matrix")
    ? api.get<{ commission_bp: number }>("/api/admin/charter/commission", undefined, { signal }).then((r) => r.commission_bp) : Promise.resolve(null)));
  const [pct, setPct] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setError(null);
    try { await api.put("/api/admin/charter/commission", { commission_bp: Math.round(Number(pct) * 100) }); toast(t("common.saved")); setPct(null); commission.reload(); }
    catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => {
        const by = (s: string) => d.requests.filter((r) => r.status === s).length;
        return (
          <>
            <div className="grid cols-4">
              <Stat icon="airport_shuttle" label={t("rules.activeOffers")} value={d.active_offers} />
              <Stat icon="apartment" label={t("rules.carriers")} value={d.carriers} tone="blue" />
              <Stat icon="request_quote" label={t("rules.open")} value={by("REQUESTED") + by("QUOTED")} tone="wheat" />
              <Stat icon="check_circle" label={t("rules.confirmed")} value={by("CONFIRMED")} />
            </div>
            {commission.data != null && (
              <div className="card row" style={{ gap: 12, alignItems: "flex-end", flexWrap: "wrap" }}>
                <Field label={t("rules.commission")} hint={t("rules.commissionHint")}>
                  <input className="input" type="number" min={0} max={30} step="0.01" value={pct ?? String(commission.data / 100)} onChange={(e) => setPct(e.target.value)} />
                </Field>
                <button className="btn" disabled={pct == null} onClick={save}>{t("common.save")}</button>
              </div>
            )}
            <div className="card">
              {d.requests.length === 0 ? <Empty icon="request_quote" title={t("chr.noRequests")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("chr.ref")}</th><th>{t("chr.carrier")}</th><th>{t("chr.customer")}</th><th>{t("chr.what")}</th><th>{t("common.status")}</th><th>{t("chr.price")}</th></tr></thead>
                  <tbody>{d.requests.map((r) => (
                    <tr key={r.uid}>
                      <td className="mono">{r.ref}</td>
                      <td><CarrierName name={r.carrier_name} uid={r.carrier_uid} logo={r.carrier_logo} /></td>
                      <td>{r.agency_name ?? t("chr.aud.PASSENGER")}</td>
                      <td><What r={r} /></td>
                      <td><Status value={r.status} /></td>
                      <td><Price r={r} /></td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
          </>
        );
      }}</Loaded>
    </div>
  );
}
