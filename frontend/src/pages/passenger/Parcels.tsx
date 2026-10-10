import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

type Mode = "WEIGHT" | "VOLUME" | "WEIGHT_AND_VOLUME" | "FIXED" | "NEGOTIATED";
interface Tariff { uid: string; code: string; name: string; pricing_mode: Mode; currency: string; max_weight_kg: number | null; max_volume_m3: number | null }
interface Hold { max_weight_kg: number; free_weight_kg: number; free_volume_m3: number | null; free_items: number | null }
interface HoldTrip { uid: string; trip_no: string; carrier_name: string; from_seq: number; to_seq: number; departs_at: string; from_station: string; to_station: string; hold: Hold; tariffs: Tariff[] }
interface Price { mode: Mode; currency: string; weight_kg: number; volume_m3: number; weight_charge: number | null; volume_charge: number | null; fixed: number | null; basis: string; total: number | null }
interface Quote { price: Price; fits: boolean; agreed: boolean }
interface Mine { tracking_no: string; status: string; trip_no: string | null; weight_kg: number | null; volume_m3: number | null; currency: string; price_breakdown: { total?: number }; guaranteed: boolean }
interface Offer { uid: string; status: string; trip_no: string; carrier_name: string; tariff_name: string; weight_kg: number; price: number | null; currency: string | null; valid_until: string | null; tracking_no: string | null }

const tomorrow = () => new Date(Date.now() + 86400000).toISOString().slice(0, 10);

/** Parcels booked on a trip's hold (owner's decision 3): pick a trip with free space, see the price by weight and size. */
export default function Parcels() {
  const { t, money, dateTime, num } = useI18n();
  const toast = useToast();
  const [q, setQ] = useState({ origin: "DAM", destination: "ALP", on: tomorrow() });
  const [search, setSearch] = useState(q);
  const trips = useLoad((signal) => api.get<{ trips: HoldTrip[] }>("/api/parcels/trips", search, { signal }), [search]);
  const mine = useLoad((signal) => api.get<{ parcels: Mine[] }>("/api/parcels/mine", undefined, { signal }));
  const offers = useLoad((signal) => api.get<{ offers: Offer[] }>("/api/parcels/offers", undefined, { signal }));
  const [pick, setPick] = useState<{ trip: HoldTrip; tariff: Tariff } | null>(null);
  const [size, setSize] = useState({ weight_kg: 1, length_cm: 30, width_cm: 20, height_cm: 10 });
  const [who, setWho] = useState({ description: "", recipient_name: "", recipient_mobile: "" });
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [accepting, setAccepting] = useState<Offer | null>(null);

  const body = () => pick && { trip_uid: pick.trip.uid, from_seq: pick.trip.from_seq, to_seq: pick.trip.to_seq, tariff_uid: pick.tariff.uid, ...size };
  const run = async (fn: () => Promise<void>) => { setBusy(true); setError(null); try { await fn(); } catch (e) { setError(e); } finally { setBusy(false); } };
  const doQuote = () => run(async () => setQuote(await api.post<Quote>("/api/parcels/quote", body())));
  const doBook = () => run(async () => {
    const r = await api.post<{ tracking_no: string }>("/api/parcels", { ...body(), ...who, idempotency_key: crypto.randomUUID() });
    toast(t("parcel.booked", { no: r.tracking_no })); setPick(null); setQuote(null); mine.reload(); trips.reload();
  });
  const doAsk = () => run(async () => {
    await api.post("/api/parcels/offers", { ...body(), description: who.description });
    toast(t("parcel.asked")); setPick(null); setQuote(null); offers.reload();
  });
  const doAccept = () => accepting && run(async () => {
    const r = await api.post<{ tracking_no: string }>(`/api/parcels/offers/${accepting.uid}/accept`,
      { recipient_name: who.recipient_name, recipient_mobile: who.recipient_mobile, idempotency_key: crypto.randomUUID() });
    toast(t("parcel.booked", { no: r.tracking_no })); setAccepting(null); offers.reload(); mine.reload();
  });
  const set = <T extends object>(o: T, f: (v: T) => void, k: keyof T, n = false) =>
    (e: React.ChangeEvent<HTMLInputElement>) => f({ ...o, [k]: n ? Number(e.target.value) : e.target.value });

  return (
    <div className="page stack">
      <div className="page-head"><div><h1 style={{ fontSize: 28 }}>{t("parcel.title")}</h1><p>{t("parcel.sub")}</p></div></div>
      <form className="card grid cols-4" onSubmit={(e) => { e.preventDefault(); setSearch(q); }}>
        <Field label={t("parcel.from")}><input className="input ltr" value={q.origin} maxLength={3} onChange={(e) => setQ({ ...q, origin: e.target.value.toUpperCase() })} /></Field>
        <Field label={t("parcel.to")}><input className="input ltr" value={q.destination} maxLength={3} onChange={(e) => setQ({ ...q, destination: e.target.value.toUpperCase() })} /></Field>
        <Field label={t("parcel.on")}><input className="input" type="date" value={q.on} onChange={(e) => setQ({ ...q, on: e.target.value })} /></Field>
        <div style={{ alignSelf: "end" }}><button className="btn filled"><Icon name="search" />{t("parcel.find")}</button></div>
      </form>
      <Loaded state={trips}>{({ trips: list }) => list.length === 0 ? <Empty icon="local_shipping" title={t("parcel.none")} /> : (
        <div className="stack">{list.map((tr) => (
          <section key={tr.uid} className="card stack">
            <div className="row" style={{ justifyContent: "space-between" }}>
              <strong>{tr.carrier_name} · <span className="mono">{tr.trip_no}</span></strong>
              <span className="small">{dateTime(tr.departs_at)} · {tr.from_station} → {tr.to_station}</span>
            </div>
            <p className="small">{t("parcel.free", { kg: num(tr.hold.free_weight_kg) })}{tr.hold.free_volume_m3 != null && ` · ${t("parcel.freeVolume", { m3: num(tr.hold.free_volume_m3) })}`}</p>
            <div className="row" style={{ flexWrap: "wrap" }}>{tr.tariffs.map((x) => (
              <button key={x.uid} className="btn outlined" onClick={() => { setPick({ trip: tr, tariff: x }); setQuote(null); }}>
                {x.name} <span className="small">({t(`parcel.mode.${x.pricing_mode}`)})</span></button>
            ))}</div>
          </section>
        ))}</div>
      )}</Loaded>

      {pick && (
        <Modal title={`${pick.tariff.name} · ${pick.trip.trip_no}`} onClose={() => setPick(null)} wide actions={<>
          <button className="btn outlined" disabled={busy} onClick={doQuote}>{t("parcel.quote")}</button>
          {pick.tariff.pricing_mode === "NEGOTIATED"
            ? <button className="btn filled" disabled={busy || who.description.length < 2} onClick={doAsk}>{t("parcel.ask")}</button>
            : <button className="btn filled" disabled={busy || !quote?.fits || who.recipient_name.length < 3} onClick={doBook}>{t("parcel.book")}</button>}
        </>}>
          <div className="grid cols-4">
            <Field label={t("parcel.weight")}><input className="input" type="number" min={0.1} step={0.1} value={size.weight_kg} onChange={set(size, setSize, "weight_kg", true)} /></Field>
            <Field label={t("parcel.length")}><input className="input" type="number" min={1} value={size.length_cm} onChange={set(size, setSize, "length_cm", true)} /></Field>
            <Field label={t("parcel.width")}><input className="input" type="number" min={1} value={size.width_cm} onChange={set(size, setSize, "width_cm", true)} /></Field>
            <Field label={t("parcel.height")}><input className="input" type="number" min={1} value={size.height_cm} onChange={set(size, setSize, "height_cm", true)} /></Field>
          </div>
          <div className="grid cols-3">
            <Field label={t("parcel.contents")}><input className="input" value={who.description} onChange={set(who, setWho, "description")} /></Field>
            <Field label={t("parcel.recipient")}><input className="input" value={who.recipient_name} onChange={set(who, setWho, "recipient_name")} /></Field>
            <Field label={t("parcel.mobile")}><input className="input ltr" value={who.recipient_mobile} onChange={set(who, setWho, "recipient_mobile")} /></Field>
          </div>
          {quote && (
            <div className="card stack" aria-live="polite">
              <div className="row" style={{ justifyContent: "space-between" }}><span>{t("parcel.weight")}</span><strong>{num(quote.price.weight_kg)} kg</strong></div>
              <div className="row" style={{ justifyContent: "space-between" }}><span>{t("parcel.volume")}</span><strong>{num(quote.price.volume_m3)} m³</strong></div>
              {quote.price.weight_charge != null && <div className="row" style={{ justifyContent: "space-between" }}><span>{t("parcel.byWeight")}</span><span>{money(quote.price.weight_charge, true, quote.price.currency)}</span></div>}
              {quote.price.volume_charge != null && <div className="row" style={{ justifyContent: "space-between" }}><span>{t("parcel.byVolume")}</span><span>{money(quote.price.volume_charge, true, quote.price.currency)}</span></div>}
              <div className="row" style={{ justifyContent: "space-between" }}><span>{t(`parcel.basis.${quote.price.basis}`)}</span>
                <strong>{quote.price.total == null ? t("parcel.agreed") : money(quote.price.total, true, quote.price.currency)}</strong></div>
              {!quote.fits && <p className="small" style={{ color: "var(--error)" }}>{t("parcel.noSpace")}</p>}
            </div>
          )}
          <ErrorBox error={error} />
        </Modal>
      )}

      <section className="card stack" aria-labelledby="my-offers">
        <h3 id="my-offers">{t("parcel.offers")}</h3>
        <Loaded state={offers}>{({ offers: list }) => list.length === 0 ? <p className="small muted">{t("parcel.noOffers")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table"><tbody>{list.map((o) => (
            <tr key={o.uid}><td>{o.carrier_name} · <span className="mono">{o.trip_no}</span></td><td>{o.tariff_name}</td><td>{num(o.weight_kg)} kg</td>
              <td><Status value={o.status} /></td><td>{o.price != null && o.currency ? money(o.price, true, o.currency) : "—"}</td>
              <td>{o.status === "OFFERED" && <button className="btn filled" onClick={() => setAccepting(o)}>{t("parcel.accept")}</button>}</td></tr>
          ))}</tbody></table></div>
        )}</Loaded>
      </section>
      {accepting && (
        <Modal title={t("parcel.accept")} onClose={() => setAccepting(null)} actions={
          <button className="btn filled" disabled={busy || who.recipient_name.length < 3} onClick={doAccept}>{t("parcel.book")}</button>}>
          <div className="grid cols-2">
            <Field label={t("parcel.recipient")}><input className="input" value={who.recipient_name} onChange={set(who, setWho, "recipient_name")} /></Field>
            <Field label={t("parcel.mobile")}><input className="input ltr" value={who.recipient_mobile} onChange={set(who, setWho, "recipient_mobile")} /></Field>
          </div>
          <ErrorBox error={error} />
        </Modal>
      )}

      <section className="card stack" aria-labelledby="my-parcels">
        <h3 id="my-parcels">{t("parcel.mine")}</h3>
        <Loaded state={mine}>{({ parcels }) => parcels.length === 0 ? <p className="small muted">{t("parcel.noneYet")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table"><tbody>{parcels.map((p) => (
            <tr key={p.tracking_no}><td className="mono">{p.tracking_no}</td><td className="mono">{p.trip_no ?? "—"}</td>
              <td>{p.weight_kg != null ? `${num(p.weight_kg)} kg` : "—"}{p.volume_m3 != null && ` · ${num(p.volume_m3)} m³`}</td>
              <td>{p.price_breakdown.total != null ? money(p.price_breakdown.total, true, p.currency) : "—"}</td><td><Status value={p.status} /></td></tr>
          ))}</tbody></table></div>
        )}</Loaded>
      </section>
    </div>
  );
}
