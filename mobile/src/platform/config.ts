import Constants from "expo-constants";

interface Extra { variant: "passenger" | "driver" | "operator" | "officer"; apiUrl: string; apiPins: string[] }

const extra = (Constants.expoConfig?.extra ?? {}) as Partial<Extra>;

export const VARIANT: Extra["variant"] = extra.variant === "driver" || extra.variant === "operator" || extra.variant === "officer" ? extra.variant : "passenger";
export const API_URL = (extra.apiUrl ?? "https://masslak.com").replace(/\/$/, "");
export const API_PINS: string[] = extra.apiPins ?? [];
// The operator app is for carrier staff (transport, parcels, taxi, rental and freight companies alike)
// The officer app is the platform's own app for the members of government bodies who check vehicles at the roadside (N48)
export const PORTAL = VARIANT === "driver" ? "DRIVER" : VARIANT === "operator" ? "OPERATOR" : VARIANT === "officer" ? "INSPECTOR" : "PASSENGER";
