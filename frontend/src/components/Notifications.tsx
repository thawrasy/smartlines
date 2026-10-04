import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { Icon } from "./ui";

interface Item { id: number; template_code: string; payload: Record<string, string | number | null>; created_at: string; read_at: string | null }

/** Bell with the signed-in user's notifications. The server stores only a template code and its values; the words
 *  come from the locale files, so each reader sees them in their own language. */
export function NotificationBell() {
  const { t, money, city, dateTime, has } = useI18n();
  const [data, setData] = useState<{ notifications: Item[]; unread: number } | null>(null);
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  const load = () => api.get<{ notifications: Item[]; unread: number }>("/api/notifications").then(setData).catch(() => {});
  useEffect(() => {
    void load();
    const id = window.setInterval(load, 60000);
    return () => clearInterval(id);
  }, []);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);

  const values = (p: Item["payload"]) => {
    const out: Record<string, string | number> = {};
    for (const [k, v] of Object.entries(p)) {
      if (v === null || v === undefined) continue;
      out[k] = k.endsWith("amount") && typeof v === "number" ? money(v) : k.endsWith("_city") ? city(String(v))
        : k === "doc_type" ? t(`documents.types.${v}`) : v;
    }
    return out;
  };
  const openList = async () => {
    setOpen((o) => !o);
    if (!open && data?.unread) {
      await api.post("/api/notifications/read", {}).catch(() => {});
      void load();
    }
  };
  return (
    <div className="bell" ref={box}>
      <button className="icon-btn" onClick={openList} aria-label={t("notify.title")} aria-expanded={open}>
        <Icon name="notifications" />
        {!!data?.unread && <span className="bell-badge">{data.unread > 9 ? "9+" : data.unread}</span>}
      </button>
      {open && (
        <div className="bell-panel card" role="dialog" aria-label={t("notify.title")}>
          <strong>{t("notify.title")}</strong>
          {!data?.notifications.length ? <p className="small muted">{t("notify.none")}</p> : (
            <ul className="bell-list">
              {data.notifications.map((n) => {
                const key = `notify.${n.template_code.replace(/\./g, "_")}`;   // i18n keys cannot contain dots
                return (
                  <li key={n.id} className={n.read_at ? "" : "unread"}>
                    <span style={{ fontWeight: 600 }}>{has(`${key}.title`) ? t(`${key}.title`, values(n.payload)) : n.template_code}</span>
                    {has(`${key}.body`) && <span className="small">{t(`${key}.body`, values(n.payload))}</span>}
                    <span className="small muted">{dateTime(n.created_at)}</span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
