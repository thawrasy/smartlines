import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useErrorText, useLoad, useToast } from "../../components/ui";

interface Waiting { tracking_no: string; recipient_name: string; recipient_mobile: string; contents: string; arrived_at: string; exception_kind: string | null;
  exception_note: string | null; pickup_code_tries: number; code_sends: number; station: string | null; trip_no: string; overdue: boolean; days_waited: number;
  delivery_mode: "PICKUP" | "ADDRESS"; delivery_address: string | null; secure: boolean; out_for_delivery_at: string | null }
interface AtLocation { tracking_no: string; recipient_name: string; contents: string; secure: boolean; location: string; received_at: string }
interface WaitingList { unclaimed_days: number; code_tries: number; code_sends: number; parcels: Waiting[]; at_locations: AtLocation[] }
interface Point { uid: string; name: string; status: string }
interface Journey { tracking_no: string; status: string; recipient_name: string; station: string | null; delivered_at: string | null;
  exception_kind: string | null; exception_note: string | null; delivery_mode: "PICKUP" | "ADDRESS"; delivery_address: string | null; secure: boolean;
  out_for_delivery_at: string | null; pickup_code: string | null; id_check: { kind: string; last4: string; holder: string } | null;
  events: { milestone: string; reason_code: string | null; ts: string; place: string | null }[];
  hops: { seq: number; location: string; received_at: string; dispatched_at: string | null; sent_to: string | null }[] }
type Kind = "DAMAGED" | "MISSING" | "REFUSED" | "UNCLAIMED";
const KINDS: Kind[] = ["DAMAGED", "MISSING", "REFUSED", "UNCLAIMED"];
const DOCS = ["NATIONAL_ID", "PASSPORT", "FAMILY_BOOK", "RESIDENCE", "DRIVING_LICENCE", "OTHER"] as const;
const REASONS = ["NOBODY_HOME", "WRONG_ADDRESS", "REFUSED_AT_DOOR", "NO_CODE", "ACCESS", "OTHER"] as const;
type Step = "load" | "receive" | "dispatch" | "arrive";
const STEPS: { step: Step; icon: "local_shipping" | "inventory_2" | "route" | "location_on" }[] = [
  { step: "load", icon: "local_shipping" }, { step: "receive", icon: "inventory_2" }, { step: "dispatch", icon: "route" }, { step: "arrive", icon: "location_on" }];

interface Detector { detect(source: HTMLVideoElement): Promise<{ rawValue: string }[]> }
const detectorClass = (): (new (o: { formats: string[] }) => Detector) | null =>
  (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => Detector }).BarcodeDetector ?? null;

/** The phone's back camera reading labels one after another: the same label is not read twice within a few seconds. */
function LabelCamera({ onRead }: { onRead: (code: string) => void }) {
  const { t } = useI18n();
  const video = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    const Klass = detectorClass();
    if (!Klass || !navigator.mediaDevices) { setError(true); return; }
    const detector = new Klass({ formats: ["qr_code"] });
    let stream: MediaStream | null = null, timer = 0, stopped = false;
    let last = "", lastAt = 0;
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } }).then((st) => {
      if (stopped) { st.getTracks().forEach((tr) => tr.stop()); return; }
      stream = st;
      if (video.current) { video.current.srcObject = st; void video.current.play(); }
      const tick = async () => {
        if (stopped || !video.current) return;
        try {
          const code = (await detector.detect(video.current)).map((f) => f.rawValue).find((v) => v.length > 40);
          if (code && (code !== last || Date.now() - lastAt > 4000)) { last = code; lastAt = Date.now(); onRead(code); }
        } catch { /* the frame was not ready */ }
        timer = window.setTimeout(tick, 300);
      };
      void tick();
    }).catch(() => setError(true));
    return () => { stopped = true; window.clearTimeout(timer); stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [onRead]);
  if (error) return <div className="alert info small"><Icon name="info" /><span>{t("parcel.journey.noCamera")}</span></div>;
  return <video ref={video} muted playsInline aria-label={t("parcel.journey.cameraView")} style={{ width: "100%", maxHeight: 320, borderRadius: 16, background: "#000", objectFit: "cover" }} />;
}

/** What the scanner read: a label's signed code is long, a typed tracking number is short. */
const scanned = (v: string) => (v.trim().length > 40 ? { code: v.trim() } : { tracking_no: v.trim().toUpperCase() });

/** On board, through the carrier's locations, off at the destination (1182, 1183). A handheld scanner types the label's
 *  code into the field and presses Enter, or the clerk types the tracking number; the field empties and keeps the focus,
 *  so a stack of parcels is scanned one after another. At a location the clerk picks where they are, and where it goes next. */
export function ParcelScan() {
  const { t } = useI18n();
  const errorText = useErrorText();
  const points = useLoad((signal) => api.get<{ points: Point[] }>("/api/carrier/parcels/points", undefined, { signal }));
  const [step, setStep] = useState<Step>("load");
  const [here, setHere] = useState("");
  const [next, setNext] = useState("");
  const [value, setValue] = useState("");
  const [log, setLog] = useState<{ ok: boolean; text: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [camera, setCamera] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const active = (points.data?.points ?? []).filter((p) => p.status === "ACTIVE");
  const send = useRef<(raw?: string) => Promise<void>>(async () => undefined);
  const go = async (raw?: string) => {
    const read = raw ?? value;
    if (!read.trim()) return;
    setBusy(true);
    try {
      const extra = step === "receive" ? { point_uid: here } : step === "dispatch" && next ? { next_point_uid: next } : {};
      const r = await api.post<{ tracking_no: string; recipient_name?: string; location?: string; to?: string | null }>(
        `/api/carrier/parcels/scan/${step}`, { ...scanned(read), ...extra });
      setLog((l) => [{ ok: true, text: t(`parcel.journey.done.${step}`, { no: r.tracking_no, name: r.recipient_name ?? "", place: r.location ?? r.to ?? "" }) }, ...l].slice(0, 30));
    } catch (e) {
      setLog((l) => [{ ok: false, text: `${read.trim().slice(0, 24)} — ${errorText(e)}` }, ...l].slice(0, 30));
    } finally { setValue(""); setBusy(false); if (!camera) input.current?.focus(); }
  };
  const blocked = step === "receive" && !here;
  send.current = async (raw?: string) => { if (!blocked) await go(raw); };
  const onCamera = useCallback((code: string) => { void send.current(code); }, []);
  return (
    <div className="card stack">
      <div className="segmented" role="radiogroup" aria-label={t("parcel.journey.step")} style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {STEPS.map(({ step: s, icon }) => (
          <button key={s} role="radio" aria-checked={step === s} className={step === s ? "on" : ""} onClick={() => { setStep(s); input.current?.focus(); }}>
            <Icon name={icon} />{t(`parcel.journey.${s}`)}</button>
        ))}
      </div>
      <p className="small muted">{t(`parcel.journey.${step}Hint`)}</p>
      {step === "receive" && (
        <Field label={t("parcel.journey.here")}>
          <select value={here} onChange={(e) => setHere(e.target.value)}><option value="">{t("parcel.choose")}</option>
            {active.map((p) => <option key={p.uid} value={p.uid}>{p.name}</option>)}</select>
        </Field>
      )}
      {step === "dispatch" && (
        <Field label={t("parcel.journey.nextLocation")}>
          <select value={next} onChange={(e) => setNext(e.target.value)}><option value="">{t("parcel.journey.toDestination")}</option>
            {active.map((p) => <option key={p.uid} value={p.uid}>{p.name}</option>)}</select>
        </Field>
      )}
      <form className="row" style={{ gap: 8, flexWrap: "wrap" }} onSubmit={(e) => { e.preventDefault(); if (!blocked) void go(); }}>
        <Field label={t("parcel.journey.scanField")}>
          <input ref={input} className="input ltr mono" autoFocus autoComplete="off" value={value} onChange={(e) => setValue(e.target.value)} />
        </Field>
        <button className="btn" style={{ alignSelf: "end" }} disabled={busy || blocked || value.trim().length < 4}><Icon name="qr_code_scanner" />{t(`parcel.journey.${step}`)}</button>
        <button type="button" className="btn tonal" style={{ alignSelf: "end" }} aria-pressed={camera} onClick={() => setCamera(!camera)}>
          <Icon name="qr_code_scanner" />{t(camera ? "parcel.journey.cameraOff" : "parcel.journey.cameraOn")}</button>
      </form>
      {camera && !blocked && <LabelCamera onRead={onCamera} />}
      {log.length > 0 && (
        <ul className="stack" style={{ listStyle: "none", padding: 0, margin: 0, gap: 4 }} aria-live="polite">
          {log.map((x, i) => (
            <li key={i} className={`small alert ${x.ok ? "success" : "error"}`}><Icon name={x.ok ? "check_circle" : "error"} /><span>{x.text}</span></li>
          ))}
        </ul>
      )}
    </div>
  );
}

type Act = "deliver" | "exception" | "return" | "failed";
const BLANK = { code: "", withId: false, docKind: "NATIONAL_ID" as (typeof DOCS)[number], docNo: "", holder: "", issuer: "", to: "",
  kind: "DAMAGED" as Kind, note: "", reason: "NOBODY_HOME" as (typeof REASONS)[number] };

/** Parcels at the destination: collected at the counter with the code (sent again when asked), or taken to the address;
 *  without the code, or for an important parcel, an identity check recorded field by field. Problems are recorded and a
 *  parcel with a problem goes back. Parcels held at the carrier's locations on the way are listed below. */
export function ParcelWaiting() {
  const { t, dateTime, num } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<WaitingList>("/api/carrier/parcels/waiting", undefined, { signal }));
  const [act, setAct] = useState<{ p: Waiting; kind: Act } | null>(null);
  const [f, setF] = useState(BLANK);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const tries = state.data?.code_tries ?? 5;
  const locked = (p: Waiting) => p.pickup_code_tries >= tries;
  const open = (p: Waiting, kind: Act) => {
    setAct({ p, kind }); setError(null);
    setF({ ...BLANK, withId: p.secure || locked(p), holder: p.recipient_name, to: p.recipient_name, kind: p.overdue ? "UNCLAIMED" : "DAMAGED" });
  };
  const quick = async (p: Waiting, what: "send-code" | "out") => {
    try {
      await api.post(`/api/carrier/parcels/${p.tracking_no}/${what}`, {});
      toast(t(what === "out" ? "parcel.journey.wentOut" : "parcel.journey.codeSent", { no: p.tracking_no })); state.reload();
    } catch (e) { setError(e); }
  };
  const send = async () => {
    if (!act) return;
    setBusy(true); setError(null);
    const no = act.p.tracking_no;
    try {
      if (act.kind === "deliver") {
        const id = f.withId ? { doc_kind: f.docKind, doc_no: f.docNo.trim(), holder_name: f.holder.trim(), issued_by: f.issuer.trim() || null } : null;
        const useCode = f.code.trim().length === 6;
        await api.post(`/api/carrier/parcels/${no}/deliver`, { pickup_code: useCode ? f.code.trim() : null, id_check: id, delivered_to: f.to.trim() });
        toast(t("parcel.journey.delivered", { no }));
      } else if (act.kind === "exception") {
        await api.post(`/api/carrier/parcels/${no}/exception`, { kind: f.kind, note: f.note.trim() });
        toast(t("parcel.journey.recorded"));
      } else if (act.kind === "failed") {
        await api.post(`/api/carrier/parcels/${no}/attempt-failed`, { reason: f.reason });
        toast(t("parcel.journey.recorded"));
      } else {
        await api.post(`/api/carrier/parcels/${no}/return`, { note: f.note.trim() });
        toast(t("parcel.journey.returned", { no }));
      }
      setAct(null); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const idOk = f.docNo.trim().length >= 4 && f.holder.trim().length >= 3;
  const codeOk = /^\d{6}$/.test(f.code.trim());
  const ready = !act ? false
    : act.kind === "deliver" ? f.to.trim().length >= 3 && (act.p.secure ? idOk && (codeOk || locked(act.p)) : f.withId ? idOk : codeOk)
    : act.kind === "failed" ? true : f.note.trim().length >= 3;
  return (
    <div className="stack">
      {!act && <ErrorBox error={error} />}
      <Loaded state={state}>{({ unclaimed_days, code_sends, parcels, at_locations }) => (
        <>
          <div className="card stack">
            <p className="small muted">{t("parcel.journey.waitingHint", { n: num(unclaimed_days) })}</p>
            {parcels.length === 0 ? <Empty icon="inventory_2" title={t("parcel.journey.noneWaiting")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("parcel.tracking")}</th><th>{t("parcel.recipient")}</th><th>{t("parcel.journey.handOver")}</th><th>{t("parcel.journey.arrived")}</th>
                  <th>{t("common.status")}</th><th /></tr></thead>
                <tbody>{parcels.map((p) => {
                  const address = p.delivery_mode === "ADDRESS";
                  const hasCode = !address || p.out_for_delivery_at;
                  return (
                    <tr key={p.tracking_no}>
                      <td className="mono">{p.tracking_no}<div className="small muted">{p.trip_no}{p.station && ` · ${p.station}`}</div>
                        {p.secure && <span className="chip red small"><Icon name="lock" />{t("parcel.journey.important")}</span>}</td>
                      <td>{p.recipient_name}<div className="small ltr muted">{p.recipient_mobile}</div><div className="small muted">{p.contents}</div></td>
                      <td className="small">{t(`parcel.journey.mode.${p.delivery_mode}`)}{p.delivery_address && <div className="muted">{p.delivery_address}</div>}</td>
                      <td className="small">{dateTime(p.arrived_at)}<div className={p.overdue ? "chip red" : "muted"}>{t("parcel.journey.days", { n: num(p.days_waited) })}</div></td>
                      <td>{p.exception_kind ? <span className="chip red" title={p.exception_note ?? ""}>{t(`parcel.journey.kind.${p.exception_kind}`)}</span>
                        : <span className="chip">{t(p.out_for_delivery_at ? "parcel.journey.outNow" : "parcel.journey.waiting")}</span>}</td>
                      <td className="row" style={{ gap: 4, flexWrap: "wrap" }}>
                        {!p.exception_kind && address && !p.out_for_delivery_at &&
                          <button className="btn tonal" onClick={() => void quick(p, "out")}><Icon name="local_shipping" />{t("parcel.journey.goOut")}</button>}
                        {!p.exception_kind && hasCode &&
                          <button className="btn tonal" onClick={() => open(p, "deliver")}><Icon name="how_to_reg" />{t("parcel.journey.deliver")}</button>}
                        {!p.exception_kind && hasCode && p.code_sends < code_sends &&
                          <button className="btn text" onClick={() => void quick(p, "send-code")}>{t("parcel.journey.sendCode")}</button>}
                        {!p.exception_kind && p.out_for_delivery_at &&
                          <button className="btn text" onClick={() => open(p, "failed")}>{t("parcel.journey.failed")}</button>}
                        {!p.exception_kind && <button className="btn text" onClick={() => open(p, "exception")}>{t("parcel.journey.exception")}</button>}
                        {p.exception_kind && <button className="btn text" onClick={() => open(p, "return")}><Icon name="undo" />{t("parcel.journey.sendBack")}</button>}
                      </td>
                    </tr>
                  );
                })}</tbody>
              </table></div>
            )}
          </div>
          <section className="card stack" aria-labelledby="at-locations">
            <h3 id="at-locations">{t("parcel.journey.atLocations")}</h3>
            {at_locations.length === 0 ? <p className="small muted">{t("parcel.journey.noneAtLocations")}</p> : (
              <div className="table-wrap" tabIndex={0}><table className="table"><tbody>{at_locations.map((p) => (
                <tr key={p.tracking_no}><td className="mono">{p.tracking_no}</td><td>{p.location}</td><td className="small">{dateTime(p.received_at)}</td>
                  <td>{p.recipient_name}</td><td className="small">{p.contents}</td>
                  <td>{p.secure && <span className="chip red small"><Icon name="lock" />{t("parcel.journey.important")}</span>}</td></tr>
              ))}</tbody></table></div>
            )}
          </section>
        </>
      )}</Loaded>
      {act && (
        <Modal title={`${t(`parcel.journey.${act.kind === "return" ? "sendBack" : act.kind}`)} · ${act.p.tracking_no}`} onClose={() => setAct(null)} actions={<>
          <button className="btn text" onClick={() => setAct(null)}>{t("common.cancel")}</button>
          <button className="btn" disabled={busy || !ready} onClick={() => void send()}>{t("common.confirm")}</button></>}>
          {act.kind === "deliver" && (
            <div className="stack">
              {act.p.secure && <div className="alert info small"><Icon name="lock" /><span>{t("parcel.journey.importantHint")}</span></div>}
              {locked(act.p) && <div className="alert error small"><Icon name="lock" /><span>{t("parcel.journey.locked")}</span></div>}
              {!locked(act.p) && (act.p.secure || !f.withId) &&
                <Field label={t("parcel.journey.code")}><input className="input ltr mono" inputMode="numeric" maxLength={6} autoFocus value={f.code} onChange={(e) => setF({ ...f, code: e.target.value.replace(/\D/g, "") })} /></Field>}
              {!act.p.secure && !locked(act.p) &&
                <label className="check"><input type="checkbox" checked={f.withId} onChange={(e) => setF({ ...f, withId: e.target.checked })} />{t("parcel.journey.noCode")}</label>}
              {f.withId && (
                <fieldset className="stack" style={{ border: 0, padding: 0 }}>
                  <legend className="small muted">{t("parcel.journey.idTitle")}</legend>
                  <div className="grid cols-2">
                    <Field label={t("parcel.journey.docKind")}>
                      <select value={f.docKind} onChange={(e) => setF({ ...f, docKind: e.target.value as (typeof DOCS)[number] })}>
                        {DOCS.map((d) => <option key={d} value={d}>{t(`parcel.journey.doc.${d}`)}</option>)}</select>
                    </Field>
                    <Field label={t("parcel.journey.docNo")} hint={t("parcel.journey.docNoHint")}><input className="input ltr mono" maxLength={40} autoComplete="off" value={f.docNo} onChange={(e) => setF({ ...f, docNo: e.target.value })} /></Field>
                    <Field label={t("parcel.journey.holder")}><input className="input" maxLength={120} value={f.holder} onChange={(e) => setF({ ...f, holder: e.target.value })} /></Field>
                    <Field label={t("parcel.journey.issuer")}><input className="input" maxLength={120} placeholder={t("common.optional")} value={f.issuer} onChange={(e) => setF({ ...f, issuer: e.target.value })} /></Field>
                  </div>
                </fieldset>
              )}
              <Field label={t("parcel.journey.deliveredTo")}><input className="input" maxLength={120} value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></Field>
            </div>
          )}
          {act.kind === "failed" && (
            <Field label={t("parcel.journey.why")}>
              <select value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value as (typeof REASONS)[number] })}>
                {REASONS.map((r) => <option key={r} value={r}>{t(`parcel.journey.reason.${r}`)}</option>)}</select>
            </Field>
          )}
          {act.kind === "exception" && (
            <div className="stack">
              <Field label={t("parcel.journey.what")}>
                <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as Kind })}>
                  {KINDS.filter((k) => k !== "UNCLAIMED" || act.p.overdue).map((k) => <option key={k} value={k}>{t(`parcel.journey.kind.${k}`)}</option>)}</select>
              </Field>
              <Field label={t("parcel.journey.note")}><textarea className="input" rows={3} maxLength={300} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
            </div>
          )}
          {act.kind === "return" && (
            <Field label={t("parcel.journey.note")}><input className="input" maxLength={300} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
          )}
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}

/** Where the sender's parcel is: each step and each location it passed, how it is handed over, and the code while valid. */
export function JourneyView({ trackingNo, onClose }: { trackingNo: string; onClose: () => void }) {
  const { t, has, dateTime } = useI18n();
  const state = useLoad((signal) => api.get<Journey>(`/api/parcels/${trackingNo}/journey`, undefined, { signal }), [trackingNo]);
  const where = (e: Journey["events"][number]) => e.place ?? (e.milestone === "RECEIVED_AT_HUB" || e.milestone === "DEPARTED" ? e.reason_code : null);
  return (
    <Modal title={t("parcel.journey.title", { no: trackingNo })} onClose={onClose} actions={<button className="btn text" onClick={onClose}>{t("common.close")}</button>}>
      <Loaded state={state}>{(j) => (
        <div className="stack">
          <div className="row small" style={{ gap: 8, flexWrap: "wrap" }}>
            <span className="chip">{t(`parcel.journey.mode.${j.delivery_mode}`)}</span>
            {j.secure && <span className="chip red"><Icon name="lock" />{t("parcel.journey.important")}</span>}
            {j.delivery_address && <span className="muted">{j.delivery_address}</span>}
          </div>
          {j.pickup_code && (
            <div className="alert info" style={{ flexDirection: "column", alignItems: "flex-start", gap: 4 }}>
              <span className="small">{j.delivery_mode === "ADDRESS" ? t("parcel.journey.codeForCourier", { name: j.recipient_name })
                : t("parcel.journey.codeFor", { name: j.recipient_name, station: j.station ?? "—" })}</span>
              <strong className="mono ltr" style={{ fontSize: 28, letterSpacing: "0.2em" }}>{j.pickup_code}</strong>
            </div>
          )}
          {j.exception_kind && <div className="alert error small"><Icon name="warning" /><span>{t(`parcel.journey.kind.${j.exception_kind}`)}{j.exception_note && `: ${j.exception_note}`}</span></div>}
          {j.id_check && <p className="small">{t("parcel.journey.idDone", { doc: t(`parcel.journey.doc.${j.id_check.kind}`), last4: j.id_check.last4, holder: j.id_check.holder })}</p>}
          {j.hops.length > 0 && (
            <div className="small"><strong>{t("parcel.journey.route")}: </strong>{j.hops.map((h) => h.location).join(" · ")}</div>
          )}
          {j.events.length === 0 ? <p className="small muted">{t("parcel.journey.noSteps")}</p> : (
            <ol className="stack" style={{ margin: 0, paddingInlineStart: 20, gap: 6 }}>
              {j.events.map((e, i) => (
                <li key={i}><strong>{has(`parcel.journey.milestone.${e.milestone}`) ? t(`parcel.journey.milestone.${e.milestone}`) : e.milestone}</strong>
                  <span className="small muted"> · {dateTime(e.ts)}{where(e) && ` · ${where(e)}`}</span></li>
              ))}
            </ol>
          )}
        </div>
      )}</Loaded>
    </Modal>
  );
}
