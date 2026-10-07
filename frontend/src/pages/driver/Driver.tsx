import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, NavLink, Outlet, useNavigate, useParams } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { LangSwitch } from "../../components/layout";
import { Empty, ErrorBox, Icon, Loaded, Logo, Status, useLoad, useToast } from "../../components/ui";

interface DriverTrip {
  uid: string; trip_no: string; status: string; departure_at: string; arrival_at: string; seats_total: number; plate_no: string | null;
  booked: number; boarded: number;
  stops: { seq: number; kind: string; sched_arr: string; sched_dep: string; actual_arr: string | null; actual_dep: string | null; station_name: string; station_code: string; city_code: string }[];
}
type ScanResult = { result: "OK" | "DUPLICATE" | "INVALID_QR" | "WRONG_TRIP"; seat_no?: number; passenger?: string };

export function DriverLayout() {
  const { t } = useI18n();
  const { me, logout } = useAuth();
  const nav = useNavigate();
  return (
    <div className="app">
      <div className="app-bar">
        <Logo size={32} />
        <div className="grow"><div style={{ fontWeight: 600 }}>{t("nav.driver")}</div><div className="small muted">{me?.name}</div></div>
        <LangSwitch compact />
        <button className="icon-btn" onClick={async () => { await logout(); nav("/login?portal=DRIVER"); }} title={t("nav.logout")}><Icon name="logout" flip /></button>
      </div>
      <Outlet />
      <nav className="navbar">
        <NavLink to="/driver" end><span className="pill"><Icon name="directions_bus" /></span>{t("driver.myTrips")}</NavLink>
      </nav>
    </div>
  );
}

export function DriverTrips() {
  const { t, time, date, city } = useI18n();
  const state = useLoad(() => api.get<{ trips: DriverTrip[] }>("/api/driver/trips"));
  return (
    <div className="app-body">
      <Loaded state={state}>{({ trips }) => trips.length === 0 ? <div className="card"><Empty icon="directions_bus" title={t("driver.none")} /></div> : (
        trips.map((x) => {
          const a = x.stops[0], b = x.stops[x.stops.length - 1];
          return (
            <Link key={x.uid} to={`/driver/trip/${x.uid}`} className="card stack tight" style={{ color: "inherit", textDecoration: "none" }}>
              <div className="row between"><span className="mono small muted">{x.trip_no}</span><Status value={x.status} /></div>
              <div className="row between" style={{ marginTop: 6 }}>
                <div><div style={{ fontSize: 22, fontWeight: 600 }}>{city(a.city_code)}</div><div className="muted">{time(a.sched_dep)}</div></div>
                <Icon name="directions_bus" />
                <div style={{ textAlign: "end" }}><div style={{ fontSize: 22, fontWeight: 600 }}>{city(b.city_code)}</div><div className="muted">{time(b.sched_arr)}</div></div>
              </div>
              <div className="row between small muted">
                <span>{date(x.departure_at)} · <span className="mono">{x.plate_no}</span></span>
                <span>{t("driver.boarded")} {x.boarded}/{x.booked}</span>
              </div>
            </Link>
          );
        })
      )}</Loaded>
    </div>
  );
}

// Camera scanning uses the browser's BarcodeDetector when available (Chrome on Android); otherwise the code is typed in
function CameraScanner({ onCode }: { onCode: (code: string) => void }) {
  const { t } = useI18n();
  const video = useRef<HTMLVideoElement>(null);
  const [on, setOn] = useState(false);
  const [unsupported, setUnsupported] = useState(false);
  const last = useRef<{ code: string; at: number }>({ code: "", at: 0 });

  useEffect(() => {
    if (!on) return;
    const Detector = (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => { detect: (v: HTMLVideoElement) => Promise<{ rawValue: string }[]> } }).BarcodeDetector;
    if (!Detector || !navigator.mediaDevices?.getUserMedia) { setUnsupported(true); setOn(false); return; }
    const detector = new Detector({ formats: ["qr_code"] });
    let stream: MediaStream | null = null, raf = 0, live = true;
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
        if (!live || !video.current) return;
        video.current.srcObject = stream;
        await video.current.play();
        const loop = async () => {
          if (!live || !video.current) return;
          try {
            const codes = await detector.detect(video.current);
            const code = codes[0]?.rawValue;
            if (code && (code !== last.current.code || Date.now() - last.current.at > 4000)) {
              last.current = { code, at: Date.now() };
              onCode(code);
            }
          } catch { /* frame not ready */ }
          raf = window.setTimeout(loop, 250);
        };
        void loop();
      } catch { setUnsupported(true); setOn(false); }
    })();
    return () => { live = false; clearTimeout(raf); stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [on, onCode]);

  return (
    <div className="stack tight">
      {on && <video ref={video} className="camera" muted playsInline />}
      {unsupported && <div className="alert info small">{t("driver.cameraUnsupported")}</div>}
      <button className={`btn ${on ? "outlined" : "tonal"} block large`} onClick={() => setOn(!on)}>
        <Icon name="qr_code_scanner" />{on ? t("driver.stopCamera") : t("driver.camera")}
      </button>
    </div>
  );
}

export function DriverTrip() {
  const { uid = "" } = useParams();
  const { t, time, station, city } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ trips: DriverTrip[] }>("/api/driver/trips").then((r) => r.trips.find((x) => x.uid === uid) ?? null), [uid]);
  const [code, setCode] = useState("");
  const [scan, setScan] = useState<ScanResult | null>(null);
  const [error, setError] = useState<unknown>(null);

  const check = async (token: string) => {
    setError(null);
    try {
      const r = await api.post<ScanResult>("/api/driver/scan", { trip_uid: uid, token });
      setScan(r); setCode("");
      if (navigator.vibrate) navigator.vibrate(r.result === "OK" ? 80 : [80, 60, 80]);
      if (r.result === "OK") state.reload();
    } catch (e) { setError(e); }
  };
  const submit = (e: FormEvent) => { e.preventDefault(); if (code.trim()) void check(code.trim()); };

  const stopEvent = async (seq: number, kind: "ARRIVE" | "DEPART") => {
    setError(null);
    try {
      const r = await api.post<{ delay_min: number }>(`/api/driver/trips/${uid}/stops/${seq}`, { kind });
      toast(r.delay_min > 5 ? t("driver.delay", { n: r.delay_min }) : t("driver.early"));
      state.reload();
    } catch (e) { setError(e); }
  };

  const locationSeq = useRef(Date.now());
  const shareLocation = () => {
    navigator.geolocation?.getCurrentPosition(async (p) => {
      try {
        // the device's own id, counter and time for the position, so a resend is recognised (audit T3-11)
        locationSeq.current += 1;
        await api.post("/api/driver/location", { trip_uid: uid, lat: p.coords.latitude, lng: p.coords.longitude,
          speed_kmh: p.coords.speed != null ? p.coords.speed * 3.6 : null, accuracy_m: p.coords.accuracy,
          event_id: crypto.randomUUID(), seq: locationSeq.current, device_ts: new Date(p.timestamp).toISOString(), provider: "DEVICE" });
        toast(t("driver.locationSent"));
      } catch (e) { setError(e); }
    }, () => {}, { enableHighAccuracy: true, timeout: 10000 });
  };

  return (
    <div className="app-body">
      <Loaded state={state}>{(trip) => !trip ? <Empty title={t("errors.NOT_FOUND")} /> : (
        <>
          <div className="card stack tight">
            <div className="row between"><span className="mono small">{trip.trip_no}</span><Status value={trip.status} /></div>
            <h2>{city(trip.stops[0].city_code)} — {city(trip.stops[trip.stops.length - 1].city_code)}</h2>
            <div className="grid cols-3" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
              <div className="stat" style={{ boxShadow: "none", background: "var(--surface-tint)", padding: 12 }}><div className="label">{t("driver.booked")}</div><div className="value" style={{ fontSize: 22 }}>{trip.booked}</div></div>
              <div className="stat" style={{ boxShadow: "none", background: "var(--surface-tint)", padding: 12 }}><div className="label">{t("driver.boarded")}</div><div className="value" style={{ fontSize: 22 }}>{trip.boarded}</div></div>
              <div className="stat" style={{ boxShadow: "none", background: "var(--surface-tint)", padding: 12 }}><div className="label">{t("common.seats")}</div><div className="value" style={{ fontSize: 22 }}>{trip.seats_total}</div></div>
            </div>
          </div>
          <ErrorBox error={error} />
          <div className="card stack">
            <h3>{t("driver.scanTitle")}</h3>
            {scan && (
              <div className={`scan-result ${scan.result === "OK" ? "ok" : scan.result === "DUPLICATE" ? "warn" : "bad"}`}>
                <Icon name={scan.result === "OK" ? "check_circle" : "cancel"} size={36} />
                <div><div style={{ fontSize: 18 }}>{t(`driver.results.${scan.result}`)}</div>
                  {scan.seat_no && <div className="small">{t("driver.seatOf", { n: scan.seat_no })} · {scan.passenger}</div>}</div>
              </div>
            )}
            <CameraScanner onCode={check} />
            <form onSubmit={submit} className="row nowrap">
              <input className="input ltr mono grow" placeholder={t("driver.manual")} value={code} onChange={(e) => setCode(e.target.value)} />
              <button className="btn">{t("driver.check")}</button>
            </form>
          </div>
          <div className="card">
            <div className="card-title"><h3>{t("driver.stops")}</h3><button className="btn text small" onClick={shareLocation}><Icon name="location_on" size={18} />{t("driver.location")}</button></div>
            <div className="stops">
              {trip.stops.map((s, i) => {
                const last = i === trip.stops.length - 1;
                const done = last ? !!s.actual_arr : !!s.actual_dep;
                const current = !done && (i === 0 || !!trip.stops[i - 1].actual_dep);
                return (
                  <div key={s.seq} className={`stop${done ? " done" : current ? " current" : ""}`}>
                    <span className="dot" />
                    <div>
                      <div style={{ fontWeight: 500 }}>{station(s.station_code, s.station_name)}</div>
                      <div className="small muted">{i > 0 && <>{time(s.sched_arr)}{s.actual_arr && <> · ✓ {time(s.actual_arr)}</>}</>}{!last && <> → {time(s.sched_dep)}{s.actual_dep && <> · ✓ {time(s.actual_dep)}</>}</>}</div>
                    </div>
                    {current && (
                      <div className="row nowrap" style={{ gap: 6 }}>
                        {i > 0 && !s.actual_arr && <button className="btn tonal small" onClick={() => stopEvent(s.seq, "ARRIVE")}>{t("driver.arrive")}</button>}
                        {!last && (i === 0 || s.actual_arr) && <button className="btn small" onClick={() => stopEvent(s.seq, "DEPART")}>{t("driver.depart")}</button>}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        </>
      )}</Loaded>
    </div>
  );
}
