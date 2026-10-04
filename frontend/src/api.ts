// API client. The session lives in an HttpOnly cookie; every request carries the client header the
// server requires on state-changing calls (a CSRF defence alongside SameSite=Strict).
export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: { "X-Masslak-Client": "web", ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError(0, "NETWORK", "network error");
  }
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) {
    const err = data?.error ?? {};
    throw new ApiError(res.status, err.code ?? "SERVER_ERROR", err.message ?? res.statusText, err);
  }
  return data as T;
}

export const api = {
  get: <T>(path: string, params?: Record<string, string | number | undefined>) => {
    const q = params ? new URLSearchParams(Object.entries(params).filter(([, v]) => v !== undefined).map(([k, v]) => [k, String(v)])) : null;
    return request<T>("GET", q && q.toString() ? `${path}?${q}` : path);
  },
  post: <T>(path: string, body: unknown = {}) => request<T>("POST", path, body),
  patch: <T>(path: string, body: unknown = {}) => request<T>("PATCH", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
};

export function newKey() {
  return crypto.randomUUID().replace(/-/g, "");
}

// ---------- Response types ----------
export type Portal = "PASSENGER" | "OPERATOR" | "DRIVER" | "AGENCY" | "PLATFORM";

export interface Me {
  uid: string; name: string; email: string; portal: Portal; locale: string; is_owner: boolean;
  company: { name: string; uid: string; code: string | null } | null;
  roles: string[]; permissions: string[];
  mfa?: { enrolled: boolean; required: boolean };
}

export type MfaStep = "VERIFY" | "ENROLL";

export interface TripResult {
  uid: string; trip_no: string; service_type: string; has_rest: boolean; seats_total: number; currency: string;
  from_seq: number; to_seq: number; departs_at: string; arrives_at: string; from_station: string; to_station: string;
  from_code: string; to_code: string; price: number; carrier_name: string; carrier_code: string | null;
  stops_between: number; seats_left: number; bookable: boolean;
}

export interface TripStop {
  seq: number; kind: string; sched_arr: string; sched_dep: string; fare_from_origin: number; rest_min: number | null;
  station_name: string; station_code: string; city_code: string;
}

export interface TripDetail {
  trip: { uid: string; trip_no: string; status: string; seats_total: number; currency: string; hold_min: number;
          service_type: string; departure_at: string; arrival_at: string; carrier_name: string; carrier_code: string | null };
  stops: TripStop[]; price: number; from_seq: number; to_seq: number; seats: { seat_no: number; free: boolean }[];
}

export interface FareBrand {
  code: string; name: string; factor: number;
  rules: { refundable: boolean; refund: [number, number][]; changeable: boolean; bags_included: number; kg_per_piece: number; change_fee_pct?: number };
}

export interface Ticket {
  uid: string; ticket_no: string; seat_no: number; status: string; fare_brand_code: string; total_amount: number;
  /** Full name as on the identity document; the ticket prints ticket_name (first and last name). */
  full_name: string; ticket_name: string; from_station: string; from_code: string; from_city: string; departs_at: string;
  to_station: string; to_code: string; to_city: string; arrives_at: string;
}

export interface BookingDetail {
  booking: { booking_ref: string; status: string; total_amount: number; currency: string; trip_no: string; carrier_name: string;
             created_at: string; verify_token: string; contact_mobile?: string; commission?: number | null;
             price_breakdown: { fare_per_passenger: number; passengers: number; fares_total: number; platform_fee: number; total: number; fare_brand: string } };
  tickets: Ticket[];
}

export interface BookingRow {
  booking_ref: string; status: string; total_amount: number; currency: string; created_at: string; trip_no: string; carrier_name: string;
  journey: { from_station: string; from_code: string; from_city: string; departs_at: string; to_station: string; to_code: string; to_city: string; arrives_at: string } | null;
}
