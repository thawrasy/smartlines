import { useEffect, useRef, useState } from "react";
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, newKey, type FareBrand, type TripDetail } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { minutesBetween } from "../../dates";
import { ErrorBox, Field, Icon, Spinner, useLoad } from "../../components/ui";

interface Hold { hold_token: string; expires_at: string }
interface Pax { full_name: string; id_type: string; id_last4: string }

const roundUnit = (minor: number) => Math.round(minor / 100) * 100;

function SeatMap({ seats, selected, toggle, max }: { seats: TripDetail["seats"]; selected: number[]; toggle: (n: number) => void; max: number }) {
  const { t } = useI18n();
  const cells: (number | null)[] = [];
  seats.forEach((s, i) => { cells.push(s.seat_no); if (i % 4 === 1) cells.push(null); });
  const free = new Map(seats.map((s) => [s.seat_no, s.free]));
  return (
    <div className="stack">
      <div className="bus">
        <div className="bus-front"><span>{t("seats.front")}</span><span className="row" style={{ gap: 4 }}><Icon name="directions_car" size={18} />{t("seats.driver")}</span></div>
        <div className="seats">
          {cells.map((n, i) => n === null ? <span key={`a${i}`} /> : (
            <button key={n} type="button" className={`seat${selected.includes(n) ? " mine" : !free.get(n) ? " taken" : ""}`}
                    disabled={!free.get(n) || (!selected.includes(n) && selected.length >= max)}
                    onClick={() => toggle(n)} aria-pressed={selected.includes(n)} aria-label={`${t("common.seat")} ${n}`}>{n}</button>
          ))}
        </div>
      </div>
      <div className="legend">
        <span><i />{t("seats.free")}</span>
        <span><i style={{ background: "var(--surface-container-high)", borderColor: "transparent" }} />{t("seats.taken")}</span>
        <span><i style={{ background: "var(--primary)", borderColor: "var(--primary)" }} />{t("seats.mine")}</span>
      </div>
    </div>
  );
}

function useCountdown(until: string | null) {
  const [left, setLeft] = useState(0);
  useEffect(() => {
    if (!until) return;
    const tick = () => setLeft(Math.max(0, Math.round((new Date(until).getTime() - Date.now()) / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [until]);
  return left;
}

export default function Book() {
  const { uid = "" } = useParams();
  const [params] = useSearchParams();
  const fromSeq = Number(params.get("from") ?? 0), toSeq = Number(params.get("to") ?? 1), paxCount = Number(params.get("pax") ?? 1);
  const { t, money, time, date, station, duration } = useI18n();
  const { me } = useAuth();
  const nav = useNavigate();
  const loc = useLocation();

  const detail = useLoad(() => api.get<TripDetail>(`/api/trips/${uid}`, { from_seq: fromSeq, to_seq: toSeq }), [uid, fromSeq, toSeq]);
  const ref = useLoad(() => api.get<{ fare_brands: FareBrand[]; platform_fee: number }>("/api/ref"));
  const wallet = useLoad(() => (me?.portal === "PASSENGER" ? api.get<{ balance: number }>("/api/wallet") : Promise.resolve(null)), [me]);

  const [selected, setSelected] = useState<number[]>([]);
  const [hold, setHold] = useState<Hold | null>(null);
  const [brand, setBrand] = useState("STANDARD");
  const [pax, setPax] = useState<Pax[]>([]);
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [idemKey] = useState(newKey);
  const left = useCountdown(hold?.expires_at ?? null);

  // Release the hold if the passenger leaves the page without paying
  const holdRef = useRef<string | null>(null);
  useEffect(() => { holdRef.current = hold?.hold_token ?? null; }, [hold]);
  useEffect(() => () => { if (holdRef.current) void api.del(`/api/holds/${holdRef.current}`).catch(() => {}); }, []);

  if (detail.error) return <div className="page"><ErrorBox error={detail.error} /></div>;
  if (!detail.data || !ref.data) return <Spinner />;
  const d = detail.data;
  const from = d.stops.find((s) => s.seq === d.from_seq)!, to = d.stops.find((s) => s.seq === d.to_seq)!;
  const brands = ref.data.fare_brands;
  const fb = brands.find((b) => b.code === brand) ?? brands[0];
  const farePer = roundUnit(d.price * fb.factor);
  const total = farePer * paxCount + ref.data.platform_fee;

  const toggle = (n: number) => setSelected((s) => (s.includes(n) ? s.filter((x) => x !== n) : [...s, n].slice(-paxCount)));

  const doHold = async () => {
    if (!me || me.portal !== "PASSENGER") { nav(`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`); return; }
    setBusy(true); setError(null);
    try {
      const h = await api.post<Hold>("/api/holds", { trip_uid: uid, from_seq: fromSeq, to_seq: toSeq, seat_nos: selected });
      setHold(h);
      setPax(selected.map((_, i) => pax[i] ?? { full_name: i === 0 ? me.name : "", id_type: "NATIONAL_ID", id_last4: "" }));
    } catch (e) {
      setError(e); detail.reload(); setSelected([]);
    } finally { setBusy(false); }
  };

  const release = async () => {
    if (hold) await api.del(`/api/holds/${hold.hold_token}`).catch(() => {});
    setHold(null); detail.reload();
  };

  const pay = async () => {
    if (!hold) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ booking_ref: string }>("/api/bookings", {
        hold_token: hold.hold_token, trip_uid: uid, from_seq: fromSeq, to_seq: toSeq, fare_brand: brand, idempotency_key: idemKey,
        passengers: selected.map((seat, i) => ({ seat_no: seat, full_name: pax[i].full_name, id_type: pax[i].id_type, id_last4: pax[i].id_last4 || null })),
      });
      holdRef.current = null;
      nav(`/booking/${r.booking_ref}?new=1`);
    } catch (e) {
      setError(e);
      if (e instanceof Error && "code" in e && (e as { code: string }).code === "HOLD_EXPIRED") { setHold(null); detail.reload(); }
    } finally { setBusy(false); }
  };

  const paxValid = pax.length === selected.length && pax.every((p) => p.full_name.trim().length >= 3 && (!p.id_last4 || /^[0-9A-Za-z]{3,4}$/.test(p.id_last4)));
  const mm = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;

  return (
    <div className="page stack">
      {/* Journey header */}
      <div className="card row between">
        <div className="stack tight">
          <div className="row" style={{ gap: 8 }}><span style={{ fontWeight: 600 }}>{d.trip.carrier_name}</span><span className="chip outline mono">{d.trip.trip_no}</span></div>
          <div className="timeline" style={{ marginTop: 16, minWidth: "min(520px, 80vw)" }}>
            <div><div className="time">{time(from.sched_dep)}</div><div className="small muted">{station(from.station_code, from.station_name)}</div></div>
            <div className="line"><span className="dur">{duration(minutesBetween(from.sched_dep, to.sched_arr))}</span></div>
            <div style={{ textAlign: "end" }}><div className="time">{time(to.sched_arr)}</div><div className="small muted">{station(to.station_code, to.station_name)}</div></div>
          </div>
        </div>
        <div className="stack tight" style={{ alignItems: "flex-end" }}>
          <span className="muted">{date(from.sched_dep, { weekday: "long", day: "numeric", month: "long" })}</span>
          <span className="chip"><Icon name="group" size={16} />{paxCount} {t("common.passengers")}</span>
        </div>
      </div>

      <ErrorBox error={error} />

      {!hold ? (
        <div className="grid cols-2" style={{ alignItems: "start" }}>
          <div className="card"><div className="card-title"><h3>{t("seats.title")}</h3><span className="muted">{t("seats.pick", { n: paxCount })}</span></div>
            <SeatMap seats={d.seats} selected={selected} toggle={toggle} max={paxCount} />
          </div>
          <div className="card stack">
            <h3>{t("seats.selected")}</h3>
            <div className="row">{selected.length ? selected.map((s) => <span key={s} className="chip green">{t("common.seat")} {s}</span>) : <span className="muted">—</span>}</div>
            <div className="divider" />
            <div className="row between"><span className="muted">{t("results.perPassenger")}</span><span className="price" style={{ fontSize: 20 }}>{money(d.price)}</span></div>
            <p className="small muted"><Icon name="lock" size={16} /> {t("seats.holdFor", { n: d.trip.hold_min })}</p>
            <button className="btn large block" disabled={selected.length !== paxCount || busy} onClick={doHold}>
              {me?.portal === "PASSENGER" ? t("seats.hold") : t("seats.signInFirst")}
            </button>
          </div>
        </div>
      ) : (
        <div className="grid checkout-grid">
          <div className="stack">
            <h2>{t("checkout.title")}</h2>
            <div className="alert warn"><Icon name="schedule" /><span>{left > 0 ? t("checkout.holdLeft", { t: mm }) : t("checkout.holdExpired")}</span></div>
            <div className="card stack">
              <div><h3>{t("checkout.fare")}</h3><p className="small muted">{t("checkout.brandHint")}</p></div>
              <div className="grid cols-3">
                {brands.map((b) => (
                  <button key={b.code} type="button" onClick={() => setBrand(b.code)} className={`card flat stack tight${brand === b.code ? " on" : ""}`}
                          style={{ textAlign: "start", cursor: "pointer", padding: 16, borderColor: brand === b.code ? "var(--primary)" : undefined,
                                   background: brand === b.code ? "var(--surface-tint)" : undefined, borderWidth: brand === b.code ? 2 : 1 }}>
                    <span style={{ fontWeight: 600 }}>{b.name}</span>
                    <span className="price" style={{ fontSize: 18 }}>{money(roundUnit(d.price * b.factor))}</span>
                    <span className="small" style={{ color: b.rules.refundable ? "var(--primary)" : "var(--error)" }}>
                      {b.rules.refundable ? t("checkout.refundable") : t("checkout.nonRefundable")}
                    </span>
                    {b.rules.refund.map(([h, pct]) => <span key={h} className="small muted">{t("checkout.refundRule", { pct, h })}</span>)}
                    <span className="small muted"><Icon name="luggage" size={16} /> {t("checkout.bags", { n: b.rules.bags_included, kg: b.rules.kg_per_piece })}</span>
                  </button>
                ))}
              </div>
            </div>
            {selected.map((seat, i) => (
              <div key={seat} className="card stack">
                <div className="row between"><h3>{t("common.passenger")} {i + 1}</h3><span className="chip green">{t("common.seat")} {seat}</span></div>
                <div className="grid cols-3">
                  <Field label={t("checkout.fullName")}>
                    <input className="input" value={pax[i]?.full_name ?? ""} required minLength={3}
                           onChange={(e) => setPax((p) => p.map((x, j) => (j === i ? { ...x, full_name: e.target.value } : x)))} />
                  </Field>
                  <Field label={t("checkout.idType")}>
                    <select className="input" value={pax[i]?.id_type} onChange={(e) => setPax((p) => p.map((x, j) => (j === i ? { ...x, id_type: e.target.value } : x)))}>
                      {["NATIONAL_ID", "PASSPORT", "RESIDENCE", "OTHER"].map((k) => <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
                    </select>
                  </Field>
                  <Field label={`${t("checkout.idLast4")} (${t("common.optional")})`}>
                    <input className="input ltr" inputMode="numeric" maxLength={4} value={pax[i]?.id_last4 ?? ""}
                           onChange={(e) => setPax((p) => p.map((x, j) => (j === i ? { ...x, id_last4: e.target.value.trim() } : x)))} />
                  </Field>
                </div>
              </div>
            ))}
          </div>
          <div className="card stack" style={{ position: "sticky", top: 84 }}>
            <h3>{t("checkout.summary")}</h3>
            <div className="row between"><span className="muted">{t("checkout.fares", { n: paxCount })}</span><span>{money(farePer * paxCount)}</span></div>
            <div className="row between"><span className="muted">{t("checkout.fee")}</span><span>{money(ref.data.platform_fee)}</span></div>
            <div className="divider" />
            <div className="row between"><strong>{t("common.total")}</strong><span className="price">{money(total)}</span></div>
            {wallet.data && (
              <div className={`alert ${wallet.data.balance >= total ? "info" : "error"}`}>
                <Icon name="account_balance_wallet" />
                <span className="grow">{t("checkout.walletBalance")}: <strong>{money(wallet.data.balance)}</strong></span>
                {wallet.data.balance < total && <Link to="/wallet">{t("checkout.topupFirst")}</Link>}
              </div>
            )}
            <label className="check small"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} />{t("checkout.agree")}</label>
            <button className="btn large block" disabled={busy || !agree || !paxValid || left === 0} onClick={pay}>
              <Icon name="lock" />{t("checkout.pay", { amount: money(total) })}
            </button>
            <button className="btn text" onClick={release}>{t("common.back")}</button>
          </div>
        </div>
      )}
    </div>
  );
}
