import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api, type BookingRow } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";
import { SearchForm } from "../passenger/Home";
import Results from "../passenger/Results";

interface AgencyBooking extends BookingRow { contact_mobile: string | null; sold_by: string | null; commission: number | null; passengers: number }
interface Dashboard {
  balance: number; currency: string; sold_today: number; remaining_today: number; commission_held: number; commission_released: number;
  agreement: { status: string; commission_bp: number; daily_limit: number } | null; recent: AgencyBooking[];
}
interface Statement {
  month: string; opening_balance: number; closing_balance: number; total_credit: number; total_debit: number;
  entries: { direction: "DR" | "CR"; amount: number; balance_after: number; created_at: string; txn_type: string; memo: string | null }[];
  days: { day: string; bookings: number; sales: number; cancelled: number }[];
}
interface StaffMember { uid: string; full_name: string; email: string; is_owner: boolean; status: string; role: string | null; last_login_at: string | null; mfa_enrolled: boolean }

const pct = (bp: number) => `${(bp / 100).toLocaleString("en", { maximumFractionDigits: 2 })}%`;

function BookingsTable({ rows }: { rows: AgencyBooking[] }) {
  const { t, money, dateTime, city } = useI18n();
  if (rows.length === 0) return <Empty icon="confirmation_number" title={t("common.noData")} />;
  return (
    <div className="table-wrap"><table className="table">
      <thead><tr><th>{t("agency.ref")}</th><th>{t("agency.journey")}</th><th>{t("common.passengers")}</th><th>{t("agency.contact")}</th>
        <th>{t("agency.soldBy")}</th><th className="num">{t("common.total")}</th><th className="num">{t("agency.commission")}</th><th>{t("common.status")}</th></tr></thead>
      <tbody>{rows.map((b) => (
        <tr key={b.booking_ref}>
          <td><Link className="mono" to={`/agency/booking/${b.booking_ref}`}>{b.booking_ref}</Link></td>
          <td>{b.journey ? <>{city(b.journey.from_city)} – {city(b.journey.to_city)}<div className="small muted">{dateTime(b.journey.departs_at)}</div></> : b.trip_no}</td>
          <td className="num">{b.passengers}</td>
          <td className="ltr mono small">{b.contact_mobile}</td>
          <td className="small">{b.sold_by}</td>
          <td className="num">{money(b.total_amount)}</td>
          <td className="num">{b.commission != null ? money(b.commission) : "—"}</td>
          <td><Status value={b.status} /></td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

// ------------------------------------------------------------------ dashboard
export function AgencyDashboard() {
  const { t, money } = useI18n();
  const { me } = useAuth();
  const state = useLoad(() => api.get<Dashboard>("/api/agency/dashboard"));
  return (
    <div className="stack">
      <PageHead title={me?.company?.name ?? t("nav.agency")}>
        <Link className="btn" to="/agency/search"><Icon name="search" />{t("agency.sell")}</Link>
      </PageHead>
      <Loaded state={state}>{(d) => (
        <>
          {d.agreement?.status !== "ACTIVE" && <div className="alert error"><Icon name="block" />{t("errors.AGENCY_SUSPENDED")}</div>}
          <div className="grid cols-3">
            <Stat icon="account_balance_wallet" label={t("agency.balance")} value={money(d.balance)} />
            <Stat icon="payments" label={t("agency.soldToday")} value={money(d.sold_today)} tone="wheat" />
            <Stat icon="trending_up" label={t("agency.remainingToday")} value={money(d.remaining_today)} tone="blue" />
            <Stat icon="handshake" label={t("agency.commissionHeld")} value={money(d.commission_held)} tone="wheat" />
            <Stat icon="loyalty" label={t("agency.commissionReleased")} value={money(d.commission_released)} />
            <Stat icon="receipt_long" label={t("agency.rate")} value={d.agreement ? pct(d.agreement.commission_bp) : "—"} tone="blue" />
          </div>
          <div className="card">
            <div className="card-title"><h3>{t("agency.recent")}</h3><Link to="/agency/bookings">{t("agency.bookings")}</Link></div>
            <BookingsTable rows={d.recent} />
          </div>
          <p className="small muted"><Icon name="shield" size={16} /> {t("agency.fundingNote")}</p>
        </>
      )}</Loaded>
    </div>
  );
}

// ------------------------------------------------------------------ sell: search, then the shared results screen
export function AgencySell() {
  const [params] = useSearchParams();
  return params.get("from") ? <Results /> : <AgencySearch />;
}

function AgencySearch() {
  const { t } = useI18n();
  return (
    <div className="stack">
      <PageHead title={t("agency.sell")} sub={t("agency.sellHint")} />
      <div className="card"><SearchForm /></div>
    </div>
  );
}

// ------------------------------------------------------------------ bookings
export function AgencyBookings() {
  const { t } = useI18n();
  const [params, setParams] = useSearchParams();
  const q = params.get("q") ?? "";
  const [text, setText] = useState(q);
  const state = useLoad(() => api.get<{ bookings: AgencyBooking[] }>("/api/agency/bookings", { q: q || undefined }), [q]);
  return (
    <div className="stack">
      <PageHead title={t("agency.bookings")} />
      <form className="row" onSubmit={(e) => { e.preventDefault(); setParams(text.trim() ? { q: text.trim() } : {}); }}>
        <input className="input ltr grow" style={{ maxWidth: 360 }} placeholder={t("agency.findHint")} value={text}
               onChange={(e) => setText(e.target.value.replace(/[^0-9A-Za-z+]/g, ""))} maxLength={20} />
        <button className="btn tonal" type="submit"><Icon name="search" />{t("common.search")}</button>
      </form>
      <div className="card"><Loaded state={state}>{({ bookings }) => <BookingsTable rows={bookings} />}</Loaded></div>
    </div>
  );
}

// ------------------------------------------------------------------ statement
export function AgencyStatement() {
  const { t, money, dateTime, date } = useI18n();
  const now = new Date();
  const [month, setMonth] = useState(`${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`);
  const state = useLoad(() => api.get<Statement>("/api/agency/statement", { month }), [month]);
  return (
    <div className="stack">
      <PageHead title={t("agency.statement")}>
        <input className="input ltr" type="month" value={month} onChange={(e) => e.target.value && setMonth(e.target.value)} style={{ width: 180 }} />
        <button className="btn outlined" onClick={() => print()}><Icon name="download" />{t("common.print")}</button>
      </PageHead>
      <Loaded state={state}>{(s) => (
        <>
          <div className="grid cols-3">
            <Stat icon="account_balance_wallet" label={t("agency.opening")} value={money(s.opening_balance)} />
            <Stat icon="payments" label={t("agency.debits")} value={money(s.total_debit)} tone="red" />
            <Stat icon="loyalty" label={t("agency.credits")} value={money(s.total_credit)} tone="blue" />
          </div>
          <div className="grid split" style={{ alignItems: "start" }}>
            <div className="card">
              <div className="card-title"><h3>{t("agency.movements")}</h3><span className="muted">{t("agency.closing")}: <strong>{money(s.closing_balance)}</strong></span></div>
              {s.entries.length === 0 ? <Empty title={t("common.noData")} /> : (
                <div className="table-wrap"><table className="table">
                  <thead><tr><th>{t("common.when")}</th><th>{t("common.type")}</th><th>{t("agency.ref")}</th><th className="num">{t("common.amount")}</th><th className="num">{t("common.balance")}</th></tr></thead>
                  <tbody>{s.entries.map((e, i) => (
                    <tr key={i}>
                      <td className="small">{dateTime(e.created_at)}</td><td>{t(`txn.${e.txn_type}`)}</td><td className="mono small">{e.memo}</td>
                      <td className="num" style={{ color: e.direction === "CR" ? "var(--success)" : "var(--error)" }}>{e.direction === "CR" ? "+" : "−"}{money(e.amount)}</td>
                      <td className="num">{money(e.balance_after)}</td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
            <div className="card">
              <h3>{t("agency.byDay")}</h3>
              {s.days.length === 0 ? <Empty title={t("common.noData")} /> : (
                <table className="table">
                  <thead><tr><th>{t("common.date")}</th><th className="num">{t("agency.bookings")}</th><th className="num">{t("agency.sales")}</th></tr></thead>
                  <tbody>{s.days.map((d) => (
                    <tr key={d.day}><td>{date(`${d.day}T12:00:00Z`, { day: "numeric", month: "short" })}</td><td className="num">{d.bookings}{d.cancelled ? <span className="small muted"> (−{d.cancelled})</span> : null}</td><td className="num">{money(d.sales)}</td></tr>
                  ))}</tbody>
                </table>
              )}
            </div>
          </div>
        </>
      )}</Loaded>
    </div>
  );
}

// ------------------------------------------------------------------ staff
export function AgencyStaff() {
  const { t, dateTime } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ staff: StaffMember[] }>("/api/agency/staff"));
  const blank = { full_name: "", email: "", mobile: "", password: "", role: "SELLER" };
  const [f, setF] = useState(blank);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/agency/staff", { ...f, mobile: f.mobile || null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("agency.staff")} sub={t("agency.staffHint")}>
        {can("company.staff") && <button className="btn" onClick={() => setOpen(true)}><Icon name="person_add" />{t("agency.addStaff")}</button>}
      </PageHead>
      <Loaded state={state}>{({ staff }) => (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("common.email")}</th><th>{t("agency.role")}</th><th>{t("agency.twoStep")}</th><th>{t("agency.lastLogin")}</th><th>{t("common.status")}</th></tr></thead>
          <tbody>{staff.map((s) => (
            <tr key={s.uid}>
              <td style={{ fontWeight: 500 }}>{s.full_name}</td><td className="ltr small">{s.email}</td>
              <td>{s.is_owner ? t("agency.owner") : t(`agency.roles.${s.role ?? "AGENCY_SELLER"}`)}</td>
              <td>{s.mfa_enrolled ? <span className="chip green"><Icon name="verified" size={16} />{t("common.yes")}</span> : <span className="chip">{t("common.no")}</span>}</td>
              <td className="small">{s.last_login_at ? dateTime(s.last_login_at) : "—"}</td>
              <td><Status value={s.status} /></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("agency.addStaff")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={save}>{t("common.create")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("common.name")}><input className="input" value={f.full_name} onChange={set("full_name")} /></Field>
            <div className="grid cols-2">
              <Field label={t("common.email")}><input className="input ltr" type="email" value={f.email} onChange={set("email")} /></Field>
              <Field label={`${t("common.mobile")} (${t("common.optional")})`}><input className="input ltr" inputMode="tel" value={f.mobile} onChange={set("mobile")} /></Field>
            </div>
            <Field label={t("agency.role")}>
              <select className="input" value={f.role} onChange={set("role")}>
                <option value="SELLER">{t("agency.roles.AGENCY_SELLER")}</option>
                <option value="ACCOUNTANT">{t("agency.roles.AGENCY_ACCOUNTANT")}</option>
              </select>
            </Field>
            <Field label={t("common.password")} hint={t("auth.passwordHint")}><input className="input ltr" type="password" autoComplete="new-password" value={f.password} onChange={set("password")} /></Field>
            <p className="small muted"><Icon name="shield" size={16} /> {t("agency.staffMfa")}</p>
          </div>
        </Modal>
      )}
    </div>
  );
}
