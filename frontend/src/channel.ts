import { useLocation } from "react-router-dom";
import type { Portal } from "./api";

// The booking screens serve two selling channels: passengers on the public site, and agency staff inside the
// agency portal (paths under /agency). The channel decides the API base, the links and who may hold seats;
// the server checks the same rules again.
export interface Channel { agency: boolean; portal: Portal; api: string; link: (path: string) => string }

const PASSENGER: Channel = { agency: false, portal: "PASSENGER", api: "/api", link: (p) => p };
const AGENCY: Channel = { agency: true, portal: "AGENCY", api: "/api/agency", link: (p) => `/agency${p}` };

export function useChannel(): Channel {
  return useLocation().pathname.startsWith("/agency") ? AGENCY : PASSENGER;
}
