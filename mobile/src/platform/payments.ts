// Ways of paying a booking (1056) for the passenger app: the options platform administration has opened on the APP
// channel, and the provider's page a reservation is paid on (review stage C8).
import { Linking } from "react-native";
import { api } from "./api";
import { API_URL } from "./config";

export type PayWith = "WALLET" | "PAY_LATER" | "CARD" | "INSTALLMENT" | "FINANCING";
export interface BookingOption { code: PayWith; min_amount: number; max_amount: number | null; hold_hours?: number; cutoff_minutes?: number;
                                 trip_types?: string[]; providers?: { code: string; name: string }[] }

export const bookingOptions = () => api.get<{ options: BookingOption[] }>("/api/payments/booking-options").then((r) => r.options);

/** An option is offered when the amount is within its limits and, for financing, the trip is of a kind it covers. */
export const usable = (o: BookingOption, total: number, tripType?: string) => total >= o.min_amount
  && (o.max_amount == null || total <= o.max_amount) && (!o.trip_types?.length || o.trip_types.includes(tripType ?? ""));

/** Opens the provider's page in the browser (the sandbox gateway answers with a path on the same server). */
export async function openPayment(ref: string, provider: string, key: string): Promise<boolean> {
  const p = await api.post<{ url: string | null }>(`/api/bookings/${ref}/payments`, { provider, idempotency_key: key });
  const url = p.url?.startsWith("https://") ? p.url : p.url?.startsWith("/") ? `${API_URL}${p.url}` : null;
  if (url) await Linking.openURL(url);
  return !!url;
}
