import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useAuth } from "../../auth";
import { useI18n } from "../../i18n";
import { LangSwitch } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Logo, useLoad } from "../../components/ui";

// The inspector portal on the web (owner's notes N47 and N48, migrations 1169 and 1178): the same roadside check as the
// officer's phone app, for an officer at a checkpoint desk or with a laptop. The browser's camera reads the movement code
// where the browser can read QR codes; the code can always be typed. The server answers with the vehicle and its movement
// within what the officer's body may see and opens a check; the officer draws a sample of passengers (the server picks
// them) or all of them, and closes the check with its outcome.

interface Body { code: string; kind: string; name_ar: string | null; name_en: string | null; scopes: string[] }
interface Movement { kind: string; ref: string; status: string; departure_at: string | null; origin?: string | null; destination?: string | null;
  seats?: number | null; sold?: number | null; boarded?: number | null; crew: { role: string; name: string; licence_expiry: string | null }[];
  cargo?: { parcels: number; load_kg: number } | null }
interface Scan { check: string; result: string; warnings: string[]; body: string | null; movement: Movement | null; movement_hidden: boolean;
  vehicle: { plate_no: string; type: string; make: string | null; model: string | null; seats: number | null; status: string; carrier: string } }
interface Person { ticket: string; seat: number | null; boarded: boolean; name: string | null }
interface Check { uid: string; created_at: string; status: string; result: string; outcome: string | null; movement_ref: string | null;
  warnings: string[]; plate_no: string; carrier: string; body: string | null }
type Outcome = "CHECKED" | "ISSUE" | "ABSENT";

// MS1 and 13 letters A-Z or digits 2-7, as the server's vehicle_code_shape (spaces and small letters are allowed when typed)
export function vehicleCode(read: string): string | null {
  const code = read.replace(/\s+/g, "").toUpperCase();
  return code.length === 16 && code.startsWith("MS1") && /^[A-Z2-7]+$/.test(code.slice(3)) ? code : null;
}

interface Detector { detect(source: HTMLVideoElement): Promise<{ rawValue: string }[]> }
const detectorClass = (): (new (o: { formats: string[] }) => Detector) | null =>
  (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => Detector }).BarcodeDetector ?? null;

export function InspectorLayout() {
  const { t } = useI18n();
  const { me, logout } = useAuth();
  const nav = useNavigate();
  return (
    <div className="app">
      <div className="app-bar">
        <Logo size={32} />
        <div className="grow"><div style={{ fontWeight: 600 }}>{t("insp.portal")}</div><div className="small muted">{me?.name}</div></div>
        <LangSwitch compact />
        <button className="icon-btn" onClick={async () => { await logout(); nav("/login?portal=INSPECTOR"); }} title={t("nav.logout")}><Icon name="logout" flip /></button>
      </div>
      <Outlet />
      <nav className="navbar">
        <NavLink to="/inspector" end><span className="pill"><Icon name="qr_code_scanner" /></span>{t("insp.scan")}</NavLink>
        <NavLink to="/inspector/checks"><span className="pill"><Icon name="fact_check" /></span>{t("insp.mine")}</NavLink>
      </nav>
    </div>
  );
}

function Camera({ onRead }: { onRead: (code: string) => void }) {
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
          const found = await detector.detect(video.current);
          const code = found.map((f) => vehicleCode(f.rawValue)).find(Boolean);
          if (code) { onRead(code); return; }
        } catch { /* the frame was not ready */ }
        timer = window.setTimeout(tick, 250);
      };
      void tick();
    }).catch(() => setError(true));
    return () => { stopped = true; window.clearTimeout(timer); stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [onRead]);
  if (error) return <div className="alert info"><Icon name="info" /><span>{t("insp.noCamera")}</span></div>;
  return <video ref={video} muted playsInline aria-label={t("insp.camera")} style={{ width: "100%", maxHeight: 360, borderRadius: 16, background: "#000", objectFit: "cover" }} />;
}

export function InspectorScan() {
  const { t, locale, dateTime } = useI18n();
  const bodies = useLoad((signal) => api.get<{ bodies: Body[]; platform: boolean }>("/api/roadside/bodies", undefined, { signal }));
  const [body, setBody] = useState<string>("");
  const [camera, setCamera] = useState(false);
  const [typed, setTyped] = useState("");
  const [scan, setScan] = useState<Scan | null>(null);
  const [people, setPeople] = useState<Person[] | null>(null);
  const [namesHidden, setNamesHidden] = useState(false);
  const [marks, setMarks] = useState<Record<string, Outcome>>({});
  const [note, setNote] = useState("");
  const [closed, setClosed] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const working = useRef(false);

  const list = bodies.data?.bodies ?? [];
  const acting = body || (list.length === 1 ? list[0].code : "");
  const needBody = list.length > 1 && !acting;
  const name = (b: Body) => (locale === "ar" ? b.name_ar : b.name_en) || b.code;

  const read = async (raw: string) => {
    const code = vehicleCode(raw);
    if (!code || working.current || needBody) return;
    working.current = true; setBusy(true); setError(null); setCamera(false);
    try {
      setScan(await api.post<Scan>("/api/roadside/scan", { code, ...(acting ? { body: acting } : {}) }));
      setPeople(null); setMarks({}); setNote(""); setClosed(null); setTyped("");
    } catch (e) { setError(e); } finally { working.current = false; setBusy(false); }
  };
  const draw = async (mode: "SAMPLE" | "FULL") => {
    if (!scan) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ people: Person[]; names_hidden: boolean }>(`/api/roadside/checks/${scan.check}/sample`, { mode });
      setPeople(r.people); setNamesHidden(r.names_hidden);
      setMarks(Object.fromEntries(r.people.map((p) => [p.ticket, "CHECKED" as Outcome])));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const issues = Object.values(marks).some((m) => m !== "CHECKED");
  const close = async (outcome: "CLEAR" | "ISSUES") => {
    if (!scan) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/roadside/checks/${scan.check}/close`, {
        outcome, note: note.trim() || undefined, people: Object.entries(marks).map(([ticket, o]) => ({ ticket, outcome: o })) });
      setClosed(outcome);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const next = () => { setScan(null); setPeople(null); setMarks({}); setNote(""); setClosed(null); };
  const tone = !scan ? "" : scan.result !== "VALID" ? "red" : scan.warnings.length ? "amber" : "green";

  return (
    <div className="app-body stack">
      <h2 style={{ margin: 0 }}>{t("insp.title")}</h2>
      <ErrorBox error={error} />
      <Loaded state={bodies}>{(b) => (
        <>
          {b.bodies.length === 0 && !b.platform && <div className="alert warn"><Icon name="warning" /><span>{t("insp.noBody")}</span></div>}
          {b.bodies.length > 1 && (
            <Field label={t("insp.body")} required>
              <select className="input" value={acting} onChange={(e) => setBody(e.target.value)} required>
                <option value="">{t("insp.pickBody")}</option>
                {b.bodies.map((x) => <option key={x.code} value={x.code}>{name(x)}</option>)}
              </select>
            </Field>
          )}
        </>
      )}</Loaded>
      {!scan ? (
        <div className="card stack">
          {camera ? <Camera onRead={(c) => { void read(c); }} /> : (
            <button className="btn tonal" disabled={needBody || busy} onClick={() => setCamera(true)}><Icon name="qr_code_scanner" />{t("insp.useCamera")}</button>
          )}
          <p className="small muted" style={{ margin: 0 }}>{needBody ? t("insp.pickBody") : t("insp.aim")}</p>
          <form className="row" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault(); void read(typed); }}>
            <div className="grow"><Field label={t("insp.typed")}>
              <input className="input mono ltr" autoCapitalize="characters" autoComplete="off" spellCheck={false} maxLength={24}
                     placeholder="MS1…" value={typed} onChange={(e) => setTyped(e.target.value)} />
            </Field></div>
            <button className="btn" disabled={busy || needBody || !vehicleCode(typed)}>{t("insp.check")}</button>
          </form>
        </div>
      ) : (
        <>
          <div className={`card stack roadside-${tone}`} aria-live="assertive">
            <div className="mono" style={{ fontSize: 28, fontWeight: 800, letterSpacing: 1 }}>{scan.vehicle.plate_no}</div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>{t(`insp.res.${scan.result}`)}</div>
            <div>{scan.vehicle.carrier}{scan.vehicle.seats ? ` · ${t("insp.seats", { n: scan.vehicle.seats })}` : ""}</div>
            {scan.warnings.length > 0 && <ul style={{ margin: 0, paddingInlineStart: 20 }}>{scan.warnings.map((w) => <li key={w} style={{ fontWeight: 600 }}>{t(`insp.warn.${w}`)}</li>)}</ul>}
          </div>
          {scan.movement ? (
            <div className="card stack">
              <strong>{t(`insp.mk.${scan.movement.kind}`)} {scan.movement.ref}</strong>
              {(scan.movement.origin || scan.movement.destination) && <div>{scan.movement.origin ?? "?"} → {scan.movement.destination ?? "?"}</div>}
              {scan.movement.departure_at && <div className="small muted">{t("insp.departs", { at: dateTime(scan.movement.departure_at) })}</div>}
              <div>{t("insp.counts", { sold: scan.movement.sold ?? 0, boarded: scan.movement.boarded ?? 0, seats: scan.movement.seats ?? scan.vehicle.seats ?? 0 })}</div>
              {scan.movement.crew.map((c, i) => <div key={i} className="small">{t(`insp.role.${c.role}`)}: {c.name}{c.licence_expiry ? ` · ${t("insp.licence", { d: c.licence_expiry })}` : ""}</div>)}
              {scan.movement.cargo && <div className="small">{t("insp.cargo", { n: scan.movement.cargo.parcels, kg: scan.movement.cargo.load_kg })}</div>}
            </div>
          ) : scan.movement_hidden ? <div className="alert info"><Icon name="visibility_off" /><span>{t("insp.hidden")}</span></div> : null}
          {closed ? (
            <div className="card stack">
              <div className="alert ok"><Icon name="check_circle" /><span>{t("insp.closed", { outcome: t(`insp.out.${closed}`) })}</span></div>
              <button className="btn" onClick={next}>{t("insp.next")}</button>
            </div>
          ) : (
            <div className="card stack">
              {scan.movement?.kind === "SCHEDULED_TRIP" && !people && (
                <div className="row" style={{ gap: 8 }}>
                  <button className="btn tonal" disabled={busy} onClick={() => draw("SAMPLE")}>{t("insp.sample")}</button>
                  <button className="btn text" disabled={busy} onClick={() => draw("FULL")}>{t("insp.full")}</button>
                </div>
              )}
              {people && (
                <>
                  <p className="small muted" style={{ margin: 0 }}>{namesHidden ? t("insp.namesHidden") : t("insp.drawn", { n: people.length })}</p>
                  <div className="table-wrap" tabIndex={0}><table className="table">
                    <thead><tr><th>{t("insp.seat")}</th><th>{t("insp.passenger")}</th><th>{t("insp.boardedCol")}</th><th>{t("insp.result")}</th></tr></thead>
                    <tbody>{people.map((p) => (
                      <tr key={p.ticket}>
                        <td className="mono">{p.seat ?? "—"}</td><td>{p.name ?? "—"}</td>
                        <td className="small">{p.boarded ? t("insp.boarded") : t("insp.notBoarded")}</td>
                        <td><select className="input" aria-label={t("insp.result")} value={marks[p.ticket] ?? "CHECKED"}
                                    onChange={(e) => setMarks({ ...marks, [p.ticket]: e.target.value as Outcome })}>
                          {(["CHECKED", "ISSUE", "ABSENT"] as const).map((o) => <option key={o} value={o}>{t(`insp.person.${o}`)}</option>)}
                        </select></td>
                      </tr>))}</tbody>
                  </table></div>
                </>
              )}
              <Field label={t("insp.note")} optional>
                <textarea className="input" rows={2} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
              </Field>
              <div className="row" style={{ gap: 8 }}>
                <button className="btn" disabled={busy || issues} onClick={() => close("CLEAR")}>{t("insp.closeClear")}</button>
                <button className="btn tonal" disabled={busy || (!issues && !note.trim())} onClick={() => close("ISSUES")}>{t("insp.closeIssues")}</button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export function InspectorChecks() {
  const { t, dateTime } = useI18n();
  const state = useLoad((signal) => api.get<{ checks: Check[] }>("/api/roadside/checks", undefined, { signal }));
  return (
    <div className="app-body stack">
      <h2 style={{ margin: 0 }}>{t("insp.mine")}</h2>
      <Loaded state={state}>{({ checks }) => checks.length === 0 ? <div className="card"><Empty icon="fact_check" title={t("insp.none")} /></div> : (
        <div className="stack">{checks.map((c) => (
          <div key={c.uid} className="card">
            <div className="row between"><strong className="mono">{c.plate_no}</strong>
              <span className="chip">{t(`insp.res.${c.result}`)}</span></div>
            <div className="small">{c.carrier}{c.movement_ref ? ` · ${c.movement_ref}` : ""}{c.body ? ` · ${c.body}` : ""}</div>
            <div className="small muted">{dateTime(c.created_at)} · {c.outcome ? t(`insp.out.${c.outcome}`) : t("insp.open")}</div>
          </div>))}</div>)}</Loaded>
    </div>
  );
}
