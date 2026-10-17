import { useLocation } from "react-router-dom";
import type { Portal } from "./api";

// The booking screens serve four selling channels: passengers on the public site, agency staff inside the agency
// portal (paths under /agency), a carrier's counter staff selling for cash (paths under /carrier/counter), and a
// station's counter selling for the carriers that gave it the BOOKING right (paths under /station, 1110). The channel
// decides the API base, the links and who may hold seats; the server checks the same rules again.
//   staff: sold on someone's behalf (agency or counter): a contact mobile instead of an account, no family register
//   extra: what the channel adds to a hold and a sale (the station counter names its station and counter)
export interface Channel {
  agency: boolean; counter: boolean; staff: boolean; portal: Portal; api: string; link: (path: string) => string;
  funds?: string; extra?: () => Record<string, string | undefined>;
}

const PASSENGER: Channel = { agency: false, counter: false, staff: false, portal: "PASSENGER", api: "/api", link: (p) => p };
const AGENCY: Channel = { agency: true, counter: false, staff: true, portal: "AGENCY", api: "/api/agency", link: (p) => `/agency${p}` };
const COUNTER: Channel = { agency: false, counter: true, staff: true, portal: "OPERATOR", api: "/api/carrier/counter",
                           link: (p) => `/carrier/counter${p}` };

const STATION: Channel = { agency: false, counter: true, staff: true, portal: "STATION", api: "/api/station",
                           link: (p) => `/station${p}`, funds: "/api/station/cash",
                           extra: () => { const s = currentStation(); return { station_uid: s?.station_uid, counter_code: s?.counter_code ?? undefined }; } };

/** The station and counter a station clerk works at, chosen in the station portal and kept on this device. */
export interface StationChoice { station_uid: string; station_code: string; station_name: string; counter_code: string | null }
export function currentStation(): StationChoice | null {
  try { const raw = localStorage.getItem("masslak.station"); return raw ? JSON.parse(raw) as StationChoice : null; } catch { return null; }
}
export function chooseStation(s: StationChoice | null): void {
  try { if (s) localStorage.setItem("masslak.station", JSON.stringify(s)); else localStorage.removeItem("masslak.station"); } catch { /* private mode */ }
}

export function useChannel(): Channel {
  const path = useLocation().pathname;
  if (path.startsWith("/agency")) return AGENCY;
  if (path.startsWith("/station")) return STATION;
  return path.startsWith("/carrier/counter") ? COUNTER : PASSENGER;
}
