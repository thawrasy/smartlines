import { useLocation } from "react-router-dom";
import type { Portal } from "./api";

// The booking screens serve three selling channels: passengers on the public site, agency staff inside the agency
// portal (paths under /agency), and a carrier's counter staff selling for cash (paths under /carrier/counter). The
// channel decides the API base, the links and who may hold seats; the server checks the same rules again.
//   staff: sold on someone's behalf (agency or counter): a contact mobile instead of an account, no family register
export interface Channel { agency: boolean; counter: boolean; staff: boolean; portal: Portal; api: string; link: (path: string) => string }

const PASSENGER: Channel = { agency: false, counter: false, staff: false, portal: "PASSENGER", api: "/api", link: (p) => p };
const AGENCY: Channel = { agency: true, counter: false, staff: true, portal: "AGENCY", api: "/api/agency", link: (p) => `/agency${p}` };
const COUNTER: Channel = { agency: false, counter: true, staff: true, portal: "OPERATOR", api: "/api/carrier/counter",
                           link: (p) => `/carrier/counter${p}` };

export function useChannel(): Channel {
  const path = useLocation().pathname;
  if (path.startsWith("/agency")) return AGENCY;
  return path.startsWith("/carrier/counter") ? COUNTER : PASSENGER;
}
