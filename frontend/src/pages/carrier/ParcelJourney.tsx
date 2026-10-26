import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useErrorText, useLoad, useToast } from "../../components/ui";

interface Waiting { tracking_no: string; recipient_name: string; recipient_mobile: string; contents: string; arrived_at: string; exception_kind: string | null;
  exception_note: string | null; pickup_code_tries: number; station: string | null; trip_no: string; overdue: boolean; days_waited: number }
interface Journey { tracking_no: string; status: string; recipient_name: string; station: string | null; handed_over_at: string | null; loaded_at: string | null;
  arrived_at: string | null; delivered_at: string | null; returned_at: string | null; exception_kind: string | null; exception_note: string | null;
  pickup_code: string | null; events: { milestone: string; reason_code: string | null; ts: string; place: string | null }[] }
type Kind = "DAMAGED" | "MISSING" | "REFUSED" | "UNCLAIMED";
const KINDS: Kind[] = ["DAMAGED", "MISSING", "REFUSED", "UNCLAIMED"];

/** What the scanner read: a label's signed code is long, a typed tracking number is short. */
const scanned = (v: string) => (v.trim().length > 40 ? { code: v.trim() } : { tracking_no: v.trim().toUpperCase() });

/** On board and off (1182): a handheld scanner types the label's code into the field and presses Enter; the clerk may
 *  also type the tracking number. The field empties and keeps the focus, so a stack of parcels is scanned one after another. */
export function ParcelScan() {
  const { t } = useI18n();
  const errorText = useErrorText();
  const [step, setStep] = useState<"load" | "arrive">("load");
  const [value, setValue] = useState("");
  const [log, setLog] = useState<{ ok: boolean; text: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const go = async () => {
    if (!value.trim()) return;
    setBusy(true);
    try {
      const r = await api.post<{ tracking_no: string; recipient_name: string; trip_no?: string; station?: string }>(`/api/carrier/parcels/scan/${step}`, scanned(value));
      setLog((l) => [{ ok: true, text: t(`parcel.journey.done.${step}`, { no: r.tracking_no, name: r.recipient_name }) }, ...l].slice(0, 30));
    } catch (e) {
      setLog((l) => [{ ok: false, text: `${value.trim().slice(0, 24)} — ${errorText(e)}` }, ...l].slice(0, 30));
    } finally { setValue(""); setBusy(false); input.current?.focus(); }
  };
  return (
    <div className="card stack">
      <div className="segmented" role="radiogroup" aria-label={t("parcel.journey.step")} style={{ alignSelf: "flex-start" }}>
        {(["load", "arrive"] as const).map((s) => (
          <button key={s} role="radio" aria-checked={step === s} className={step === s ? "on" : ""} onClick={() => { setStep(s); input.current?.focus(); }}>
            <Icon name={s === "load" ? "local_shipping" : "location_on"} />{t(`parcel.journey.${s}`)}</button>
        ))}
      </div>
      <p className="small muted">{t(`parcel.journey.${step}Hint`)}</p>
      <form className="row" style={{ gap: 8, flexWrap: "wrap" }} onSubmit={(e) => { e.preventDefault(); void go(); }}>
        <Field label={t("parcel.journey.scanField")}>
          <input ref={input} className="input ltr mono" autoFocus autoComplete="off" value={value} onChange={(e) => setValue(e.target.value)} />
        </Field>
        <button className="btn" style={{ alignSelf: "end" }} disabled={busy || value.trim().length < 4}><Icon name="qr_code_scanner" />{t(`parcel.journey.${step}`)}</button>
      </form>
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

/** Parcels at the destination waiting for their recipients: hand over with the code or after an identity check,
 *  record what went wrong, and send back a parcel after an exception. */
export function ParcelWaiting() {
  const { t, dateTime, num } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ unclaimed_days: number; parcels: Waiting[] }>("/api/carrier/parcels/waiting", undefined, { signal }));
  const [act, setAct] = useState<{ p: Waiting; kind: "deliver" | "exception" | "return" } | null>(null);
  const [f, setF] = useState({ code: "", byId: false, idNote: "", to: "", kind: "DAMAGED" as Kind, note: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const open = (p: Waiting, kind: "deliver" | "exception" | "return") => {
    setAct({ p, kind }); setError(null);
    setF({ code: "", byId: p.pickup_code_tries >= 5, idNote: "", to: p.recipient_name, kind: p.overdue ? "UNCLAIMED" : "DAMAGED", note: "" });
  };
  const send = async () => {
    if (!act) return;
    setBusy(true); setError(null);
    const no = act.p.tracking_no;
    try {
      if (act.kind === "deliver") {
        await api.post(`/api/carrier/parcels/${no}/deliver`, f.byId ? { id_checked: true, id_note: f.idNote.trim(), delivered_to: f.to.trim() }
          : { pickup_code: f.code.trim(), delivered_to: f.to.trim() });
        toast(t("parcel.journey.delivered", { no }));
      } else if (act.kind === "exception") {
        await api.post(`/api/carrier/parcels/${no}/exception`, { kind: f.kind, note: f.note.trim() });
        toast(t("parcel.journey.recorded"));
      } else {
        await api.post(`/api/carrier/parcels/${no}/return`, { note: f.note.trim() });
        toast(t("parcel.journey.returned", { no }));
      }
      setAct(null); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const ready = !act ? false : act.kind === "deliver" ? f.to.trim().length >= 3 && (f.byId ? f.idNote.trim().length >= 3 : /^\d{6}$/.test(f.code.trim()))
    : f.note.trim().length >= 3;
  return (
    <div className="stack">
      <Loaded state={state}>{({ unclaimed_days, parcels }) => (
        <div className="card stack">
          <p className="small muted">{t("parcel.journey.waitingHint", { n: num(unclaimed_days) })}</p>
          {parcels.length === 0 ? <Empty icon="inventory_2" title={t("parcel.journey.noneWaiting")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("parcel.tracking")}</th><th>{t("parcel.recipient")}</th><th>{t("parcel.contents")}</th><th>{t("parcel.journey.arrived")}</th>
                <th>{t("common.status")}</th><th /></tr></thead>
              <tbody>{parcels.map((p) => (
                <tr key={p.tracking_no}>
                  <td className="mono">{p.tracking_no}<div className="small muted">{p.trip_no}{p.station && ` · ${p.station}`}</div></td>
                  <td>{p.recipient_name}<div className="small ltr muted">{p.recipient_mobile}</div></td>
                  <td className="small">{p.contents}</td>
                  <td className="small">{dateTime(p.arrived_at)}<div className={p.overdue ? "chip red" : "muted"}>{t("parcel.journey.days", { n: num(p.days_waited) })}</div></td>
                  <td>{p.exception_kind ? <span className="chip red" title={p.exception_note ?? ""}>{t(`parcel.journey.kind.${p.exception_kind}`)}</span>
                    : <span className="chip">{t("parcel.journey.waiting")}</span>}</td>
                  <td className="row" style={{ gap: 4, flexWrap: "wrap" }}>
                    {!p.exception_kind && <button className="btn tonal" onClick={() => open(p, "deliver")}><Icon name="how_to_reg" />{t("parcel.journey.deliver")}</button>}
                    {!p.exception_kind && <button className="btn text" onClick={() => open(p, "exception")}>{t("parcel.journey.exception")}</button>}
                    {p.exception_kind && <button className="btn text" onClick={() => open(p, "return")}><Icon name="undo" />{t("parcel.journey.sendBack")}</button>}
                  </td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </div>
      )}</Loaded>
      {act && (
        <Modal title={`${t(`parcel.journey.${act.kind === "return" ? "sendBack" : act.kind}`)} · ${act.p.tracking_no}`} onClose={() => setAct(null)} actions={<>
          <button className="btn text" onClick={() => setAct(null)}>{t("common.cancel")}</button>
          <button className="btn" disabled={busy || !ready} onClick={() => void send()}>{t("common.confirm")}</button></>}>
          {act.kind === "deliver" && (
            <div className="stack">
              {act.p.pickup_code_tries >= 5 ? <div className="alert error small"><Icon name="lock" /><span>{t("parcel.journey.locked")}</span></div>
                : <label className="check"><input type="checkbox" checked={f.byId} onChange={(e) => setF({ ...f, byId: e.target.checked })} />{t("parcel.journey.noCode")}</label>}
              {f.byId
                ? <Field label={t("parcel.journey.idNote")} hint={t("parcel.journey.idNoteHint")}><input className="input" maxLength={120} value={f.idNote} onChange={(e) => setF({ ...f, idNote: e.target.value })} /></Field>
                : <Field label={t("parcel.journey.code")}><input className="input ltr mono" inputMode="numeric" maxLength={6} autoFocus value={f.code} onChange={(e) => setF({ ...f, code: e.target.value.replace(/\D/g, "") })} /></Field>}
              <Field label={t("parcel.journey.deliveredTo")}><input className="input" maxLength={120} value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></Field>
            </div>
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

/** Where the sender's parcel is: each step, and the pickup code while it waits at its station. */
export function JourneyView({ trackingNo, onClose }: { trackingNo: string; onClose: () => void }) {
  const { t, has, dateTime } = useI18n();
  const state = useLoad((signal) => api.get<Journey>(`/api/parcels/${trackingNo}/journey`, undefined, { signal }), [trackingNo]);
  return (
    <Modal title={t("parcel.journey.title", { no: trackingNo })} onClose={onClose} actions={<button className="btn text" onClick={onClose}>{t("common.close")}</button>}>
      <Loaded state={state}>{(j) => (
        <div className="stack">
          {j.pickup_code && (
            <div className="alert info" style={{ flexDirection: "column", alignItems: "flex-start", gap: 4 }}>
              <span className="small">{t("parcel.journey.codeFor", { name: j.recipient_name, station: j.station ?? "—" })}</span>
              <strong className="mono ltr" style={{ fontSize: 28, letterSpacing: "0.2em" }}>{j.pickup_code}</strong>
            </div>
          )}
          {j.exception_kind && <div className="alert error small"><Icon name="warning" /><span>{t(`parcel.journey.kind.${j.exception_kind}`)}{j.exception_note && `: ${j.exception_note}`}</span></div>}
          {j.events.length === 0 ? <p className="small muted">{t("parcel.journey.noSteps")}</p> : (
            <ol className="stack" style={{ margin: 0, paddingInlineStart: 20, gap: 6 }}>
              {j.events.map((e, i) => (
                <li key={i}><strong>{has(`parcel.journey.milestone.${e.milestone}`) ? t(`parcel.journey.milestone.${e.milestone}`) : e.milestone}</strong>
                  <span className="small muted"> · {dateTime(e.ts)}{e.place && ` · ${e.place}`}</span></li>
              ))}
            </ol>
          )}
        </div>
      )}</Loaded>
    </Modal>
  );
}
