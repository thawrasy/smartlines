import { useEffect, useMemo, useState } from "react";
import QRCode from "qrcode";
import { Link } from "react-router-dom";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";
import { PLACES } from "./places";

const isoLocal = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);

/** Pounds typed by people, minor units on the wire. */
const toMinor = (pounds: string) => Math.round(Number(pounds || 0) * 100);

// ------------------------------------------------------------------ shuttle passes

interface Plan { id: number; code: string; name: string; period_days: number; rides_limit: number | null; price: number; operator: string; line: string | null; zone: string | null }
interface Sub { uid: string; plan: string; operator: string; starts_on: string; ends_on: string; rides_used: number; rides_limit: number | null; status: string; pass_no: string | null }

export function BuyPass() {
  const { t, money, date } = useI18n();
  const toast = useToast();
  const plans = useLoad(() => api.get<{ plans: Plan[] }>("/api/w/subscriptions/plans"));
  const mine = useLoad(() => api.get<{ subscriptions: Sub[] }>("/api/w/subscriptions/mine"));
  const [pick, setPick] = useState<Plan | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [show, setShow] = useState<Sub | null>(null);
  const buy = async () => {
    if (!pick) return;
    setBusy(true); setError(null);
    try {
      await api.post("/api/w/subscriptions", { plan_id: pick.id, idempotency_key: newKey() });
      toast(t("wf.buyPass.done")); setPick(null); mine.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const d = (s: string) => date(`${s}T12:00:00Z`, { day: "numeric", month: "short", year: "numeric" });
  return (
    <div className="stack">
      <Loaded state={mine}>{(m) => m.subscriptions.length > 0 && (
        <div className="card stack">
          <h3>{t("wf.buyPass.mine")}</h3>
          <div className="grid cols-2">
            {m.subscriptions.map((s) => (
              <div key={s.uid} className="pass-card">
                <div className="row between nowrap"><strong>{s.plan}</strong><Status value={s.status} /></div>
                <div className="small muted">{s.operator}</div>
                <div className="row between small"><span>{d(s.starts_on)} → {d(s.ends_on)}</span>
                  <span>{t("wf.buyPass.rides", { used: s.rides_used, limit: s.rides_limit ?? "∞" })}</span></div>
                {s.pass_no && s.status === "ACTIVE" && <button className="btn tonal small" onClick={() => setShow(s)}><Icon name="qr_code_2" />{t("wf.buyPass.showPass")}</button>}
              </div>
            ))}
          </div>
        </div>
      )}</Loaded>
      <div className="card stack">
        <h3>{t("wf.buyPass.plans")}</h3>
        <Loaded state={plans}>{(p) => p.plans.length === 0 ? <Empty icon="card_membership" title={t("wf.buyPass.none")} /> : (
          <div className="grid cols-3">
            {p.plans.map((x) => (
              <div key={x.id} className="offer-card">
                <div className="small muted">{x.operator}</div>
                <h3>{x.name}</h3>
                <div className="offer-price">{money(x.price)}</div>
                <ul className="small muted plain">
                  <li>{t("wf.buyPass.period", { n: x.period_days })}</li>
                  <li>{x.rides_limit ? t("wf.buyPass.ridesN", { n: x.rides_limit }) : t("wf.buyPass.unlimited")}</li>
                  {(x.line || x.zone) && <li>{x.line ?? x.zone}</li>}
                </ul>
                <button className="btn" onClick={() => { setPick(x); setError(null); }}>{t("wf.buyPass.buy")}</button>
              </div>
            ))}
          </div>
        )}</Loaded>
      </div>
      {pick && (
        <Modal title={t("wf.buyPass.confirm", { name: pick.name })} onClose={() => setPick(null)}
               actions={<><button className="btn text" onClick={() => setPick(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy} onClick={buy}>{t("wf.buyPass.pay", { amount: money(pick.price) })}</button></>}>
          <p className="muted">{t("wf.buyPass.note")}</p>
          <ErrorBox error={error} />
          {error !== null && <Link to="/wallet" className="small">{t("wf.topUp")}</Link>}
        </Modal>
      )}
      {show && <PassModal sub={show} onClose={() => setShow(null)} />}
    </div>
  );
}

function PassModal({ sub, onClose }: { sub: Sub; onClose: () => void }) {
  const { t } = useI18n();
  const [qr, setQr] = useState("");
  useEffect(() => { QRCode.toDataURL(`MASSLAK-PASS:${sub.pass_no}`, { margin: 1, width: 240 }).then(setQr); }, [sub.pass_no]);
  return (
    <Modal title={sub.plan} onClose={onClose}>
      <div className="stack" style={{ alignItems: "center" }}>
        {qr && <img src={qr} alt={t("wf.buyPass.showPass")} width={240} height={240} />}
        <div className="mono ltr" style={{ fontSize: 20, fontWeight: 700 }}>{sub.pass_no}</div>
        <p className="muted small" style={{ textAlign: "center" }}>{t("wf.buyPass.scan")}</p>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ parcels

interface Station { id: number; code: string; name: string; city: string }
interface Parcel { tracking_no: string; status: string; created_at: string; recipient_name: string | null; service: string; origin: string; destination: string; origin_code: string | null; destination_code: string | null; price: number | null }

export function SendParcel() {
  const { t, money, dateTime, station } = useI18n();
  const toast = useToast();
  const opts = useLoad(() => api.get<{ services: { id: number; name: string }[]; stations: Station[] }>("/api/w/parcels/options"));
  const mine = useLoad(() => api.get<{ parcels: Parcel[] }>("/api/w/parcels/mine"));
  const [f, setF] = useState({ service_id: "", origin_station_id: "", dest_station_id: "", weight_kg: "1", declared_value: "",
                               recipient_name: "", recipient_mobile: "", contents: "" });
  const [quote, setQuote] = useState<{ price: number; zone: string } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => { setF({ ...f, [k]: e.target.value }); setQuote(null); };
  const core = () => ({ service_id: Number(f.service_id), origin_station_id: Number(f.origin_station_id), dest_station_id: Number(f.dest_station_id),
                        weight_kg: Number(f.weight_kg), declared_value: toMinor(f.declared_value) });
  const ready = f.service_id && f.origin_station_id && f.dest_station_id && Number(f.weight_kg) > 0;
  useEffect(() => {
    if (!ready) return;
    const id = setTimeout(() => {
      api.post<{ price: number; zone: string }>("/api/w/parcels/quote", core()).then((q) => { setQuote(q); setError(null); }).catch((e) => { setQuote(null); setError(e); });
    }, 300);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f.service_id, f.origin_station_id, f.dest_station_id, f.weight_kg, f.declared_value]);
  const send = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ tracking_no: string }>("/api/w/parcels", { ...core(), recipient_name: f.recipient_name, recipient_mobile: f.recipient_mobile,
                                                                           contents: f.contents || null, idempotency_key: newKey() });
      setSent(r.tracking_no); toast(t("wf.sendParcel.done")); mine.reload();
      setF({ ...f, recipient_name: "", recipient_mobile: "", contents: "" }); setQuote(null);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="grid cols-2 wf-split">
      <div className="card stack">
        <h3>{t("wf.sendParcel.form")}</h3>
        <Loaded state={opts}>{(o) => (
          <form className="stack" onSubmit={(e) => { e.preventDefault(); void send(); }}>
            <Field label={t("wf.sendParcel.service")}>
              <select required value={f.service_id} onChange={set("service_id")}>
                <option value="">—</option>{o.services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </select>
            </Field>
            <div className="grid cols-2">
              <Field label={t("common.from")}><StationSelect stations={o.stations} value={f.origin_station_id} onChange={set("origin_station_id")} /></Field>
              <Field label={t("common.to")}><StationSelect stations={o.stations} value={f.dest_station_id} onChange={set("dest_station_id")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("wf.sendParcel.weight")}><input type="number" min="0.1" step="0.1" required value={f.weight_kg} onChange={set("weight_kg")} /></Field>
              <Field label={t("wf.sendParcel.value")} hint={t("common.optional")}><input type="number" min="0" step="1000" value={f.declared_value} onChange={set("declared_value")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("wf.sendParcel.recipient")}><input required minLength={3} value={f.recipient_name} onChange={set("recipient_name")} /></Field>
              <Field label={t("wf.sendParcel.mobile")}><input required className="ltr" inputMode="tel" pattern="\+?[0-9]{8,15}" value={f.recipient_mobile} onChange={set("recipient_mobile")} /></Field>
            </div>
            <Field label={t("wf.sendParcel.contents")} hint={t("common.optional")}><input maxLength={200} value={f.contents} onChange={set("contents")} /></Field>
            <div className="quote-box">
              <span className="muted">{t("wf.price")}</span>
              <strong>{quote ? money(quote.price) : "—"}</strong>
            </div>
            <ErrorBox error={error} />
            <button className="btn large" disabled={!quote || busy}><Icon name="package_2" />{quote ? t("wf.sendParcel.send", { amount: money(quote.price) }) : t("wf.sendParcel.sendShort")}</button>
            {sent && <div className="alert ok"><Icon name="check_circle" /><span>{t("wf.sendParcel.sent")} <Link className="mono ltr" to={`/track/${sent}`}>{sent}</Link></span></div>}
          </form>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3>{t("wf.sendParcel.mine")}</h3>
        <Loaded state={mine}>{(m) => m.parcels.length === 0 ? <Empty icon="package_2" title={t("wf.sendParcel.noneYet")} /> : (
          <div className="list">
            {m.parcels.map((p) => (
              <Link key={p.tracking_no} to={`/track/${p.tracking_no}`} className="list-row">
                <div className="stack tight">
                  <span className="mono ltr">{p.tracking_no}</span>
                  <span className="small muted">{station(p.origin_code, p.origin)} → {station(p.destination_code, p.destination)} · {dateTime(p.created_at)}</span>
                </div>
                <Status value={p.status} />
              </Link>
            ))}
          </div>
        )}</Loaded>
      </div>
    </div>
  );
}

function StationSelect({ stations, value, onChange }: { stations: Station[]; value: string; onChange: (e: { target: { value: string } }) => void }) {
  const { city, station } = useI18n();
  const groups = useMemo(() => {
    const g = new Map<string, Station[]>();
    for (const s of stations) g.set(s.city, [...(g.get(s.city) ?? []), s]);
    return [...g.entries()];
  }, [stations]);
  return (
    <select required value={value} onChange={onChange}>
      <option value="">—</option>
      {groups.map(([c, list]) => <optgroup key={c} label={city(c)}>{list.map((s) => <option key={s.id} value={s.id}>{station(s.code, s.name)}</option>)}</optgroup>)}
    </select>
  );
}

// ------------------------------------------------------------------ taxi

interface TaxiCity { id: number; code: string; lat: number; lng: number }
interface TaxiReq { uid: string; pickup_text: string; dropoff_text: string; fare_estimate: number; status: string; created_at: string; city: string; ride_status: string | null; fare: number | null }
interface Spot { key: string; lat: number; lng: number }

export function RequestTaxi() {
  const { t, money, dateTime, city } = useI18n();
  const toast = useToast();
  const cities = useLoad(() => api.get<{ cities: TaxiCity[] }>("/api/w/taxi/cities"));
  const mine = useLoad(() => api.get<{ requests: TaxiReq[] }>("/api/w/taxi/requests/mine"));
  const [cityId, setCityId] = useState<number | null>(null);
  const [from, setFrom] = useState(""); const [to, setTo] = useState("");
  const [here, setHere] = useState<Spot | null>(null);
  const [kind, setKind] = useState<"INSTANT" | "ADVANCE">("INSTANT");
  const [when, setWhen] = useState(isoLocal(new Date(Date.now() + 3600e3)));
  const [est, setEst] = useState<{ km: number; minutes: number; fare: number } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const current = cities.data?.cities.find((c) => c.id === cityId) ?? cities.data?.cities[0];
  const spots: Spot[] = useMemo(() => {
    if (!current) return [];
    const list = PLACES[current.code] ?? [{ key: "centre", lat: current.lat, lng: current.lng }];
    return here ? [here, ...list] : list;
  }, [current, here]);
  const label = (k: string) => (k === "here" ? t("wf.taxi.myLocation") : t(`place.${current?.code}.${k}`));
  const a = spots.find((s) => s.key === from), b = spots.find((s) => s.key === to);
  const trip = a && b && current ? { city_id: current.id, pickup_lat: a.lat, pickup_lng: a.lng, dropoff_lat: b.lat, dropoff_lng: b.lng } : null;
  useEffect(() => {
    setEst(null);
    if (!trip) return;
    api.post<{ km: number; minutes: number; fare: number }>("/api/w/taxi/estimate", trip).then((r) => { setEst(r); setError(null); }).catch(setError);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [from, to, current?.id]);
  const locate = () => navigator.geolocation?.getCurrentPosition((p) => { setHere({ key: "here", lat: p.coords.latitude, lng: p.coords.longitude }); setFrom("here"); },
    () => setError(new Error("geo")));
  const order = async () => {
    if (!trip || !a || !b) return;
    setBusy(true); setError(null);
    try {
      await api.post("/api/w/taxi/requests", { ...trip, pickup_text: label(a.key), dropoff_text: label(b.key), kind,
                                               requested_for: kind === "ADVANCE" ? new Date(when).toISOString() : null });
      toast(t("wf.taxi.done")); mine.reload(); setFrom(""); setTo("");
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const cancel = async (uid: string) => {
    try { await api.post(`/api/w/taxi/requests/${uid}/cancel`); toast(t("wf.taxi.cancelled")); mine.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="grid cols-2 wf-split">
      <div className="card stack">
        <h3>{t("wf.taxi.form")}</h3>
        <Loaded state={cities}>{(c) => c.cities.length === 0 ? <Empty icon="local_taxi" title={t("wf.taxi.noCity")} /> : (
          <form className="stack" onSubmit={(e) => { e.preventDefault(); void order(); }}>
            <Field label={t("common.city")}>
              <select value={current?.id} onChange={(e) => { setCityId(Number(e.target.value)); setFrom(""); setTo(""); setHere(null); }}>
                {c.cities.map((x) => <option key={x.id} value={x.id}>{city(x.code)}</option>)}
              </select>
            </Field>
            <Field label={t("wf.taxi.pickup")}>
              <div className="row nowrap">
                <select required value={from} onChange={(e) => setFrom(e.target.value)} style={{ flex: 1 }}>
                  <option value="">—</option>{spots.map((s) => <option key={s.key} value={s.key}>{label(s.key)}</option>)}
                </select>
                <button type="button" className="icon-btn" title={t("wf.taxi.myLocation")} onClick={locate}><Icon name="location_on" /></button>
              </div>
            </Field>
            <Field label={t("wf.taxi.dropoff")}>
              <select required value={to} onChange={(e) => setTo(e.target.value)}>
                <option value="">—</option>{spots.filter((s) => s.key !== "here").map((s) => <option key={s.key} value={s.key}>{label(s.key)}</option>)}
              </select>
            </Field>
            <div className="segmented" role="radiogroup">
              {(["INSTANT", "ADVANCE"] as const).map((k) => (
                <button type="button" key={k} role="radio" aria-checked={kind === k} className={kind === k ? "on" : ""} onClick={() => setKind(k)}>{t(`wf.taxi.${k}`)}</button>
              ))}
            </div>
            {kind === "ADVANCE" && <Field label={t("wf.taxi.when")}><input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} /></Field>}
            <div className="quote-box">
              <span className="muted">{est ? t("wf.taxi.estimate", { km: est.km, min: est.minutes }) : t("wf.taxi.pick")}</span>
              <strong>{est ? money(est.fare) : "—"}</strong>
            </div>
            <ErrorBox error={error} />
            <button className="btn large" disabled={!est || busy}><Icon name="local_taxi" />{t("wf.taxi.order")}</button>
            <p className="small muted">{t("wf.taxi.payNote")}</p>
          </form>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3>{t("wf.taxi.mine")}</h3>
        <Loaded state={mine}>{(m) => m.requests.length === 0 ? <Empty icon="local_taxi" title={t("wf.taxi.noneYet")} /> : (
          <div className="list">
            {m.requests.map((r) => (
              <div key={r.uid} className="list-row">
                <div className="stack tight">
                  <span>{r.pickup_text} → {r.dropoff_text}</span>
                  <span className="small muted">{city(r.city)} · {dateTime(r.created_at)} · {money(r.fare ?? r.fare_estimate)}</span>
                </div>
                <div className="row nowrap">
                  <Status value={r.ride_status ?? r.status} />
                  {(r.status === "SEARCHING" || r.status === "ASSIGNED") && <button className="btn text small" onClick={() => cancel(r.uid)}>{t("common.cancel")}</button>}
                </div>
              </div>
            ))}
          </div>
        )}</Loaded>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ car rental

interface Branch { id: number; station: string; station_code: string; city: string; brand: string }
interface Offer { rate_id: number; rental_class: string; class_name: string; unit: string; price: number; total: number; days: number; deposit: number; km_per_day: number | null; available: number }
interface Rental { uid: string; rental_class: string; class_name: string; starts_at: string; ends_at: string; quoted_total: number; status: string; brand: string; pickup: string; pickup_code: string }

export function RentCar() {
  const { t, money, dateTime, city, station, has } = useI18n();
  const toast = useToast();
  const [q, setQ] = useState({ branch_id: "", starts_at: isoLocal(new Date(Date.now() + 86400e3)), ends_at: isoLocal(new Date(Date.now() + 4 * 86400e3)) });
  const params = q.branch_id ? { branch_id: q.branch_id, starts_at: new Date(q.starts_at).toISOString(), ends_at: new Date(q.ends_at).toISOString() } : {};
  const offers = useLoad(() => api.get<{ branches: Branch[]; offers: Offer[] }>("/api/w/rental/offers", params), [q.branch_id, q.starts_at, q.ends_at]);
  const mine = useLoad(() => api.get<{ bookings: Rental[] }>("/api/w/rental/bookings/mine"));
  const [pick, setPick] = useState<Offer | null>(null);
  const [error, setError] = useState<unknown>(null);
  const book = async () => {
    if (!pick) return;
    setError(null);
    try {
      await api.post("/api/w/rental/bookings", { rate_id: pick.rate_id, pickup_branch_id: Number(q.branch_id), ...params });
      toast(t("wf.rent.done")); setPick(null); mine.reload();
    } catch (e) { setError(e); }
  };
  const cancel = async (uid: string) => {
    try { await api.post(`/api/w/rental/bookings/${uid}/cancel`); mine.reload(); } catch (e) { setError(e); }
  };
  const cls = (code: string, name: string) => (has(`val.${code}`) ? t(`val.${code}`) : name);
  return (
    <div className="stack">
      <div className="card stack">
        <div className="grid cols-3">
          <Field label={t("wf.rent.branch")}>
            <select value={q.branch_id} onChange={(e) => setQ({ ...q, branch_id: e.target.value })}>
              <option value="">—</option>
              {(offers.data?.branches ?? []).map((b) => <option key={b.id} value={b.id}>{city(b.city)} · {station(b.station_code, b.station)} · {b.brand}</option>)}
            </select>
          </Field>
          <Field label={t("wf.rent.pickupAt")}><input type="datetime-local" value={q.starts_at} onChange={(e) => setQ({ ...q, starts_at: e.target.value })} /></Field>
          <Field label={t("wf.rent.returnAt")}><input type="datetime-local" value={q.ends_at} onChange={(e) => setQ({ ...q, ends_at: e.target.value })} /></Field>
        </div>
        {!q.branch_id ? <p className="muted">{t("wf.rent.pickBranch")}</p> : (
          <Loaded state={offers}>{(o) => o.offers.length === 0 ? <Empty icon="car_rental" title={t("wf.rent.none")} /> : (
            <div className="grid cols-3">
              {o.offers.map((x) => (
                <div key={x.rate_id} className="offer-card">
                  <div className="row between nowrap"><h3>{cls(x.rental_class, x.class_name)}</h3>
                    <span className={`chip ${x.available > 0 ? "green" : "red"}`}>{t("wf.rent.available", { n: x.available })}</span></div>
                  <div className="offer-price">{money(x.total)}</div>
                  <ul className="small muted plain">
                    <li>{t("wf.rent.forDays", { n: x.days })} · {money(x.price)} / {t(`wf.rent.unit.${x.unit}`)}</li>
                    {x.km_per_day && <li>{t("wf.rent.km", { n: x.km_per_day })}</li>}
                    <li>{t("wf.rent.deposit", { amount: money(x.deposit) })}</li>
                  </ul>
                  <button className="btn" disabled={x.available === 0} onClick={() => { setPick(x); setError(null); }}>{t("wf.rent.book")}</button>
                </div>
              ))}
            </div>
          )}</Loaded>
        )}
      </div>
      <div className="card stack">
        <h3>{t("wf.rent.mine")}</h3>
        <Loaded state={mine}>{(m) => m.bookings.length === 0 ? <Empty icon="car_rental" title={t("wf.rent.noneYet")} /> : (
          <div className="list">
            {m.bookings.map((b) => (
              <div key={b.uid} className="list-row">
                <div className="stack tight">
                  <span>{cls(b.rental_class, b.class_name)} · {b.brand}</span>
                  <span className="small muted">{station(b.pickup_code, b.pickup)} · {dateTime(b.starts_at)} → {dateTime(b.ends_at)} · {money(b.quoted_total)}</span>
                </div>
                <div className="row nowrap">
                  <Status value={b.status} />
                  {(b.status === "PENDING" || b.status === "CONFIRMED") && <button className="btn text small" onClick={() => cancel(b.uid)}>{t("common.cancel")}</button>}
                </div>
              </div>
            ))}
          </div>
        )}</Loaded>
      </div>
      {pick && (
        <Modal title={t("wf.rent.confirm")} onClose={() => setPick(null)}
               actions={<><button className="btn text" onClick={() => setPick(null)}>{t("common.cancel")}</button><button className="btn" onClick={book}>{t("wf.rent.book")}</button></>}>
          <dl className="kv">
            <div><dt>{t("wf.rent.class")}</dt><dd>{cls(pick.rental_class, pick.class_name)}</dd></div>
            <div><dt>{t("wf.price")}</dt><dd>{money(pick.total)}</dd></div>
            <div><dt>{t("wf.rent.pickupAt")}</dt><dd>{dateTime(new Date(q.starts_at))}</dd></div>
            <div><dt>{t("wf.rent.returnAt")}</dt><dd>{dateTime(new Date(q.ends_at))}</dd></div>
          </dl>
          <p className="muted small">{t("wf.rent.note", { amount: money(pick.deposit) })}</p>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ freight (shipper)

interface Bid { id: number; price: number; valid_until: string; status: string; carrier: string; created_at: string }
interface Load { uid: string; cargo_category: string; cargo_description: string; declared_weight_kg: number; pickup_from: string; pickup_to: string; target_price: number | null; status: string; origin: string; destination: string; origin_code: string; destination_code: string; bids: Bid[] }

const CARGO = ["GENERAL", "FOOD", "REFRIGERATED", "LIQUID", "LIVESTOCK", "VEHICLES", "CONTAINERS", "OTHER"];
const TRAILERS = ["FLATBED", "CURTAIN", "REEFER", "TANKER", "CONTAINER_CHASSIS", "LOWBED", "TIPPER", "BOX"];

export function PostLoad() {
  const { t, money, dateTime, station, num } = useI18n();
  const toast = useToast();
  const opts = useLoad(() => api.get<{ stations: Station[] }>("/api/w/parcels/options"));
  const mine = useLoad(() => api.get<{ requests: Load[] }>("/api/w/freight/requests/mine"));
  const [f, setF] = useState({ origin_station_id: "", dest_station_id: "", cargo_category: "GENERAL", cargo_description: "", declared_weight_kg: "",
                               packages: "", required_trailer_type: "", pickup_from: isoLocal(new Date(Date.now() + 2 * 86400e3)),
                               pickup_to: isoLocal(new Date(Date.now() + 3 * 86400e3)), target_price: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const post = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/w/freight/requests", {
        origin_station_id: Number(f.origin_station_id), dest_station_id: Number(f.dest_station_id), cargo_category: f.cargo_category,
        cargo_description: f.cargo_description, declared_weight_kg: Number(f.declared_weight_kg), packages: f.packages ? Number(f.packages) : null,
        required_trailer_type: f.required_trailer_type || null, pickup_from: new Date(f.pickup_from).toISOString(),
        pickup_to: new Date(f.pickup_to).toISOString(), target_price: f.target_price ? toMinor(f.target_price) : null });
      toast(t("wf.load.done")); mine.reload(); setF({ ...f, cargo_description: "", declared_weight_kg: "", packages: "", target_price: "" });
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const accept = async (bid: Bid) => {
    if (!confirm(t("wf.load.acceptConfirm", { carrier: bid.carrier, amount: money(bid.price) }))) return;
    try { await api.post(`/api/w/freight/bids/${bid.id}/accept`); toast(t("wf.load.accepted")); mine.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="grid cols-2 wf-split">
      <div className="card stack">
        <h3>{t("wf.load.form")}</h3>
        <Loaded state={opts}>{(o) => (
          <form className="stack" onSubmit={(e) => { e.preventDefault(); void post(); }}>
            <div className="grid cols-2">
              <Field label={t("common.from")}><StationSelect stations={o.stations} value={f.origin_station_id} onChange={set("origin_station_id")} /></Field>
              <Field label={t("common.to")}><StationSelect stations={o.stations} value={f.dest_station_id} onChange={set("dest_station_id")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("wf.load.category")}><select value={f.cargo_category} onChange={set("cargo_category")}>{CARGO.map((c) => <option key={c} value={c}>{t(`wf.load.cat.${c}`)}</option>)}</select></Field>
              <Field label={t("wf.load.trailer")} hint={t("common.optional")}>
                <select value={f.required_trailer_type} onChange={set("required_trailer_type")}><option value="">—</option>{TRAILERS.map((c) => <option key={c} value={c}>{t(`val.${c}`)}</option>)}</select>
              </Field>
            </div>
            <Field label={t("wf.load.description")}><input required minLength={3} maxLength={300} value={f.cargo_description} onChange={set("cargo_description")} /></Field>
            <div className="grid cols-3">
              <Field label={t("wf.load.weight")}><input type="number" required min="1" value={f.declared_weight_kg} onChange={set("declared_weight_kg")} /></Field>
              <Field label={t("wf.load.packages")} hint={t("common.optional")}><input type="number" min="1" value={f.packages} onChange={set("packages")} /></Field>
              <Field label={t("wf.load.target")} hint={t("common.optional")}><input type="number" min="0" step="1000" value={f.target_price} onChange={set("target_price")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("wf.load.pickupFrom")}><input type="datetime-local" required value={f.pickup_from} onChange={set("pickup_from")} /></Field>
              <Field label={t("wf.load.pickupTo")}><input type="datetime-local" required value={f.pickup_to} onChange={set("pickup_to")} /></Field>
            </div>
            <ErrorBox error={error} />
            <button className="btn large" disabled={busy}><Icon name="local_shipping" />{t("wf.load.post")}</button>
          </form>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3>{t("wf.load.mine")}</h3>
        <Loaded state={mine}>{(m) => m.requests.length === 0 ? <Empty icon="local_shipping" title={t("wf.load.noneYet")} /> : (
          <div className="stack">
            {m.requests.map((r) => (
              <div key={r.uid} className="load-card">
                <div className="row between nowrap"><strong>{station(r.origin_code, r.origin)} → {station(r.destination_code, r.destination)}</strong><Status value={r.status} /></div>
                <div className="small muted">{r.cargo_description} · {num(r.declared_weight_kg)} {t("wf.kg")} · {dateTime(r.pickup_from)}</div>
                {r.bids.length === 0 ? <div className="small muted">{t("wf.load.noBids")}</div> : (
                  <table className="table compact">
                    <tbody>{r.bids.map((b) => (
                      <tr key={b.id}>
                        <td>{b.carrier}</td><td className="num">{money(b.price)}</td><td><Status value={b.status} /></td>
                        <td className="num">{r.status === "OPEN" && b.status === "SUBMITTED" && <button className="btn tonal small" onClick={() => accept(b)}>{t("wf.load.accept")}</button>}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                )}
              </div>
            ))}
          </div>
        )}</Loaded>
      </div>
    </div>
  );
}
