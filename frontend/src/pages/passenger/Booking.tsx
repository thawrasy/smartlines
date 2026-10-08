import { useEffect, useState } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import QRCode from "qrcode";
import { api, newKey, type BookingDetail, type BookingOption, type Ticket } from "../../api";
import { useI18n } from "../../i18n";
import { ErrorBox, Icon, Loaded, Status, useLoad, useToast } from "../../components/ui";
import { useChannel } from "../../channel";

// The QR code is a short-lived signed token fetched from the server; it is refreshed before it expires,
// so a screenshot stops working after a minute or two.
function RotatingQr({ ticket }: { ticket: Ticket }) {
  const { t } = useI18n();
  const ch = useChannel();
  const [img, setImg] = useState<string | null>(null);
  const [until, setUntil] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [error, setError] = useState<unknown>(null);
  const [period, setPeriod] = useState(90);

  useEffect(() => {
    let live = true, timer = 0;
    const load = async () => {
      try {
        const r = await api.get<{ token: string; valid_until: number; window: number }>(`${ch.api}/tickets/${ticket.uid}/qr`);
        const url = await QRCode.toDataURL(r.token, { margin: 1, width: 440, errorCorrectionLevel: "M", color: { dark: "#00382A", light: "#FFFFFF" } });
        if (!live) return;
        setImg(url); setError(null);
        const ms = r.valid_until * 1000;
        setUntil(ms);
        setPeriod(r.window);
        timer = window.setTimeout(load, Math.max(5000, ms - Date.now() - 5000));
      } catch (e) {
        if (live) { setError(e); timer = window.setTimeout(load, 15000); }
      }
    };
    void load();
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => { live = false; clearTimeout(timer); clearInterval(tick); };
  }, [ticket.uid, ch.api]);

  if (error && !img) return <ErrorBox error={error} />;
  const remaining = Math.max(0, Math.round((until - now) / 1000));
  return (
    <div className="stack tight" style={{ alignItems: "center" }}>
      <div className="qr-box">{img ? <img src={img} alt="QR" /> : <div style={{ width: 220, height: 220 }} />}</div>
      <div className="progress" style={{ width: 220 }}><div style={{ width: `${Math.min(100, (remaining / period) * 100)}%` }} /></div>
      <span className="small muted">{t("booking.qrRefresh", { n: period })}</span>
    </div>
  );
}

// A reservation waiting for its money (1056): where and by when to pay, and the provider's page for online options
function PayPanel({ b, onChange }: { b: BookingDetail["booking"]; onChange: () => void }) {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const ch = useChannel();
  const [params] = useSearchParams();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const payment = params.get("payment");
  const last = useLoad(() => (payment && !ch.staff ? api.get<{ status: string }>(`/api/payments/${payment}`) : Promise.resolve(null)), [payment, ch.staff]);
  const opts = useLoad(() => (ch.staff ? Promise.resolve([] as BookingOption[])
    : api.get<{ options: BookingOption[] }>("/api/payments/booking-options").then((r) => r.options)), [ch.staff]);
  const when = b.pay_by ? dateTime(b.pay_by) : "";
  const atCounter = b.pay_option === "PAY_LATER";
  const provider = opts.data?.find((o) => o.code === b.pay_option)?.providers?.[0];

  const run = async (fn: () => Promise<void>) => {
    setBusy(true); setError(null);
    try { await fn(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const payNow = () => run(async () => {
    const p = await api.post<{ url: string | null }>(`/api/bookings/${b.booking_ref}/payments`, { provider: provider!.code, idempotency_key: newKey() });
    if (p.url) window.location.assign(p.url);           // the provider's page (or the sandbox gateway)
  });
  const collect = () => run(async () => {
    await api.post(`${ch.api}/bookings/${b.booking_ref}/collect`);
    toast(t("counter.collected")); onChange();
  });
  const cancel = () => run(async () => {
    if (!confirm(t("opt.cancelReservationConfirm"))) return;
    await api.post(`${ch.api}/bookings/${b.booking_ref}/cancel`);
    toast(t("opt.reservationCancelled")); onChange();
  });

  return (
    <div className="card stack">
      <ErrorBox error={error} />
      {last.data?.status === "FAILED" && <div className="alert error"><Icon name="error" />{t("opt.paymentFailed", { time: when })}</div>}
      <div className="alert warn"><Icon name="schedule" />
        <span><strong>{t("opt.reserved")}</strong>{" "}
          {atCounter ? t("opt.payAtCounter", { amount: money(b.total_amount), carrier: b.carrier_name, time: when, ref: b.booking_ref })
                     : t("opt.payOnline", { time: when })}</span>
      </div>
      <div className="row">
        {ch.counter && b.collectable && (
          <button className="btn" disabled={busy} onClick={collect}><Icon name="payments" />{t("counter.collect", { amount: money(b.total_amount) })}</button>
        )}
        {!ch.staff && !atCounter && provider && (
          <button className="btn" disabled={busy} onClick={payNow}><Icon name="lock" />{t("opt.payNow")}</button>
        )}
        <button className="btn outlined danger" disabled={busy} onClick={cancel}><Icon name="cancel" />{t("opt.cancelReservation")}</button>
      </div>
    </div>
  );
}

export default function Booking() {
  const { ref = "" } = useParams();
  const [params] = useSearchParams();
  const { t, money, time, date, station, city } = useI18n();
  const toast = useToast();
  const ch = useChannel();
  const state = useLoad(() => api.get<BookingDetail>(`${ch.api}/bookings/${ref}`), [ref, ch.api]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const cancel = async () => {
    if (!confirm(t("booking.cancelConfirm"))) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ refund: number }>(`${ch.api}/bookings/${ref}/cancel`);
      toast(r.refund > 0 ? t(ch.counter ? "counter.cancelled" : ch.agency ? "agency.cancelled" : "booking.cancelled", { amount: money(r.refund) })
                         : t(ch.counter ? "counter.cancelledNoRefund" : "booking.cancelledNoRefund"));
      state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className={ch.staff ? "stack" : "page narrow stack"} style={ch.staff ? { maxWidth: 760 } : undefined}>
      <Loaded state={state}>{({ booking: b, tickets }) => {
        const first = tickets[0];
        const verifyUrl = `${location.origin}/verify?token=${encodeURIComponent(b.verify_token)}`;
        return (
          <>
            {params.get("new") && b.status === "CONFIRMED" && <div className="alert ok"><Icon name="check_circle" />{t("booking.success")}</div>}
            {params.get("payment") && b.status === "CONFIRMED" && <div className="alert ok"><Icon name="check_circle" />{t("opt.paymentDone")}</div>}
            {b.status === "EXPIRED" && <div className="alert error"><Icon name="timer_off" />{t("opt.expired")}</div>}
            <ErrorBox error={error} />
            <div className="row between">
              <div><h1 style={{ fontSize: 28 }}>{t("booking.title", { ref: b.booking_ref })}</h1>
                <p className="muted">{b.carrier_name} · <span className="mono">{b.trip_no}</span></p></div>
              <Status value={b.status} />
            </div>
            {b.status === "PENDING_PAYMENT" && <PayPanel b={b} onChange={state.reload} />}
            {tickets.map((k) => (
              <div key={k.uid} className="ticket">
                <div className="ticket-top">
                  <div className="row between">
                    <span style={{ opacity: .85 }}>{t("booking.ticketTitle")}</span>
                    <span className="mono" style={{ opacity: .85 }}>{k.ticket_no}</span>
                  </div>
                  <div className="row between" style={{ marginTop: 16, alignItems: "flex-end" }}>
                    <div><div style={{ fontSize: 28, fontWeight: 700 }}>{city(k.from_city)}</div><div style={{ opacity: .85 }}>{time(k.departs_at)}</div></div>
                    <Icon name="directions_bus" size={30} />
                    <div style={{ textAlign: "end" }}><div style={{ fontSize: 28, fontWeight: 700 }}>{city(k.to_city)}</div><div style={{ opacity: .85 }}>{time(k.arrives_at)}</div></div>
                  </div>
                </div>
                <div style={{ padding: 24 }} className="stack">
                  <dl className="kv">
                    <dt>{t("common.passenger")}</dt><dd>{k.ticket_name || k.full_name}</dd>
                    <dt>{t("common.date")}</dt><dd>{date(k.departs_at, { weekday: "long", day: "numeric", month: "long", year: "numeric" })}</dd>
                    <dt>{t("common.from")}</dt><dd>{station(k.from_code, k.from_station)}</dd>
                    <dt>{t("common.to")}</dt><dd>{station(k.to_code, k.to_station)}</dd>
                    <dt>{t("common.seat")}</dt><dd>{k.seat_no === null ? <span className="chip outline">{t("pax.onLap")}</span>
                      : <span className="chip green">{k.seat_label ?? k.seat_no}</span>}</dd>
                    <dt>{t("booking.fare")}</dt><dd>{k.fare_brand_code} · {money(k.total_amount)}</dd>
                    <dt>{t("common.status")}</dt><dd><Status value={k.status} /></dd>
                  </dl>
                  {k.status === "HOLD" && <div className="alert warn small"><Icon name="lock_clock" size={20} />{t("opt.notBoardable")}</div>}
                </div>
                {(k.status === "ISSUED" || k.status === "BOARDED") && b.status === "CONFIRMED" && (
                  <>
                    <div className="ticket-cut" />
                    <div style={{ padding: 24 }} className="stack tight center">
                      <strong>{t("booking.showQr")}</strong>
                      <RotatingQr ticket={k} />
                    </div>
                  </>
                )}
              </div>
            ))}
            <div className="card stack">
              <h3>{t("booking.breakdown")}</h3>
              {b.price_breakdown.lines ? b.price_breakdown.lines.map((l) => (
                <div key={l.passenger} className="row between small"><span className="muted">{t("common.passenger")} {l.passenger} · {t(`pax.cat.${l.category}`)}{!l.seat ? ` · ${t("pax.onLap")}` : ""}</span><span>{money(l.list_fare ?? l.fare)}</span></div>
              )) : <div className="row between"><span className="muted">{t("checkout.fares", { n: b.price_breakdown.passengers })}</span><span>{money(b.price_breakdown.fares_total)}</span></div>}
              {b.price_breakdown.family_offer && (
                <div className="row between small" style={{ color: "var(--success)" }}><span>{b.price_breakdown.family_offer.name}</span><span>−{money(b.price_breakdown.family_offer.discount)}</span></div>
              )}
              <div className="row between"><span className="muted">{t("checkout.fee")}</span><span>{money(b.price_breakdown.platform_fee)}</span></div>
              <div className="divider" />
              <div className="row between"><strong>{t("common.total")}</strong><span className="price" style={{ fontSize: 20 }}>{money(b.total_amount)}</span></div>
              {ch.agency && b.commission != null && (
                <div className="row between"><span className="muted">{t("agency.commissionEarned")}</span><span style={{ color: "var(--success)" }}>{money(b.commission)}</span></div>
              )}
              {b.contact_mobile && <div className="row between"><span className="muted">{t("agency.contact")}</span><span className="ltr mono">{b.contact_mobile}</span></div>}
              {b.pay_option && <div className="row between"><span className="muted">{t("counter.paidWith")}</span><span>{t(`opt.name.${b.pay_option}`)}</span></div>}
            </div>
            <div className="card stack tight">
              <h3>{t("booking.verifyLink")}</h3>
              <div className="row nowrap">
                <input className="input filled ltr grow" readOnly value={verifyUrl} style={{ height: 44, fontSize: 13 }} />
                <button className="btn tonal" onClick={() => { void navigator.clipboard?.writeText(verifyUrl); toast(t("common.copied")); }}>
                  <Icon name="content_copy" />{t("common.copy")}
                </button>
              </div>
            </div>
            {b.status === "CONFIRMED" && first?.status === "ISSUED" && (
              <div className="row">
                {(!ch.counter || b.refundable_here) && <button className="btn danger" disabled={busy} onClick={cancel}><Icon name="cancel" />{t("booking.cancel")}</button>}
                <button className="btn outlined" onClick={() => print()}><Icon name="download" />{t("common.print")}</button></div>
            )}
            {ch.counter && b.status === "CONFIRMED" && !b.refundable_here && <p className="small muted">{t("errors.CANCEL_ONLINE")}</p>}
          </>
        );
      }}</Loaded>
    </div>
  );
}
