import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Loaded, Modal, useLoad, useToast } from "../../components/ui";
import type { CarrierTrip } from "./Carrier";

interface Reason { code: string; en: string; ar: string }
interface Reasons { reasons: Reason[]; free_cancel_shift_min: number; max_shift_min: number; rebook_window_hours: number }
interface Change {
  uid: string; kind: string; reason_code: string | null; note: string | null; old_departure: string | null; new_departure: string | null;
  shift_min: number | null; details: Record<string, unknown>; affected: number; notified: number; unreachable: number; created_at: string;
  by_name: string | null; to_call: { id: number; booking_ref: string; mobile: string | null; contacted_at: string | null; outcome: string | null }[];
}
interface Target { uid: string; trip_no: string; trip_code: string | null; departure_at: string; plate_no: string | null; seats_left: number }
interface Vehicle { uid: string; plate_no: string; passenger_seats: number; status: string }
interface Crew { uid: string; full_name: string; status: string }
interface Told { affected: number; notified: number; unreachable: number }

type Tab = "vehicle" | "time" | "move" | "log";

/** Changes to one trip (N42, 1148): another vehicle, a moved departure, passengers moved to another trip, and the
 *  record of what changed with the passengers the carrier still has to call. The trip keeps its number throughout. */
export function TripChanges({ trip, onClose, onDone }: { trip: CarrierTrip; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const live = ["DRAFT", "PUBLISHED", "BOARDING"].includes(trip.status);
  const tabs: Tab[] = [...(live || trip.status === "DEPARTED" ? ["vehicle"] as Tab[] : []), ...(live ? ["time", "move"] as Tab[] : []), "log"];
  const [tab, setTab] = useState<Tab>(tabs[0]);
  const reasons = useLoad(() => api.get<Reasons>("/api/carrier/trip-changes/reasons"));
  return (
    <Modal wide title={t("tripChange.title", { trip: trip.trip_code ?? trip.trip_no })} onClose={onClose}
           actions={<button className="btn text" onClick={onClose}>{t("common.close")}</button>}>
      <div className="stack">
        <div className="small muted">{t("tripChange.keepsNumber")}</div>
        <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
          {tabs.map((v) => <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`tripChange.tab.${v}`)}</button>)}
        </div>
        <Loaded state={reasons}>{(r) => <>
          {tab === "vehicle" && <ChangeVehicle trip={trip} reasons={r} onDone={onDone} />}
          {tab === "time" && <Reschedule trip={trip} reasons={r} onDone={onDone} />}
          {tab === "move" && <MovePassengers trip={trip} reasons={r} onDone={onDone} />}
          {tab === "log" && <ChangeLog trip={trip} reasons={r} />}
        </>}</Loaded>
      </div>
    </Modal>
  );
}

function useReasonLabel(reasons: Reasons) {
  const { locale } = useI18n();
  return (code: string | null) => {
    const r = reasons.reasons.find((x) => x.code === code);
    return r ? (locale === "ar" ? r.ar : r.en) : code ?? "—";
  };
}

function Why({ reasons, value, onChange }: { reasons: Reasons; value: { reason: string; note: string }; onChange: (v: { reason: string; note: string }) => void }) {
  const { t } = useI18n();
  const label = useReasonLabel(reasons);
  return (
    <div className="grid cols-2">
      <Field label={t("tripChange.reason")}>
        <select className="input" value={value.reason} onChange={(e) => onChange({ ...value, reason: e.target.value })}>
          <option value="" disabled>—</option>
          {reasons.reasons.map((r) => <option key={r.code} value={r.code}>{label(r.code)}</option>)}
        </select>
      </Field>
      <Field label={value.reason === "OTHER" ? t("tripChange.noteRequired") : `${t("tripChange.note")} (${t("common.optional")})`}>
        <input className="input" maxLength={500} value={value.note} onChange={(e) => onChange({ ...value, note: e.target.value })} />
      </Field>
    </div>
  );
}

function useTold() {
  const { t } = useI18n();
  const toast = useToast();
  return (r: Told) => toast(t("tripChange.told", { affected: r.affected, notified: r.notified, unreachable: r.unreachable }));
}

function ready(why: { reason: string; note: string }) {
  return !!why.reason && (why.reason !== "OTHER" || why.note.trim().length >= 3);
}

function ChangeVehicle({ trip, reasons, onDone }: { trip: CarrierTrip; reasons: Reasons; onDone: () => void }) {
  const { t } = useI18n();
  const told = useTold();
  const vehicles = useLoad(() => api.get<{ vehicles: Vehicle[] }>("/api/carrier/vehicles"));
  const crew = useLoad(() => api.get<{ crew: Crew[] }>("/api/carrier/crew"));
  const enRoute = trip.status === "DEPARTED";
  const [why, setWhy] = useState({ reason: "", note: "" });
  const [form, setForm] = useState({ vehicle_uid: "", driver_uid: "", at_stop_seq: "1" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<Told & { seats_moved: number }>(`/api/carrier/trips/${trip.uid}/vehicle`, {
        vehicle_uid: form.vehicle_uid, driver_uid: form.driver_uid || null, at_stop_seq: enRoute ? Number(form.at_stop_seq) : null,
        reason: why.reason, note: why.note || null });
      told(r); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="small muted">{t(enRoute ? "tripChange.vehicleEnRoute" : "tripChange.vehicleHint", { plate: trip.plate_no ?? "—" })}</div>
      <div className="grid cols-2">
        <Field label={t("tripChange.newVehicle")}>
          <select className="input" value={form.vehicle_uid} onChange={(e) => setForm({ ...form, vehicle_uid: e.target.value })}>
            <option value="" disabled>—</option>
            {vehicles.data?.vehicles.filter((v) => v.status === "ACTIVE" && v.plate_no !== trip.plate_no).map((v) =>
              <option key={v.uid} value={v.uid}>{v.plate_no} · {v.passenger_seats} {t("common.seats")}</option>)}
          </select>
        </Field>
        <Field label={`${t("tripChange.newDriver")} (${t("common.optional")})`}>
          <select className="input" value={form.driver_uid} onChange={(e) => setForm({ ...form, driver_uid: e.target.value })}>
            <option value="">{t("tripChange.sameDriver")}</option>
            {crew.data?.crew.filter((c) => c.status === "ACTIVE").map((c) => <option key={c.uid} value={c.uid}>{c.full_name}</option>)}
          </select>
        </Field>
      </div>
      {enRoute && (
        <Field label={t("tripChange.atStop")} hint={t("tripChange.atStopHint")}>
          <input className="input" type="number" min={0} max={60} value={form.at_stop_seq} onChange={(e) => setForm({ ...form, at_stop_seq: e.target.value })} />
        </Field>
      )}
      <Why reasons={reasons} value={why} onChange={setWhy} />
      <div className="row"><button className="btn" disabled={busy || !form.vehicle_uid || !ready(why)} onClick={submit}>{t("tripChange.applyVehicle")}</button></div>
    </div>
  );
}

function toLocalInput(iso: string) {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function Reschedule({ trip, reasons, onDone }: { trip: CarrierTrip; reasons: Reasons; onDone: () => void }) {
  const { t, dateTime } = useI18n();
  const told = useTold();
  const [when, setWhen] = useState(toLocalInput(trip.departure_at));
  const [why, setWhy] = useState({ reason: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const shift = Math.round((new Date(when).getTime() - new Date(trip.departure_at).getTime()) / 60000);
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<Told>(`/api/carrier/trips/${trip.uid}/reschedule`, { departure_at: new Date(when).toISOString(), reason: why.reason, note: why.note || null });
      told(r); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="small muted">{t("tripChange.timeHint", { at: dateTime(trip.departure_at), min: reasons.free_cancel_shift_min })}</div>
      <Field label={t("tripChange.newDeparture")} hint={shift ? t("tripChange.shift", { min: shift > 0 ? `+${shift}` : String(shift) }) : undefined}>
        <input className="input" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
      </Field>
      {Math.abs(shift) >= reasons.free_cancel_shift_min && <div className="notice">{t("tripChange.freeCancel")}</div>}
      <Why reasons={reasons} value={why} onChange={setWhy} />
      <div className="row"><button className="btn" disabled={busy || !shift || !ready(why)} onClick={submit}>{t("tripChange.applyTime")}</button></div>
    </div>
  );
}

function MovePassengers({ trip, reasons, onDone }: { trip: CarrierTrip; reasons: Reasons; onDone: () => void }) {
  const { t, dateTime } = useI18n();
  const told = useTold();
  const opts = useLoad(() => api.get<{ trips: Target[]; bookings: { booking_ref: string; tickets: number; reachable: boolean }[] }>(`/api/carrier/trips/${trip.uid}/rebook-options`));
  const [target, setTarget] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [why, setWhy] = useState({ reason: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<Told & { bookings_moved: number }>(`/api/carrier/trips/${trip.uid}/rebook`,
        { to_trip_uid: target, booking_refs: picked.length ? picked : null, reason: why.reason, note: why.note || null });
      told(r); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Loaded state={opts}>{({ trips, bookings }) => (
      <div className="stack">
        <ErrorBox error={error} />
        <div className="small muted">{t("tripChange.moveHint", { hours: reasons.rebook_window_hours })}</div>
        {bookings.length === 0 ? <Empty icon="group" title={t("tripChange.noBookings")} /> : <>
          <Field label={t("tripChange.toTrip")}>
            <select className="input" value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="" disabled>—</option>
              {trips.map((x) => <option key={x.uid} value={x.uid} disabled={x.seats_left <= 0}>
                {x.trip_code ?? x.trip_no} · {dateTime(x.departure_at)} · {x.plate_no ?? "—"} · {t("tripChange.seatsLeft", { n: x.seats_left })}</option>)}
            </select>
          </Field>
          {trips.length === 0 && <div className="small muted">{t("tripChange.noTargets")}</div>}
          <fieldset className="stack tight">
            <legend className="small">{t("tripChange.whichBookings")}</legend>
            {bookings.map((b) => (
              <label key={b.booking_ref} className="row small">
                <input type="checkbox" checked={picked.includes(b.booking_ref)}
                       onChange={(e) => setPicked(e.target.checked ? [...picked, b.booking_ref] : picked.filter((x) => x !== b.booking_ref))} />
                <span className="mono">{b.booking_ref}</span> · {t("tripChange.tickets", { n: b.tickets })}
                {!b.reachable && <span className="muted"> · {t("tripChange.mustCall")}</span>}
              </label>
            ))}
            <div className="small muted">{t("tripChange.allIfNone")}</div>
          </fieldset>
          <Why reasons={reasons} value={why} onChange={setWhy} />
          <div className="small muted">{t("tripChange.thenCancel")}</div>
          <div className="row"><button className="btn" disabled={busy || !target || !ready(why)} onClick={submit}>{t("tripChange.applyMove")}</button></div>
        </>}
      </div>
    )}</Loaded>
  );
}

function ChangeLog({ trip, reasons }: { trip: CarrierTrip; reasons: Reasons }) {
  const { t, dateTime } = useI18n();
  const label = useReasonLabel(reasons);
  const log = useLoad(() => api.get<{ changes: Change[] }>(`/api/carrier/trips/${trip.uid}/changes`));
  const [error, setError] = useState<unknown>(null);
  const call = async (id: number, outcome: string) => {
    setError(null);
    try { await api.post(`/api/carrier/trips/${trip.uid}/changes/calls/${id}`, { outcome }); log.reload(); } catch (e) { setError(e); }
  };
  return (
    <Loaded state={log}>{({ changes }) => changes.length === 0 ? <Empty icon="history" title={t("tripChange.noChanges")} /> : (
      <div className="stack">
        <ErrorBox error={error} />
        {changes.map((c) => (
          <div key={c.uid} className="card stack tight">
            <div className="row" style={{ justifyContent: "space-between" }}>
              <strong>{t(`tripChange.kind.${c.kind}`)}</strong><span className="small muted">{dateTime(c.created_at)}{c.by_name ? ` · ${c.by_name}` : ""}</span>
            </div>
            <div className="small">{label(c.reason_code)}{c.note ? ` — ${c.note}` : ""}</div>
            {c.kind === "RESCHEDULE" && c.old_departure && c.new_departure &&
              <div className="small">{dateTime(c.old_departure)} → {dateTime(c.new_departure)}</div>}
            {c.kind === "VEHICLE_SWAP" && <div className="small mono">{String(c.details.plate ?? "")}</div>}
            {c.kind === "REBOOK" && <div className="small mono">{String(c.details.to_trip_code ?? c.details.to_trip_no ?? "")}</div>}
            <div className="small muted">{t("tripChange.told", { affected: c.affected, notified: c.notified, unreachable: c.unreachable })}</div>
            {c.to_call.length > 0 && (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("booking.ref")}</th><th>{t("tripChange.mobile")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                <tbody>{c.to_call.map((x) => (
                  <tr key={x.id}>
                    <td className="mono">{x.booking_ref}</td><td className="mono">{x.mobile ?? "—"}</td>
                    <td>{x.outcome ? t(`tripChange.outcome.${x.outcome}`) : <span className="muted">{t("tripChange.toCall")}</span>}</td>
                    <td><div className="row nowrap" style={{ gap: 4 }}>
                      <button className="btn text small" onClick={() => call(x.id, "INFORMED")}>{t("tripChange.informed")}</button>
                      <button className="btn text small" onClick={() => call(x.id, "NO_ANSWER")}>{t("tripChange.noAnswer")}</button>
                    </div></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
        ))}
      </div>
    )}</Loaded>
  );
}

/** The platform's reasons and limits for trip changes (N42, 1148), on the booking rules page. */
export function TripChangePolicy() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Reasons>("/api/admin/trip-changes/policy"));
  const [p, setP] = useState<Reasons | null>(null);
  const [error, setError] = useState<unknown>(null);
  const cur = p ?? state.data;
  const save = async () => {
    if (!cur) return;
    setError(null);
    try { await api.put("/api/admin/trip-changes/policy", cur); toast(t("tripChange.policy.saved")); setP(null); state.reload(); } catch (e) { setError(e); }
  };
  const setReason = (i: number, k: keyof Reason, v: string) => cur && setP({ ...cur, reasons: cur.reasons.map((r, j) => j === i ? { ...r, [k]: k === "code" ? v.toUpperCase() : v } : r) });
  return (
    <Loaded state={state}>{() => cur && (
      <section className="card stack" aria-labelledby="trip-change-policy">
        <div><h3 id="trip-change-policy">{t("tripChange.policy.title")}</h3><p className="small muted">{t("tripChange.policy.sub")}</p></div>
        <div className="grid cols-3">
          <Field label={t("tripChange.policy.freeCancel")}><input className="input ltr" type="number" min={0} max={1440} value={cur.free_cancel_shift_min} onChange={(e) => setP({ ...cur, free_cancel_shift_min: Number(e.target.value) })} /></Field>
          <Field label={t("tripChange.policy.maxShift")}><input className="input ltr" type="number" min={15} max={10080} value={cur.max_shift_min} onChange={(e) => setP({ ...cur, max_shift_min: Number(e.target.value) })} /></Field>
          <Field label={t("tripChange.policy.window")}><input className="input ltr" type="number" min={1} max={720} value={cur.rebook_window_hours} onChange={(e) => setP({ ...cur, rebook_window_hours: Number(e.target.value) })} /></Field>
        </div>
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("tripChange.policy.code")}</th><th>{t("tripChange.policy.en")}</th><th>{t("tripChange.policy.ar")}</th></tr></thead>
          <tbody>{cur.reasons.map((r, i) => (
            <tr key={i}>
              <td><input className="input ltr mono" aria-label={t("tripChange.policy.code")} value={r.code} disabled={r.code === "OTHER"} onChange={(e) => setReason(i, "code", e.target.value)} /></td>
              <td><input className="input" aria-label={t("tripChange.policy.en")} value={r.en} onChange={(e) => setReason(i, "en", e.target.value)} /></td>
              <td><input className="input" dir="rtl" aria-label={t("tripChange.policy.ar")} value={r.ar} onChange={(e) => setReason(i, "ar", e.target.value)} /></td>
            </tr>
          ))}</tbody>
        </table></div>
        <p className="small muted">{t("tripChange.policy.otherKept")}</p>
        <ErrorBox error={error} />
        <div className="row">
          <button className="btn tonal" onClick={() => setP({ ...cur, reasons: [...cur.reasons, { code: "", en: "", ar: "" }] })}>{t("tripChange.policy.addReason")}</button>
          <button className="btn" onClick={() => void save()}>{t("common.save")}</button>
        </div>
      </section>
    )}</Loaded>
  );
}
