import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import QRCode from "qrcode";
import { api, type TripDetail } from "../../api";
import { chooseStation, currentStation, type StationChoice } from "../../channel";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";

// The station portal (operating companies at boarding stations, 1099-1111): the rights carriers gave the company, the
// station's trips, the counter check and the boarding pass with its bay, boarding at the bay, and selling tickets for
// carriers that gave the BOOKING right. Every action is checked again by the API and the database. After the design
// review of October 2026 (docs/design/STATION_SCREENS_REVIEW.md): the trips name where they go and show the check-in
// state at this station, the identity check comes before the scan and is asked for when missed, and the boarding pass
// carries the ticket's signed code, so the bay and the driver's app scan the paper.

interface Grant {
  uid: string; permission: "BOOKING" | "BOARDING_PASS" | "BOARDING"; carrier_name: string | null; station_uid: string | null;
  station_code: string | null; station_name: string | null; usable_now: boolean | null;
}
interface Counter { station_uid: string; station_code: string; code: string; status: string; boarding_on_now: boolean }
interface Overview { grants: Grant[]; counters: Counter[] }
export interface StationTrip {
  trip_uid: string; trip_no: string; carrier: string; status: string; stop_seq: number; departs_at: string; bay: string | null;
  dest_code?: string; dest_name?: string; dest_city?: string | null; checkin_opens_at?: string | null; checkin_closes_at?: string | null;
  may_check_in: boolean; may_board: boolean; may_sell: boolean; tickets: number; checked_in: number; boarded: number;
}
interface Pass {
  pass_no: string; status: string; ticket_no: string; seat_no: number | null; passenger: string; trip_no: string; carrier: string;
  from_station: string; to_station: string; from_code?: string; to_code?: string; departs_at: string; bay: string | null;
  counter: string | null; repeated?: boolean; credential?: string | null; credential_opens_at?: string;
}
interface DaySales {
  day: string; count: number; total: number; currency: string | null;
  bookings: { booking_ref: string; status: string; total_amount: number; created_at: string; trip_no: string; carrier: string; counter: string | null; tickets: number }[];
}
interface CashPosition { owed: number; limit: number; remaining: number; currency: string }

/** Where the clerk works: chosen once on this device, from the counters the platform opened for the company. */
function useStation(): [StationChoice | null, (s: StationChoice | null) => void] {
  const [s, setS] = useState<StationChoice | null>(currentStation());
  return [s, (v) => { chooseStation(v); setS(v); }];
}

/** Where the clerk works, named in the interface's language ("SY-DAM-C001 · Damascus Central Station"). */
function useWhere() {
  const { t, station: placeName } = useI18n();
  return (s: StationChoice) => `${s.station_code} · ${placeName(s.station_code, s.station_name)}${s.counter_code ? ` · ${t("st.counter")} ${s.counter_code}` : ""}`;
}

/** The check-in state of a trip at this station, from its window (1113): not open yet, open until, closed, or no window. */
function checkinState(x: StationTrip, now: number): { key: "NONE" | "SOON" | "OPEN" | "CLOSED"; at: string | null } {
  if (x.checkin_opens_at && now < Date.parse(x.checkin_opens_at)) return { key: "SOON", at: x.checkin_opens_at };
  if (x.checkin_closes_at && now > Date.parse(x.checkin_closes_at)) return { key: "CLOSED", at: null };
  return x.checkin_closes_at ? { key: "OPEN", at: x.checkin_closes_at } : { key: "NONE", at: null };
}
const CHECKIN_TONE = { NONE: "green", SOON: "", OPEN: "green", CLOSED: "wheat" };

function NeedStation() {
  const { t } = useI18n();
  return <div className="card"><Empty icon="location_on" title={t("st.chooseFirst")}><Link className="btn" to="/station">{t("st.choose")}</Link></Empty></div>;
}

export function StationHome() {
  const { t, station: placeName } = useI18n();
  const { me } = useAuth();
  const state = useLoad(() => api.get<Overview>("/api/station/overview"));
  const [station, setStation] = useStation();
  return (
    <div className="stack">
      <PageHead title={t("st.title")} sub={me?.company?.name ?? t("st.sub")} />
      <Loaded state={state}>{(o) => {
        const stations = new Map<string, { code: string; name: string }>();
        o.counters.forEach((c) => stations.set(c.station_uid, { code: c.station_code, name: placeName(c.station_code, c.station_code) }));
        o.grants.forEach((g) => { if (g.station_uid) stations.set(g.station_uid, { code: g.station_code ?? "", name: placeName(g.station_code, g.station_name ?? g.station_code ?? "") }); });
        return (
          <>
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("st.whereAmI")}</h3>
              {stations.size === 0 ? <Empty icon="location_off" title={t("st.noStation")} hint={t("st.noStationHint")} /> : (
                <div className="row" style={{ gap: 12, alignItems: "flex-end", flexWrap: "wrap" }}>
                  <Field label={t("st.station")}>
                    <select className="input" value={station?.station_uid ?? ""} onChange={(e) => {
                      const uid = e.target.value; const s = stations.get(uid);
                      setStation(s ? { station_uid: uid, station_code: s.code, station_name: s.name, counter_code: null } : null);
                    }}>
                      <option value="">—</option>
                      {[...stations.entries()].map(([uid, s]) => <option key={uid} value={uid}>{s.code} · {s.name}</option>)}
                    </select>
                  </Field>
                  {station && (
                    <Field label={t("st.counter")}>
                      <select className="input" value={station.counter_code ?? ""} onChange={(e) => setStation({ ...station, counter_code: e.target.value || null })}>
                        <option value="">—</option>
                        {o.counters.filter((c) => c.station_uid === station.station_uid && c.status === "ACTIVE").map((c) =>
                          <option key={c.code} value={c.code}>{c.code}</option>)}
                      </select>
                    </Field>
                  )}
                  {station && <Link className="btn" to="/station/trips"><Icon name="directions_bus" />{t("st.trips")}</Link>}
                </div>
              )}
              {station && !station.counter_code && <div className="alert info small"><Icon name="info" />{t("st.chooseCounter")}</div>}
            </div>
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("st.rights")}</h3>
              {o.grants.length === 0 ? <Empty icon="key_off" title={t("st.noRights")} hint={t("st.noRightsHint")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("st.carrier")}</th><th>{t("st.station")}</th><th>{t("st.right")}</th><th>{t("st.now")}</th></tr></thead>
                  <tbody>{o.grants.map((g) => (
                    <tr key={g.uid}>
                      <td>{g.carrier_name ?? t("st.everyCarrier")}</td>
                      <td>{g.station_code ? `${g.station_code} · ${placeName(g.station_code, g.station_name ?? "")}` : t("st.everyStation")}</td>
                      <td>{t(`st.perm.${g.permission}`)}</td>
                      <td>{g.usable_now === null ? "—" : <span className={`chip ${g.usable_now ? "green" : ""}`}>{t(g.usable_now ? "st.usable" : "st.notUsable")}</span>}</td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
              <p className="small muted" style={{ margin: 0 }}>{t("st.rightsHint")}</p>
            </div>
          </>
        );
      }}</Loaded>
    </div>
  );
}

function useTrips(stationUid: string | undefined) {
  const state = useLoad(() => (stationUid ? api.get<{ trips: StationTrip[] }>("/api/station/trips", { station_uid: stationUid }).then((r) => r.trips)
    : Promise.resolve([] as StationTrip[])), [stationUid]);
  const reload = state.reload;
  useEffect(() => { const id = window.setInterval(() => reload(), 30000); return () => window.clearInterval(id); }, [reload]);
  return state;
}

export function StationTrips() {
  const { t, time, date, city, station: placeName } = useI18n();
  const where = useWhere();
  const [station] = useStation();
  const state = useTrips(station?.station_uid);
  const [sellFor, setSellFor] = useState<StationTrip | null>(null);
  if (!station) return <NeedStation />;
  const now = Date.now();
  const today = date(new Date(now)), tomorrow = date(new Date(now + 864e5));
  const day = (iso: string) => { const d = date(iso); return d === today ? t("st.today") : d === tomorrow ? t("st.tomorrow") : d; };
  const dest = (x: StationTrip) => (x.dest_city && city(x.dest_city) !== x.dest_city ? city(x.dest_city) : placeName(x.dest_code, x.dest_name ?? "—"));
  return (
    <div className="stack">
      <PageHead title={t("st.trips")} sub={where(station)}>
        <Link className="btn outlined" to="/station/checkin"><Icon name="how_to_reg" />{t("st.checkin")}</Link>
        <Link className="btn outlined" to="/station/boarding"><Icon name="qr_code_scanner" />{t("st.boarding")}</Link>
      </PageHead>
      <Loaded state={state}>{(trips) => trips.length === 0 ? <div className="card"><Empty icon="departure_board" title={t("st.noTrips")} hint={t("st.noTripsHint")} /></div> : (
        <div className="card"><div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("st.departs")}</th><th>{t("st.to")}</th><th>{t("st.trip")}</th><th>{t("st.carrier")}</th><th>{t("st.bay")}</th><th>{t("st.checkin")}</th>
            <th className="num">{t("st.tickets")}</th><th className="num">{t("st.checkedIn")}</th><th className="num">{t("st.boarded")}</th><th></th></tr></thead>
          <tbody>{trips.map((x, i) => {
            const ck = checkinState(x, now);
            const first = i === 0 || date(trips[i - 1].departs_at) !== date(x.departs_at);
            return [
              first && <tr key={`day-${x.departs_at}`} className="day-row"><th colSpan={10} scope="colgroup">{day(x.departs_at)}</th></tr>,
              <tr key={`${x.trip_uid}-${x.stop_seq}`}>
                <td><strong className="mono">{time(x.departs_at)}</strong></td>
                <td><strong>{dest(x)}</strong></td>
                <td className="mono small">{x.trip_no}</td>
                <td>{x.carrier}</td>
                <td className="mono">{x.bay ?? "—"}</td>
                <td>{x.status === "BOARDING" ? <Status value="BOARDING" />
                  : <span className={`chip ${CHECKIN_TONE[ck.key]}`}>{t(`st.ck.${ck.key}`, { time: ck.at ? time(ck.at) : "" })}</span>}</td>
                <td className="num">{x.tickets}</td><td className="num">{x.checked_in}</td><td className="num">{x.boarded}</td>
                <td className="row" style={{ gap: 4, justifyContent: "flex-end", flexWrap: "nowrap" }}>
                  {x.may_sell && <button className="btn outlined small" onClick={() => setSellFor(x)}><Icon name="point_of_sale" />{t("st.sell")}</button>}
                  {x.may_board && <Link className="btn text small" to={`/station/boarding?trip=${x.trip_uid}`}>{t("st.boarding")}</Link>}
                </td>
              </tr>,
            ];
          })}</tbody>
        </table></div></div>
      )}</Loaded>
      {sellFor && <Destination trip={sellFor} onClose={() => setSellFor(null)} />}
    </div>
  );
}

/** Where the passenger travels to: a later stop of the trip; then the booking screen of the station counter. */
function Destination({ trip, onClose }: { trip: StationTrip; onClose: () => void }) {
  const { t, time, station: placeName } = useI18n();
  const nav = useNavigate();
  const detail = useLoad(() => api.get<TripDetail>(`/api/trips/${trip.trip_uid}`, { from_seq: trip.stop_seq, to_seq: trip.stop_seq + 1 }), [trip.trip_uid]);
  const [to, setTo] = useState<number | null>(null);
  const [pax, setPax] = useState(1);
  return (
    <Modal title={`${t("st.sell")} · ${trip.trip_no}`} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={to === null} onClick={() => nav(`/station/trip/${trip.trip_uid}?from=${trip.stop_seq}&to=${to}&pax=${pax}`)}>{t("common.next")}</button></>}>
      <Loaded state={detail}>{(d) => (
        <div className="stack">
          <Field label={t("st.to")}>
            <select className="input" value={to ?? ""} onChange={(e) => setTo(e.target.value ? Number(e.target.value) : null)}>
              <option value="">—</option>
              {d.stops.filter((s) => s.seq > trip.stop_seq).map((s) => <option key={s.seq} value={s.seq}>{placeName(s.station_code, s.station_name)} · {time(s.sched_arr)}</option>)}
            </select>
          </Field>
          <Field label={t("common.passengers")}>
            <input className="input mono" type="number" min={1} max={9} value={pax} onChange={(e) => setPax(Math.max(1, Math.min(9, Number(e.target.value) || 1)))} />
          </Field>
        </div>
      )}</Loaded>
    </Modal>
  );
}

/** The ticket's signed code (T2) on the pass: fixed, so it prints and scans at the bay and in the driver's app. */
function PassCode({ pass }: { pass: Pass }) {
  const { t, dateTime } = useI18n();
  const [img, setImg] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    setImg(null);
    if (pass.credential) {
      void QRCode.toDataURL(pass.credential, { margin: 1, width: 360, errorCorrectionLevel: "M", color: { dark: "#0B1F3F", light: "#FFFFFF" } })
        .then((url) => { if (live) setImg(url); });
    }
    return () => { live = false; };
  }, [pass.credential]);
  if (!pass.credential) {
    return pass.credential_opens_at
      ? <div className="alert info small"><Icon name="schedule" />{t("st.codeLater", { time: dateTime(pass.credential_opens_at) })}</div>
      : null;
  }
  return (
    <div className="stack tight" style={{ alignItems: "center" }}>
      <div className="qr-box pass-qr">{img ? <img src={img} alt={`${t("st.pass")} ${pass.pass_no}`} /> : <div className="qr-wait" />}</div>
      <span className="small muted">{t("st.code")}</span>
    </div>
  );
}

function PassCard({ pass }: { pass: Pass }) {
  const { t, time, date, station: placeName } = useI18n();
  return (
    <div className="card boarding-pass stack" style={{ borderTop: "6px solid var(--brand-navy)" }}>
      <div className="row between"><strong>{t("st.pass")}</strong><span className="mono">{pass.pass_no}</span></div>
      <div style={{ fontSize: 22, fontWeight: 700 }}>{pass.passenger}</div>
      <div className="row" style={{ gap: 24, flexWrap: "wrap" }}>
        <div><div className="small muted">{t("st.trip")}</div><div className="mono">{pass.trip_no}</div></div>
        <div><div className="small muted">{t("st.carrier")}</div><div>{pass.carrier}</div></div>
        <div><div className="small muted">{t("st.seat")}</div><div className="mono">{pass.seat_no ?? "—"}</div></div>
        <div><div className="small muted">{t("st.departs")}</div><div><strong>{time(pass.departs_at)}</strong> {date(pass.departs_at)}</div></div>
      </div>
      <div className="row" style={{ gap: 24 }}>
        <div><div className="small muted">{t("st.from")}</div><div>{placeName(pass.from_code, pass.from_station)}</div></div>
        <div><div className="small muted">{t("st.to")}</div><div>{placeName(pass.to_code, pass.to_station)}</div></div>
      </div>
      <div className="row between" style={{ gap: 24, alignItems: "flex-end", flexWrap: "wrap" }}>
        <div className="row" style={{ gap: 24, alignItems: "flex-end" }}>
          <div><div className="small muted">{t("st.bay")}</div><div className="mono" style={{ fontSize: 40, fontWeight: 800, color: "var(--brand-navy)" }}>{pass.bay ?? "—"}</div></div>
          <div><div className="small muted">{t("st.counter")}</div><div className="mono">{pass.counter ?? "—"}</div></div>
          <div><div className="small muted">{t("st.ticket")}</div><div className="mono">{pass.ticket_no}</div></div>
        </div>
        <PassCode pass={pass} />
      </div>
    </div>
  );
}

export function StationCheckin() {
  const { t } = useI18n();
  const toast = useToast();
  const where = useWhere();
  const [station] = useStation();
  const [token, setToken] = useState("");
  const [ticketNo, setTicketNo] = useState("");
  const [ref, setRef] = useState("");
  const [doc, setDoc] = useState(false);
  const [needDoc, setNeedDoc] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [pass, setPass] = useState<Pass | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState("");
  const scan = useRef<HTMLInputElement>(null);
  const docBox = useRef<HTMLInputElement>(null);
  useEffect(() => { scan.current?.focus(); }, [pass]);
  if (!station) return <NeedStation />;
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    // a scanner ends with Enter: an unconfirmed identity check is asked for, the scanned code stays in the field
    if (!doc) { setNeedDoc(true); docBox.current?.focus(); return; }
    setBusy(true); setError(null);
    try {
      const p = await api.post<Pass>("/api/station/checkin", {
        station_uid: station.station_uid, counter_code: station.counter_code ?? undefined, document_checked: doc,
        ...(token.trim() ? { token: token.trim() } : { ticket_no: ticketNo.trim(), booking_ref: ref.trim().toUpperCase() }),
      });
      setPass(p); setToken(""); setTicketNo(""); setRef(""); setDoc(false); setNeedDoc(false);
      if (!p.repeated) toast(t("st.passIssued"));
    } catch (err) { setError(err); } finally { setBusy(false); }
  };
  const cancel = async () => {
    if (!pass) return;
    setError(null);
    try {
      await api.post(`/api/station/passes/${pass.pass_no}/cancel`, { reason: reason.trim() });
      toast(t("st.passCancelled")); setPass(null); setCancelling(false); setReason("");
    } catch (err) { setError(err); }
  };
  return (
    <div className="stack">
      <div className="no-print">
        <PageHead title={t("st.checkin")} sub={where(station)} />
      </div>
      <form className="card stack no-print" onSubmit={submit}>
        <label className={`check-row check-first${needDoc ? " invalid" : ""}`}>
          <input ref={docBox} type="checkbox" checked={doc} aria-invalid={needDoc || undefined} aria-describedby={needDoc ? "doc-first" : undefined}
                 onChange={(e) => { setDoc(e.target.checked); if (e.target.checked) { setNeedDoc(false); scan.current?.focus(); } }} />
          <span><strong>{t("st.docChecked")}</strong></span>
        </label>
        {needDoc && <div id="doc-first" className="alert error small" role="alert"><Icon name="badge" />{t("st.docFirst")}</div>}
        <Field label={t("st.scan")} hint={t("st.scanHint")}>
          <input ref={scan} className="input mono ltr" value={token} onChange={(e) => setToken(e.target.value)} autoComplete="off" />
        </Field>
        <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
          <Field label={t("st.ticketNo")}><input className="input mono ltr" value={ticketNo} onChange={(e) => setTicketNo(e.target.value)} disabled={!!token.trim()} /></Field>
          <Field label={t("st.bookingRef")}><input className="input mono ltr" value={ref} onChange={(e) => setRef(e.target.value)} disabled={!!token.trim()} /></Field>
        </div>
        <div className="alert info small"><Icon name="no_photography" />{t("st.photoOff")}</div>
        <ErrorBox error={error} />
        <button className="btn large" disabled={busy || (!token.trim() && !(ticketNo.trim() && ref.trim()))}><Icon name="how_to_reg" />{t("st.issuePass")}</button>
      </form>
      {pass && (
        <>
          {pass.repeated && <div className="alert info no-print" role="status"><Icon name="history" />{t("st.passAgain")}</div>}
          <PassCard pass={pass} />
          <div className="row no-print" style={{ gap: 8 }}>
            <button className="btn" onClick={() => window.print()}><Icon name="print" />{t("st.print")}</button>
            <button className="btn text" onClick={() => setCancelling(true)}>{t("st.cancelPass")}</button>
          </div>
        </>
      )}
      {cancelling && (
        <Modal title={t("st.cancelPass")} onClose={() => setCancelling(false)}
               actions={<><button className="btn text" onClick={() => setCancelling(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={reason.trim().length < 3} onClick={cancel}>{t("common.confirm")}</button></>}>
          <Field label={t("st.reason")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        </Modal>
      )}
    </div>
  );
}

const BOARD_TONE: Record<string, string> = { OK: "ok", DUPLICATE: "warn", CHECKIN_REQUIRED: "err" };

export function StationBoarding() {
  const { t, time, has, city, station: placeName } = useI18n();
  const where = useWhere();
  const [params, setParams] = useSearchParams();
  const [station] = useStation();
  const trips = useTrips(station?.station_uid);
  const tripUid = params.get("trip") ?? "";
  const [token, setToken] = useState("");
  const [last, setLast] = useState<{ result: string; at: string; passenger?: string; seat_no?: number } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const scan = useRef<HTMLInputElement>(null);
  useEffect(() => { scan.current?.focus(); }, [last, tripUid]);
  if (!station) return <NeedStation />;
  const board = async (e: FormEvent) => {
    e.preventDefault();
    if (!token.trim() || !tripUid) return;
    setError(null);
    try {
      const r = await api.post<{ result: string; passenger?: string; seat_no?: number }>("/api/station/board",
        { station_uid: station.station_uid, trip_uid: tripUid, token: token.trim() });
      setLast({ ...r, at: new Date().toISOString() }); setToken(""); trips.reload();
    } catch (err) { setError(err); }
  };
  return (
    <div className="stack">
      <PageHead title={t("st.boarding")} sub={where(station)} />
      <div className="card stack">
        <Field label={t("st.trip")}>
          <select className="input" value={tripUid} onChange={(e) => setParams(e.target.value ? { trip: e.target.value } : {})}>
            <option value="">—</option>
            {(trips.data ?? []).filter((x) => x.may_board).map((x) =>
              <option key={x.trip_uid} value={x.trip_uid}>{time(x.departs_at)} · {x.dest_city && city(x.dest_city) !== x.dest_city ? city(x.dest_city) : placeName(x.dest_code, x.dest_name ?? "")} · {x.trip_no} · {x.carrier}{x.bay ? ` · ${t("st.bay")} ${x.bay}` : ""}</option>)}
          </select>
        </Field>
        {tripUid && (() => {
          const x = (trips.data ?? []).find((y) => y.trip_uid === tripUid);
          return x ? (
            <div className="grid cols-3">
              <Stat icon="confirmation_number" label={t("st.tickets")} value={x.tickets} />
              <Stat icon="how_to_reg" label={t("st.checkedIn")} value={x.checked_in} tone="blue" />
              <Stat icon="airline_seat_recline_normal" label={t("st.boarded")} value={x.boarded} tone="wheat" />
            </div>
          ) : null;
        })()}
        <form onSubmit={board} className="stack">
          <Field label={t("st.scan")} hint={t("st.boardHint")}>
            <input ref={scan} className="input mono ltr" value={token} onChange={(e) => setToken(e.target.value)} disabled={!tripUid} autoComplete="off" />
          </Field>
          <button className="btn large" disabled={!tripUid || !token.trim()}><Icon name="qr_code_scanner" />{t("st.board")}</button>
        </form>
        <ErrorBox error={error} />
        {last && (
          <div className={`alert ${BOARD_TONE[last.result] === "ok" ? "success" : BOARD_TONE[last.result] === "warn" ? "info" : "error"}`} style={{ fontSize: 18 }}>
            <Icon name={last.result === "OK" ? "check_circle" : "error"} />
            <span><strong>{has(`st.result.${last.result}`) ? t(`st.result.${last.result}`) : last.result}</strong>{last.passenger ? ` · ${last.passenger}` : ""}{last.seat_no ? ` · ${t("st.seat")} ${last.seat_no}` : ""}</span>
          </div>
        )}
      </div>
    </div>
  );
}

export function StationSales() {
  const { t, money, time } = useI18n();
  const where = useWhere();
  const [station] = useStation();
  const [day, setDay] = useState("");
  const sales = useLoad(() => (station ? api.get<DaySales>("/api/station/bookings", { station_uid: station.station_uid, day: day || undefined })
    : Promise.resolve(null)), [station?.station_uid, day]);
  const cash = useLoad(() => api.get<CashPosition>("/api/station/cash"));
  if (!station) return <NeedStation />;
  return (
    <div className="stack">
      <PageHead title={t("st.sales")} sub={where(station)}>
        <Link className="btn" to="/station/trips"><Icon name="point_of_sale" />{t("st.sell")}</Link>
      </PageHead>
      <Loaded state={cash}>{(c) => (
        <div className="grid cols-3">
          <Stat icon="account_balance" label={t("st.owed")} value={money(c.owed)} tone="wheat" />
          <Stat icon="price_check" label={t("st.limit")} value={money(c.limit)} />
          <Stat icon="trending_up" label={t("st.remaining")} value={money(c.remaining)} tone={c.remaining > 0 ? "blue" : "red"} />
        </div>
      )}</Loaded>
      {cash.data && cash.data.remaining === 0 && <div className="alert error"><Icon name="warning" />{t("st.limitReached")}</div>}
      <div className="card stack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3 style={{ margin: 0 }}>{t("st.daySales")}</h3>
          <input className="input" type="date" value={day} onChange={(e) => setDay(e.target.value)} aria-label={t("common.date")} style={{ maxWidth: 200 }} />
        </div>
        <Loaded state={sales}>{(d) => !d || d.bookings.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
          <>
            <div className="row" style={{ gap: 24 }}>
              <span>{t("st.soldCount")}: <strong>{d.count}</strong></span><span>{t("common.total")}: <strong>{money(d.total)}</strong></span>
            </div>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("st.bookingRef")}</th><th>{t("st.time")}</th><th>{t("st.trip")}</th><th>{t("st.carrier")}</th><th>{t("st.counter")}</th>
                <th className="num">{t("st.tickets")}</th><th className="num">{t("common.total")}</th><th>{t("common.status")}</th></tr></thead>
              <tbody>{d.bookings.map((b) => (
                <tr key={b.booking_ref}>
                  <td><Link className="mono" to={`/station/booking/${b.booking_ref}`}>{b.booking_ref}</Link></td>
                  <td>{time(b.created_at)}</td><td className="mono">{b.trip_no}</td><td>{b.carrier}</td><td className="mono">{b.counter ?? "—"}</td>
                  <td className="num">{b.tickets}</td><td className="num">{money(b.total_amount)}</td><td><Status value={b.status} /></td>
                </tr>
              ))}</tbody>
            </table></div>
          </>
        )}</Loaded>
      </div>
    </div>
  );
}
