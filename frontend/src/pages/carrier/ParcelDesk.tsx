import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { api, newKey } from "../../api";
import { fromMinor, toMinor, useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

export interface ParcelLabel {
  tracking_no: string; label_no: string; status: string; sender_name: string | null; shipper_name: string | null; recipient_name: string;
  recipient_mobile: string; contents: string; weight_kg: number | null; trip_no: string; from_code: string; from_station: string; to_code: string;
  to_station: string; departs_at: string; paid_at: string | null; pay_method: string | null; handed_over_at: string | null; price: string | null;
  currency: string; carrier_name: string; code: string;
}
interface Settings {
  booking_mode: "ONLINE_DROPOFF" | "COUNTER_ONLY"; handover_minutes: number; cancel_fee: number; no_show_fee: number; address_delivery: boolean; address_fee: number;
  pending_fees: { cancel_fee: number; no_show_fee: number } | null; fees_decision: string | null; allowed: boolean; not_allowed_reason: string | null;
  min_handover_minutes: number; fee_policy: "CARRIER" | "PLATFORM"; prohibited: string[];
}
interface Point { uid: string; kind: "STATION" | "OFFICE"; name: string; address: string; hours: string; phone: string | null; status: string; station_code: string | null }
interface Awaiting { tracking_no: string; status: string; handover_by: string | null; paid_at: string | null; recipient_name: string; contents: string;
  price: string | null; currency: string; shipper_name: string | null; trip_no: string; departs_at: string; drop_point: string | null }
interface Trip { uid: string; trip_no: string; trip_code?: string | null; departure_at: string; segments_count: number; origin: string; destination: string; status: string }
interface Tariff { uid: string; code: string; name: string; status: string }

/** A prohibited item: its words when the platform used one of the known codes, else the text the platform wrote. */
export function useItem() {
  const { t, has } = useI18n();
  return (code: string) => (has(`parcel.item.${code}`) ? t(`parcel.item.${code}`) : code);
}

/** The label printed when the parcel is handed over: who sends to whom, on which trip, with its signed code. */
export function LabelView({ label, onClose }: { label: ParcelLabel; onClose: () => void }) {
  const { t, money, dateTime, num } = useI18n();
  const [qr, setQr] = useState<string | null>(null);
  useEffect(() => { void QRCode.toDataURL(label.code, { margin: 1, width: 220 }).then(setQr); }, [label.code]);
  return (
    <Modal title={t("parcel.labelTitle")} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.close")}</button>
      <button className="btn" onClick={() => print()}><Icon name="print" />{t("common.print")}</button></>}>
      <div className="parcel-label stack">
        <div className="row" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
          <div className="stack" style={{ gap: 4 }}>
            <strong>{label.carrier_name}</strong>
            <span className="mono" style={{ fontSize: 20 }}>{label.tracking_no}</span>
            <span className="small mono">{label.label_no}</span>
          </div>
          {qr && <img src={qr} alt={t("parcel.labelCode")} width={140} height={140} />}
        </div>
        <div className="grid cols-2">
          <div><span className="small muted">{t("parcel.fromTo")}</span><div><strong>{label.from_code}</strong> {label.from_station} → <strong>{label.to_code}</strong> {label.to_station}</div></div>
          <div><span className="small muted">{t("parcel.trip")}</span><div className="mono">{label.trip_no} · {dateTime(label.departs_at)}</div></div>
          <div><span className="small muted">{t("parcel.sender")}</span><div>{label.sender_name ?? label.shipper_name ?? "—"}</div></div>
          <div><span className="small muted">{t("parcel.recipient")}</span><div>{label.recipient_name} · <span className="ltr">{label.recipient_mobile}</span></div></div>
          <div><span className="small muted">{t("parcel.contents")}</span><div>{label.contents}</div></div>
          <div><span className="small muted">{t("parcel.weight")}</span><div>{label.weight_kg != null ? `${num(label.weight_kg)} kg` : "—"}</div></div>
          <div><span className="small muted">{t("parcel.paid")}</span><div>{label.price != null ? money(Number(label.price), true, label.currency) : "—"}
            {label.pay_method && ` · ${t(`parcel.payMethod.${label.pay_method}`)}`}</div></div>
          <div><span className="small muted">{t("parcel.handedOver")}</span><div>{label.handed_over_at ? dateTime(label.handed_over_at) : "—"}</div></div>
        </div>
      </div>
    </Modal>
  );
}

/** Online reservations waiting for the sender: receive the parcel, take the cash if unpaid, print the label. */
export function ParcelAwaiting() {
  const { t, money, dateTime } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ parcels: Awaiting[] }>("/api/carrier/parcels/awaiting", undefined, { signal }));
  const [receiving, setReceiving] = useState<Awaiting | null>(null);
  const [weight, setWeight] = useState("");
  const [label, setLabel] = useState<ParcelLabel | null>(null);
  const [find, setFind] = useState("");
  const [error, setError] = useState<unknown>(null);
  const receive = async () => {
    if (!receiving) return;
    setError(null);
    try {
      const l = await api.post<ParcelLabel>(`/api/carrier/parcels/${receiving.tracking_no}/receive`, { weight_kg: weight ? Number(weight) : null });
      toast(t("parcel.received")); setReceiving(null); setWeight(""); setLabel(l); state.reload();
    } catch (e) { setError(e); }
  };
  const openLabel = async () => {
    setError(null);
    try { setLabel(await api.get<ParcelLabel>(`/api/carrier/parcels/${find.trim().toUpperCase()}/label`)); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <form className="card row" style={{ gap: 8, flexWrap: "wrap" }} onSubmit={(e) => { e.preventDefault(); void openLabel(); }}>
        <Field label={t("parcel.tracking")}><input className="input ltr mono" value={find} onChange={(e) => setFind(e.target.value)} /></Field>
        <button className="btn tonal" style={{ alignSelf: "end" }} disabled={find.trim().length < 6}><Icon name="qr_code_2" />{t("parcel.reprint")}</button>
      </form>
      <ErrorBox error={error} />
      <div className="card">
        <Loaded state={state}>{({ parcels }) => parcels.length === 0 ? <Empty icon="inventory_2" title={t("parcel.noneAwaiting")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("parcel.tracking")}</th><th>{t("parcel.trip")}</th><th>{t("parcel.handoverBy")}</th><th>{t("parcel.recipient")}</th>
              <th>{t("parcel.contents")}</th><th className="num">{t("parcel.price")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{parcels.map((p) => (
              <tr key={p.tracking_no}>
                <td className="mono">{p.tracking_no}</td><td className="small"><span className="mono">{p.trip_no}</span> · {dateTime(p.departs_at)}</td>
                <td className="small">{p.handover_by ? dateTime(p.handover_by) : "—"}{p.drop_point && <div className="muted">{p.drop_point}</div>}</td>
                <td>{p.recipient_name}</td><td className="small">{p.contents}</td>
                <td className="num">{p.price != null ? money(Number(p.price), true, p.currency) : "—"}<div className="small muted">{p.paid_at ? t("parcel.paidOnline") : t("parcel.payAtCounter")}</div></td>
                <td><Status value={p.status} /></td>
                <td>{can("parcels.counter") && <button className="btn tonal" onClick={() => { setReceiving(p); setError(null); }}><Icon name="check_circle" />{t("parcel.receive")}</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {receiving && (
        <Modal title={t("parcel.receiveTitle", { no: receiving.tracking_no })} onClose={() => setReceiving(null)} actions={<>
          <button className="btn text" onClick={() => setReceiving(null)}>{t("common.cancel")}</button>
          <button className="btn" onClick={() => void receive()}>{t("parcel.receive")}</button></>}>
          <p className="small">{receiving.paid_at ? t("parcel.alreadyPaid") : t("parcel.collectCash", { amount: receiving.price != null ? money(Number(receiving.price), true, receiving.currency) : "—" })}</p>
          <Field label={t("parcel.weighed")} hint={t("parcel.weighedHint")}><input className="input ltr" type="number" min={0.1} step={0.1} value={weight} onChange={(e) => setWeight(e.target.value)} /></Field>
          <ErrorBox error={error} />
        </Modal>
      )}
      {label && <LabelView label={label} onClose={() => setLabel(null)} />}
    </div>
  );
}

/** How the parcel is handed over at its destination (1183): collected at the counter, or taken to an address when the
 *  carrier offers it (its fee shown); and whether it is important (code and identity check both required, every step told). */
export function HandOverChoice({ offers, fee, mode, address, secure, onChange }: { offers: boolean; fee: number; mode: "PICKUP" | "ADDRESS";
  address: string; secure: boolean; onChange: (v: { delivery_mode?: "PICKUP" | "ADDRESS"; delivery_address?: string; secure?: boolean }) => void }) {
  const { t, money } = useI18n();
  return (
    <fieldset className="stack" style={{ border: 0, padding: 0 }}>
      <legend className="small muted">{t("parcel.handOverTitle")}</legend>
      <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
        <label className="check"><input type="radio" name="parcel-handover" checked={mode === "PICKUP"} onChange={() => onChange({ delivery_mode: "PICKUP" })} />{t("parcel.journey.mode.PICKUP")}</label>
        {offers && <label className="check"><input type="radio" name="parcel-handover" checked={mode === "ADDRESS"} onChange={() => onChange({ delivery_mode: "ADDRESS" })} />
          {t("parcel.journey.mode.ADDRESS")}{fee > 0 && ` (+${money(fee)})`}</label>}
      </div>
      {mode === "ADDRESS" && <Field label={t("parcel.deliveryAddress")}><input className="input" maxLength={300} value={address} onChange={(e) => onChange({ delivery_address: e.target.value })} /></Field>}
      <label className="check"><input type="checkbox" checked={secure} onChange={(e) => onChange({ secure: e.target.checked })} />{t("parcel.secure")}</label>
      <p className="small muted">{t("parcel.secureHint")}</p>
    </fieldset>
  );
}

/** A parcel sold at the counter: the clerk takes the cash, receives the parcel and prints its label at once. */
export function CounterParcel() {
  const { t, dateTime } = useI18n();
  const item = useItem();
  const toast = useToast();
  const trips = useLoad((signal) => api.get<{ trips: Trip[] }>("/api/carrier/trips", undefined, { signal }));
  const tariffs = useLoad((signal) => api.get<{ tariffs: Tariff[] }>("/api/carrier/parcels/tariffs", undefined, { signal }));
  const settings = useLoad((signal) => api.get<Settings>("/api/carrier/parcels/settings", undefined, { signal }));
  const blank = { trip: "", tariff: "", weight_kg: 1, length_cm: 30, width_cm: 20, height_cm: 10, description: "", sender_name: "", recipient_name: "", recipient_mobile: "",
    delivery_mode: "PICKUP", delivery_address: "", secure: false as boolean };
  const [f, setF] = useState(blank);
  const [ok, setOk] = useState(false);
  const [label, setLabel] = useState<ParcelLabel | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: Exclude<keyof typeof blank, "secure">, n = false) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: n ? Number(e.target.value) : e.target.value });
  const upcoming = (trips.data?.trips ?? []).filter((x) => new Date(x.departure_at).getTime() > Date.now() && x.status !== "CANCELLED");
  const sell = async () => {
    const trip = upcoming.find((x) => x.uid === f.trip);
    if (!trip) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ tracking_no: string; label: ParcelLabel }>("/api/carrier/parcels/counter", {
        trip_uid: trip.uid, from_seq: 0, to_seq: trip.segments_count, tariff_uid: f.tariff, weight_kg: f.weight_kg, length_cm: f.length_cm,
        width_cm: f.width_cm, height_cm: f.height_cm, description: f.description, sender_name: f.sender_name, recipient_name: f.recipient_name,
        recipient_mobile: f.recipient_mobile, accept_rules: ok, idempotency_key: newKey(), delivery_mode: f.delivery_mode,
        delivery_address: f.delivery_mode === "ADDRESS" ? f.delivery_address : null, secure: f.secure });
      toast(t("parcel.sold", { no: out.tracking_no })); setLabel(out.label); setF(blank); setOk(false);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const ready = f.trip && f.tariff && ok && f.description.length >= 2 && f.sender_name.length >= 3 && f.recipient_name.length >= 3 && f.recipient_mobile.length >= 8
    && (f.delivery_mode === "PICKUP" || f.delivery_address.trim().length >= 5);
  return (
    <div className="card stack">
      <p className="small muted">{t("parcel.counterHint")}</p>
      <div className="grid cols-2">
        <Field label={t("parcel.trip")}>
          <select value={f.trip} onChange={set("trip")}><option value="">{t("parcel.choose")}</option>
            {upcoming.map((x) => <option key={x.uid} value={x.uid}>{x.trip_code ?? x.trip_no} · {x.origin} → {x.destination} · {dateTime(x.departure_at)}</option>)}</select>
        </Field>
        <Field label={t("parcel.tariff")}>
          <select value={f.tariff} onChange={set("tariff")}><option value="">{t("parcel.choose")}</option>
            {(tariffs.data?.tariffs ?? []).filter((x) => x.status === "ACTIVE").map((x) => <option key={x.uid} value={x.uid}>{x.name}</option>)}</select>
        </Field>
      </div>
      <div className="grid cols-4">
        <Field label={t("parcel.weight")}><input className="input ltr" type="number" min={0.1} step={0.1} value={f.weight_kg} onChange={set("weight_kg", true)} /></Field>
        <Field label={t("parcel.length")}><input className="input ltr" type="number" min={1} value={f.length_cm} onChange={set("length_cm", true)} /></Field>
        <Field label={t("parcel.width")}><input className="input ltr" type="number" min={1} value={f.width_cm} onChange={set("width_cm", true)} /></Field>
        <Field label={t("parcel.height")}><input className="input ltr" type="number" min={1} value={f.height_cm} onChange={set("height_cm", true)} /></Field>
      </div>
      <div className="grid cols-2">
        <Field label={t("parcel.contents")}><input className="input" value={f.description} onChange={set("description")} /></Field>
        <Field label={t("parcel.sender")}><input className="input" value={f.sender_name} onChange={set("sender_name")} /></Field>
        <Field label={t("parcel.recipient")}><input className="input" value={f.recipient_name} onChange={set("recipient_name")} /></Field>
        <Field label={t("parcel.mobile")}><input className="input ltr" value={f.recipient_mobile} onChange={set("recipient_mobile")} /></Field>
      </div>
      <HandOverChoice offers={settings.data?.address_delivery ?? false} fee={settings.data?.address_fee ?? 0} mode={f.delivery_mode as "PICKUP" | "ADDRESS"}
        address={f.delivery_address} secure={f.secure}
        onChange={(v) => setF({ ...f, ...v })} />
      {settings.data && (
        <div className="alert info small" style={{ flexDirection: "column", alignItems: "flex-start", gap: 4 }}>
          <strong>{t("parcel.prohibitedTitle")}</strong>
          <span>{settings.data.prohibited.map(item).join(" · ")}</span>
        </div>
      )}
      <label className="check"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} />{t("parcel.prohibitedAck")}</label>
      <ErrorBox error={error} />
      <div className="row"><button className="btn" disabled={busy || !ready} onClick={() => void sell()}><Icon name="point_of_sale" />{t("parcel.sellCash")}</button></div>
      {label && <LabelView label={label} onClose={() => setLabel(null)} />}
    </div>
  );
}

/** The carrier's choices: online booking with drop-off or counter only, the hand-over time and its fees. */
export function ParcelSettings() {
  const { t, money } = useI18n();
  const item = useItem();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Settings>("/api/carrier/parcels/settings", undefined, { signal }));
  const [f, setF] = useState<Pick<Settings, "booking_mode" | "handover_minutes" | "cancel_fee" | "no_show_fee" | "address_delivery" | "address_fee"> | null>(null);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { if (state.data) setF({ booking_mode: state.data.booking_mode, handover_minutes: state.data.handover_minutes,
    cancel_fee: state.data.cancel_fee, no_show_fee: state.data.no_show_fee, address_delivery: state.data.address_delivery ?? false,
    address_fee: state.data.address_fee ?? 0 }); }, [state.data]);
  const save = async () => {
    if (!f) return;
    setError(null);
    try { await api.put("/api/carrier/parcels/settings", f); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <Loaded state={state}>{(s) => f && (
        <>
          {!s.allowed && <div className="alert error" role="alert"><Icon name="error" /> <span>{t(`parcel.notAllowed.${s.not_allowed_reason ?? "CARRIER_TYPE"}`)}</span></div>}
          <fieldset className="stack" style={{ border: 0, padding: 0 }}>
            <legend className="small muted">{t("parcel.bookingMode")}</legend>
            {(["ONLINE_DROPOFF", "COUNTER_ONLY"] as const).map((m) => (
              <label key={m} className="check-row"><input type="radio" name="parcel-mode" checked={f.booking_mode === m} onChange={() => setF({ ...f, booking_mode: m })} />
                <span className="grow" style={{ display: "flex", flexDirection: "column" }}>{t(`parcel.modes.${m}`)}<span className="small muted">{t(`parcel.modesHint.${m}`)}</span></span></label>
            ))}
          </fieldset>
          <div className="grid cols-3">
            <Field label={t("parcel.handoverMinutes")} hint={t("parcel.handoverMin", { n: s.min_handover_minutes })}>
              <input className="input ltr" type="number" min={s.min_handover_minutes} max={2880} value={f.handover_minutes} onChange={(e) => setF({ ...f, handover_minutes: Number(e.target.value) })} />
            </Field>
            <Field label={t("parcel.cancelFee")}><input className="input ltr" type="number" min={0} value={fromMinor(f.cancel_fee)} onChange={(e) => setF({ ...f, cancel_fee: toMinor(e.target.value) })} /></Field>
            <Field label={t("parcel.noShowFee")}><input className="input ltr" type="number" min={0} value={fromMinor(f.no_show_fee)} onChange={(e) => setF({ ...f, no_show_fee: toMinor(e.target.value) })} /></Field>
          </div>
          <p className="small muted">{t(`parcel.feePolicy.${s.fee_policy}`)}</p>
          <fieldset className="stack" style={{ border: 0, padding: 0 }}>
            <legend className="small muted">{t("parcel.handOverTitle")}</legend>
            <label className="check"><input type="checkbox" checked={f.address_delivery} onChange={(e) => setF({ ...f, address_delivery: e.target.checked })} />{t("parcel.addressDelivery")}</label>
            <p className="small muted">{t("parcel.addressDeliveryHint")}</p>
            {f.address_delivery && (
              <Field label={t("parcel.addressFee")}><input className="input ltr" type="number" min={0} value={fromMinor(f.address_fee)} onChange={(e) => setF({ ...f, address_fee: toMinor(e.target.value) })} /></Field>
            )}
          </fieldset>
          {s.pending_fees && <div className="alert info small">{t("parcel.feesPending", { cancel: money(s.pending_fees.cancel_fee), noShow: money(s.pending_fees.no_show_fee) })}</div>}
          {s.fees_decision && <p className="small muted">{t("parcel.feesDecision")}: {s.fees_decision}</p>}
          <div className="small"><strong>{t("parcel.prohibitedTitle")}:</strong> {s.prohibited.map(item).join(" · ")}</div>
          <ErrorBox error={error} />
          <div className="row"><button className="btn" onClick={() => void save()}><Icon name="save" />{t("common.save")}</button></div>
        </>
      )}</Loaded>
    </div>
  );
}

/** Where the carrier receives parcels: its stations and offices with address and hours. */
export function ParcelPoints() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ points: Point[] }>("/api/carrier/parcels/points", undefined, { signal }));
  const stations = useLoad((signal) => api.get<{ stations: { uid: string; name: string; code: string }[] }>("/api/carrier/stations", undefined, { signal }));
  const blank = { kind: "OFFICE" as "OFFICE" | "STATION", station_uid: "", name: "", address: "", hours: "", phone: "" };
  const [f, setF] = useState(blank);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setError(null);
    try {
      await api.post("/api/carrier/parcels/points", { ...f, station_uid: f.kind === "STATION" ? f.station_uid : null, phone: f.phone || null });
      toast(t("common.saved")); setAdding(false); setF(blank); state.reload();
    } catch (e) { setError(e); }
  };
  const close = async (uid: string) => { await api.post(`/api/carrier/parcels/points/${uid}/close`, {}); state.reload(); };
  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <p className="small muted">{t("parcel.pointsHint")}</p>
        <button className="btn tonal" onClick={() => setAdding(true)}><Icon name="add" />{t("parcel.addPoint")}</button>
      </div>
      <Loaded state={state}>{({ points }) => points.length === 0 ? <Empty icon="location_on" title={t("parcel.noPoints")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("common.type")}</th><th>{t("parcel.address")}</th><th>{t("parcel.hours")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{points.map((p) => (
            <tr key={p.uid}><td style={{ fontWeight: 500 }}>{p.name}{p.station_code && <span className="small mono"> · {p.station_code}</span>}</td>
              <td>{t(`parcel.pointKind.${p.kind}`)}</td><td className="small">{p.address}{p.phone && <div className="ltr">{p.phone}</div>}</td>
              <td className="small">{p.hours}</td><td><Status value={p.status} /></td>
              <td>{p.status === "ACTIVE" && <button className="btn text" onClick={() => void close(p.uid)}>{t("parcel.closePoint")}</button>}</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {adding && (
        <Modal title={t("parcel.addPoint")} onClose={() => setAdding(false)} actions={<>
          <button className="btn text" onClick={() => setAdding(false)}>{t("common.cancel")}</button>
          <button className="btn" disabled={f.name.length < 2 || f.address.length < 3 || f.hours.length < 2 || (f.kind === "STATION" && !f.station_uid)} onClick={() => void save()}>{t("common.save")}</button></>}>
          <Field label={t("common.type")}>
            <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as "OFFICE" | "STATION" })}>
              <option value="OFFICE">{t("parcel.pointKind.OFFICE")}</option><option value="STATION">{t("parcel.pointKind.STATION")}</option></select>
          </Field>
          {f.kind === "STATION" && (
            <Field label={t("parcel.station")}>
              <select value={f.station_uid} onChange={(e) => setF({ ...f, station_uid: e.target.value })}><option value="">{t("parcel.choose")}</option>
                {(stations.data?.stations ?? []).map((s) => <option key={s.uid} value={s.uid}>{s.name} ({s.code})</option>)}</select>
            </Field>
          )}
          <Field label={t("common.name")}><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <Field label={t("parcel.address")}><input className="input" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
          <Field label={t("parcel.hours")}><input className="input" value={f.hours} onChange={(e) => setF({ ...f, hours: e.target.value })} /></Field>
          <Field label={t("parcel.phone")}><input className="input ltr" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}

interface Policy { carrier_types: string[]; scheduled_only: boolean; min_handover_minutes: number; fee_policy: "CARRIER" | "PLATFORM"; prohibited: string[] }
interface CarrierRow { uid: string; legal_name: string; company_type: string; booking_mode: string | null; handover_minutes: number | null;
  cancel_fee: number | null; no_show_fee: number | null; pending_fees: { cancel_fee: number; no_show_fee: number } | null; stopped: boolean;
  stopped_reason: string | null; points: number; tariffs: number; type_allowed: boolean }
const KINDS = ["CARRIER", "INDIVIDUAL_OPERATOR", "FOREIGN_CARRIER"];

/** The platform's parcel policy (1147) and each carrier's parcels: stop or resume, and decide fees while it regulates them. */
export function ParcelPolicy() {
  const { t, money } = useI18n();
  const item = useItem();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ carriers: CarrierRow[]; policy: Policy }>("/api/admin/parcels/carriers", undefined, { signal }));
  const [p, setP] = useState<(Policy & { text: string }) | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [acting, setActing] = useState<{ row: CarrierRow; kind: "stop" | "fees" } | null>(null);
  const [why, setWhy] = useState("");
  useEffect(() => { if (state.data) setP({ ...state.data.policy, text: state.data.policy.prohibited.join("\n") }); }, [state.data]);
  const save = async () => {
    if (!p) return;
    setError(null);
    try {
      await api.put("/api/admin/parcels/policy", { carrier_types: p.carrier_types, scheduled_only: p.scheduled_only, min_handover_minutes: p.min_handover_minutes,
        fee_policy: p.fee_policy, prohibited: p.text.split("\n").map((x) => x.trim()).filter(Boolean), reason: reason.trim() });
      toast(t("parcel.policy.saved")); setReason(""); state.reload();
    } catch (e) { setError(e); }
  };
  const act = async (decision?: boolean) => {
    if (!acting) return;
    setError(null);
    try {
      if (acting.kind === "stop") await api.put(`/api/admin/parcels/carriers/${acting.row.uid}/stop`, { stopped: !acting.row.stopped, reason: why.trim() });
      else await api.post(`/api/admin/parcels/carriers/${acting.row.uid}/fees`, { approve: decision, reason: why.trim() });
      toast(t("common.saved")); setActing(null); setWhy(""); state.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <Loaded state={state}>{(d) => p && (
        <>
          <section className="card stack" aria-labelledby="parcel-policy">
            <div><h3 id="parcel-policy">{t("parcel.policy.title")}</h3><p className="small muted">{t("parcel.policy.sub")}</p></div>
            <fieldset className="stack" style={{ border: 0, padding: 0 }}>
              <legend className="small muted">{t("parcel.policy.carrierTypes")}</legend>
              {KINDS.map((k) => (
                <label key={k} className="check"><input type="checkbox" checked={p.carrier_types.includes(k)}
                  onChange={() => setP({ ...p, carrier_types: p.carrier_types.includes(k) ? p.carrier_types.filter((x) => x !== k) : [...p.carrier_types, k] })} />{t(`parcel.policy.kind.${k}`)}</label>
              ))}
            </fieldset>
            <label className="check"><input type="checkbox" checked={p.scheduled_only} onChange={(e) => setP({ ...p, scheduled_only: e.target.checked })} />{t("parcel.policy.scheduledOnly")}</label>
            <div className="grid cols-2">
              <Field label={t("parcel.policy.minHandover")}><input className="input ltr" type="number" min={15} max={1440} value={p.min_handover_minutes} onChange={(e) => setP({ ...p, min_handover_minutes: Number(e.target.value) })} /></Field>
              <Field label={t("parcel.policy.feePolicy")}>
                <select value={p.fee_policy} onChange={(e) => setP({ ...p, fee_policy: e.target.value as Policy["fee_policy"] })}>
                  <option value="CARRIER">{t("parcel.policy.feeCarrier")}</option><option value="PLATFORM">{t("parcel.policy.feePlatform")}</option></select>
              </Field>
            </div>
            <Field label={t("parcel.policy.prohibited")}><textarea className="input" rows={6} value={p.text} onChange={(e) => setP({ ...p, text: e.target.value })} /></Field>
            <p className="small muted">{p.text.split("\n").filter(Boolean).map((x) => item(x.trim())).join(" · ")}</p>
            <Field label={t("parcel.policy.reason")}><input className="input" maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
            <ErrorBox error={error} />
            <div className="row"><button className="btn" disabled={reason.trim().length < 5 || p.carrier_types.length === 0} onClick={() => void save()}><Icon name="save" />{t("common.save")}</button></div>
          </section>
          <section className="card stack" aria-labelledby="parcel-carriers">
            <h3 id="parcel-carriers">{t("parcel.policy.carriers")}</h3>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("common.name")}</th><th>{t("parcel.bookingMode")}</th><th>{t("parcel.handoverMinutes")}</th><th>{t("parcel.tab.points")}</th>
                <th>{t("parcel.policy.pendingFees")}</th><th>{t("common.status")}</th><th /></tr></thead>
              <tbody>{d.carriers.map((c) => (
                <tr key={c.uid}>
                  <td style={{ fontWeight: 500 }}>{c.legal_name}{!c.type_allowed && <div className="small muted">{t("parcel.policy.typeNotAllowed")}</div>}</td>
                  <td className="small">{t(`parcel.modes.${c.booking_mode ?? "ONLINE_DROPOFF"}`)}</td><td>{c.handover_minutes ?? 120}</td><td>{c.points}</td>
                  <td className="small">{c.pending_fees ? `${money(c.pending_fees.cancel_fee)} · ${money(c.pending_fees.no_show_fee)}` : "—"}</td>
                  <td>{c.stopped ? <span className="chip red" title={c.stopped_reason ?? ""}>{t("parcel.policy.stopped")}</span> : <Status value="ACTIVE" />}</td>
                  <td className="row" style={{ gap: 4 }}>
                    <button className="btn text" onClick={() => { setActing({ row: c, kind: "stop" }); setWhy(""); }}>{c.stopped ? t("parcel.policy.resume") : t("parcel.policy.stop")}</button>
                    {c.pending_fees && <button className="btn text" onClick={() => { setActing({ row: c, kind: "fees" }); setWhy(""); }}>{t("parcel.policy.pendingFees")}</button>}
                  </td>
                </tr>
              ))}</tbody>
            </table></div>
          </section>
        </>
      )}</Loaded>
      {acting && (
        <Modal title={acting.row.legal_name} onClose={() => setActing(null)} actions={acting.kind === "stop" ? <>
          <button className="btn text" onClick={() => setActing(null)}>{t("common.cancel")}</button>
          <button className="btn" disabled={why.trim().length < 5} onClick={() => void act()}>{acting.row.stopped ? t("parcel.policy.resume") : t("parcel.policy.stop")}</button></> : <>
          <button className="btn text" disabled={why.trim().length < 5} onClick={() => void act(false)}>{t("parcel.policy.reject")}</button>
          <button className="btn" disabled={why.trim().length < 5} onClick={() => void act(true)}>{t("parcel.policy.approve")}</button></>}>
          {acting.kind === "fees" && acting.row.pending_fees && <p className="small">{t("parcel.feesPending", { cancel: money(acting.row.pending_fees.cancel_fee), noShow: money(acting.row.pending_fees.no_show_fee) })}</p>}
          <Field label={t("parcel.policy.stopReason")}><input className="input" maxLength={300} value={why} onChange={(e) => setWhy(e.target.value)} /></Field>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}
