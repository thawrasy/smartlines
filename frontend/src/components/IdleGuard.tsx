import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../api";
import { useAuth } from "../auth";
import { useI18n } from "../i18n";
import { Modal } from "./ui";

const EVENTS = ["pointerdown", "keydown", "wheel", "touchstart", "scroll"] as const;
const WARN_SECONDS = 60;

/** Signs the user out after the platform's idle period for their portal (owner's note, 1146). A minute before, it asks
 *  whether to stay signed in. Activity on the page that sends no request keeps the server's session alive with a light
 *  call now and then, so the screen and the server agree on when the session ends. */
export function IdleGuard() {
  const { me, logout } = useAuth();
  const { t } = useI18n();
  const nav = useNavigate();
  const last = useRef(Date.now());
  const touched = useRef(Date.now());
  const [left, setLeft] = useState<number | null>(null);
  const minutes = me?.idle_minutes ?? 0;

  useEffect(() => {
    if (!me || !minutes) return;
    const limit = minutes * 60_000;
    last.current = touched.current = Date.now();
    const active = () => {
      last.current = Date.now();
      if (Date.now() - touched.current > limit / 3) {            // tell the server now and then that the user is here
        touched.current = Date.now();
        void api.get("/api/auth/me").catch(() => {});
      }
    };
    EVENTS.forEach((e) => window.addEventListener(e, active, { passive: true }));
    const tick = window.setInterval(async () => {
      const idle = Date.now() - last.current;
      if (idle >= limit) {
        window.clearInterval(tick);
        setLeft(null);
        await logout().catch(() => {});
        nav(`/login?portal=${me.portal}&idle=1`, { replace: true });
      } else if (idle >= limit - WARN_SECONDS * 1000) {
        setLeft(Math.ceil((limit - idle) / 1000));
      } else {
        setLeft(null);
      }
    }, 1000);
    return () => { EVENTS.forEach((e) => window.removeEventListener(e, active)); window.clearInterval(tick); };
  }, [me, minutes, logout, nav]);

  if (left === null) return null;
  const stay = () => { last.current = touched.current = Date.now(); setLeft(null); void api.get("/api/auth/me").catch(() => {}); };
  return (
    <Modal title={t("idle.title")} onClose={stay} actions={<>
      <button className="btn text" onClick={() => { last.current = 0; }}>{t("idle.signOut")}</button>
      <button className="btn" onClick={stay}>{t("idle.stay")}</button></>}>
      <p role="timer" aria-live="polite">{t("idle.body", { s: left })}</p>
    </Modal>
  );
}
