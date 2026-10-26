import { useEffect, useState } from "react";
import { api } from "../../api";
import { toMinor, useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { CarrierNumberRanges } from "./NumberRanges";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Regular trips (owner's decision, October 2026; migration 1117). The carrier defines a trip that repeats at the same
// time under one number: every day, on days of the week, or on days of the month, from a date to a date or with no end
// until it is stopped, without its dates off. Each new regular trip and each change passes the approval stages the
// platform sets (the platform first; government authorities later, by settings); a stop and a trip made by hand pass
// them only when the settings say so. Once approved, the regular trip makes its trips by itself, ahead of time.

type Recurrence = "DAILY" | "WEEKLY" | "MONTHLY";
type Stage = { by: "PLATFORM" | "AUTHORITY"; authority?: string };
export interface PatternLike { recurrence: Recurrence | string; days_of_week?: number[]; days_of_month?: number[] }
interface Rules { approval_stages: Stage[]; approval_kinds: string[]; min_notice_days: number; horizon_days: number; recurrences: Recurrence[];
                 min_turnaround_min: number }
interface Schedule extends PatternLike {
  uid: string; status: "ACTIVE" | "PAUSED" | "RETIRED"; departure_time: string; from_date: string; until_date: string | null;
  skip_dates: string[]; base_price: number; currency: string; trip_type: string; auto_publish: boolean; route_code: string;
  origin: string; destination: string; origin_code: string; dest_code: string; plate_no: string | null; trip_code: string | null;
  // the legs of a vehicle's day (1119): the number this one continues and the one that continues it
  service_no: number | null; follows_code: string | null; next_code: string | null;
  next_departure: string | null; upcoming: number; last_run: { created: number; skipped_count: number; skipped: { date: string; reason: string }[] } | null;
}
export interface ScheduleRequest {
  uid: string; kind: "NEW" | "CHANGE" | "STOP" | "TRIP"; status: "PENDING" | "APPROVED" | "REJECTED" | "WITHDRAWN";
  proposal: Record<string, unknown>; effective_from: string | null; proposed_number: number | null; assigned_number: number | null;
  note: string | null; approval_stages: Stage[]; step: number; requested_at: string; decided_at: string | null; decision_note: string | null;
  result: { trip_code?: string; kept?: { trip_code: string; departure_at: string; bookings: number }[]; cancelled?: number } | null;
  template_uid: string | null; trip_no: string | null; trip_code: string | null; schedule_code?: string | null; schedule_time?: string | null; route?: { code: string; origin: string; destination: string; origin_code: string; dest_code: string };
  plate_no?: string | null; requested_by_name: string;
}
interface Overview {
  schedules: Schedule[]; requests: ScheduleRequest[]; rules: Rules;
  routes: { uid: string; code: string; origin: string; destination: string; origin_code: string; dest_code: string }[];
  vehicles: { uid: string; plate_no: string; passenger_seats: number }[];
}

const DAYS = [1, 2, 3, 4, 5, 6, 7];

/** "Daily", "Mon, Wed, Fri", "On the 1, 15 of each month", in the reader's language. */
export function usePattern() {
  const { t, intl } = useI18n();
  const sep = t("common.listSep");
  const weekday = (d: number) => new Intl.DateTimeFormat(intl, { weekday: "short", timeZone: "UTC" }).format(new Date(Date.UTC(2024, 0, d)));
  return {
    weekday,
    text: (p: PatternLike) => p.recurrence === "DAILY" || (p.recurrence === "WEEKLY" && (p.days_of_week ?? []).length === 7) ? t("sched.everyDay")
      : p.recurrence === "WEEKLY" ? (p.days_of_week ?? []).map(weekday).join(sep)
      : t("sched.monthDays", { days: (p.days_of_month ?? []).join(sep) }),
  };
}

/** Who a request waits for, or who approves: the platform or an authority by its code. */
export function stageName(t: (k: string, v?: Record<string, string | number>) => string, s?: Stage | null) {
  if (!s) return "";
  return s.by === "PLATFORM" ? t("sched.stage.PLATFORM") : t("sched.stage.AUTHORITY", { name: s.authority ?? "" });
}

function DaysPicker({ recurrence, dow, dom, onDow, onDom }: {
  recurrence: Recurrence; dow: number[]; dom: number[]; onDow: (v: number[]) => void; onDom: (v: number[]) => void;
}) {
  const { weekday } = usePattern();
  const toggle = (list: number[], d: number) => (list.includes(d) ? list.filter((x) => x !== d) : [...list, d].sort((a, b) => a - b));
  if (recurrence === "WEEKLY") return (
    <div className="row" style={{ gap: 6, flexWrap: "wrap" }} role="group">
      {DAYS.map((d) => <label key={d} className={`chip ${dow.includes(d) ? "green" : "outline"}`} style={{ cursor: "pointer" }}>
        <input type="checkbox" className="sr-only" checked={dow.includes(d)} onChange={() => onDow(toggle(dow, d))} />{weekday(d)}</label>)}
    </div>
  );
  if (recurrence === "MONTHLY") return (
    <div className="row" style={{ gap: 4, flexWrap: "wrap", maxWidth: 420 }} role="group">
      {Array.from({ length: 31 }, (_, i) => i + 1).map((d) => (
        <label key={d} className={`chip ${dom.includes(d) ? "green" : "outline"}`} style={{ cursor: "pointer", minWidth: 36, justifyContent: "center" }}>
          <input type="checkbox" className="sr-only" checked={dom.includes(d)} onChange={() => onDom(toggle(dom, d))} />{d}</label>))}
    </div>
  );
  return null;
}

function SkipDates({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const { t, date } = useI18n();
  const [d, setD] = useState("");
  return (
    <div className="stack tight">
      <div className="row" style={{ gap: 8 }}>
        <input className="input" type="date" value={d} onChange={(e) => setD(e.target.value)} aria-label={t("sched.skip")} />
        <button type="button" className="btn tonal small" disabled={!d} onClick={() => { if (!value.includes(d)) onChange([...value, d].sort()); setD(""); }}>
          <Icon name="add" />{t("sched.addSkip")}</button>
      </div>
      <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
        {value.length === 0 ? <span className="small muted">{t("sched.noSkip")}</span> : value.map((x) => (
          <button type="button" key={x} className="chip outline" onClick={() => onChange(value.filter((y) => y !== x))} aria-label={`${date(`${x}T12:00:00Z`)} ×`}>
            {date(`${x}T12:00:00Z`)} ×</button>))}
      </div>
    </div>
  );
}

function NewSchedule({ data, onClose, onDone }: { data: Overview; onClose: () => void; onDone: (msg: string) => void }) {
  const { t, date, station } = useI18n();
  const today = new Date().toISOString().slice(0, 10);
  const [f, setF] = useState({
    route_uid: data.routes[0]?.uid ?? "", vehicle_uid: "", departure_time: "08:00", recurrence: data.rules.recurrences[0] ?? "DAILY" as Recurrence,
    days_of_week: [] as number[], days_of_month: [] as number[], skip_dates: [] as string[], from_date: today, no_end: true, until_date: "",
    price: "", trip_type: "SCHEDULED", direction: "OUTBOUND", proposed_number: "", auto_publish: true, note: "", follows_uid: "",
  });
  // a leg the vehicle runs before this one: a regular trip of the carrier whose number ends in 1 to 7 and that nothing continues yet
  const legs = data.schedules.filter((s) => s.status !== "RETIRED" && s.service_no !== null && s.service_no % 10 >= 1 && s.service_no % 10 <= 7 && !s.next_code);
  const after = legs.find((s) => s.uid === f.follows_uid) ?? null;
  const cityOf = (code: string) => code.split("-")[1] ?? code;
  const routes = after ? data.routes.filter((r) => cityOf(r.origin_code) === cityOf(after.dest_code)) : data.routes;
  const [preview, setPreview] = useState<{ dates: string[]; in_30_days: number } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const needs = data.rules.approval_kinds.includes("NEW");
  // the number from the carrier's range (1165, N7): its free numbers that fit the type and direction, the default first
  const [numbers, setNumbers] = useState<{ range: { from: number; to: number }; suggested: number | null; free: number[] } | null>(null);
  useEffect(() => {
    if (after || !f.route_uid) { setNumbers(null); return; }
    let live = true;
    api.get<{ range: { from: number; to: number }; suggested: number | null; free: number[] }>("/api/carrier/numbers", {
      trip_type: f.trip_type, direction: f.direction, from_date: f.from_date, until_date: f.no_end ? undefined : f.until_date || undefined, route_uid: f.route_uid,
    }).then((n) => { if (live) { setNumbers(n); setF((x) => ({ ...x, proposed_number: n.suggested != null ? String(n.suggested) : "" })); } })
      .catch(() => live && setNumbers(null));
    return () => { live = false; };
  }, [after, f.route_uid, f.trip_type, f.direction, f.from_date, f.until_date, f.no_end]);
  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => { setF({ ...f, [k]: v }); setPreview(null); };
  const pattern = () => ({ departure_time: f.departure_time, recurrence: f.recurrence, days_of_week: f.days_of_week, days_of_month: f.days_of_month,
                           skip_dates: f.skip_dates, from_date: f.from_date, until_date: f.no_end ? null : f.until_date || null });
  const show = async () => { setError(null); try { setPreview(await api.post("/api/carrier/schedules/preview", pattern())); } catch (e) { setError(e); } };
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ status: string }>("/api/carrier/schedules", {
        ...pattern(), route_uid: f.route_uid, vehicle_uid: f.vehicle_uid || null, base_price: toMinor(f.price), trip_type: f.trip_type,
        direction: f.direction, auto_publish: f.auto_publish, note: f.note || null,
        ...(after ? { follows_uid: after.uid } : { proposed_number: f.proposed_number ? Number(f.proposed_number) : null }) });
      onDone(r.status === "PENDING" ? t("sched.asked") : t("sched.applied"));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("sched.new")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !f.route_uid || (!after && !f.proposed_number)} onClick={submit}><Icon name="send" />{needs ? t("sched.ask") : t("sched.askNow")}</button></>}>
      <div className="stack">
        <Field label={t("sched.follows")} hint={after ? t("sched.followsHint", { code: after.trip_code ?? "", n: data.rules.min_turnaround_min,
                                                                                 next: (after.service_no ?? 0) + 1 }) : t("sched.followsNone")}>
          <select className="input" value={f.follows_uid} onChange={(e) => {
            const leg = legs.find((s) => s.uid === e.target.value);
            const next = leg ? data.routes.find((r) => cityOf(r.origin_code) === cityOf(leg.dest_code)) : undefined;
            setF({ ...f, follows_uid: e.target.value, route_uid: next?.uid ?? f.route_uid, vehicle_uid: f.vehicle_uid,
                   direction: leg ? (((leg.service_no ?? 0) + 1) % 2 === 1 ? "OUTBOUND" : "INBOUND") : f.direction, proposed_number: "" });
            setPreview(null);
          }}>
            <option value="">{t("sched.followsStandalone")}</option>
            {legs.map((s) => <option key={s.uid} value={s.uid}>{s.trip_code} · {s.departure_time} · {station(s.origin_code, s.origin)} → {station(s.dest_code, s.destination)}</option>)}
          </select>
        </Field>
        <div className="grid cols-2">
          <Field label={t("sched.route")}>
            <select className="input" value={f.route_uid} onChange={(e) => set("route_uid", e.target.value)}>
              {routes.map((r) => <option key={r.uid} value={r.uid}>{r.code} · {r.origin} → {r.destination}</option>)}
            </select>
          </Field>
          <Field label={t("sched.vehicle")}>
            <select className="input" value={f.vehicle_uid} onChange={(e) => set("vehicle_uid", e.target.value)}>
              <option value="">{t("sched.noVehicle")}</option>
              {data.vehicles.map((v) => <option key={v.uid} value={v.uid}>{v.plate_no} · {v.passenger_seats}</option>)}
            </select>
          </Field>
          <Field label={t("sched.time")}><input className="input ltr" type="time" value={f.departure_time} onChange={(e) => set("departure_time", e.target.value)} /></Field>
          <Field label={t("sched.repeats")}>
            <select className="input" value={f.recurrence} onChange={(e) => set("recurrence", e.target.value as Recurrence)}>
              {data.rules.recurrences.map((r) => <option key={r} value={r}>{t(`sched.rec.${r}`)}</option>)}
            </select>
          </Field>
        </div>
        <DaysPicker recurrence={f.recurrence} dow={f.days_of_week} dom={f.days_of_month}
                    onDow={(v) => set("days_of_week", v)} onDom={(v) => set("days_of_month", v)} />
        <div className="grid cols-2">
          <Field label={t("sched.from")}><input className="input" type="date" value={f.from_date} onChange={(e) => set("from_date", e.target.value)} /></Field>
          <Field label={t("sched.end")}>
            <div className="stack tight">
              <label className="row" style={{ gap: 6 }}><input type="radio" name="sched-end" checked={f.no_end} onChange={() => set("no_end", true)} />{t("sched.noEnd")}</label>
              <label className="row" style={{ gap: 6 }}><input type="radio" name="sched-end" checked={!f.no_end} onChange={() => set("no_end", false)} />{t("sched.until")}
                <input className="input" type="date" value={f.until_date} disabled={f.no_end} onChange={(e) => set("until_date", e.target.value)} aria-label={t("sched.until")} /></label>
            </div>
          </Field>
        </div>
        <Field label={t("sched.skip")}><SkipDates value={f.skip_dates} onChange={(v) => set("skip_dates", v)} /></Field>
        <div className="grid cols-2">
          <Field label={t("sched.price")}><input className="input ltr" inputMode="decimal" value={f.price} onChange={(e) => set("price", e.target.value)} /></Field>
          <Field label={t("sched.tripType")}>
            <select className="input" value={f.trip_type} onChange={(e) => set("trip_type", e.target.value)}>
              {["SCHEDULED", "INTERNATIONAL", "SHUTTLE", "CARGO", "EXTRA"].map((x) => <option key={x} value={x}>{t(`sched.type.${x}`)}</option>)}
            </select>
          </Field>
          <Field label={t("sched.direction")}>
            <select className="input" value={f.direction} disabled={!!after} onChange={(e) => set("direction", e.target.value)}>
              {["OUTBOUND", "INBOUND"].map((x) => <option key={x} value={x}>{t(`sched.dir.${x}`)}</option>)}
            </select>
          </Field>
          <Field label={t("sched.number")} hint={after ? t("sched.numberAfter", { n: (after.service_no ?? 0) + 1 })
                                                       : numbers ? t("numbers.rangeHint", { from: numbers.range.from, to: numbers.range.to }) : t("sched.numberHint")}>
            {after ? <input className="input ltr" disabled value={String((after.service_no ?? 0) + 1)} /> : (
              <select className="input ltr mono" value={f.proposed_number} disabled={!numbers} onChange={(e) => set("proposed_number", e.target.value)}>
                {(!numbers || numbers.free.length === 0) && <option value="">{numbers ? t("numbers.full") : "—"}</option>}
                {numbers?.free.map((n) => <option key={n} value={n}>{n}{n === numbers.suggested ? ` · ${t("numbers.default")}` : ""}</option>)}
              </select>
            )}
          </Field>
        </div>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.auto_publish} onChange={(e) => set("auto_publish", e.target.checked)} />{t("sched.publish")}</label>
        <Field label={t("sched.note")}><input className="input" maxLength={500} value={f.note} onChange={(e) => set("note", e.target.value)} /></Field>
        <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
          <button type="button" className="btn tonal small" onClick={show}><Icon name="event_repeat" />{t("sched.preview")}</button>
          {preview && <span className="small">{t("sched.inMonth", { n: preview.in_30_days })}</span>}
        </div>
        {preview && <div className="small muted">{t("sched.nextDays")}: {preview.dates.map((d) => date(`${d}T12:00:00Z`)).join(" · ")}</div>}
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function ChangeSchedule({ s, data, onClose, onDone }: { s: Schedule; data: Overview; onClose: () => void; onDone: (msg: string) => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({ effective_from: new Date().toISOString().slice(0, 10), departure_time: "", recurrence: "" as Recurrence | "",
                               days_of_week: s.days_of_week ?? [], days_of_month: s.days_of_month ?? [], end: "KEEP" as "KEEP" | "NONE" | "DATE",
                               until_date: s.until_date ?? "", vehicle_uid: "", price: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const rec = (f.recurrence || s.recurrence) as Recurrence;
  const submit = async () => {
    setError(null);
    try {
      const r = await api.post<{ status: string }>(`/api/carrier/schedules/${s.uid}/change`, {
        effective_from: f.effective_from, departure_time: f.departure_time || null, recurrence: f.recurrence || null,
        days_of_week: f.recurrence === "WEEKLY" || (!f.recurrence && rec === "WEEKLY") ? f.days_of_week : null,
        days_of_month: f.recurrence === "MONTHLY" || (!f.recurrence && rec === "MONTHLY") ? f.days_of_month : null,
        until_date: f.end === "DATE" ? f.until_date : null, no_end: f.end === "NONE", vehicle_uid: f.vehicle_uid || null,
        base_price: f.price ? toMinor(f.price) : null, note: f.note || null });
      onDone(r.status === "PENDING" ? t("sched.asked") : t("sched.applied"));
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("sched.changeTitle", { code: s.trip_code ?? s.route_code })} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" onClick={submit}>{t("sched.ask")}</button></>}>
      <div className="stack">
        <p className="small muted" style={{ margin: 0 }}>{t("sched.changeHint")}</p>
        <div className="grid cols-2">
          <Field label={t("sched.effective")}><input className="input" type="date" value={f.effective_from} onChange={(e) => setF({ ...f, effective_from: e.target.value })} /></Field>
          <Field label={t("sched.time")}><input className="input ltr" type="time" value={f.departure_time} placeholder={s.departure_time} onChange={(e) => setF({ ...f, departure_time: e.target.value })} /></Field>
          <Field label={t("sched.repeats")}>
            <select className="input" value={f.recurrence} onChange={(e) => setF({ ...f, recurrence: e.target.value as Recurrence | "" })}>
              <option value="">{t("sched.keep")} ({t(`sched.rec.${s.recurrence}`)})</option>
              {data.rules.recurrences.map((r) => <option key={r} value={r}>{t(`sched.rec.${r}`)}</option>)}
            </select>
          </Field>
          <Field label={t("sched.vehicle")}>
            <select className="input" value={f.vehicle_uid} onChange={(e) => setF({ ...f, vehicle_uid: e.target.value })}>
              <option value="">{t("sched.keep")}{s.plate_no ? ` (${s.plate_no})` : ""}</option>
              {data.vehicles.map((v) => <option key={v.uid} value={v.uid}>{v.plate_no}</option>)}
            </select>
          </Field>
        </div>
        <DaysPicker recurrence={rec} dow={f.days_of_week} dom={f.days_of_month}
                    onDow={(v) => setF({ ...f, days_of_week: v })} onDom={(v) => setF({ ...f, days_of_month: v })} />
        <Field label={t("sched.end")}>
          <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
            {(["KEEP", "NONE", "DATE"] as const).map((k) => (
              <label key={k} className="row" style={{ gap: 6 }}><input type="radio" name="change-end" checked={f.end === k} onChange={() => setF({ ...f, end: k })} />
                {k === "KEEP" ? t("sched.keep") : k === "NONE" ? t("sched.noEnd") : t("sched.until")}</label>))}
            {f.end === "DATE" && <input className="input" type="date" value={f.until_date} onChange={(e) => setF({ ...f, until_date: e.target.value })} aria-label={t("sched.until")} />}
          </div>
        </Field>
        <div className="grid cols-2">
          <Field label={t("sched.price")}><input className="input ltr" inputMode="decimal" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} /></Field>
          <Field label={t("sched.note")}><input className="input" maxLength={500} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
        </div>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function StopSchedule({ s, onClose, onDone }: { s: Schedule; onClose: () => void; onDone: (msg: string) => void }) {
  const { t } = useI18n();
  const [from, setFrom] = useState(new Date().toISOString().slice(0, 10));
  const [note, setNote] = useState("");
  const [error, setError] = useState<unknown>(null);
  const submit = async () => {
    setError(null);
    try {
      const r = await api.post<{ status: string }>(`/api/carrier/schedules/${s.uid}/stop`, { from_date: from, note: note || null });
      onDone(r.status === "PENDING" ? t("sched.asked") : t("sched.applied"));
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("sched.stopTitle", { code: s.trip_code ?? s.route_code })} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn danger" onClick={submit}><Icon name="stop_circle" />{t("sched.stop")}</button></>}>
      <div className="stack">
        <div className="alert info small"><Icon name="info" />{t("sched.stopHint")}</div>
        <Field label={t("sched.stopFrom")}><input className="input" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label={t("sched.note")}><input className="input" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

export function RequestStatus({ r }: { r: ScheduleRequest }) {
  const { t } = useI18n();
  const tone = r.status === "APPROVED" ? "green" : r.status === "REJECTED" ? "red" : r.status === "PENDING" ? "wheat" : "";
  return <span className={`chip ${tone}`}>{t(`sched.rstatus.${r.status}`, { who: stageName(t, r.approval_stages[r.step]) })}</span>;
}

export function CarrierSchedules() {
  const { t, date, time, station } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Overview>("/api/carrier/schedules"));
  const pattern = usePattern();
  const [modal, setModal] = useState<{ kind: "new" } | { kind: "change" | "stop"; s: Schedule } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const done = (msg: string) => { setModal(null); toast(msg); state.reload(); };
  const act = async (call: () => Promise<unknown>, msg: string) => {
    setError(null);
    try { await call(); toast(msg); state.reload(); } catch (e) { setError(e); }
  };
  // a short date, with its year when it is not this year (a period may run into the next one)
  const day = (d: string) => date(d.length === 10 ? `${d}T12:00:00Z` : d,
    { weekday: undefined, year: d.startsWith(String(new Date().getFullYear())) ? undefined : "numeric" });
  const period = (from: string, until: string | null) => `${day(from)} – ${until ? day(until) : t("sched.openEnd")}`;
  return (
    <div className="stack">
      <PageHead title={t("sched.title")} sub={t("sched.sub")}>
        <button className="btn" onClick={() => setModal({ kind: "new" })} disabled={!state.data}><Icon name="add" />{t("sched.new")}</button>
      </PageHead>
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => (
        <>
          <div className="card stack tight">
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <strong>{t("sched.rules")}:</strong>
              {d.rules.approval_stages.map((s, i) => <span key={i} className="chip outline">{i + 1}. {stageName(t, s)}</span>)}
            </div>
            <div className="small muted">
              {(["NEW", "CHANGE", "STOP", "TRIP"] as const).map((k) => `${t(`sched.needs.${k}`)}: ${d.rules.approval_kinds.includes(k) ? d.rules.approval_stages.map((s) => stageName(t, s)).join(" ← ") : t("sched.noApproval")}`).join(" · ")}
            </div>
            <div className="small muted">{t("sched.horizon", { n: d.rules.horizon_days })}{d.rules.min_notice_days > 0 ? ` ${t("sched.notice", { n: d.rules.min_notice_days })}` : ""}</div>
          </div>
          <div className="card">
            {d.schedules.length === 0 ? <Empty icon="event_repeat" title={t("sched.none")} hint={t("sched.noneHint")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("sched.col.number")}</th><th>{t("sched.col.route")}</th><th>{t("sched.col.pattern")}</th>
                  <th>{t("sched.col.period")}</th><th>{t("sched.col.upcoming")}</th><th>{t("sched.col.status")}</th><th /></tr></thead>
                <tbody>{d.schedules.map((s) => (
                  <tr key={s.uid}>
                    <td className="mono text-nowrap"><strong>{s.trip_code ?? "—"}</strong><div className="small">{s.departure_time}</div>
                      {s.follows_code && <div className="small muted" title={t("sched.follows")}>{t("sched.after", { code: s.follows_code })}</div>}
                      {s.next_code && <div className="small muted" title={t("sched.follows")}>{t("sched.then", { code: s.next_code })}</div>}</td>
                    <td style={{ minWidth: 190 }}><strong className="mono">{s.route_code}</strong>
                      <div className="small muted">{station(s.origin_code, s.origin)} → {station(s.dest_code, s.destination)}{s.plate_no ? ` · ${s.plate_no}` : ""}</div></td>
                    <td>{pattern.text(s)}{s.skip_dates.length > 0 && <div className="small muted">{t("sched.skip")}: {s.skip_dates.length}</div>}</td>
                    <td className="small text-nowrap">{period(s.from_date, s.until_date)}</td>
                    <td><strong>{s.upcoming}</strong>
                      {s.next_departure && <div className="small muted text-nowrap">{t("sched.col.next")}: {day(s.next_departure)} {time(s.next_departure)}</div>}
                      {s.last_run && s.last_run.skipped_count > 0 && (
                      <div className="small" style={{ color: "var(--error)" }} title={s.last_run.skipped.map((x) => `${x.date}: ${t(`sched.skipReason.${x.reason}`)}`).join("\n")}>
                        {t("sched.skipped", { n: s.last_run.skipped_count })}</div>)}</td>
                    <td><span className={`chip ${s.status === "ACTIVE" ? "green" : s.status === "PAUSED" ? "wheat" : ""}`}>{t(`sched.status.${s.status}`)}</span></td>
                    <td><div className="row nowrap" style={{ gap: 0 }}>
                      {/* icons with their names, so the row fits the screen; the name shows on hover and is read aloud */}
                      {s.status !== "RETIRED" && <button className="icon-btn" title={t("sched.change")} aria-label={`${t("sched.change")} ${s.trip_code ?? ""}`}
                        onClick={() => setModal({ kind: "change", s })}><Icon name="edit_calendar" /></button>}
                      {s.status === "ACTIVE" && <button className="icon-btn" title={t("sched.pause")} aria-label={`${t("sched.pause")} ${s.trip_code ?? ""}`}
                        onClick={() => act(() => api.post(`/api/carrier/schedules/${s.uid}/pause`), t("sched.paused"))}><Icon name="pause_circle" /></button>}
                      {s.status === "PAUSED" && <button className="icon-btn" title={t("sched.resume")} aria-label={`${t("sched.resume")} ${s.trip_code ?? ""}`}
                        onClick={() => act(() => api.post(`/api/carrier/schedules/${s.uid}/resume`), t("sched.resumed"))}><Icon name="play_circle" /></button>}
                      {s.status !== "RETIRED" && <button className="icon-btn" title={t("sched.stop")} aria-label={`${t("sched.stop")} ${s.trip_code ?? ""}`}
                        onClick={() => setModal({ kind: "stop", s })}><Icon name="stop_circle" /></button>}
                    </div></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("sched.requests")}</h3>
            {d.requests.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("sched.noRequests")}</p> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <tbody>{d.requests.map((r) => (
                  <tr key={r.uid}>
                    <td><span className="chip outline">{t(`sched.kind.${r.kind}`)}</span></td>
                    <td>{r.schedule_code && r.kind !== "NEW" ? <strong className="mono">{r.schedule_code} </strong> : null}
                      {r.route ? `${station(r.route.origin_code, r.route.origin)} → ${station(r.route.dest_code, r.route.destination)}` : r.trip_code ?? r.trip_no ?? ""}
                      <div className="small muted">
                        {typeof r.proposal.departure_time === "string" ? `${r.proposal.departure_time} · ` : ""}
                        {typeof r.proposal.recurrence === "string" ? pattern.text(r.proposal as unknown as PatternLike) : ""}
                        {r.effective_from ? ` · ${t("sched.effective")} ${day(r.effective_from)}` : ""}
                      </div>
                      {r.result?.trip_code && r.kind === "NEW" && <div className="small">{t("sched.given", { code: r.result.trip_code })}</div>}
                      {r.decision_note && r.status === "REJECTED" && <div className="small" style={{ color: "var(--error)" }}>{t("sched.reason", { reason: r.decision_note })}</div>}
                      {(r.result?.kept?.length ?? 0) > 0 && (
                        <div className="small" style={{ color: "var(--error)" }}>{t("sched.kept", { n: r.result!.kept!.length })}:{" "}
                          {r.result!.kept!.map((k) => `${k.trip_code} ${date(k.departure_at)}`).join(" · ")}</div>)}
                    </td>
                    <td className="small text-nowrap">{day(r.requested_at)}</td>
                    <td><RequestStatus r={r} /></td>
                    <td>{r.status === "PENDING" && <button className="btn text small" onClick={() => act(() => api.post(`/api/carrier/schedule-requests/${r.uid}/withdraw`), t("sched.withdrawn"))}>{t("sched.withdraw")}</button>}</td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
          <CarrierNumberRanges />
          {modal?.kind === "new" && <NewSchedule data={d} onClose={() => setModal(null)} onDone={done} />}
          {modal?.kind === "change" && <ChangeSchedule s={modal.s} data={d} onClose={() => setModal(null)} onDone={done} />}
          {modal?.kind === "stop" && <StopSchedule s={modal.s} onClose={() => setModal(null)} onDone={done} />}
        </>
      )}</Loaded>
    </div>
  );
}
