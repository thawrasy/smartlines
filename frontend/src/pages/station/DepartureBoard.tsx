import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";

// The station's big screen (build step 4): every departure of the next hours with its bay, and the arrivals, fed by the
// trips and the bays the platform assigns. Public and read-only, without any passenger data; shown only for a station
// whose screens the platform has switched on. Refreshes itself; open it full screen on the station's display. Cities and
// central stations are named in the screen's language from their codes; when the connection drops, the last board
// stays up with the time it was last updated (design review of the station screens, October 2026).

interface BoardRow {
  trip_no: string; carrier: string; at: string; city: string; city_code: string; via: string[]; via_codes?: (string | null)[]; bay: string | null;
  status: "SCHEDULED" | "CHECK_IN" | "BOARDING" | "DEPARTED" | "CANCELLED" | "ARRIVED" | "EXPECTED";
}
interface Board {
  station: { code: string; name: string; time_zone: string }; now: string;
  departures: BoardRow[]; arrivals: BoardRow[];
}

const TONE: Record<string, string> = { BOARDING: "board-go", CHECK_IN: "board-info", DEPARTED: "board-dim", CANCELLED: "board-bad", ARRIVED: "board-dim" };

export default function DepartureBoard() {
  const { uid } = useParams();
  const { t, has, intl, city, station } = useI18n();
  const [board, setBoard] = useState<Board | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [updated, setUpdated] = useState<Date | null>(null);
  const [clock, setClock] = useState(new Date());

  useEffect(() => {
    let live = true;
    const load = () => api.get<Board>(`/api/public/stations/${uid}/board`)
      .then((b) => { if (live) { setBoard(b); setError(null); setUpdated(new Date()); } })
      .catch((e: { code?: string }) => { if (live) setError(e?.code ?? "UNAVAILABLE"); });
    load();
    const refresh = window.setInterval(load, 20000);
    const tick = window.setInterval(() => setClock(new Date()), 1000);
    return () => { live = false; window.clearInterval(refresh); window.clearInterval(tick); };
  }, [uid]);

  const zone = board?.station.time_zone;
  const hm = (iso: string | Date) => new Intl.DateTimeFormat(intl, { timeZone: zone, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(iso));
  const label = (s: string) => (has(`board.status.${s}`) ? t(`board.status.${s}`) : s);
  const place = (code: string | null | undefined, name: string) => (code && city(code) !== code ? city(code) : name);

  if (error && !board) return <div className="board-screen"><div className="board-empty">{t("board.unavailable")}</div></div>;
  if (!board) return <div className="board-screen"><div className="board-empty">…</div></div>;
  const rows = (list: BoardRow[], kind: "dep" | "arr") => list.length === 0
    ? <tr><td colSpan={6} className="board-none">{t(kind === "dep" ? "board.noDepartures" : "board.noArrivals")}</td></tr>
    : list.map((r) => (
      <tr key={`${kind}-${r.trip_no}-${r.at}`} className={TONE[r.status] ?? ""}>
        <td className="board-time">{hm(r.at)}</td>
        <td className="board-city">{place(r.city_code, r.city)}
          {r.via.length > 0 && <span className="board-via">{t("board.via")} {r.via.map((v, i) => place(r.via_codes?.[i], v)).join(" · ")}</span>}</td>
        <td>{r.carrier}</td>
        <td className="board-mono board-narrow-hide">{r.trip_no}</td>
        <td className="board-bay">{r.bay ?? "—"}</td>
        <td className="board-status">{label(r.status)}</td>
      </tr>
    ));
  return (
    <div className="board-screen">
      <header className="board-head">
        <div><div className="board-station">{station(board.station.code, board.station.name)}</div><div className="board-code">{board.station.code}</div></div>
        <div className="board-clock">{hm(clock)}
          {error && updated && <div className="board-offline" role="status">{t("board.offline", { time: hm(updated) })}</div>}</div>
      </header>
      <section>
        <h2 className="board-title">{t("board.departures")}</h2>
        <table className="board-table">
          <thead><tr><th>{t("board.time")}</th><th>{t("board.to")}</th><th>{t("board.carrier")}</th><th className="board-narrow-hide">{t("board.trip")}</th><th>{t("board.bay")}</th><th>{t("board.state")}</th></tr></thead>
          <tbody>{rows(board.departures, "dep")}</tbody>
        </table>
      </section>
      {board.arrivals.length > 0 && (
        <section>
          <h2 className="board-title">{t("board.arrivals")}</h2>
          <table className="board-table">
            <thead><tr><th>{t("board.time")}</th><th>{t("board.from")}</th><th>{t("board.carrier")}</th><th className="board-narrow-hide">{t("board.trip")}</th><th>{t("board.bay")}</th><th>{t("board.state")}</th></tr></thead>
            <tbody>{rows(board.arrivals, "arr")}</tbody>
          </table>
        </section>
      )}
    </div>
  );
}
