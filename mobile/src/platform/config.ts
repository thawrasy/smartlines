import Constants from "expo-constants";

interface Extra { variant: "passenger" | "driver"; apiUrl: string; apiPins: string[] }

const extra = (Constants.expoConfig?.extra ?? {}) as Partial<Extra>;

export const VARIANT: Extra["variant"] = extra.variant === "driver" ? "driver" : "passenger";
export const API_URL = (extra.apiUrl ?? "https://masslak.example.sy").replace(/\/$/, "");
export const API_PINS: string[] = extra.apiPins ?? [];
export const PORTAL = VARIANT === "driver" ? "DRIVER" : "PASSENGER";
