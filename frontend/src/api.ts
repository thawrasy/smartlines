// API client. The session lives in an HttpOnly cookie; every request carries the client header the
// server requires on state-changing calls (a CSRF defence alongside SameSite=Strict).
export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  const form = body instanceof FormData;   // file uploads: the browser sets the multipart boundary itself
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: { "X-Masslak-Client": "web", ...(body !== undefined && !form ? { "Content-Type": "application/json" } : {}) },
      body: body === undefined ? undefined : form ? body : JSON.stringify(body),
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
  put: <T>(path: string, body: unknown = {}) => request<T>("PUT", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
  upload: <T>(path: string, form: FormData) => request<T>("POST", path, form),
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
          service_type: string; trip_type?: string; departure_at: string; arrival_at: string; carrier_name: string; carrier_code: string | null };
  stops: TripStop[]; price: number; from_seq: number; to_seq: number; seats: { seat_no: number; free: boolean }[];
  /** The vehicle's real layout, frozen when the trip was created (null for trips created before layouts existed). */
  seat_map: import("./components/SeatGrid").SeatMapData | null;
  /** Who counts as an adult, a child or an infant on this carrier, and what each pays on this segment (4.19). */
  categories: CategoryFare[];
  family_offers: FamilyOfferBrief[];
}

export type Category = "ADULT" | "CHILD" | "INFANT";
export interface CategoryFare {
  category: Category; min_age: number; max_age: number | null; seat_required: boolean; needs_adult: boolean;
  max_per_adult: number | null; fare: number;
}
export interface FamilyOfferBrief {
  code: string; name: string; applies_to: string; min_members: number; min_adults: number; min_minors: number;
  discount_type: "PCT" | "FIXED_PER_MEMBER"; discount_value: number; max_discount: number | null;
}

/** POST /api/bookings/quote: the fare of every traveller and any family offer, before paying. */
export interface Quote {
  fare_per_passenger: number; passengers: number; fares_gross: number; fares_total: number; platform_fee: number; total: number;
  lines: { passenger: number; category: Category; seat: boolean; fare: number; list_fare?: number }[];
  family_offer?: { code: string; name: string; discount: number };
}

export interface FamilyMember {
  uid: string; relation: string; first_name: string; father_name: string | null; grandfather_name: string | null; last_name: string;
  full_name: string; nationality: string; birth_date: string; age: number; gender: "M" | "F" | null; id_type: string | null;
  id_last4: string | null; passport_expiry: string | null; mobile: string | null;
  account_status: "NONE" | "INVITED" | "PENDING" | "LINKED" | "REVOKED"; funding: "OWN" | "HEAD_WALLET" | "FAMILY_ACCOUNT";
  per_trip_limit: number | null; daily_limit: number | null; monthly_limit: number | null;
}
export interface FamilyRule {
  uid: string; rule_type: "TIME_WINDOW" | "ROUTE" | "LINE"; days: number[] | null; start_time: string | null; end_time: string | null;
  from_city?: string | null; to_city?: string | null; both_ways: boolean; line_id: number | null; line?: string | null;
}
export interface FamilyView {
  role: "HEAD" | "MEMBER" | null;
  family?: { uid: string; name: string };
  account?: { balance: number; currency: string };
  members?: FamilyMember[];
  requests?: { uid: string; status: string; device_label: string | null; submitted_at: string | null; expires_at: string; member_uid: string; member: string }[];
  me?: FamilyMember; rules?: FamilyRule[];
}

export interface FareBrand {
  code: string; name: string; factor: number;
  rules: { refundable: boolean; refund: [number, number][]; changeable: boolean; bags_included: number; kg_per_piece: number; change_fee_pct?: number };
}

export interface Ticket {
  uid: string; ticket_no: string; seat_no: number | null; seat_label: string | null; status: string; fare_brand_code: string; total_amount: number;
  /** Full name as on the identity document; the ticket prints ticket_name (first and last name). */
  full_name: string; ticket_name: string; from_station: string; from_code: string; from_city: string; departs_at: string;
  to_station: string; to_code: string; to_city: string; arrives_at: string;
}

export interface BookingDetail {
  booking: { booking_ref: string; status: string; total_amount: number; currency: string; trip_no: string; carrier_name: string;
             created_at: string; verify_token: string; contact_mobile?: string; commission?: number | null;
             // how it is paid (1056): a reserved booking waits for its money until pay_by; the counter view says what it may do
             pay_option?: string | null; pay_by?: string | null; pay_method?: string; counter_sale?: boolean; collectable?: boolean;
             refundable_here?: boolean;
             price_breakdown: { fare_per_passenger: number; passengers: number; fares_total: number; platform_fee: number; total: number; fare_brand: string;
                                lines?: Quote["lines"]; family_offer?: Quote["family_offer"] } };
  tickets: Ticket[];
}

// A way of paying that platform administration has opened for this channel (1056)
export type PayWith = "WALLET" | "PAY_LATER" | "CARD" | "INSTALLMENT" | "FINANCING";
export interface BookingOption {
  code: PayWith; min_amount: number; max_amount: number | null; hold_hours?: number; cutoff_minutes?: number;
  providers?: { code: string; name: string; min_amount: number; max_amount: number }[]; trip_types?: string[];
}

export interface BookingRow {
  booking_ref: string; status: string; total_amount: number; currency: string; created_at: string; trip_no: string; carrier_name: string;
  journey: { from_station: string; from_code: string; from_city: string; departs_at: string; to_station: string; to_code: string; to_city: string; arrives_at: string } | null;
}
