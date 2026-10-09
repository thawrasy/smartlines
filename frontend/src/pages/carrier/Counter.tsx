import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api, type BookingRow } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { localDate } from "../../dates";
import { PageHead } from "../../components/layout";
import { Empty, Icon, Loaded, Stat, Status, useLoad } from "../../components/ui";
import { SearchForm } from "../passenger/Home";
import Results from "../passenger/Results";

// The carrier's counter (study 6.5, schema 1056): sell tickets for cash, collect reservations paid at the counter,
// cancel with cash back, and count the drawer at the end of the day. The cash taken is owed to the platform until
// the carrier's earnings are set off against it or it is remitted.

interface CounterBooking extends BookingRow {
  contact_mobile: string | null; sold_by: string | null; passengers: number; pay_option: string; pay_method: string; pay_by: string | null;
}
interface Dashboard {
  owed: number; limit: number; remaining: number; today: string; my_sales: number; my_cash_in: number; my_refunds: number; my_net: number;
  reservations_waiting: number; options: string[];
}
interface DayReport {
  day: string; sales: number; cash_in: number; refunds: number; net: number;
  by_seller: { user_id: number; seller: string | null; sales: number; cash_in: number; refunds: number; net: number }[];
  position: { owed: number; limit: number; remaining: number };
}

function CounterBookings({ rows }: { rows: CounterBooking[] }) {
  const { t, money, dateTime, city } = useI18n();
  if (rows.length === 0) return <Empty icon="confirmation_number" title={t("common.noData")} />;
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("agency.ref")}</th><th>{t("agency.journey")}</th><th>{t("common.passengers")}</th><th>{t("counter.paidWith")}</th>
        <th>{t("agency.contact")}</th><th className="num">{t("common.total")}</th><th>{t("common.status")}</th></tr></thead>
      <tbody>{rows.map((b) => (
        <tr key={b.booking_ref}>
          <td><Link className="mono" to={`/carrier/counter/booking/${b.booking_ref}`}>{b.booking_ref}</Link></td>
          <td>{b.journey ? <>{city(b.journey.from_city)} – {city(b.journey.to_city)}<div className="small muted">{dateTime(b.journey.departs_at)}</div></> : b.trip_no}</td>
          <td className="num">{b.passengers}</td>
          <td className="small">{t(`opt.name.${b.pay_option}`)}{b.pay_by && <div className="small muted">{t("opt.payBy")} {dateTime(b.pay_by)}</div>}</td>
          <td className="ltr mono small">{b.contact_mobile}</td>
          <td className="num">{money(b.total_amount)}</td>
          <td><Status value={b.status} /></td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

export function CounterDashboard() {
  const { t, money } = useI18n();
  const { me } = useAuth();
  const [params, setParams] = useSearchParams();
  const q = params.get("q") ?? "", only = params.get("status") ?? "";
  const [text, setText] = useState(q);
  const state = useLoad(() => api.get<Dashboard>("/api/carrier/counter/dashboard"));
  const list = useLoad(() => api.get<{ bookings: CounterBooking[] }>("/api/carrier/counter/bookings",
    { q: q || undefined, status: only || undefined }), [q, only]);
  const set = (k: string, v: string) => { const p = new URLSearchParams(params); if (v) p.set(k, v); else p.delete(k); setParams(p); };
  return (
    <div className="stack">
      <PageHead title={t("counter.title")} sub={me?.company?.name ?? t("counter.sub")}>
        <Link className="btn outlined" to="/carrier/counter/report"><Icon name="receipt_long" />{t("counter.report")}</Link>
        <Link className="btn" to="/carrier/counter/search"><Icon name="point_of_sale" />{t("counter.sell")}</Link>
      </PageHead>
      <Loaded state={state}>{(d) => (
        <>
          {!d.options.includes("CASH_COUNTER") && <div className="alert error"><Icon name="block" />{t("errors.PAYMENT_METHOD_DISABLED")}</div>}
          {d.remaining === 0 && <div className="alert error"><Icon name="warning" />{t("counter.limitReached")}</div>}
          <div className="grid cols-4">
            <Stat icon="payments" label={t("counter.myCash")} value={money(d.my_cash_in)} />
            <Stat icon="undo" label={t("counter.myRefunds")} value={money(d.my_refunds)} tone="red" />
            <Stat icon="savings" label={t("counter.net")} value={money(d.my_net)} tone="wheat" />
            <Stat icon="hourglass_top" label={t("counter.waiting")} value={d.reservations_waiting} tone="blue" />
            <Stat icon="account_balance" label={t("counter.owed")} value={money(d.owed)} tone="wheat" />
            <Stat icon="price_check" label={t("counter.limit")} value={money(d.limit)} />
            <Stat icon="trending_up" label={t("counter.remaining")} value={money(d.remaining)} tone={d.remaining > 0 ? "blue" : "red"} />
            <Stat icon="confirmation_number" label={t("counter.mySales")} value={d.my_sales} />
          </div>
        </>
      )}</Loaded>
      <div className="card stack">
        <div className="card-title"><h3>{t("counter.bookings")}</h3>
          <div className="row" style={{ gap: 4 }}>
            <button className={`chip${only === "" ? " green" : " outline"}`} onClick={() => set("status", "")}>{t("counter.all")}</button>
            <button className={`chip${only === "PENDING_PAYMENT" ? " green" : " outline"}`} onClick={() => set("status", "PENDING_PAYMENT")}>{t("counter.pendingOnly")}</button>
          </div>
        </div>
        <form className="row" onSubmit={(e) => { e.preventDefault(); set("q", text.trim()); }}>
          <input className="input ltr grow" style={{ maxWidth: 360 }} placeholder={t("counter.findHint")} value={text} aria-label={t("counter.find")}
                 onChange={(e) => setText(e.target.value.replace(/[^0-9A-Za-z+]/g, ""))} maxLength={20} />
          <button className="btn tonal" type="submit"><Icon name="search" />{t("common.search")}</button>
        </form>
        <Loaded state={list}>{({ bookings }) => <CounterBookings rows={bookings} />}</Loaded>
      </div>
    </div>
  );
}

// sell: search the carrier's own trips, then the shared results and checkout screens
export function CounterSell() {
  const { t } = useI18n();
  const [params] = useSearchParams();
  if (params.get("from")) return <Results />;
  return (
    <div className="stack">
      <PageHead title={t("counter.sell")} sub={t("counter.sub")} />
      <div className="card"><SearchForm /></div>
    </div>
  );
}

export function CounterReport() {
  const { t, money, date } = useI18n();
  const [day, setDay] = useState(localDate(0));
  const state = useLoad(() => api.get<DayReport>("/api/carrier/counter/report", { day }), [day]);
  return (
    <div className="stack">
      <PageHead title={t("counter.report")} sub={date(`${day}T12:00:00Z`, { weekday: "long", day: "numeric", month: "long", year: "numeric" })}>
        <input className="input" type="date" value={day} max={localDate(0)} onChange={(e) => e.target.value && setDay(e.target.value)} aria-label={t("counter.day")} />
        <button className="btn outlined" onClick={() => print()}><Icon name="download" />{t("common.print")}</button>
      </PageHead>
      <Loaded state={state}>{(r) => (
        <>
          <div className="grid cols-4">
            <Stat icon="confirmation_number" label={t("counter.sales")} value={r.sales} />
            <Stat icon="payments" label={t("counter.cashIn")} value={money(r.cash_in)} />
            <Stat icon="undo" label={t("counter.refunds")} value={money(r.refunds)} tone="red" />
            <Stat icon="savings" label={t("counter.net")} value={money(r.net)} tone="wheat" />
          </div>
          <div className="card">
            {r.by_seller.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("counter.seller")}</th><th className="num">{t("counter.sales")}</th><th className="num">{t("counter.cashIn")}</th>
                  <th className="num">{t("counter.refunds")}</th><th className="num">{t("counter.net")}</th></tr></thead>
                <tbody>{r.by_seller.map((s) => (
                  <tr key={s.user_id}><td>{s.seller ?? "—"}</td><td className="num">{s.sales}</td><td className="num">{money(s.cash_in)}</td>
                    <td className="num">{money(s.refunds)}</td><td className="num"><strong>{money(s.net)}</strong></td></tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
          <div className="row small muted"><Icon name="account_balance" size={16} />
            {t("counter.owed")}: <strong>{money(r.position.owed)}</strong> · {t("counter.limit")}: {money(r.position.limit)}</div>
        </>
      )}</Loaded>
    </div>
  );
}
