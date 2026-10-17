import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api } from "../../api";
import { LOCALES, translator, type Locale } from "../../i18n";
import { Icon, logoUrl } from "../../components/ui";

// The station's big screen (build step 4): every departure of the next hours with its bay, and the arrivals, fed by the
// trips and the bays the station's administration assigns. Public and read-only, without any passenger data; shown only
// for a station whose screens the platform has switched on. Refreshes itself; open it full screen on the station's
// display. Cities and central stations are named from their codes; when the connection drops, the last board stays up
// with the time it was last updated (design review of the station screens, October 2026).
// The owner's decisions (1114, 1115): the board shows its languages in turn (Arabic and English every 10 seconds unless
// the platform sets otherwise), keeping the layout of the first; each trip shows its short number ("DC 1201") and the
// carrier's logo next to its name; a cancelled trip turns red.
// Separate screens (1120): a screen the station's administration registered opens at /screen/{uid} and shows one kind,
// headed with its word in large type ("Departures", "Arrivals") in the languages shown in turn; /board/{uid} stays the
// board with both, where the platform allows it at the station.

interface BoardRow {
  trip_no: string; trip_code?: string | null; carrier: string; carrier_uid?: string; carrier_logo?: string | null;
  at: string; city: string; city_code: string; via: string[]; via_codes?: (string | null)[]; bay: string | null;
  status: "SCHEDULED" | "CHECK_IN" | "BOARDING" | "DEPARTED" | "CANCELLED" | "ARRIVED" | "EXPECTED";
}
type Kind = "DEPARTURES" | "ARRIVALS" | "COMBINED";
interface Board {
  station: { code: string; name: string; time_zone: string }; now: string;
  languages?: string[]; rotate_seconds?: number; kind?: Kind;
  screen?: { uid: string; kind: Kind; label: string };
  departures: BoardRow[]; arrivals: BoardRow[];
}

const TONE: Record<string, string> = { BOARDING: "board-go", CHECK_IN: "board-info", DEPARTED: "board-dim", CANCELLED: "board-bad", ARRIVED: "board-dim" };

function languagesOf(b: Board | null): Locale[] {
  const wanted = (b?.languages ?? ["ar", "en"]).filter((l): l is Locale => l in LOCALES);
  return wanted.length ? wanted : ["ar"];
}

export default function DepartureBoard({ screen = false }: { screen?: boolean }) {
  const { uid } = useParams();
  const [board, setBoard] = useState<Board | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [updated, setUpdated] = useState<Date | null>(null);
  const [clock, setClock] = useState(new Date());
  const [turn, setTurn] = useState(0);

  useEffect(() => {
    let live = true;
    const load = () => api.get<Board>(screen ? `/api/public/screens/${uid}` : `/api/public/stations/${uid}/board`)
      .then((b) => { if (live) { setBoard(b); setError(null); setUpdated(new Date()); } })
      .catch((e: { code?: string }) => { if (live) setError(e?.code ?? "UNAVAILABLE"); });
    load();
    const refresh = window.setInterval(load, 20000);
    const tick = window.setInterval(() => setClock(new Date()), 1000);
    return () => { live = false; window.clearInterval(refresh); window.clearInterval(tick); };
  }, [uid, screen]);

  const langs = languagesOf(board);
  const seconds = Math.min(60, Math.max(5, board?.rotate_seconds ?? 10));
  useEffect(() => {
    if (langs.length < 2) return;
    const id = window.setInterval(() => setTurn((n) => n + 1), seconds * 1000);
    return () => window.clearInterval(id);
  }, [langs.length, seconds]);

  const layout = translator(langs[0]);                 // the layout stays that of the first language
  const tr = translator(langs[turn % langs.length]);  // the words change in turn
  const { t, has, city, station } = tr;
  const zone = board?.station.time_zone;
  const hm = (iso: string | Date) => new Intl.DateTimeFormat(tr.intl, { timeZone: zone, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(iso));
  const label = (s: string) => (has(`board.status.${s}`) ? t(`board.status.${s}`) : s);
  const place = (code: string | null | undefined, name: string) => (code && city(code) !== code ? city(code) : name);

  if (error && !board) return <div className="board-screen" dir={layout.dir} lang={tr.locale}><div className="board-empty">{t(screen ? "board.screenOff" : "board.unavailable")}</div></div>;
  if (!board) return <div className="board-screen" dir={layout.dir}><div className="board-empty">…</div></div>;
  const carrier = (r: BoardRow) => (
    <span className="board-carrier">
      {r.carrier_logo && r.carrier_uid && (
        <span className="board-logo"><img src={logoUrl(r.carrier_uid, r.carrier_logo)} alt="" /></span>
      )}
      <span>{r.carrier}</span>
    </span>
  );
  const rows = (list: BoardRow[], kind: "dep" | "arr") => list.length === 0
    ? <tr><td colSpan={6} className="board-none">{t(kind === "dep" ? "board.noDepartures" : "board.noArrivals")}</td></tr>
    : list.map((r) => (
      <tr key={`${kind}-${r.trip_no}-${r.at}`} className={TONE[r.status] ?? ""}>
        <td className="board-time">{hm(r.at)}</td>
        <td className="board-city">{place(r.city_code, r.city)}
          {r.via.length > 0 && <span className="board-via">{t("board.via")} {r.via.map((v, i) => place(r.via_codes?.[i], v)).join(" · ")}</span>}</td>
        <td>{carrier(r)}</td>
        <td className="board-trip board-narrow-hide"><bdi dir="ltr">{r.trip_code ?? r.trip_no}</bdi></td>
        <td className="board-bay">{r.bay ?? "—"}</td>
        <td className="board-status">{label(r.status)}</td>
      </tr>
    ));
  const head = (kind: "dep" | "arr") => (
    <thead><tr><th>{t("board.time")}</th><th>{t(kind === "dep" ? "board.to" : "board.from")}</th><th>{t("board.carrier")}</th>
      <th className="board-narrow-hide">{t("board.trip")}</th><th>{t("board.bay")}</th><th>{t("board.state")}</th></tr></thead>
  );
  const kind: Kind = board.kind ?? "COMBINED";
  // one kind on the screen: its word heads it, large, and only its table is shown
  const single = kind !== "COMBINED";
  return (
    <div className={`board-screen${single ? ` board-${kind === "DEPARTURES" ? "dep" : "arr"}` : ""}`} dir={layout.dir} lang={tr.locale}>
      <header className="board-head">
        <div><div className="board-station">{station(board.station.code, board.station.name)}</div>
          <div className="board-code">{board.station.code}{board.screen && <span className="board-place"> · {board.screen.label}</span>}</div></div>
        {single && (
          <h1 key={tr.locale} className="board-kind board-turn">
            <Icon name={kind === "DEPARTURES" ? "flight_takeoff" : "flight_land"} />{t(kind === "DEPARTURES" ? "board.departures" : "board.arrivals")}
          </h1>
        )}
        <div className="board-clock">{hm(clock)}
          {error && updated && <div className="board-offline" role="status">{t("board.offline", { time: hm(updated) })}</div>}</div>
      </header>
      <div key={tr.locale} className="board-turn">
        {kind !== "ARRIVALS" && (
          <section>
            {!single && <h2 className="board-title">{t("board.departures")}</h2>}
            <table className="board-table">{head("dep")}<tbody>{rows(board.departures, "dep")}</tbody></table>
          </section>
        )}
        {(kind === "ARRIVALS" || (kind === "COMBINED" && board.arrivals.length > 0)) && (
          <section>
            {!single && <h2 className="board-title">{t("board.arrivals")}</h2>}
            <table className="board-table">{head("arr")}<tbody>{rows(board.arrivals, "arr")}</tbody></table>
          </section>
        )}
      </div>
    </div>
  );
}
