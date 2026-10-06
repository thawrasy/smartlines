import { useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";
import { LayoutPreview, type LayoutRow } from "./Layouts";

export interface CarrierTrip {
  uid: string; trip_no: string; status: string; departure_at: string; arrival_at?: string; seats_total: number; segments_count?: number;
  plate_no: string | null; route_code?: string; origin: string; destination: string; origin_code: string; dest_code: string; sold: number; driver_name?: string | null;
}
interface Dashboard {
  trips_today: number; sales_today: number; tickets_today: number; released_balance: number; active_vehicles: number; load_factor: number;
  trips: CarrierTrip[]; alerts: { kind: string; detail: string; at: string; subject: string }[];
}
interface Route {
  uid: string; code: string; service_type: string; status: string; std_duration_min: number;
  stops: { seq: number; station_uid: string; station_name: string; station_code: string; city_code: string; arr_offset_min: number; dep_offset_min: number; fare_from_origin: number }[];
}
interface Vehicle { uid: string; plate_no: string; vehicle_type: string; make: string | null; model: string | null; manufacture_year: number | null; passenger_seats: number; status: string; next_expiry: string | null; seat_layout_uid: string | null; seat_layout_name: string | null }
interface Crew { uid: string; full_name: string; crew_type: string; license_class: string | null; status: string; email: string | null }
interface Station { uid: string; code: string; name: string; city_code: string }

export function useArrow() {
  return useI18n().dir === "rtl" ? "←" : "→";
}

function useLine() {
  const { station } = useI18n();
  const arrow = useArrow();
  return (t: CarrierTrip) => `${station(t.origin_code, t.origin)} ${arrow} ${station(t.dest_code, t.destination)}`;
}

// ------------------------------------------------------------------ dashboard
export function CarrierDashboard() {
  const { t, money, num, dateTime } = useI18n();
  const { me } = useAuth();
  const line = useLine();
  const state = useLoad(() => api.get<Dashboard>("/api/carrier/dashboard"));
  return (
    <div className="stack">
      <PageHead title={me?.company?.name ?? t("nav.carrier")} sub={me?.company?.code ? `${t("common.code")}: ${me.company.code}` : undefined}>
        <Link className="btn" to="/carrier/trips?new=1"><Icon name="add" />{t("carrier.newTrip")}</Link>
      </PageHead>
      <Loaded state={state}>{(d) => (
        <>
          <div className="grid cols-3">
            <Stat icon="directions_bus" label={t("carrier.tripsToday")} value={num(d.trips_today)} />
            <Stat icon="payments" label={t("carrier.salesToday")} value={money(d.sales_today)} tone="wheat" />
            <Stat icon="confirmation_number" label={t("carrier.ticketsToday")} value={num(d.tickets_today)} tone="blue" />
            <Stat icon="account_balance_wallet" label={t("carrier.released")} value={money(d.released_balance)} />
            <Stat icon="directions_car" label={t("carrier.activeVehicles")} value={num(d.active_vehicles)} tone="blue" />
            <Stat icon="trending_up" label={t("carrier.loadFactor")} value={`${d.load_factor}%`} tone="wheat" />
          </div>
          <div className="grid split">
            <div className="card">
              <div className="card-title"><h3>{t("carrier.upcoming")}</h3><Link to="/carrier/trips">{t("carrier.trips")}</Link></div>
              {d.trips.length === 0 ? <Empty title={t("common.noData")} /> : (
                <div className="table-wrap"><table className="table">
                  <thead><tr><th>{t("booking.tripNo")}</th><th>{t("booking.departs")}</th><th>{t("carrier.route")}</th><th>{t("carrier.sold")}</th><th>{t("common.status")}</th></tr></thead>
                  <tbody>{d.trips.map((x) => (
                    <tr key={x.uid}>
                      <td className="mono small">{x.trip_no}</td><td>{dateTime(x.departure_at)}</td>
                      <td className="small">{line(x)}</td>
                      <td className="num">{x.sold}/{x.seats_total}</td><td><Status value={x.status} /></td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
            <div className="card">
              <div className="card-title"><h3>{t("carrier.alerts")}</h3></div>
              {d.alerts.length === 0 ? <div className="alert ok"><Icon name="check_circle" />{t("carrier.noAlerts")}</div> : (
                <div className="stack tight">{d.alerts.map((a, i) => (
                  <div key={i} className="alert warn"><Icon name="warning" /><span>{a.subject} · {a.detail} · {a.at.slice(0, 10)}</span></div>
                ))}</div>
              )}
            </div>
          </div>
        </>
      )}</Loaded>
    </div>
  );
}

// ------------------------------------------------------------------ trips
function NewTrip({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { t, station } = useI18n();
  const arrow = useArrow();
  const routes = useLoad(() => api.get<{ routes: Route[] }>("/api/carrier/routes"));
  const vehicles = useLoad(() => api.get<{ vehicles: Vehicle[] }>("/api/carrier/vehicles"));
  const crew = useLoad(() => api.get<{ crew: Crew[] }>("/api/carrier/crew"));
  const [form, setForm] = useState({ route_uid: "", vehicle_uid: "", driver_uid: "", departure_local: "", publish: true });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/carrier/trips", { ...form, driver_uid: form.driver_uid || null });
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const routeLabel = (r: Route) => `${r.code} · ${r.stops.map((s) => station(s.station_code, s.station_name)).join(` ${arrow} `)}`;
  return (
    <Modal title={t("carrier.newTrip")} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !form.route_uid || !form.vehicle_uid || !form.departure_local} onClick={submit}>{t("common.create")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Field label={t("carrier.route")}>
          <select className="input" value={form.route_uid} onChange={(e) => setForm({ ...form, route_uid: e.target.value })}>
            <option value="" disabled>—</option>
            {routes.data?.routes.filter((r) => r.status === "ACTIVE").map((r) => <option key={r.uid} value={r.uid}>{routeLabel(r)}</option>)}
          </select>
        </Field>
        <div className="grid cols-2">
          <Field label={t("carrier.vehicle")}>
            <select className="input" value={form.vehicle_uid} onChange={(e) => setForm({ ...form, vehicle_uid: e.target.value })}>
              <option value="" disabled>—</option>
              {vehicles.data?.vehicles.filter((v) => v.status === "ACTIVE").map((v) => <option key={v.uid} value={v.uid}>{v.plate_no} · {v.passenger_seats} {t("common.seats")}</option>)}
            </select>
          </Field>
          <Field label={`${t("carrier.driver")} (${t("common.optional")})`}>
            <select className="input" value={form.driver_uid} onChange={(e) => setForm({ ...form, driver_uid: e.target.value })}>
              <option value="">{t("carrier.noDriver")}</option>
              {crew.data?.crew.filter((c) => c.status === "ACTIVE").map((c) => <option key={c.uid} value={c.uid}>{c.full_name}</option>)}
            </select>
          </Field>
        </div>
        <Field label={t("carrier.departureLocal")}>
          <input className="input ltr" type="datetime-local" value={form.departure_local} onChange={(e) => setForm({ ...form, departure_local: e.target.value })} />
        </Field>
        <label className="check"><input type="checkbox" checked={form.publish} onChange={(e) => setForm({ ...form, publish: e.target.checked })} />{t("carrier.publishNow")}</label>
      </div>
    </Modal>
  );
}

interface Manifest { trip_no: string; passengers: { ticket_no: string; seat_no: number | null; passenger_category: string; status: string; full_name: string; nationality: string | null; id_type: string | null; id_no_last4: string | null; booking_ref: string; from_station: string; to_station: string; from_code: string; to_code: string; boarded_at: string | null }[] }

function ManifestModal({ uid, onClose }: { uid: string; onClose: () => void }) {
  const { t, station, time, locale } = useI18n();
  const regions = new Intl.DisplayNames([locale], { type: "region" });
  const state = useLoad(() => api.get<Manifest>(`/api/carrier/trips/${uid}/manifest`), [uid]);
  return (
    <Modal title={t("carrier.manifest")} onClose={onClose} wide>
      <Loaded state={state}>{(m) => (
        <div className="stack">
          <div className="row between"><span className="chip outline mono">{m.trip_no}</span><span className="small muted">{t("carrier.exportHint")}</span></div>
          {m.passengers.length === 0 ? <Empty icon="group" title={t("common.noData")} /> : (
            <div className="table-wrap"><table className="table">
              <thead><tr><th>{t("common.seat")}</th><th>{t("common.passenger")}</th><th>{t("pax.category")}</th><th>{t("checkout.nationality")}</th><th>{t("carrier.idDoc")}</th><th>{t("common.from")}</th><th>{t("common.to")}</th><th>{t("booking.ref")}</th><th>{t("common.status")}</th></tr></thead>
              <tbody>{m.passengers.map((p) => (
                <tr key={p.ticket_no}>
                  <td>{p.seat_no ? <span className="chip green">{p.seat_no}</span> : <span className="chip outline">{t("pax.onLap")}</span>}</td><td>{p.full_name}</td>
                  <td className="small">{t(`pax.cat.${p.passenger_category}`)}</td>
                  <td className="small">{p.nationality ? regions.of(p.nationality) : "—"}</td>
                  <td className="small">{p.id_type ? t(`checkout.idTypes.${p.id_type}`) : "—"} {p.id_no_last4 && <span className="mono">•••{p.id_no_last4}</span>}</td>
                  <td className="small">{station(p.from_code, p.from_station)}</td><td className="small">{station(p.to_code, p.to_station)}</td>
                  <td className="mono small">{p.booking_ref}</td>
                  <td><Status value={p.status} /> {p.boarded_at && <span className="small muted">{time(p.boarded_at)}</span>}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
          <IssuedManifests uid={uid} />
        </div>
      )}</Loaded>
    </Modal>
  );
}

interface Delivery { uid: string; authority: string; channel: string; status: string; ack_ref: string | null }
interface Issued { uid: string; scope: string; type: string; version: number; status: string; border_point: string | null; persons: number;
                   issued_at: string; sha256: string | null; deliveries: Delivery[] }

/** Manifests the carrier issued for this trip (study 11.10): signed versions and where each was delivered. */
function IssuedManifests({ uid }: { uid: string }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ scope: string; manifests: Issued[] }>(`/api/carrier/trips/${uid}/manifests`).catch(() => null), [uid]);
  const [error, setError] = useState<unknown>(null);
  if (!state.data) return null;
  const issue = async (type: string) => {
    setError(null);
    try { await api.post(`/api/carrier/trips/${uid}/manifests`, { type }); toast(t("manifest.issued")); state.reload(); } catch (e) { setError(e); }
  };
  const any = state.data.manifests.length > 0;
  return (
    <div className="stack">
      <div className="divider" />
      <div className="row between">
        <div className="row"><Icon name="fact_check" size={22} /><h3>{t("manifest.title")}</h3>
          <span className="chip outline">{t(`manifest.scope.${state.data.scope}`)}</span></div>
        <div className="row">
          <button className="btn small" onClick={() => issue(any ? "AMENDMENT" : "PRE_DEPARTURE")}>{any ? t("manifest.amend") : t("manifest.issue")}</button>
          {any && <button className="btn tonal small" onClick={() => issue("FINAL")}>{t("manifest.final")}</button>}
          {any && <button className="btn text small" onClick={() => confirm(t("manifest.cancelConfirm")) && issue("CANCELLATION")}>{t("manifest.cancel")}</button>}
        </div>
      </div>
      <p className="small muted">{t("manifest.hint")}</p>
      <ErrorBox error={error} />
      {!any ? <p className="muted">{t("manifest.none")}</p> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("manifest.version")}</th><th>{t("manifest.type")}</th><th>{t("manifest.persons")}</th><th>{t("manifest.issuedAt")}</th>
            <th>{t("common.status")}</th><th>{t("manifest.deliveries")}</th><th /></tr></thead>
          <tbody>{state.data.manifests.map((m) => (
            <tr key={m.uid}>
              <td className="mono">v{m.version}{m.border_point && <div className="small muted">{m.border_point}</div>}</td>
              <td className="small">{t(`manifest.types.${m.type}`)}</td><td className="num">{m.persons}</td>
              <td className="small">{m.issued_at ? dateTime(m.issued_at) : "—"}{m.sha256 && <div className="mono small muted" title={m.sha256}>{m.sha256.slice(0, 12)}…</div>}</td>
              <td><Status value={m.status} /></td>
              <td>{m.deliveries.length === 0 ? <span className="small muted">{t("manifest.noRoute")}</span>
                : <div className="stack tight">{m.deliveries.map((d) => (
                    <span key={d.uid} className="small">{d.authority} · <Status value={d.status} />{d.ack_ref && <span className="mono muted"> {d.ack_ref}</span>}</span>))}</div>}</td>
              <td><a className="btn text small" href={`/api/carrier/manifests/${m.uid}/export`} download><Icon name="download" size={18} />CSV</a></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

export function CarrierTrips() {
  const { t, dateTime, money } = useI18n();
  const toast = useToast();
  const line = useLine();
  const state = useLoad(() => api.get<{ trips: CarrierTrip[] }>("/api/carrier/trips"));
  const [creating, setCreating] = useState(() => new URLSearchParams(location.search).has("new"));
  const [manifest, setManifest] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const act = async (fn: () => Promise<void>) => { setError(null); try { await fn(); state.reload(); } catch (e) { setError(e); } };
  return (
    <div className="stack">
      <PageHead title={t("carrier.trips")}><button className="btn" onClick={() => setCreating(true)}><Icon name="add" />{t("carrier.newTrip")}</button></PageHead>
      <ErrorBox error={error} />
      <Loaded state={state}>{({ trips }) => trips.length === 0 ? <div className="card"><Empty icon="directions_bus" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("booking.tripNo")}</th><th>{t("booking.departs")}</th><th>{t("carrier.route")}</th><th>{t("carrier.plate")}</th><th>{t("carrier.driver")}</th><th>{t("carrier.sold")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{trips.map((x) => (
            <tr key={x.uid}>
              <td className="mono small">{x.trip_no}</td><td>{dateTime(x.departure_at)}</td><td className="small">{line(x)}</td>
              <td className="mono">{x.plate_no}</td><td>{x.driver_name ?? <span className="muted">{t("carrier.noDriver")}</span>}</td>
              <td className="num">{x.sold}/{x.seats_total}</td><td><Status value={x.status} /></td>
              <td><div className="row nowrap" style={{ gap: 4 }}>
                <button className="btn text small" onClick={() => setManifest(x.uid)}><Icon name="group" size={18} />{t("carrier.manifest")}</button>
                {x.status === "DRAFT" && <button className="btn tonal small" onClick={() => act(async () => { await api.post(`/api/carrier/trips/${x.uid}/publish`); })}>{t("carrier.publish")}</button>}
                {["DEPARTED", "BOARDING", "PUBLISHED"].includes(x.status) && new Date(x.arrival_at ?? x.departure_at) < new Date() && (
                  <button className="btn tonal small" onClick={() => act(async () => {
                    const r = await api.post<{ released: number }>(`/api/carrier/trips/${x.uid}/complete`);
                    toast(t("carrier.completed", { amount: money(r.released) }));
                  })}>{t("carrier.complete")}</button>
                )}
              </div></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {creating && <NewTrip onClose={() => setCreating(false)} onDone={() => { setCreating(false); toast(t("common.saved")); state.reload(); }} />}
      {manifest && <ManifestModal uid={manifest} onClose={() => setManifest(null)} />}
    </div>
  );
}

// ------------------------------------------------------------------ vehicles
export function CarrierVehicles() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ vehicles: Vehicle[] }>("/api/carrier/vehicles"));
  const layouts = useLoad(() => api.get<{ layouts: LayoutRow[] }>("/api/carrier/seat-layouts"));
  const [open, setOpen] = useState(false);
  const [relayout, setRelayout] = useState<Vehicle | null>(null);
  const [newLayout, setNewLayout] = useState("");
  const blank = { plate_no: "", chassis_no: "", vehicle_type: "COACH", make: "", model: "", manufacture_year: "", seat_layout_uid: "", insurance_no: "", insurer: "", insurance_issue: "", insurance_expiry: "" };
  const [f, setF] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/carrier/vehicles", { ...f, make: f.make || null, model: f.model || null,
        manufacture_year: f.manufacture_year ? Number(f.manufacture_year) : null, seat_layout_uid: f.seat_layout_uid || null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const changeLayout = async () => {
    if (!relayout) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/carrier/vehicles/${relayout.uid}/layout`, { layout_uid: newLayout });
      setRelayout(null); toast(t("layout.changed")); state.reload(); layouts.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const layoutOptions = (layouts.data?.layouts ?? []).map((l) => <option key={l.uid} value={l.uid}>{l.name} · {t("layout.total", { n: l.total_seats })}</option>);
  return (
    <div className="stack">
      <PageHead title={t("carrier.vehicles")}><button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("carrier.newVehicle")}</button></PageHead>
      <Loaded state={state}>{({ vehicles }) => vehicles.length === 0 ? <div className="card"><Empty icon="directions_car" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("carrier.plate")}</th><th>{t("carrier.vtype")}</th><th>{t("carrier.make")}</th><th>{t("carrier.year")}</th><th>{t("carrier.seatsCount")}</th><th>{t("layout.layout")}</th><th>{t("carrier.nextExpiry")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{vehicles.map((v) => (
            <tr key={v.uid}>
              <td className="mono">{v.plate_no}</td><td>{t(`carrier.vtypes.${v.vehicle_type}`)}</td><td>{[v.make, v.model].filter(Boolean).join(" ")}</td>
              <td>{v.manufacture_year}</td><td className="num">{v.passenger_seats}</td>
              <td>{v.seat_layout_name ?? <span className="chip" style={{ color: "var(--error)" }}>{t("layout.missing")}</span>}</td>
              <td className="mono small">{v.next_expiry}</td><td><Status value={v.status} /></td>
              <td><button className="btn tonal small" onClick={() => { setRelayout(v); setNewLayout(v.seat_layout_uid ?? ""); setError(null); }}>{t("layout.change")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("carrier.newVehicle")} onClose={() => setOpen(false)} wide
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={submit}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-3">
              <Field label={t("carrier.plate")}><input className="input ltr" value={f.plate_no} onChange={set("plate_no")} /></Field>
              <Field label={t("carrier.chassis")}><input className="input ltr" value={f.chassis_no} onChange={set("chassis_no")} /></Field>
              <Field label={t("carrier.vtype")}>
                <select className="input" value={f.vehicle_type} onChange={set("vehicle_type")}>
                  {["COACH", "MINIBUS", "CITY_BUS", "VAN"].map((k) => <option key={k} value={k}>{t(`carrier.vtypes.${k}`)}</option>)}
                </select>
              </Field>
              <Field label={t("carrier.make")}><input className="input" value={f.make} onChange={set("make")} /></Field>
              <Field label={t("carrier.model")}><input className="input" value={f.model} onChange={set("model")} /></Field>
              <Field label={t("carrier.year")}><input className="input ltr" type="number" value={f.manufacture_year} onChange={set("manufacture_year")} /></Field>
              <Field label={t("layout.layout")} hint={t("layout.vehicleHint")}>
                <select className="input" value={f.seat_layout_uid} onChange={set("seat_layout_uid")} required>
                  <option value="" disabled>{t("layout.choose")}</option>{layoutOptions}
                </select>
              </Field>
              <Field label={t("carrier.insuranceNo")}><input className="input ltr" value={f.insurance_no} onChange={set("insurance_no")} /></Field>
              <Field label={t("carrier.insurer")}><input className="input" value={f.insurer} onChange={set("insurer")} /></Field>
              <Field label={t("carrier.insuranceIssue")}><input className="input ltr" type="date" value={f.insurance_issue} onChange={set("insurance_issue")} /></Field>
              <Field label={t("carrier.insuranceExpiry")}><input className="input ltr" type="date" value={f.insurance_expiry} onChange={set("insurance_expiry")} /></Field>
            </div>
            {f.seat_layout_uid && <LayoutPreview uid={f.seat_layout_uid} />}
          </div>
        </Modal>
      )}
      {relayout && (
        <Modal title={`${t("layout.change")} · ${relayout.plate_no}`} onClose={() => setRelayout(null)} wide
               actions={<><button className="btn text" onClick={() => setRelayout(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !newLayout || newLayout === relayout.seat_layout_uid} onClick={changeLayout}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("layout.layout")}>
              <select className="input" value={newLayout} onChange={(e) => setNewLayout(e.target.value)}>
                <option value="" disabled>{t("layout.choose")}</option>{layoutOptions}
              </select>
            </Field>
            <div className="alert info"><Icon name="event_seat" /><span>{t("layout.changeNote")}</span></div>
            {newLayout && <LayoutPreview uid={newLayout} />}
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ routes
export function CarrierRoutes() {
  const { t, station, money, duration } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ routes: Route[] }>("/api/carrier/routes"));
  const stations = useLoad(() => api.get<{ stations: Station[] }>("/api/carrier/stations"));
  const [open, setOpen] = useState(false);
  type StopRow = { station_uid: string; arr: string; dep: string; fare: string };
  const blankStops: StopRow[] = [{ station_uid: "", arr: "0", dep: "0", fare: "0" }, { station_uid: "", arr: "", dep: "", fare: "" }];
  const [code, setCode] = useState("");
  const [stops, setStops] = useState<StopRow[]>(blankStops);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const setStop = (i: number, k: keyof StopRow, v: string) => setStops(stops.map((s, j) => (j === i ? { ...s, [k]: v, ...(k === "arr" && (j === stops.length - 1) ? { dep: v } : {}) } : s)));
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/carrier/routes", { code: code.toUpperCase(), stops: stops.map((s) => ({
        station_uid: s.station_uid, arr_offset_min: Number(s.arr), dep_offset_min: Number(s.dep || s.arr), fare_from_origin: Number(s.fare) * 100 })) });
      setOpen(false); setCode(""); setStops(blankStops); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("carrier.routes")}><button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("carrier.newRoute")}</button></PageHead>
      <Loaded state={state}>{({ routes }) => routes.length === 0 ? <div className="card"><Empty icon="route" title={t("common.noData")} /></div> : (
        <div className="grid cols-2">{routes.map((r) => (
          <div key={r.uid} className="card stack">
            <div className="row between"><div className="row"><span className="chip outline mono">{r.code}</span><span className="chip">{t(`service.${r.service_type}`)}</span></div>
              <span className="small muted"><Icon name="schedule" size={16} /> {duration(r.std_duration_min)}</span></div>
            <div className="stops">{r.stops.map((s, i) => (
              <div key={s.seq} className={`stop${i === 0 ? " done" : ""}`}>
                <span className="dot" /><span>{station(s.station_code, s.station_name)}<span className="small muted"> · +{s.arr_offset_min}′</span></span>
                <span className="mono small">{money(s.fare_from_origin)}</span>
              </div>
            ))}</div>
          </div>
        ))}</div>
      )}</Loaded>
      {open && (
        <Modal title={t("carrier.newRoute")} onClose={() => setOpen(false)} wide
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy || !code} onClick={submit}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("carrier.routeCode")}><input className="input ltr mono" value={code} placeholder="DAM-ALP" onChange={(e) => setCode(e.target.value.toUpperCase())} /></Field>
            <strong>{t("carrier.stopsLabel")}</strong>
            {stops.map((s, i) => (
              <div key={i} className="grid" style={{ gridTemplateColumns: "2fr 1fr 1fr 1.2fr auto", alignItems: "end" }}>
                <Field label={`${i + 1}. ${t("common.station")}`}>
                  <select className="input" value={s.station_uid} onChange={(e) => setStop(i, "station_uid", e.target.value)}>
                    <option value="" disabled>—</option>
                    {stations.data?.stations.map((st) => <option key={st.uid} value={st.uid}>{station(st.code, st.name)}</option>)}
                  </select>
                </Field>
                <Field label={t("carrier.arrOffset")}><input className="input ltr" type="number" min={0} disabled={i === 0} value={s.arr} onChange={(e) => setStop(i, "arr", e.target.value)} /></Field>
                <Field label={t("carrier.depOffset")}><input className="input ltr" type="number" min={0} disabled={i === 0 || i === stops.length - 1} value={s.dep} onChange={(e) => setStop(i, "dep", e.target.value)} /></Field>
                <Field label={t("carrier.fareFromOrigin")}><input className="input ltr" type="number" min={0} step={500} disabled={i === 0} value={s.fare} onChange={(e) => setStop(i, "fare", e.target.value)} /></Field>
                <button className="icon-btn" disabled={i === 0 || stops.length <= 2} onClick={() => setStops(stops.filter((_, j) => j !== i))}><Icon name="close" /></button>
              </div>
            ))}
            <button className="btn outlined" style={{ alignSelf: "flex-start" }} onClick={() => setStops([...stops.slice(0, -1), { station_uid: "", arr: "", dep: "", fare: "" }, stops[stops.length - 1]])}>
              <Icon name="add" />{t("carrier.addStop")}
            </button>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ crew
export function CarrierCrew() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ crew: Crew[] }>("/api/carrier/crew"));
  const [open, setOpen] = useState(false);
  const blank = { full_name: "", email: "", mobile: "", password: "", license_class: "D" };
  const [f, setF] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/carrier/crew", { ...f, mobile: f.mobile || null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("carrier.crew")}><button className="btn" onClick={() => setOpen(true)}><Icon name="person_add" />{t("carrier.newDriver")}</button></PageHead>
      <Loaded state={state}>{({ crew }) => crew.length === 0 ? <div className="card"><Empty icon="badge" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("common.email")}</th><th>{t("carrier.licenseClass")}</th><th>{t("common.status")}</th></tr></thead>
          <tbody>{crew.map((c) => (
            <tr key={c.uid}><td>{c.full_name}</td><td className="ltr small">{c.email}</td><td>{c.license_class}</td><td><Status value={c.status} /></td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("carrier.newDriver")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={submit}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("common.name")}><input className="input" value={f.full_name} onChange={set("full_name")} /></Field>
            <div className="grid cols-2">
              <Field label={t("common.email")}><input className="input ltr" type="email" value={f.email} onChange={set("email")} /></Field>
              <Field label={`${t("common.mobile")} (${t("common.optional")})`}><input className="input ltr" value={f.mobile} onChange={set("mobile")} /></Field>
              <Field label={t("common.password")} hint={t("auth.passwordHint")}><input className="input ltr" type="password" value={f.password} onChange={set("password")} /></Field>
              <Field label={t("carrier.licenseClass")}><input className="input ltr" value={f.license_class} onChange={set("license_class")} /></Field>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
