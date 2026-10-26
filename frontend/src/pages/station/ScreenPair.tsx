import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../../api";
import { LOCALES, translator, type Locale } from "../../i18n";

// Pairing a display (1129): a display opens /screen/pair and shows a short code for ten minutes; the station's
// administration enters the code against one of its screens, and the display opens that screen's board. The display
// asks with a secret only it holds; the secret stays in this tab only. No one signs in on the display.

interface Started { code: string; token: string; expires_at: string }
interface State { status: "WAITING" | "PAIRED" | "EXPIRED" | "UNKNOWN"; screen_uid?: string }

const KEY = "masslak.screenPairing";
const LANGS: Locale[] = (["ar", "en"] as Locale[]).filter((l) => l in LOCALES);

function stored(): Started | null {
  try {
    const raw = window.sessionStorage.getItem(KEY);
    const s = raw ? (JSON.parse(raw) as Started) : null;
    return s && new Date(s.expires_at).getTime() > Date.now() ? s : null;
  } catch { return null; }
}

export default function ScreenPair() {
  const navigate = useNavigate();
  const [pairing, setPairing] = useState<Started | null>(stored);
  const [failed, setFailed] = useState(false);
  const [turn, setTurn] = useState(0);

  // a code, kept for its ten minutes across a reload of the page
  useEffect(() => {
    if (pairing) return;
    let live = true;
    api.post<Started>("/api/public/screens/pair")
      .then((s) => { if (!live) return; try { window.sessionStorage.setItem(KEY, JSON.stringify(s)); } catch { /* the tab keeps it */ } setPairing(s); setFailed(false); })
      .catch(() => { if (live) { setFailed(true); window.setTimeout(() => live && setFailed(false), 15000); } });
    return () => { live = false; };
  }, [pairing, failed]);

  // ask every few seconds whether the administration gave it a screen
  useEffect(() => {
    if (!pairing) return;
    let live = true;
    const ask = () => api.post<State>("/api/public/screens/pair/state", { token: pairing.token }).then((s) => {
      if (!live) return;
      if (s.status === "PAIRED" && s.screen_uid) {
        try { window.sessionStorage.removeItem(KEY); } catch { /* nothing kept */ }
        navigate(`/screen/${s.screen_uid}`, { replace: true });
      } else if (s.status !== "WAITING") {
        try { window.sessionStorage.removeItem(KEY); } catch { /* nothing kept */ }
        setPairing(null);
      }
    }).catch(() => undefined);
    const id = window.setInterval(ask, 4000);
    return () => { live = false; window.clearInterval(id); };
  }, [pairing, navigate]);

  useEffect(() => {
    const id = window.setInterval(() => setTurn((n) => n + 1), 10000);
    return () => window.clearInterval(id);
  }, []);

  const layout = translator(LANGS[0] ?? "ar");
  const tr = translator(LANGS[turn % LANGS.length] ?? "ar");
  return (
    <div className="board-screen" dir={layout.dir} lang={tr.locale}>
      <div className="board-empty" style={{ display: "flex", flexDirection: "column", gap: 24, alignItems: "center" }}>
        <div>{tr.t("pair.title")}</div>
        {pairing ? (
          <>
            <div className="mono ltr" aria-label={tr.t("pair.code")} style={{ fontSize: "min(13vw, 12rem)", letterSpacing: "0.1em", fontWeight: 700, maxWidth: "100%", overflowWrap: "anywhere" }}>{pairing.code}</div>
            <div style={{ fontSize: "1.4rem", maxWidth: 900, textAlign: "center" }}>{tr.t("pair.hint")}</div>
          </>
        ) : <div style={{ fontSize: "1.4rem" }}>{tr.t(failed ? "pair.failed" : "pair.waiting")}</div>}
      </div>
    </div>
  );
}
