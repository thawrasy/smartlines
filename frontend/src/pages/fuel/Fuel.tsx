import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import QRCode from "qrcode";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, Field, Icon, Loaded, Modal, Stat, useErrorText, useLoad, useToast } from "../../components/ui";

// The fuel company's portal (owner's note of 25 October 2026; migration 1180; docs/design/FUEL_STATIONS.md). The
// manager sees the stations with their prices and the day's fills, the accounts held with the company (each sum the
// company received is recorded here), the fills with the meter's photo and what the checks found. The attendant works
// at the pump on a phone: identify the vehicle by its NFC tag (a secure tag signs each tap), the code the driver's app
// shows (read by the camera) or the card's number, see what it may take, answer what the system asks from the fill's
// risk (the pump's QR sticker, the odometer's photo), and photograph the meter with the live camera only (1181).

export interface Prices { [fuel: string]: { price: number; currency: string; from: string } }
interface Station { uid: string; code: string; name: string; status: string; pumps: number | null; station: string | null; prices: Prices;
  attendants: number; today: { fills: number; litres: number; amount: number } }
interface AccountRow { uid: string; holder: string; holder_uid: string; currency: string; balance: number; status: string; cards: number; last_topup: string | null }
interface Overview { stations: Station[]; accounts: AccountRow[]; open_anomalies: number; enabled: boolean;
  my_stations: { uid: string; code: string; name: string; pumps: number | null; role: string }[]; can: { manage: boolean; attend: boolean } }
export interface Anomaly { uid: string; type: string; severity: string; status: string; evidence: Record<string, number>; note: string | null }
export interface Fill { uid: string; created_at: string; station_name: string; plate_no: string | null; holder_name: string | null; fuel_type: string;
  litres: number; unit_price: number; amount: number; expected_amount: number; currency: string; status: string; identified_by: string;
  pump_ref: string | null; odometer_km: number | null; has_photo: boolean; has_odometer_photo: boolean; pump_by_qr: boolean | null;
  risk: number | null; anomalies: Anomaly[] }
interface CardState { card_uid: string; card_no: string; plate_no: string; holder: string; fuel_types: string[]; currency: string; balance: number | null;
  tank_l: number | null; budget: { period: string | null; amount: number | null; litres: number | null; left_amount: number | null; left_litres: number | null };
  prices: Record<string, number>; tag_bound: boolean; can_fill: boolean; reason: string | null; identified_by: "NFC" | "APP" | "CARD_NO" }
interface FillResult { sale_uid: string; status: "COMPLETED" | "HELD"; anomalies: { type: string }[]; balance: number; currency: string; left_amount: number | null }

export const FUELS = ["DIESEL", "GASOLINE", "LPG", "CNG", "ADBLUE"] as const;
const STATUS_TONE: Record<string, string> = { COMPLETED: "green", PENDING: "wheat", DISPUTED: "red", REVERSED: "outline" };

const loadOverview = (signal: AbortSignal) => api.get<Overview>("/api/fuel/overview", undefined, { signal });

export function FuelHome() {
  const { t, money } = useI18n();
  const state = useLoad(loadOverview);
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="local_gas_station" /> {t("fuel.title")}</h1></div>
      <Loaded state={state}>{(v) => (
        <>
          {!v.enabled && <div className="alert info"><Icon name="info" /><span>{t("fuel.off")}</span></div>}
          <div className="grid cols-3">
            <Stat icon="store" label={t("fuel.stations")} value={v.stations.length} />
            <Stat icon="local_gas_station" label={t("fuel.fillsToday")} value={v.stations.reduce((n, s) => n + s.today.fills, 0)} tone="blue" />
            <Stat icon="warning" label={t("fuel.openAnomalies")} value={v.open_anomalies} tone={v.open_anomalies ? "red" : undefined} />
          </div>
          {v.can.attend && (
            <div className="card row" style={{ justifyContent: "space-between" }}>
              <span>{v.my_stations.length ? t("fuel.attendAt", { names: v.my_stations.map((s) => s.name).join(t("common.listSep")) }) : t("fuel.notAttendant")}</span>
              {v.my_stations.length > 0 && <Link className="btn" to="/fuel/pump"><Icon name="local_gas_station" />{t("fuel.pump")}</Link>}
            </div>
          )}
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("fuel.stations")}</h3>
            {v.stations.length === 0 ? <Empty icon="store" title={t("fuel.noStations")} hint={t("fuel.noStationsHint")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("fuel.station")}</th><th>{t("fuel.prices")}</th><th>{t("fuel.today")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{v.stations.map((s) => (
                  <tr key={s.uid}>
                    <td>{s.name}<div className="small muted mono">{s.code}{s.station ? ` · ${s.station}` : ""}</div></td>
                    <td className="small">{Object.keys(s.prices).length ? Object.entries(s.prices).map(([f, p]) => (
                      <div key={f}>{t(`fuel.type.${f}`)}: {money(p.price, true, p.currency)}</div>)) : "—"}</td>
                    <td className="small">{t("fuel.todayLine", { fills: s.today.fills, litres: s.today.litres })}<div className="muted">{money(s.today.amount)}</div></td>
                    <td><span className={`chip ${s.status === "ACTIVE" ? "green" : "outline"}`}>{t(`fuel.stationStatus.${s.status}`)}</span></td>
                  </tr>))}</tbody>
              </table></div>
            )}
          </div>
        </>
      )}</Loaded>
    </div>
  );
}

// ------------------------------------------------------------------ at the pump
interface Detector { detect(source: HTMLVideoElement | HTMLCanvasElement): Promise<{ rawValue: string }[]> }
const detectorClass = (): (new (o: { formats: string[] }) => Detector) | null =>
  (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => Detector }).BarcodeDetector ?? null;
interface NdefRecord { recordType: string; data?: DataView }
interface NdefReader { scan(o?: { signal?: AbortSignal }): Promise<void>;
  onreading: ((e: { serialNumber: string; message?: { records: NdefRecord[] } }) => void) | null; onreadingerror: (() => void) | null }
const ndefClass = (): (new () => NdefReader) | null => (window as unknown as { NDEFReader?: new () => NdefReader }).NDEFReader ?? null;

/** Reads a QR code from the live camera: the driver's code (F1...) or a pump's sticker (FP1...). */
export function QrCamera({ onRead, prefix }: { onRead: (code: string) => void; prefix: string }) {
  const { t } = useI18n();
  const video = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    const Klass = detectorClass();
    if (!Klass || !navigator.mediaDevices) { setError(true); return; }
    const detector = new Klass({ formats: ["qr_code"] });
    let stream: MediaStream | null = null, timer = 0, stopped = false;
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } }).then((s) => {
      if (stopped) { s.getTracks().forEach((tr) => tr.stop()); return; }
      stream = s;
      if (video.current) { video.current.srcObject = s; void video.current.play(); }
      const tick = async () => {
        if (stopped || !video.current) return;
        try {
          const code = (await detector.detect(video.current)).map((f) => f.rawValue.trim())
            .find((v) => v.startsWith(prefix) && (prefix !== "F1" || !v.startsWith("FP1")));
          if (code) { onRead(code); return; }
        } catch { /* the frame was not ready */ }
        timer = window.setTimeout(tick, 250);
      };
      void tick();
    }).catch(() => setError(true));
    return () => { stopped = true; window.clearTimeout(timer); stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [onRead, prefix]);
  if (error) return <div className="alert info"><Icon name="info" /><span>{t("fuel.noCamera")}</span></div>;
  return <video ref={video} muted playsInline aria-label={t("fuel.camera")} style={{ width: "100%", maxHeight: 320, borderRadius: 16, background: "#000", objectFit: "cover" }} />;
}

/** A photo taken from the live camera, never a file from the phone: the frame is drawn and sent as a JPEG with no
 *  metadata. The server refuses a picture that carries a camera app's metadata and flags one seen before. */
export function LiveShot({ label, shot, onShot }: { label: string; shot: Blob | null; onShot: (b: Blob | null) => void }) {
  const { t } = useI18n();
  const video = useRef<HTMLVideoElement>(null);
  const [on, setOn] = useState(false);
  const [error, setError] = useState(false);
  const [preview, setPreview] = useState("");
  useEffect(() => {
    if (!shot) { setPreview(""); return; }
    const url = URL.createObjectURL(shot); setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [shot]);
  useEffect(() => {
    if (!on) return;
    if (!navigator.mediaDevices) { setError(true); setOn(false); return; }
    let stream: MediaStream | null = null, stopped = false;
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1600 } } }).then((s) => {
      if (stopped) { s.getTracks().forEach((tr) => tr.stop()); return; }
      stream = s;
      if (video.current) { video.current.srcObject = s; void video.current.play(); }
    }).catch(() => { setError(true); setOn(false); });
    return () => { stopped = true; stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [on]);
  const take = () => {
    const v = video.current;
    if (!v || !v.videoWidth) return;
    const canvas = document.createElement("canvas");
    canvas.width = v.videoWidth; canvas.height = v.videoHeight;
    canvas.getContext("2d")?.drawImage(v, 0, 0);
    canvas.toBlob((b) => { if (b) { onShot(b); setOn(false); } }, "image/jpeg", 0.85);
  };
  return (
    <div className="stack" style={{ gap: 6 }}>
      <span className="small" style={{ fontWeight: 600 }}>{label} <span aria-hidden="true">*</span></span>
      {error && <div className="alert info"><Icon name="info" /><span>{t("fuel.noCamera")}</span></div>}
      {on ? (
        <>
          <video ref={video} muted playsInline aria-label={label} style={{ width: "100%", maxHeight: 360, borderRadius: 16, background: "#000", objectFit: "cover" }} />
          <div className="row" style={{ gap: 8 }}>
            <button type="button" className="btn" onClick={take}><Icon name="photo_camera" />{t("fuel.shoot")}</button>
            <button type="button" className="btn text" onClick={() => setOn(false)}>{t("common.cancel")}</button>
          </div>
        </>
      ) : preview ? (
        <div className="row" style={{ gap: 8, alignItems: "center" }}>
          <img src={preview} alt={label} style={{ width: 120, borderRadius: 12 }} />
          <button type="button" className="btn text small" onClick={() => { onShot(null); setOn(true); }}><Icon name="photo_camera" />{t("fuel.retake")}</button>
        </div>
      ) : (
        <button type="button" className="btn tonal" onClick={() => setOn(true)}><Icon name="photo_camera" />{t("fuel.openCamera")}</button>
      )}
    </div>
  );
}

/** Reads one NFC tag (Chrome on Android): a secure tag's signed message (its URL), or a plain tag's serial number. */
export async function readTag(signal: AbortSignal): Promise<{ tag?: string; sun?: string }> {
  const Klass = ndefClass();
  if (!Klass) throw new Error("NFC");
  const reader = new Klass();
  await reader.scan({ signal });
  return await new Promise((resolve, reject) => {
    reader.onreading = (e) => {
      const url = (e.message?.records ?? []).filter((r) => r.recordType === "url" && r.data)
        .map((r) => new TextDecoder().decode(r.data)).find((u) => /picc_data=|[?&]e=/.test(u));
      resolve(url ? { sun: url } : { tag: e.serialNumber });
    };
    reader.onreadingerror = () => reject(new Error("NFC"));
    signal.addEventListener("abort", () => reject(new Error("aborted")));
  });
}

interface Challenge { uid: string; risk: number; factors: Record<string, number>; sampled: boolean; need_pump_qr: boolean;
  need_odometer_photo: boolean; expires_at: string }
interface Identified extends CardState { challenge: Challenge; pumps: { uid: string; pump_no: number }[]; tag_kind: string | null }

export function FuelPump() {
  const { t, money, toMinor } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad(loadOverview);
  const [station, setStation] = useState<string>(() => { try { return localStorage.getItem("masslak.fuel.station") ?? ""; } catch { return ""; } });
  const [mode, setMode] = useState<"" | "camera" | "nfc" | "sticker">("");
  const [typed, setTyped] = useState("");
  const [card, setCard] = useState<Identified | null>(null);
  const [form, setForm] = useState({ fuel: "", litres: "", amount: "", odometer: "", pump: "" });
  const [sticker, setSticker] = useState<string | null>(null);
  const [photo, setPhoto] = useState<Blob | null>(null);
  const [odoPhoto, setOdoPhoto] = useState<Blob | null>(null);
  const [result, setResult] = useState<FillResult | null>(null);
  const [busy, setBusy] = useState(false);
  const nfcAbort = useRef<AbortController | null>(null);
  const stations = state.data?.my_stations ?? [];
  const here = station || (stations.length === 1 ? stations[0].uid : "");

  const pick = (uid: string) => { setStation(uid); try { localStorage.setItem("masslak.fuel.station", uid); } catch { /* private mode */ } };
  const reset = () => { setCard(null); setResult(null); setPhoto(null); setOdoPhoto(null); setSticker(null); setTyped(""); setMode("");
    setForm({ fuel: "", litres: "", amount: "", odometer: "", pump: "" }); };
  const identify = useCallback(async (by: { tag?: string; sun?: string; card_no?: string; code?: string }) => {
    setMode(""); setBusy(true);
    try {
      const s = await api.post<Identified>("/api/fuel/pump/identify", { station_uid: here, ...by });
      setCard(s); setResult(null); setSticker(null); setPhoto(null); setOdoPhoto(null);
      setForm((f) => ({ ...f, fuel: s.fuel_types.find((x) => s.prices[x] != null) ?? s.fuel_types[0] ?? "", pump: "" }));
    } catch (e) { toast(errorText(e)); } finally { setBusy(false); }
  }, [here, toast, errorText]);
  const onCode = useCallback((code: string) => { void identify({ code }); }, [identify]);
  const onSticker = useCallback((code: string) => { setSticker(code); setMode(""); }, []);
  const startNfc = async () => {
    nfcAbort.current?.abort();
    const ctrl = new AbortController(); nfcAbort.current = ctrl;
    setMode("nfc");
    try { await identify(await readTag(ctrl.signal)); }
    catch (e) {
      setMode("");
      if ((e as Error).message === "NFC") toast(t("fuel.noNfc")); else if ((e as Error).message !== "aborted") toast(errorText(e));
    }
  };
  useEffect(() => () => nfcAbort.current?.abort(), []);
  const price = card && form.fuel ? card.prices[form.fuel] : undefined;
  const expected = price != null && form.litres ? Math.round(Number(form.litres) * price) : null;
  const ch = card?.challenge;
  const ready = !!card && !!photo && !!form.fuel && Number(form.litres) > 0 && Number(form.amount) > 0
    && (!ch?.need_pump_qr || !!sticker) && (!ch?.need_odometer_photo || (!!odoPhoto && !!form.odometer));

  const submit = async () => {
    if (!card || !photo || !ch) return;
    const data = new FormData();
    data.append("challenge_uid", ch.uid);
    data.append("fuel_type", form.fuel); data.append("litres", form.litres); data.append("amount", String(toMinor(form.amount, card.currency)));
    if (form.odometer) data.append("odometer_km", form.odometer);
    if (sticker) data.append("pump_code", sticker); else if (form.pump) data.append("pump_uid", form.pump);
    data.append("photo_file", photo, "meter.jpg");
    if (odoPhoto) data.append("odometer_photo", odoPhoto, "odometer.jpg");
    setBusy(true);
    try { setResult(await api.upload<FillResult>("/api/fuel/pump/fill", data)); } catch (e) { toast(errorText(e)); } finally { setBusy(false); }
  };

  return (
    <div className="page stack" style={{ maxWidth: 640 }}>
      <div className="page-head"><h1><Icon name="local_gas_station" /> {t("fuel.pump")}</h1></div>
      <Loaded state={state}>{() => stations.length === 0 ? <Empty icon="local_gas_station" title={t("fuel.notAttendant")} /> : (
        <>
          {stations.length > 1 && (
            <Field label={t("fuel.station")} required>
              <select className="input" value={here} onChange={(e) => { pick(e.target.value); reset(); }}>
                <option value="">{t("fuel.pickStation")}</option>
                {stations.map((s) => <option key={s.uid} value={s.uid}>{s.name} · {s.code}</option>)}
              </select>
            </Field>
          )}
          {here && !card && (
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("fuel.identify")}</h3>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <button className="btn" disabled={busy} onClick={() => void startNfc()}><Icon name="nfc" />{t("fuel.byNfc")}</button>
                <button className="btn tonal" disabled={busy} onClick={() => setMode(mode === "camera" ? "" : "camera")}><Icon name="qr_code_scanner" />{t("fuel.byCode")}</button>
              </div>
              {mode === "nfc" && <div className="alert info"><Icon name="nfc" /><span>{t("fuel.tapCard")}</span>
                <button className="btn text small" onClick={() => { nfcAbort.current?.abort(); setMode(""); }}>{t("common.cancel")}</button></div>}
              {mode === "camera" && <QrCamera onRead={onCode} prefix="F1" />}
              <form className="row" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault();
                const v = typed.trim().toUpperCase(); if (v) void identify(v.startsWith("F1") ? { code: v } : { card_no: v }); }}>
                <div className="grow"><Field label={t("fuel.typeCard")} hint={t("fuel.typeCardHint")}>
                  <input className="input mono ltr" value={typed} maxLength={80} onChange={(e) => setTyped(e.target.value)} autoComplete="off" />
                </Field></div>
                <button className="btn tonal" disabled={busy || !typed.trim()}><Icon name="keyboard" />{t("fuel.find")}</button>
              </form>
            </div>
          )}
          {card && ch && !result && (
            <div className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <div><div style={{ fontSize: 22, fontWeight: 800 }} className="mono ltr">{card.plate_no}</div>
                  <div className="small muted">{card.holder} · {card.card_no} · {t(`fuel.by.${card.identified_by}`)}{card.tag_kind === "SECURE" ? ` · ${t("fuel.secureTag")}` : ""}</div></div>
                <button className="btn text small" onClick={reset}>{t("fuel.another")}</button>
              </div>
              {!card.can_fill ? <div className="alert error"><Icon name="block" /><span>{t(`fuel.reason.${card.reason}`)}</span></div> : (
                <>
                  <div className="grid cols-2 small">
                    <div>{t("fuel.balance")}: <b>{card.balance != null ? money(card.balance, true, card.currency) : "—"}</b></div>
                    <div>{t("fuel.budgetLeft")}: <b>{card.budget.period ? [card.budget.left_amount != null ? money(card.budget.left_amount, true, card.currency) : null,
                      card.budget.left_litres != null ? `${card.budget.left_litres} L` : null].filter(Boolean).join(" · ") + ` (${t(`fuel.period.${card.budget.period}`)})` : t("fuel.noBudget")}</b></div>
                    {card.tank_l != null && <div>{t("fuel.tank")}: {card.tank_l} L</div>}
                  </div>
                  {(ch.need_pump_qr || ch.need_odometer_photo) && (
                    <div className="alert warn"><Icon name="shield" /><span>{t("fuel.checksAsked")}{" "}
                      {[ch.need_pump_qr ? t("fuel.askPumpQr") : null, ch.need_odometer_photo ? t("fuel.askOdometer") : null].filter(Boolean).join(t("common.listSep"))}
                      {ch.sampled ? ` (${t("fuel.sampled")})` : ""}</span></div>
                  )}
                  <div className="grid cols-2">
                    <Field label={t("fuel.fuelType")} required>
                      <select className="input" value={form.fuel} onChange={(e) => setForm({ ...form, fuel: e.target.value })}>
                        {card.fuel_types.map((f) => <option key={f} value={f} disabled={card.prices[f] == null}>{t(`fuel.type.${f}`)}{card.prices[f] != null ? ` · ${money(card.prices[f], true, card.currency)}` : ""}</option>)}
                      </select>
                    </Field>
                    {ch.need_pump_qr || sticker ? (
                      <Field label={t("fuel.pumpNo")} required>
                        {sticker ? <div className="row" style={{ gap: 8 }}><span className="chip green"><Icon name="qr_code_2" size={14} /> {t("fuel.stickerRead")}</span>
                          <button type="button" className="btn text small" onClick={() => { setSticker(null); setMode("sticker"); }}>{t("fuel.retake")}</button></div>
                          : <button type="button" className="btn tonal" onClick={() => setMode("sticker")}><Icon name="qr_code_scanner" />{t("fuel.scanSticker")}</button>}
                      </Field>
                    ) : (
                      <Field label={t("fuel.pumpNo")} optional>
                        <div className="row" style={{ gap: 4 }}>
                          <select className="input" value={form.pump} onChange={(e) => setForm({ ...form, pump: e.target.value })}>
                            <option value="">—</option>
                            {card.pumps.map((p) => <option key={p.uid} value={p.uid}>{p.pump_no}</option>)}
                          </select>
                          {card.pumps.length > 0 && <button type="button" className="btn text small" aria-label={t("fuel.scanSticker")} onClick={() => setMode("sticker")}><Icon name="qr_code_scanner" /></button>}
                        </div>
                      </Field>
                    )}
                    <Field label={t("fuel.litres")} required>
                      <input className="input ltr" inputMode="decimal" value={form.litres} onChange={(e) => setForm({ ...form, litres: e.target.value })} />
                    </Field>
                    <Field label={t("fuel.meterAmount")} required hint={expected != null ? t("fuel.expected", { amount: money(expected, true, card.currency) }) : undefined}>
                      <input className="input ltr" inputMode="decimal" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} />
                    </Field>
                    <Field label={t("fuel.odometer")} required={ch.need_odometer_photo} optional={!ch.need_odometer_photo}>
                      <input className="input ltr" inputMode="numeric" value={form.odometer} onChange={(e) => setForm({ ...form, odometer: e.target.value.replace(/\D/g, "") })} />
                    </Field>
                  </div>
                  {mode === "sticker" && <QrCamera onRead={onSticker} prefix="FP1" />}
                  <LiveShot label={t("fuel.meterPhoto")} shot={photo} onShot={setPhoto} />
                  <p className="small muted" style={{ margin: 0 }}>{t("fuel.meterPhotoHint")}</p>
                  {ch.need_odometer_photo && <LiveShot label={t("fuel.odometerPhoto")} shot={odoPhoto} onShot={setOdoPhoto} />}
                  <button className="btn" disabled={busy || !ready} onClick={() => void submit()}><Icon name="check" />{t("fuel.record")}</button>
                </>
              )}
            </div>
          )}
          {result && (
            <div className={`card stack ${result.status === "HELD" ? "warn" : ""}`}>
              <h3 style={{ margin: 0 }}><Icon name={result.status === "HELD" ? "warning" : "check"} /> {t(`fuel.result.${result.status}`)}</h3>
              {result.anomalies.length > 0 && <ul className="small" style={{ margin: 0 }}>{result.anomalies.map((a) => <li key={a.type}>{t(`fuel.anomaly.${a.type}`)}</li>)}</ul>}
              <div className="small">{t("fuel.balance")}: <b>{money(result.balance, true, result.currency)}</b>
                {result.left_amount != null && <> · {t("fuel.budgetLeft")}: <b>{money(result.left_amount, true, result.currency)}</b></>}</div>
              <button className="btn" onClick={reset}><Icon name="add" />{t("fuel.next")}</button>
            </div>
          )}
        </>
      )}</Loaded>
    </div>
  );
}

// ------------------------------------------------------------------ fills, shared with the carrier's page
export function FillsTable({ fills, photoBase, onDecide, onReverse, onQuery }: { fills: Fill[]; photoBase: string;
  onDecide?: (a: Anomaly, f: Fill) => void; onReverse?: (f: Fill) => void; onQuery?: (f: Fill) => void }) {
  const { t, money, dateTime } = useI18n();
  const [photo, setPhoto] = useState<Fill | null>(null);
  if (fills.length === 0) return <Empty icon="local_gas_station" title={t("fuel.noFills")} />;
  return (
    <>
      <div className="table-wrap" tabIndex={0}><table className="table">
        <thead><tr><th>{t("fuel.when")}</th><th>{t("fuel.vehicle")}</th><th>{t("fuel.fill")}</th><th>{t("fuel.amount")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
        <tbody>{fills.map((f) => (
          <tr key={f.uid}>
            <td className="small">{dateTime(f.created_at)}<div className="muted">{f.station_name}{f.pump_ref ? ` · ${t("fuel.pumpShort", { n: f.pump_ref })}` : ""}
              {f.pump_by_qr && <> · <Icon name="qr_code_2" size={12} /></>}{f.risk != null ? ` · ${t("fuel.riskShort", { n: f.risk })}` : ""}</div></td>
            <td><span className="mono ltr">{f.plate_no ?? "—"}</span><div className="small muted">{f.holder_name}</div></td>
            <td className="small">{f.litres} L {t(`fuel.type.${f.fuel_type}`)}<div className="muted">{t(`fuel.by.${f.identified_by}`)}{f.odometer_km != null ? ` · ${f.odometer_km} km` : ""}</div></td>
            <td className="small">{money(f.amount, true, f.currency)}{f.expected_amount !== f.amount && <div className="muted">{t("fuel.expected", { amount: money(f.expected_amount, true, f.currency) })}</div>}</td>
            <td><span className={`chip ${STATUS_TONE[f.status] ?? "outline"}`}>{t(`fuel.saleStatus.${f.status}`)}</span>
              {f.anomalies.map((a) => (
                <div key={a.uid} className="small">{t(`fuel.anomaly.${a.type}`)} · {t(`fuel.anomalyStatus.${a.status}`)}
                  {a.status === "OPEN" && onDecide && <button className="btn text small" onClick={() => onDecide(a, f)}>{t("fuel.decide")}</button>}</div>))}</td>
            <td><div className="row nowrap" style={{ gap: 4 }}>
              {(f.has_photo || f.has_odometer_photo) && <button className="btn text small" onClick={() => setPhoto(f)}><Icon name="photo_camera" />{t("fuel.photo")}</button>}
              {onReverse && f.status !== "REVERSED" && <button className="btn text small" onClick={() => onReverse(f)}><Icon name="undo" />{t("fuel.reverse")}</button>}
              {onQuery && f.status !== "REVERSED" && <button className="btn text small" onClick={() => onQuery(f)}><Icon name="flag" />{t("fuel.query")}</button>}
            </div></td>
          </tr>))}</tbody>
      </table></div>
      {photo && (
        <Modal title={`${photo.plate_no ?? ""} · ${dateTime(photo.created_at)}`} onClose={() => setPhoto(null)} wide
          actions={<button className="btn" onClick={() => setPhoto(null)}>{t("common.close")}</button>}>
          <div className="grid cols-2">
            {photo.has_photo && <figure style={{ margin: 0 }}><img src={`${photoBase}/${photo.uid}/photo`} alt={t("fuel.meterPhoto")} style={{ maxWidth: "100%", borderRadius: 12 }} />
              <figcaption className="small muted">{t("fuel.meterPhoto")}</figcaption></figure>}
            {photo.has_odometer_photo && <figure style={{ margin: 0 }}><img src={`${photoBase}/${photo.uid}/photo?kind=odometer`} alt={t("fuel.odometerPhoto")} style={{ maxWidth: "100%", borderRadius: 12 }} />
              <figcaption className="small muted">{t("fuel.odometerPhoto")}{photo.odometer_km != null ? ` · ${photo.odometer_km} km` : ""}</figcaption></figure>}
          </div>
          <p className="small">{photo.litres} L × {money(photo.unit_price, true, photo.currency)} = {money(photo.expected_amount, true, photo.currency)} · {t("fuel.meterAmount")}: {money(photo.amount, true, photo.currency)}</p>
        </Modal>
      )}
    </>
  );
}

export function DecideModal({ anomaly, anomalyApi, onClose, onDone }: { anomaly: Anomaly; anomalyApi: string; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const [outcome, setOutcome] = useState<"EXPLAINED" | "CONFIRMED" | "DISMISSED">("EXPLAINED");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <Modal title={t(`fuel.anomaly.${anomaly.type}`)} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
        <button className="btn" disabled={busy || note.trim().length < 3} onClick={async () => {
          setBusy(true);
          try { await api.post(`${anomalyApi}/${anomaly.uid}`, { outcome, note }); toast(t("common.saved")); onDone(); } catch (e) { toast(errorText(e)); } finally { setBusy(false); }
        }}>{t("common.save")}</button></>}>
      <p className="small mono ltr" style={{ marginTop: 0 }}>{Object.entries(anomaly.evidence).map(([k, v]) => `${k}: ${v}`).join(" · ")}</p>
      <Field label={t("fuel.outcome")} required>
        <select className="input" value={outcome} onChange={(e) => setOutcome(e.target.value as typeof outcome)}>
          {(["EXPLAINED", "CONFIRMED", "DISMISSED"] as const).map((o) => <option key={o} value={o}>{t(`fuel.anomalyStatus.${o}`)}</option>)}
        </select>
      </Field>
      <Field label={t("fuel.note")} required>
        <textarea className="input" rows={3} maxLength={300} value={note} onChange={(e) => setNote(e.target.value)} />
      </Field>
    </Modal>
  );
}

export function FuelFills() {
  const { t } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const [status, setStatus] = useState("");
  const state = useLoad((signal) => api.get<{ fills: Fill[] }>("/api/fuel/fills", status ? { status } : undefined, { signal }), [status]);
  const [deciding, setDeciding] = useState<Anomaly | null>(null);
  const [reversing, setReversing] = useState<{ fill: Fill; reason: string } | null>(null);
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="receipt_long" /> {t("fuel.fills")}</h1>
        <select className="input" style={{ maxWidth: 220 }} value={status} onChange={(e) => setStatus(e.target.value)} aria-label={t("common.status")}>
          <option value="">{t("fuel.allStatuses")}</option>
          {["COMPLETED", "PENDING", "DISPUTED", "REVERSED"].map((s) => <option key={s} value={s}>{t(`fuel.saleStatus.${s}`)}</option>)}
        </select></div>
      <div className="card"><Loaded state={state}>{(v) => (
        <FillsTable fills={v.fills} photoBase="/api/fuel/fills" onDecide={(a) => setDeciding(a)} onReverse={(f) => setReversing({ fill: f, reason: "" })} />
      )}</Loaded></div>
      {deciding && <DecideModal anomaly={deciding} anomalyApi="/api/fuel/anomalies" onClose={() => setDeciding(null)} onDone={() => { setDeciding(null); state.reload(); }} />}
      {reversing && (
        <Modal title={t("fuel.reverseTitle", { plate: reversing.fill.plate_no ?? "" })} onClose={() => setReversing(null)}
          actions={<><button className="btn text" onClick={() => setReversing(null)}>{t("common.cancel")}</button>
            <button className="btn danger" disabled={reversing.reason.trim().length < 3} onClick={async () => {
              try { await api.post(`/api/fuel/fills/${reversing.fill.uid}/reverse`, { reason: reversing.reason }); toast(t("fuel.reversed")); setReversing(null); state.reload(); }
              catch (e) { toast(errorText(e)); } }}>{t("fuel.reverse")}</button></>}>
          <p className="small" style={{ marginTop: 0 }}>{t("fuel.reverseHint")}</p>
          <Field label={t("fuel.reasonLabel")} required><input className="input" maxLength={300} value={reversing.reason} onChange={(e) => setReversing({ ...reversing, reason: e.target.value })} /></Field>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ accounts held with the company
interface Entry { kind: string; amount: number; balance_after: number; reference: string | null; note: string | null; created_at: string; plate_no: string | null; station_name: string | null }
interface AccountView { uid: string; currency: string; balance: number; status: string; entries: Entry[] }

export function AccountEntries({ entries, currency }: { entries: Entry[]; currency: string }) {
  const { t, money, dateTime } = useI18n();
  if (entries.length === 0) return <p className="small muted">{t("fuel.noEntries")}</p>;
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("fuel.when")}</th><th>{t("fuel.entry")}</th><th>{t("fuel.amount")}</th><th>{t("fuel.balance")}</th></tr></thead>
      <tbody>{entries.map((e, i) => (
        <tr key={i}>
          <td className="small">{dateTime(e.created_at)}</td>
          <td className="small">{t(`fuel.entryKind.${e.kind}`)}{e.plate_no && <span className="mono ltr"> {e.plate_no}</span>}
            {(e.reference || e.note || e.station_name) && <div className="muted">{[e.station_name, e.reference, e.note].filter(Boolean).join(" · ")}</div>}</td>
          <td className={`small ${e.amount < 0 ? "" : "green-text"}`}>{e.amount > 0 ? "+" : ""}{money(e.amount, true, currency)}</td>
          <td className="small">{money(e.balance_after, true, currency)}</td>
        </tr>))}</tbody>
    </table></div>
  );
}

export function FuelAccounts() {
  const { t, money, dateTime, toMinor } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad(loadOverview);
  const [open, setOpen] = useState<AccountRow | null>(null);
  const detail = useLoad((signal) => (open ? api.get<AccountView>(`/api/fuel/accounts/${open.uid}`, undefined, { signal }) : Promise.resolve(null)), [open?.uid]);
  const [topup, setTopup] = useState({ amount: "", reference: "" });
  const [busy, setBusy] = useState(false);
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="account_balance_wallet" /> {t("fuel.accounts")}</h1></div>
      <p className="small muted" style={{ margin: 0 }}>{t("fuel.accountsHint")}</p>
      <div className="card"><Loaded state={state}>{(v) => v.accounts.length === 0 ? <Empty icon="account_balance_wallet" title={t("fuel.noAccounts")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("fuel.holder")}</th><th>{t("fuel.balance")}</th><th>{t("fuel.cards")}</th><th>{t("fuel.lastTopup")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{v.accounts.map((a) => (
            <tr key={a.uid}>
              <td>{a.holder}</td><td>{money(a.balance, true, a.currency)}</td><td>{a.cards}</td>
              <td className="small">{a.last_topup ? dateTime(a.last_topup) : "—"}</td>
              <td><button className="btn text small" onClick={() => { setOpen(a); setTopup({ amount: "", reference: "" }); }}>{t("fuel.openAccount")}</button></td>
            </tr>))}</tbody>
        </table></div>
      )}</Loaded></div>
      {open && (
        <Modal title={open.holder} onClose={() => setOpen(null)} wide actions={<button className="btn" onClick={() => setOpen(null)}>{t("common.close")}</button>}>
          <form className="row" style={{ gap: 8, alignItems: "end" }} onSubmit={async (e) => {
            e.preventDefault(); setBusy(true);
            try { await api.post(`/api/fuel/accounts/${open.uid}/topup`, { amount: toMinor(topup.amount, open.currency), reference: topup.reference || null });
                  toast(t("fuel.topupDone")); setTopup({ amount: "", reference: "" }); detail.reload(); state.reload(); }
            catch (err) { toast(errorText(err)); } finally { setBusy(false); } }}>
            <div className="grow"><Field label={t("fuel.received")} required><input className="input ltr" inputMode="decimal" value={topup.amount} onChange={(e) => setTopup({ ...topup, amount: e.target.value })} /></Field></div>
            <div className="grow"><Field label={t("fuel.reference")} optional><input className="input" maxLength={80} value={topup.reference} onChange={(e) => setTopup({ ...topup, reference: e.target.value })} /></Field></div>
            <button className="btn" disabled={busy || !(Number(topup.amount) > 0)}><Icon name="add" />{t("fuel.recordTopup")}</button>
          </form>
          <Loaded state={detail}>{(d) => d && <><p className="small">{t("fuel.balance")}: <b>{money(d.balance, true, d.currency)}</b></p><AccountEntries entries={d.entries} currency={d.currency} /></>}</Loaded>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ stations: prices and attendants
interface Person { uid: string; name: string; username: string | null; is_owner: boolean; stations: { station_uid: string; code: string; role: string }[] }

export function FuelStations() {
  const { t, money, toMinor } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad(loadOverview);
  const staff = useLoad((signal) => api.get<{ people: Person[] }>("/api/fuel/staff", undefined, { signal }));
  const [price, setPrice] = useState<{ station: Station; fuel: string; value: string } | null>(null);
  const [assign, setAssign] = useState<{ station: Station; user: string; role: string } | null>(null);
  const [pumps, setPumps] = useState<Station | null>(null);
  const run = async (call: () => Promise<unknown>, done: string) => {
    try { await call(); toast(done); state.reload(); staff.reload(); return true; } catch (e) { toast(errorText(e)); return false; }
  };
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="store" /> {t("fuel.stations")}</h1></div>
      <Loaded state={state}>{(v) => v.stations.length === 0 ? <Empty icon="store" title={t("fuel.noStations")} hint={t("fuel.noStationsHint")} /> : (
        <>{v.stations.map((s) => {
          const people = (staff.data?.people ?? []).filter((p) => p.stations.some((x) => x.station_uid === s.uid));
          return (
            <div key={s.uid} className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h3 style={{ margin: 0 }}>{s.name} <span className="small muted mono">{s.code}</span></h3>
                <div className="row" style={{ gap: 4 }}>
                  <button className="btn tonal small" onClick={() => setPrice({ station: s, fuel: "DIESEL", value: "" })}><Icon name="sell" />{t("fuel.setPrice")}</button>
                  <button className="btn tonal small" onClick={() => setAssign({ station: s, user: "", role: "ATTENDANT" })}><Icon name="group" />{t("fuel.assign")}</button>
                  <button className="btn tonal small" onClick={() => setPumps(s)}><Icon name="qr_code_2" />{t("fuel.pumpsStickers")}</button>
                </div>
              </div>
              <div className="small">{Object.keys(s.prices).length ? Object.entries(s.prices).map(([f, p]) => `${t(`fuel.type.${f}`)}: ${money(p.price, true, p.currency)}`).join(" · ") : t("fuel.noPrices")}</div>
              <div className="small">{t("fuel.attendants")}: {people.length ? people.map((p) => (
                <span key={p.uid} className="chip outline" style={{ marginInlineEnd: 4 }}>{p.name} · {t(`fuel.role.${p.stations.find((x) => x.station_uid === s.uid)?.role}`)}
                  <button className="btn text small" aria-label={t("common.remove")} onClick={() => void run(() => api.del(`/api/fuel/stations/${s.uid}/attendants/${p.uid}`), t("common.saved"))}>×</button></span>))
                : t("fuel.noAttendants")}</div>
            </div>
          );
        })}</>
      )}</Loaded>
      {price && (
        <Modal title={t("fuel.setPriceTitle", { name: price.station.name })} onClose={() => setPrice(null)}
          actions={<><button className="btn text" onClick={() => setPrice(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!(Number(price.value) > 0)} onClick={async () => {
              if (await run(() => api.post(`/api/fuel/stations/${price.station.uid}/prices`, { fuel_type: price.fuel, unit_price: toMinor(price.value) }), t("common.saved"))) setPrice(null); }}>{t("common.save")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.fuelType")} required>
              <select className="input" value={price.fuel} onChange={(e) => setPrice({ ...price, fuel: e.target.value })}>{FUELS.map((f) => <option key={f} value={f}>{t(`fuel.type.${f}`)}</option>)}</select>
            </Field>
            <Field label={t("fuel.pricePerLitre")} required><input className="input ltr" inputMode="decimal" value={price.value} onChange={(e) => setPrice({ ...price, value: e.target.value })} /></Field>
          </div>
          <p className="small muted">{t("fuel.priceHint")}</p>
        </Modal>
      )}
      {pumps && <PumpStickers station={pumps} onClose={() => setPumps(null)} />}
      {assign && (
        <Modal title={t("fuel.assignTitle", { name: assign.station.name })} onClose={() => setAssign(null)}
          actions={<><button className="btn text" onClick={() => setAssign(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!assign.user} onClick={async () => {
              if (await run(() => api.post(`/api/fuel/stations/${assign.station.uid}/attendants`, { user_uid: assign.user, role: assign.role }), t("common.saved"))) setAssign(null); }}>{t("common.save")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.person")} required>
              <select className="input" value={assign.user} onChange={(e) => setAssign({ ...assign, user: e.target.value })}>
                <option value="">{t("fuel.pickPerson")}</option>
                {(staff.data?.people ?? []).map((p) => <option key={p.uid} value={p.uid}>{p.name}{p.username ? ` (${p.username})` : ""}</option>)}
              </select>
            </Field>
            <Field label={t("fuel.roleAt")} required>
              <select className="input" value={assign.role} onChange={(e) => setAssign({ ...assign, role: e.target.value })}>
                {["ATTENDANT", "CASHIER", "MANAGER"].map((r) => <option key={r} value={r}>{t(`fuel.role.${r}`)}</option>)}
              </select>
            </Field>
          </div>
          <p className="small muted">{t("fuel.assignHint")}</p>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ pumps: their QR stickers and the station's pump controller
interface Pump { uid: string; pump_no: number; qr_version: number; status: string; code: string | null }

function PumpStickers({ station, onClose }: { station: Station; onClose: () => void }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => api.get<{ pumps: Pump[]; controller_since: string | null }>(`/api/fuel/stations/${station.uid}/pumps`, undefined, { signal }), [station.uid]);
  const [images, setImages] = useState<Record<string, string>>({});
  const [key, setKey] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    void Promise.all((state.data?.pumps ?? []).filter((p) => p.code).map(async (p) => [p.uid, await QRCode.toDataURL(p.code as string, { margin: 1, width: 220 })] as const))
      .then((pairs) => { if (live) setImages(Object.fromEntries(pairs)); });
    return () => { live = false; };
  }, [state.data]);
  const act = async (call: () => Promise<unknown>) => { try { await call(); state.reload(); } catch (e) { toast(errorText(e)); } };
  return (
    <Modal title={t("fuel.pumpsOf", { name: station.name })} onClose={onClose} wide
      actions={<><button className="btn text" onClick={() => window.print()}><Icon name="print" />{t("fuel.printStickers")}</button>
        <button className="btn" onClick={onClose}>{t("common.close")}</button></>}>
      <p className="small muted" style={{ marginTop: 0 }}>{t("fuel.stickersHint")}</p>
      <Loaded state={state}>{(v) => (
        <>
          <div className="grid cols-3">{v.pumps.filter((p) => p.status === "ACTIVE").map((p) => (
            <div key={p.uid} className="card stack" style={{ alignItems: "center", textAlign: "center" }}>
              <b>{station.name} · {t("fuel.pumpShort", { n: p.pump_no })}</b>
              {images[p.uid] && <img src={images[p.uid]} alt={t("fuel.pumpShort", { n: p.pump_no })} width={180} height={180} />}
              <span className="small muted">v{p.qr_version}</span>
              <button className="btn text small" onClick={() => void act(() => api.post(`/api/fuel/pumps/${p.uid}/new-qr`))}><Icon name="autorenew" />{t("fuel.newSticker")}</button>
            </div>))}</div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("fuel.controller")}</h3>
            <p className="small" style={{ margin: 0 }}>{v.controller_since ? t("fuel.controllerOn", { since: dateTime(v.controller_since) }) : t("fuel.controllerOff")}</p>
            <p className="small muted" style={{ margin: 0 }}>{t("fuel.controllerHint")}</p>
            {key && <div className="alert info"><Icon name="key" /><span className="mono ltr" style={{ wordBreak: "break-all" }}>{key}</span></div>}
            <div className="row" style={{ gap: 8 }}>
              <button className="btn tonal small" onClick={() => void act(async () => setKey((await api.post<{ key: string }>(`/api/fuel/stations/${station.uid}/controller`)).key))}>
                <Icon name="key" />{t("fuel.controllerKey")}</button>
              {v.controller_since && <button className="btn text small" onClick={() => void act(async () => { await api.del(`/api/fuel/stations/${station.uid}/controller`); setKey(null); })}>{t("fuel.controllerClear")}</button>}
            </div>
          </div>
        </>
      )}</Loaded>
    </Modal>
  );
}

// ------------------------------------------------------------------ anomalies
export interface AnomalyRow extends Anomaly { sale_uid: string; plate_no: string | null; station_name: string; holder_name: string | null;
  litres: number; amount: number; currency: string; filled_at: string }

export function AnomaliesList({ anomalyApi }: { anomalyApi: string }) {
  const { t, money, dateTime } = useI18n();
  const [status, setStatus] = useState("OPEN");
  const state = useLoad((signal) => api.get<{ anomalies: AnomalyRow[] }>(anomalyApi, { status }, { signal }), [status, anomalyApi]);
  const [deciding, setDeciding] = useState<Anomaly | null>(null);
  return (
    <div className="card stack">
      <select className="input" style={{ maxWidth: 220 }} value={status} onChange={(e) => setStatus(e.target.value)} aria-label={t("common.status")}>
        {["OPEN", "EXPLAINED", "CONFIRMED", "DISMISSED"].map((s) => <option key={s} value={s}>{t(`fuel.anomalyStatus.${s}`)}</option>)}
      </select>
      <Loaded state={state}>{(v) => v.anomalies.length === 0 ? <Empty icon="check" title={t("fuel.noAnomalies")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("fuel.when")}</th><th>{t("fuel.vehicle")}</th><th>{t("fuel.found")}</th><th>{t("fuel.amount")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{v.anomalies.map((a) => (
            <tr key={a.uid}>
              <td className="small">{dateTime(a.filled_at)}<div className="muted">{a.station_name}</div></td>
              <td><span className="mono ltr">{a.plate_no ?? "—"}</span><div className="small muted">{a.holder_name}</div></td>
              <td className="small"><span className={`chip ${a.severity === "HIGH" ? "red" : "wheat"}`}>{t(`fuel.anomaly.${a.type}`)}</span>
                <div className="muted mono ltr">{Object.entries(a.evidence).map(([k, x]) => `${k}: ${x}`).join(" · ")}</div>{a.note && <div>{a.note}</div>}</td>
              <td className="small">{a.litres} L · {money(a.amount, true, a.currency)}</td>
              <td>{a.status === "OPEN" && <button className="btn text small" onClick={() => setDeciding(a)}>{t("fuel.decide")}</button>}</td>
            </tr>))}</tbody>
        </table></div>
      )}</Loaded>
      {deciding && <DecideModal anomaly={deciding} anomalyApi={anomalyApi} onClose={() => setDeciding(null)} onDone={() => { setDeciding(null); state.reload(); }} />}
    </div>
  );
}

export function FuelAnomalies() {
  const { t } = useI18n();
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="warning" /> {t("fuel.anomalies")}</h1></div>
      <p className="small muted" style={{ margin: 0 }}>{t("fuel.anomaliesHint")}</p>
      <AnomaliesList anomalyApi="/api/fuel/anomalies" />
    </div>
  );
}
