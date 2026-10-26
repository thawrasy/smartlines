import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { api, newKey, type ConnectionPolicy } from "../../api";
import { useI18n, zone } from "../../i18n";
import { useAuth } from "../../auth";
import { useChannel } from "../../channel";
import { minutesBetween } from "../../dates";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, Spinner, Stat, useLoad, useToast } from "../../components/ui";
import { legsParam, pickedParam } from "./journeyLinks";

// Connections across carriers (owner's request, October 2026; migration 1130). Where no trip runs from one city to
// another, the results offer two trips through a city on the way, of one carrier or several, leaving a while after the
// first arrives. The traveller books both as one journey after reading and accepting its risks; each trip shows what its
// carrier does when a traveller misses it. A booking is changed to another trip of its carrier from the booking page:
// before departure under its fare's rules, after a missed connection under the carrier's policy.

interface ConnLeg {
  trip_uid: string; trip_no: string; trip_code: string | null; from_seq: number; to_seq: number; departs_at: string; arrives_at: string;
  from_station: string; to_station: string; from_code: string; to_code: string; from_city: string; to_city: string;
  price: number; currency: string; seats_left: number; bookable: boolean;
  carrier_name: string; carrier_uid: string; carrier_code: string | null; carrier_logo: string | null; policy: Omit<ConnectionPolicy, "offer_in_connections">;
}
interface Connection {
  legs: ConnLeg[]; departs_at: string; arrives_at: string; carriers: number; price: number | null; currency: string | null; bookable: boolean;
  change: { city: string; city_name: string; arrives_at: string; leaves_from: string; same_station: boolean; minutes: number };
}
// the day a trip leaves, where the traveller boards (the market's time zone)
const dayOf = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: zone() }).format(new Date(iso));

interface ConnSettings { enabled: boolean; min_minutes: number; min_minutes_station_change: number; max_minutes: number; require_flexible: boolean }

/** What a carrier does when a traveller misses its trip, in a line. */
export function PolicyLine({ p }: { p: Omit<ConnectionPolicy, "offer_in_connections"> }) {
  const { t } = useI18n();
  return (
    <span className="small muted" title={p.note ?? undefined}>
      <Icon name="policy" size={16} /> {t(`conn.policy.${p.missed_connection}`, { h: p.change_window_hours })}{p.note ? ` · ${p.note}` : ""}
    </span>
  );
}

/** The connections between two cities on a day, on the results page. */
export function ConnectionOptions({ from, to, on, pax }: { from: string; to: string; on: string; pax: number }) {
  const { t, city, money, time, station, duration, currency } = useI18n();
  const nav = useNavigate();
  const ch = useChannel();
  const res = useLoad(() => api.get<{ enabled: boolean; settings: ConnSettings; connections: Connection[] }>("/api/trips/connections",
    { origin: from, destination: to, on, passengers: pax }), [from, to, on, pax]);
  if (res.loading) return <Spinner />;
  if (res.error) return <ErrorBox error={res.error} />;
  const d = res.data;
  if (!d || !d.enabled) return null;
  const choose = (c: Connection) => {
    const legs = c.legs.map((l) => ({ from: l.from_city, to: l.to_city, on: dayOf(l.departs_at) }));
    nav(ch.link(`/journey?kind=CONNECTION&legs=${legsParam(legs)}&picked=${pickedParam(c.legs.map((l) => ({ uid: l.trip_uid, from: l.from_seq, to: l.to_seq })))}&pax=${pax}`));
  };
  return (
    <section className="stack" aria-labelledby="conn-title">
      <div>
        <h2 id="conn-title" className="row" style={{ gap: 8 }}><Icon name="airline_stops" />{t("conn.title", { from: city(from), to: city(to) })}</h2>
        <p className="muted small" style={{ margin: 0 }}>{t("conn.sub", { min: d.settings.min_minutes, max: d.settings.max_minutes })}</p>
      </div>
      {d.connections.length === 0 ? <div className="card"><Empty icon="airline_stops" title={t("conn.none")} hint={t("conn.noneHint")} /></div>
        : d.connections.map((c) => (
          <div key={c.legs.map((l) => l.trip_uid).join("-")} className="card stack">
            <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <span className="chip blue"><Icon name="airline_stops" size={16} />{t("conn.via", { city: city(c.change.city) })}</span>
                <span className={`chip ${c.carriers > 1 ? "wheat" : ""}`}>{t(c.carriers > 1 ? "conn.carriers" : "conn.oneCarrier", { n: c.carriers })}</span>
                <span className="small muted">{time(c.departs_at)} → {time(c.arrives_at)} · {duration(minutesBetween(c.departs_at, c.arrives_at))}</span>
              </div>
              {c.price != null && c.currency && <div className="price">{money(c.price, false, c.currency)} <small>{currency(c.currency)}</small></div>}
            </div>
            {c.legs.map((l, i) => (
              <div key={l.trip_uid} className="stack tight">
                {i > 0 && (
                  <div className={`alert ${c.change.minutes < 45 || !c.change.same_station ? "warn" : "info"} small`} role="note">
                    <Icon name="swap_horiz" size={20} />
                    {t(c.change.same_station ? "conn.changeSame" : "conn.changeOther",
                       { city: city(c.change.city), n: c.change.minutes, from: c.change.arrives_at, to: c.change.leaves_from })}
                  </div>
                )}
                <div className="journey-leg">
                  <span className="chip blue">{t("jrn.legN", { n: i + 1 })}</span>
                  <div className="grow stack tight">
                    <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                      <strong>{station(l.from_code, l.from_station)} → {station(l.to_code, l.to_station)}</strong>
                      <span className="chip outline mono" title={l.trip_no}>{l.trip_code ?? l.trip_no}</span>
                    </div>
                    <span className="small muted">{time(l.departs_at)} → {time(l.arrives_at)} · <CarrierName name={l.carrier_name} uid={l.carrier_uid} logo={l.carrier_logo} /></span>
                    <PolicyLine p={l.policy} />
                  </div>
                  <span className="text-nowrap small">{money(l.price, false, l.currency)} {currency(l.currency)}</span>
                </div>
              </div>
            ))}
            <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
              <span className="small muted"><Icon name="warning" size={16} /> {t("conn.riskShort")}</span>
              <button className="btn" disabled={!c.bookable} onClick={() => choose(c)}>{c.bookable ? t("conn.choose") : t("results.soldOut")}</button>
            </div>
          </div>
        ))}
    </section>
  );
}

/** The risks of a connection, to read and accept before booking it. */
export function RiskNotice({ accepted, onChange, flexible }: { accepted: boolean; onChange: (v: boolean) => void; flexible: boolean }) {
  const { t } = useI18n();
  return (
    <div className="card stack" role="region" aria-labelledby="risk-title" style={{ borderInlineStart: "4px solid var(--secondary)" }}>
      <h3 id="risk-title" className="row" style={{ gap: 8, margin: 0 }}><Icon name="warning" />{t("conn.risks.title")}</h3>
      <ul className="small" style={{ margin: 0, paddingInlineStart: 20 }}>
        <li>{t("conn.risks.own")}</li>
        <li>{t("conn.risks.late")}</li>
        <li>{t("conn.risks.policy")}</li>
        <li>{t("conn.risks.luggage")}</li>
        {flexible && <li>{t("conn.risks.flexible")}</li>}
      </ul>
      <label className="check"><input type="checkbox" checked={accepted} onChange={(e) => onChange(e.target.checked)} />{t("conn.risks.accept")}</label>
    </div>
  );
}

interface ChangeState {
  allowed: boolean; why: string | null; reason: string | null; basis: "FREE_CHANGE" | "FARE_RULES" | null; fee: number; fares: number; refund: number;
  currency: string; missed: boolean; inbound_late: boolean; connection: boolean; change_until?: string;
  policy: Omit<ConnectionPolicy, "offer_in_connections">;
}
interface ChangeTripRow {
  trip_uid: string; trip_no: string; trip_code: string | null; currency: string; from_seq: number; to_seq: number; departs_at: string; arrives_at: string;
  from_station: string; to_station: string; price: number; seats_left: number; bookable: boolean;
}

/** Changing a booking to another trip of its carrier between the same cities. */
export function ChangeTrip({ bookingRef }: { bookingRef: string }) {
  const { t, money, time, date, dateTime, currency } = useI18n();
  const ch = useChannel();
  const nav = useNavigate();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [key] = useState(() => newKey());
  const opts = useLoad(() => (open ? api.get<{ change: ChangeState; trips: ChangeTripRow[] }>(`/api/bookings/${bookingRef}/change-options`)
    : Promise.resolve(null)), [open, bookingRef]);
  const change = async (x: ChangeTripRow) => {
    if (!confirm(t("conn.change.confirm", { code: x.trip_code ?? x.trip_no, time: time(x.departs_at) }))) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ booking_ref: string; fee: number; refunded: number; paid: number; currency: string }>(
        `/api/bookings/${bookingRef}/change`, { trip_uid: x.trip_uid, from_seq: x.from_seq, to_seq: x.to_seq, idempotency_key: key });
      toast(t("conn.change.done", { ref: out.booking_ref, fee: money(out.fee, false, out.currency) }));
      nav(ch.link(`/booking/${out.booking_ref}`));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  if (!open) return <button className="btn outlined" onClick={() => setOpen(true)}><Icon name="event_repeat" />{t("conn.change.open")}</button>;
  return (
    <div className="card stack" style={{ flexBasis: "100%" }}>
      <h3 className="row" style={{ gap: 8, margin: 0 }}><Icon name="event_repeat" />{t("conn.change.title")}</h3>
      <ErrorBox error={error} />
      <Loaded state={opts}>{(d) => d && (
        <div className="stack">
          {d.change.allowed ? (
            <div className={`alert ${d.change.basis === "FREE_CHANGE" ? "ok" : "info"} small`}>
              <Icon name={d.change.basis === "FREE_CHANGE" ? "check_circle" : "info"} size={20} />
              <span>{t(d.change.basis === "FREE_CHANGE" ? "conn.change.free" : "conn.change.rules",
                       { fee: money(d.change.fee, false, d.change.currency), refund: money(d.change.refund, false, d.change.currency), cur: currency(d.change.currency) })}
                {d.change.missed && d.change.change_until && ` ${t("conn.change.until", { at: dateTime(d.change.change_until) })}`}</span>
            </div>
          ) : <div className="alert warn small"><Icon name="block" size={20} />{t(`errors.${d.change.why ?? "CANNOT_CHANGE"}`)}</div>}
          <PolicyLine p={d.change.policy} />
          {d.change.allowed && (d.trips.length === 0 ? <Empty icon="event_busy" title={t("conn.change.noTrips")} /> : (
            <div className="stack tight">
              {d.trips.map((x) => (
                <div key={x.trip_uid} className="row between" style={{ gap: 12, flexWrap: "wrap" }}>
                  <span><span className="chip outline mono">{x.trip_code ?? x.trip_no}</span>{" "}
                    {date(x.departs_at, { weekday: "short", day: "numeric", month: "short" })} · {time(x.departs_at)} → {time(x.arrives_at)}
                    <span className="small muted"> · {money(x.price, false, x.currency)} {currency(x.currency)} · {t("results.seatsLeft", { n: x.seats_left })}</span></span>
                  <button className="btn small" disabled={busy || !x.bookable} onClick={() => change(x)}>{busy ? <Spinner /> : t("conn.change.pick")}</button>
                </div>
              ))}
              <p className="small muted" style={{ margin: 0 }}>{t("conn.change.how")}</p>
            </div>
          ))}
          <button className="btn text" style={{ alignSelf: "flex-start" }} onClick={() => setOpen(false)}>{t("common.close")}</button>
        </div>
      )}</Loaded>
    </div>
  );
}

/** The booking page's lines for a connection: the risks accepted, and the booking it replaced or that replaced it. */
export function ChangeLinks({ from, to }: { from?: string | null; to?: string | null }) {
  const { t } = useI18n();
  const ch = useChannel();
  if (!from && !to) return null;
  return (
    <div className="alert info small">
      <Icon name="event_repeat" size={20} />
      {from && <span>{t("conn.changedFrom")} <Link className="mono" to={ch.link(`/booking/${from}`)}>{from}</Link></span>}
      {to && <span>{t("conn.changedTo")} <Link className="mono" to={ch.link(`/booking/${to}`)}>{to}</Link></span>}
    </div>
  );
}

/** The platform's connection settings (policy.matrix): offered or not, the change times, flexible later trips. */
export function ConnectionSettings() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<ConnSettings>("/api/admin/connections/settings", undefined, { signal }));
  const [f, setF] = useState<ConnSettings | null>(null);
  const [error, setError] = useState<unknown>(null);
  const v = f ?? state.data;
  const set = (patch: Partial<ConnSettings>) => v && setF({ ...v, ...patch });
  const save = async () => {
    if (!f) return;
    setError(null);
    try { await api.put("/api/admin/connections/settings", f); toast(t("common.saved")); setF(null); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("conn.admin.hint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => v && (
        <div className="stack">
          <div className="grid cols-3">
            <Stat icon="airline_stops" label={t("conn.admin.enabled")} value={t(d.enabled ? "conn.yes" : "conn.no")} />
            <Stat icon="schedule" label={t("conn.admin.window")} value={`${d.min_minutes}–${d.max_minutes}′`} tone="blue" />
            <Stat icon="event_repeat" label={t("conn.admin.flexible")} value={t(d.require_flexible ? "conn.yes" : "conn.no")} tone="wheat" />
          </div>
          <label className="check"><input type="checkbox" checked={v.enabled} onChange={(e) => set({ enabled: e.target.checked })} />{t("conn.admin.enabledLabel")}</label>
          <div className="grid cols-3">
            <Field label={t("conn.admin.min")} hint={t("conn.admin.minHint")}><input className="input" type="number" min={10} max={240} value={v.min_minutes} onChange={(e) => set({ min_minutes: Number(e.target.value) })} /></Field>
            <Field label={t("conn.admin.minChange")} hint={t("conn.admin.minChangeHint")}><input className="input" type="number" min={10} max={360} value={v.min_minutes_station_change} onChange={(e) => set({ min_minutes_station_change: Number(e.target.value) })} /></Field>
            <Field label={t("conn.admin.max")} hint={t("conn.admin.maxHint")}><input className="input" type="number" min={10} max={720} value={v.max_minutes} onChange={(e) => set({ max_minutes: Number(e.target.value) })} /></Field>
          </div>
          <label className="check"><input type="checkbox" checked={v.require_flexible} onChange={(e) => set({ require_flexible: e.target.checked })} />{t("conn.admin.flexibleLabel")}</label>
          <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!f} onClick={save}>{t("common.save")}</button>
        </div>
      )}</Loaded>
    </div>
  );
}

/** A carrier's connection policy: offered in connections, and what it does when a traveller misses its trip. */
export function CarrierConnectionPolicy() {
  const { t } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad((signal) => api.get<ConnectionPolicy & { set: boolean }>("/api/carrier/connection-policy", undefined, { signal }));
  const [f, setF] = useState<ConnectionPolicy | null>(null);
  const [error, setError] = useState<unknown>(null);
  const v = f ?? state.data;
  const editable = can("trip.publish");
  const set = (patch: Partial<ConnectionPolicy>) => v && setF({ ...v, ...patch });
  const save = async () => {
    if (!f) return;
    setError(null);
    try { await api.put("/api/carrier/connection-policy", { ...f, note: f.note || null }); toast(t("common.saved")); setF(null); state.reload(); }
    catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <h3 className="row" style={{ gap: 8, margin: 0 }}><Icon name="airline_stops" />{t("conn.carrier.title")}</h3>
      <p className="small muted" style={{ margin: 0 }}>{t("conn.carrier.sub")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{() => v && (
        <div className="stack">
          <label className="check"><input type="checkbox" disabled={!editable} checked={v.offer_in_connections} onChange={(e) => set({ offer_in_connections: e.target.checked })} />{t("conn.carrier.offer")}</label>
          <div className="stack tight" role="radiogroup" aria-label={t("conn.carrier.missed")}>
            <strong className="small">{t("conn.carrier.missed")}</strong>
            {(["FREE_CHANGE", "FARE_RULES", "NONE"] as const).map((m) => (
              <label key={m} className="check"><input type="radio" disabled={!editable} checked={v.missed_connection === m} onChange={() => set({ missed_connection: m })} />
                <span>{t(`conn.carrier.${m}`)}</span></label>
            ))}
          </div>
          <div className="grid cols-2">
            <Field label={t("conn.carrier.window")} hint={t("conn.carrier.windowHint")}>
              <input className="input" type="number" min={1} max={168} disabled={!editable || v.missed_connection === "NONE"} value={v.change_window_hours}
                     onChange={(e) => set({ change_window_hours: Number(e.target.value) })} />
            </Field>
            <Field label={t("conn.carrier.note")} hint={t("conn.carrier.noteHint")}>
              <input className="input" maxLength={500} disabled={!editable} value={v.note ?? ""} onChange={(e) => set({ note: e.target.value })} />
            </Field>
          </div>
          {editable && <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!f} onClick={save}>{t("common.save")}</button>}
        </div>
      )}</Loaded>
    </div>
  );
}
