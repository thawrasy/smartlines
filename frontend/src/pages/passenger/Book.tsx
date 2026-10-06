import { useEffect, useRef, useState } from "react";
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, newKey, type FamilyView, type FareBrand, type Quote, type TripDetail } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { minutesBetween } from "../../dates";
import { ErrorBox, Icon, Spinner, useLoad } from "../../components/ui";
import { useChannel } from "../../channel";
import { SeatGrid } from "../../components/SeatGrid";
import { PassengerFields, blankPassenger, categoryOf, documentFor, fromMember, namesFor, passengerValid, type PassengerDraft, type TravelDocs } from "./PassengerFields";

interface Hold { hold_token: string; expires_at: string }
// Passenger wallet, or the agency's dashboard figures that matter at checkout
interface Funds { balance: number; remaining_today?: number; agreement?: { commission_bp: number } | null }

const roundUnit = (minor: number) => Math.round(minor / 100) * 100;

function SeatMap({ seats, map, selected, toggle, max }: { seats: TripDetail["seats"]; map: TripDetail["seat_map"]; selected: number[]; toggle: (n: number) => void; max: number }) {
  const { t } = useI18n();
  const freeOf = new Map(seats.map((s) => [s.seat_no, s.free]));
  if (map) {
    // The real layout of this trip's vehicle: rows, aisle, doors and WC exactly as the carrier defined them
    return (
      <div className="stack">
        <SeatGrid data={map} renderSeat={(s) => {
          const mine = selected.includes(s.n), free = !!freeOf.get(s.n);
          return (
            <button type="button" className={`seat${mine ? " mine" : !free ? " taken" : ""}${s.cabin === "ACCESSIBLE" ? " accessible" : ""}`}
                    disabled={!free || (!mine && selected.length >= max)} onClick={() => toggle(s.n)} aria-pressed={mine}
                    aria-label={`${t("common.seat")} ${s.label}`}>{s.label}</button>
          );
        }} />
        <Legend />
      </div>
    );
  }
  const cells: (number | null)[] = [];
  // Trips created before seat layouts existed: a plain 2+2 drawing
  seats.forEach((s, i) => { cells.push(s.seat_no); if (i % 4 === 1) cells.push(null); });
  const free = freeOf;
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
      <Legend />
    </div>
  );
}

function Legend() {
  const { t } = useI18n();
  return (
      <div className="legend">
        <span><i />{t("seats.free")}</span>
        <span><i style={{ background: "var(--surface-container-high)", borderColor: "transparent" }} />{t("seats.taken")}</span>
        <span><i style={{ background: "var(--primary)", borderColor: "var(--primary)" }} />{t("seats.mine")}</span>
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
  const { t, money, time, date, station, duration, locale } = useI18n();
  const countryName = (code: string) => (code ? new Intl.DisplayNames([locale], { type: "region" }).of(code) ?? code : "");
  const { me } = useAuth();
  const ch = useChannel();
  const nav = useNavigate();
  const loc = useLocation();

  const detail = useLoad(() => api.get<TripDetail>(`/api/trips/${uid}`, { from_seq: fromSeq, to_seq: toSeq }), [uid, fromSeq, toSeq]);
  const ref = useLoad(() => api.get<{ fare_brands: FareBrand[]; platform_fee: number; countries: string[] }>("/api/ref"));
  // Passengers pay from their wallet; an agency pays from its prepaid balance within its daily limit
  const wallet = useLoad<Funds | null>(() => (me?.portal !== ch.portal ? Promise.resolve(null)
    : api.get<Funds>(ch.agency ? "/api/agency/dashboard" : "/api/wallet")), [me, ch.portal]);
  const [contact, setContact] = useState("");
  // The passenger's family register (4.20): members can be picked as travellers; the head may pay from the family account
  const family = useLoad<FamilyView | null>(() => (ch.agency || me?.portal !== "PASSENGER" ? Promise.resolve(null)
    : api.get<FamilyView>("/api/family").catch(() => null)), [me, ch.agency]);
  const [payFrom, setPayFrom] = useState<"WALLET" | "FAMILY_ACCOUNT">("WALLET");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoteError, setQuoteError] = useState<unknown>(null);

  const [selected, setSelected] = useState<number[]>([]);
  const [hold, setHold] = useState<Hold | null>(null);
  const [brand, setBrand] = useState("STANDARD");
  const [pax, setPax] = useState<PassengerDraft[]>([]);
  // Documents each nationality needs on this segment: a passport on international trips unless an exception applies
  const [docs, setDocs] = useState<Record<string, TravelDocs>>({});
  const nationalities = [...new Set(["SY", ...pax.map((p) => p.nationality)])];
  useEffect(() => {
    const missing = nationalities.filter((n) => !(n in docs));
    if (!uid || missing.length === 0) return;
    Promise.all(missing.map((n) => api.get<TravelDocs>(`/api/trips/${uid}/documents`, { from_seq: fromSeq, to_seq: toSeq, nationality: n })
      .then((r) => [n, r] as const))).then((rs) => setDocs((d) => ({ ...d, ...Object.fromEntries(rs) }))).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uid, fromSeq, toSeq, nationalities.join(",")]);
  useEffect(() => {
    // keep each passenger on a document type the rules accept for their nationality
    setPax((ps) => ps.map((p) => {
      const r = docs[p.nationality];
      return r?.international && !r.docs.includes(p.id_type) ? { ...p, id_type: r.docs[0] } : p;
    }));
  }, [docs]);
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [idemKey] = useState(newKey);
  const left = useCountdown(hold?.expires_at ?? null);

  // Release the hold if the passenger leaves the page without paying
  const holdRef = useRef<string | null>(null);
  useEffect(() => { holdRef.current = hold?.hold_token ?? null; }, [hold]);
  useEffect(() => () => { if (holdRef.current) void api.del(`${ch.api}/holds/${holdRef.current}`).catch(() => {}); }, [ch.api]);

  // The server prices every traveller (adult, child, infant) and the family offer; the summary shows its answer
  const quoteKey = JSON.stringify([hold?.hold_token, brand, pax.map((p) => [p.lap, p.birth_date, p.family_member_uid, p.nationality])]);
  useEffect(() => {
    if (!hold || ch.agency || pax.length === 0) { setQuote(null); return; }
    const id = setTimeout(() => {
      const body = { trip_uid: uid, from_seq: fromSeq, to_seq: toSeq, fare_brand: brand,
        passengers: pax.map((p, i) => ({ seat_no: p.lap ? null : selected[i] ?? null, nationality: p.nationality,
          ...(p.birth_date ? { birth_date: p.birth_date } : {}), ...(p.family_member_uid ? { family_member_uid: p.family_member_uid } : {}) })) };
      api.post<Quote>("/api/bookings/quote", body).then((q) => { setQuote(q); setQuoteError(null); })
        .catch((e) => { setQuote(null); setQuoteError(e); });
    }, 350);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quoteKey]);

  if (detail.error) return <div className="page"><ErrorBox error={detail.error} /></div>;
  if (!detail.data || !ref.data) return <Spinner />;
  const d = detail.data;
  const from = d.stops.find((s) => s.seq === d.from_seq)!, to = d.stops.find((s) => s.seq === d.to_seq)!;
  const brands = ref.data.fare_brands;
  const countries = ref.data.countries;
  const fb = brands.find((b) => b.code === brand) ?? brands[0];
  const farePer = roundUnit(d.price * fb.factor);
  const total = farePer * paxCount + ref.data.platform_fee;

  const seatLabel = (n: number) => d.seat_map?.seats.find((s) => s.n === n)?.label ?? String(n);
  const toggle = (n: number) => setSelected((s) => (s.includes(n) ? s.filter((x) => x !== n) : [...s, n].slice(-paxCount)));

  const doHold = async () => {
    if (!me || me.portal !== ch.portal) { nav(`/login?portal=${ch.portal}&next=${encodeURIComponent(loc.pathname + loc.search)}`); return; }
    setBusy(true); setError(null);
    try {
      const h = await api.post<Hold>(`${ch.api}/holds`, { trip_uid: uid, from_seq: fromSeq, to_seq: toSeq, seat_nos: selected });
      setHold(h);
      setPax(selected.map((_, i) => pax[i] ?? blankPassenger()));
    } catch (e) {
      setError(e); detail.reload(); setSelected([]);
    } finally { setBusy(false); }
  };

  const release = async () => {
    if (hold) await api.del(`${ch.api}/holds/${hold.hold_token}`).catch(() => {});
    setHold(null); detail.reload();
  };

  const travellers = () => pax.map((p, i) => ({
    seat_no: p.lap ? null : selected[i], ...namesFor(p), ...documentFor(p, docs[p.nationality]),
    ...(p.birth_date ? { birth_date: p.birth_date } : {}), ...(p.family_member_uid ? { family_member_uid: p.family_member_uid } : {}),
  }));

  const pay = async () => {
    if (!hold) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ booking_ref: string }>(`${ch.api}/bookings`, {
        hold_token: hold.hold_token, trip_uid: uid, from_seq: fromSeq, to_seq: toSeq, fare_brand: brand, idempotency_key: idemKey,
        ...(ch.agency ? { contact_mobile: contact.trim() } : { pay_from: payFrom }),
        passengers: travellers(),
      });
      holdRef.current = null;
      nav(ch.link(`/booking/${r.booking_ref}?new=1`));
    } catch (e) {
      setError(e);
      if (e instanceof Error && "code" in e && (e as { code: string }).code === "HOLD_EXPIRED") { setHold(null); detail.reload(); }
    } finally { setBusy(false); }
  };

  const contactValid = !ch.agency || /^\+?[0-9]{8,15}$/.test(contact.trim());
  const seated = pax.filter((p) => !p.lap).length;
  const paxValid = seated === selected.length && pax.every((p) => passengerValid(p, docs[p.nationality])) && contactValid;
  const infantBand = d.categories?.find((c) => c.category === "INFANT");
  const laps = pax.filter((p) => p.lap).length;
  const canAddLap = !!infantBand && !infantBand.seat_required && laps < selected.length;
  const travelDate = from.sched_dep.slice(0, 10);
  const used = new Set(pax.map((p) => p.family_member_uid).filter(Boolean));
  const members = family.data?.role === "HEAD" ? family.data.members ?? [] : family.data?.role === "MEMBER" && family.data.me ? [family.data.me] : [];
  const shownTotal = quote?.total ?? total;
  const tripDocs = docs.SY;
  const commission = ch.agency && wallet.data?.agreement
    ? Math.floor(farePer * paxCount * wallet.data.agreement.commission_bp / 10000 / 100) * 100 : null;
  const mm = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;

  return (
    <div className={ch.agency ? "stack" : "page stack"}>
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
            <SeatMap seats={d.seats} map={d.seat_map} selected={selected} toggle={toggle} max={paxCount} />
          </div>
          <div className="card stack">
            <h3>{t("seats.selected")}</h3>
            <div className="row">{selected.length ? selected.map((s) => <span key={s} className="chip green">{t("common.seat")} {seatLabel(s)}</span>) : <span className="muted">—</span>}</div>
            <div className="divider" />
            <div className="row between"><span className="muted">{t("results.perPassenger")}</span><span className="price" style={{ fontSize: 20 }}>{money(d.price)}</span></div>
            {d.categories?.length > 0 && (
              <div className="stack tight">
                {d.categories.filter((c) => c.category !== "ADULT").map((c) => (
                  <div key={c.category} className="row between small">
                    <span className="muted">{t(`pax.cat.${c.category}`)} · {t("pax.ages", { from: c.min_age, to: c.max_age ?? "+" })}{!c.seat_required ? ` · ${t("pax.onLap")}` : ""}</span>
                    <span>{money(c.fare)}</span>
                  </div>
                ))}
              </div>
            )}
            {d.family_offers?.map((o) => (
              <div key={o.code} className="alert ok small"><Icon name="family_restroom" size={20} />
                <span><strong>{o.name}</strong> · {t("pax.familyOfferHint", { n: o.min_members })}</span></div>
            ))}
            <p className="small muted"><Icon name="lock" size={16} /> {t("seats.holdFor", { n: d.trip.hold_min })}</p>
            <button className="btn large block" disabled={selected.length !== paxCount || busy} onClick={doHold}>
              {me?.portal === ch.portal ? t("seats.hold") : t("seats.signInFirst")}
            </button>
          </div>
        </div>
      ) : (
        <div className="grid checkout-grid">
          <div className="stack">
            <h2>{t("checkout.title")}</h2>
            <div className="alert warn"><Icon name="schedule" /><span>{left > 0 ? t("checkout.holdLeft", { t: mm }) : t("checkout.holdExpired")}</span></div>
            {tripDocs?.international && (
              <div className="alert info"><Icon name="public" />
                <span><strong>{t("checkout.international", { country: countryName(tripDocs.destination ?? "") })}</strong>{" "}
                  {t("checkout.passportRule")}</span>
              </div>
            )}
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
            {ch.agency && (
              <div className="card stack">
                <div><h3>{t("agency.contact")}</h3><p className="small muted">{t("agency.contactHint")}</p></div>
                <input className="input ltr" inputMode="tel" autoComplete="off" placeholder="+9639XXXXXXXX" value={contact}
                       onChange={(e) => setContact(e.target.value)} aria-invalid={contact !== "" && !contactValid} />
              </div>
            )}
            {pax.map((p, i) => (
              <div key={i} className="card stack">
                <div className="row between">
                  <h3>{p.lap ? t("pax.lapInfant") : `${t("common.passenger")} ${i + 1}`}</h3>
                  <div className="row">
                    {members.length > 0 && (
                      <select className="input" style={{ width: "auto" }} value={p.family_member_uid}
                              onChange={(e) => { const m = members.find((x) => x.uid === e.target.value);
                                setPax((ps) => ps.map((x, j) => (j === i ? (m ? fromMember(m, x.lap) : blankPassenger(x.lap)) : x))); }}>
                        <option value="">{t("family.pickMember")}</option>
                        {members.filter((m) => m.uid === p.family_member_uid || (!used.has(m.uid)
                          // a lap is for infants only: offer the members who are infants on the travel day
                          && (!p.lap || categoryOf(fromMember(m, true), d.categories, travelDate) === "INFANT"))).map((m) =>
                          <option key={m.uid} value={m.uid}>{m.full_name} · {t(`family.rel.${m.relation}`)}</option>)}
                      </select>
                    )}
                    {p.lap ? <button className="btn text" onClick={() => setPax((ps) => ps.filter((_, j) => j !== i))}><Icon name="close" />{t("common.remove")}</button>
                           : <span className="chip green">{t("common.seat")} {seatLabel(selected[i])}</span>}
                  </div>
                </div>
                <PassengerFields value={p} countries={countries} docs={docs[p.nationality]} bands={d.categories} travel={travelDate}
                                 onChange={(v) => setPax((ps) => ps.map((x, j) => (j === i ? v : x)))} />
              </div>
            ))}
            {canAddLap && !ch.agency && (
              <button className="btn outline" onClick={() => setPax((ps) => [...ps, blankPassenger(true)])}>
                <Icon name="child_care" />{t("pax.addLapInfant")}
              </button>
            )}
          </div>
          <div className="card stack" style={{ position: "sticky", top: 84 }}>
            <h3>{t("checkout.summary")}</h3>
            {quoteError != null && <ErrorBox error={quoteError} />}
            {quote ? (
              <>
                {quote.lines.map((l) => (
                  <div key={l.passenger} className="row between small"><span className="muted">{t("common.passenger")} {l.passenger} · {t(`pax.cat.${l.category}`)}{!l.seat ? ` · ${t("pax.onLap")}` : ""}</span><span>{money(l.list_fare ?? l.fare)}</span></div>
                ))}
                {quote.family_offer && (
                  <div className="row between small" style={{ color: "var(--success)" }}><span><Icon name="family_restroom" size={16} /> {quote.family_offer.name}</span><span>−{money(quote.family_offer.discount)}</span></div>
                )}
              </>
            ) : (
              <div className="row between"><span className="muted">{t("checkout.fares", { n: paxCount })}</span><span>{money(farePer * paxCount)}</span></div>
            )}
            <div className="row between"><span className="muted">{t("checkout.fee")}</span><span>{money(ref.data.platform_fee)}</span></div>
            <div className="divider" />
            <div className="row between"><strong>{t("common.total")}</strong><span className="price">{money(shownTotal)}</span></div>
            {family.data?.role === "HEAD" && (family.data.account?.balance ?? 0) > 0 && (
              <div className="stack tight">
                <span className="small muted">{t("family.payFrom")}</span>
                <label className="check small"><input type="radio" checked={payFrom === "WALLET"} onChange={() => setPayFrom("WALLET")} />{t("checkout.walletBalance")}</label>
                <label className="check small"><input type="radio" checked={payFrom === "FAMILY_ACCOUNT"} onChange={() => setPayFrom("FAMILY_ACCOUNT")} />
                  {t("family.account")}: {money(family.data.account!.balance)}</label>
              </div>
            )}
            {family.data?.role === "MEMBER" && family.data.me && family.data.me.funding !== "OWN" && (
              <div className="alert info small"><Icon name="diversity_3" size={20} /><span>{t("family.paidByHead")}</span></div>
            )}
            {commission !== null && (
              <div className="row between"><span className="muted">{t("agency.commissionEarned")}</span><span style={{ color: "var(--success)" }}>{money(commission)}</span></div>
            )}
            {wallet.data && (
              <div className={`alert ${wallet.data.balance >= shownTotal || payFrom === "FAMILY_ACCOUNT" ? "info" : "error"}`}>
                <Icon name="account_balance_wallet" />
                <span className="grow">{t(ch.agency ? "agency.balance" : "checkout.walletBalance")}: <strong>{money(wallet.data.balance)}</strong></span>
                {wallet.data.balance < shownTotal && payFrom === "WALLET" && !ch.agency && <Link to="/wallet">{t("checkout.topupFirst")}</Link>}
              </div>
            )}
            {wallet.data?.remaining_today !== undefined && wallet.data.remaining_today < total && (
              <div className="alert error"><Icon name="warning" /><span>{t("errors.AGENCY_DAILY_LIMIT")}</span></div>
            )}
            <label className="check small"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} />{t(ch.agency ? "agency.agree" : "checkout.agree")}</label>
            <button className="btn large block" disabled={busy || !agree || !paxValid || left === 0 || quoteError != null} onClick={pay}>
              <Icon name="lock" />{t("checkout.pay", { amount: money(shownTotal) })}
            </button>
            <button className="btn text" onClick={release}>{t("common.back")}</button>
          </div>
        </div>
      )}
    </div>
  );
}
