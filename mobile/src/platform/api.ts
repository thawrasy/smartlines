// API client for the apps: bearer access token from the keystore, automatic refresh (single flight), the client
// header the server requires, timeouts, and stable error codes for the interface to translate.
import { Platform } from "react-native";
import { SessionManager, type Tokens } from "../core/session";
import { API_URL, PORTAL } from "./config";
import { deviceId, tokenStore } from "./secure";

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

const CLIENT = Platform.OS === "ios" ? "ios" : "android";
const TIMEOUT_MS = 15000;

// a multipart form (a photo) is sent as it is; the browser or the device sets its boundary
const isForm = (body: unknown): body is FormData => typeof FormData !== "undefined" && body instanceof FormData;

async function raw(method: string, path: string, body?: unknown, token?: string | null): Promise<Response> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    return await fetch(`${API_URL}${path}`, {
      method,
      signal: ctl.signal,
      headers: {
        "X-Masslak-Client": CLIENT,
        Accept: "application/json",
        ...(body !== undefined && !isForm(body) ? { "Content-Type": "application/json" } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : isForm(body) ? body : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, "NETWORK", "network unavailable");
  } finally {
    clearTimeout(timer);
  }
}

export const session = new SessionManager(tokenStore, async (refreshToken) => {
  const r = await raw("POST", "/api/auth/refresh", { refresh_token: refreshToken, device_id: await deviceId() });
  return { status: r.status, body: r.ok ? ((await r.json()) as Tokens) : undefined };
});

async function parse<T>(r: Response): Promise<T> {
  const data = r.status === 204 ? null : await r.json().catch(() => null);
  if (!r.ok) {
    const e = data?.error ?? {};
    throw new ApiError(r.status, e.code ?? "SERVER_ERROR", e.message ?? String(r.status), e);
  }
  return data as T;
}

export async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let token = await session.accessToken();
  let r = await raw(method, path, body, token);
  const mfaPending = r.status === 401 && (await r.clone().json().catch(() => null))?.error?.code === "MFA_REQUIRED";
  if (r.status === 401 && token && !mfaPending) {
    token = await session.refresh();                     // the access token may have just expired
    if (token) r = await raw(method, path, body, token);
  }
  return parse<T>(r);
}

export const api = {
  get: <T>(path: string, params?: Record<string, string | number | undefined>) => {
    const q = params ? Object.entries(params).filter(([, v]) => v !== undefined && v !== "")
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join("&") : "";
    return request<T>("GET", q ? `${path}?${q}` : path);
  },
  post: <T>(path: string, body: unknown = {}) => request<T>("POST", path, body),
  patch: <T>(path: string, body: unknown = {}) => request<T>("PATCH", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
  upload: <T>(path: string, form: FormData) => request<T>("POST", path, form),
};

/** The headers an image needs when the app loads it from the API itself (a passenger's photo at boarding). */
export async function authHeaders(): Promise<Record<string, string>> {
  const token = await session.accessToken();
  return { "X-Masslak-Client": CLIENT, ...(token ? { Authorization: `Bearer ${token}` } : {}) };
}

export interface LoginResult { mfa: "VERIFY" | "ENROLL" | null; passwordChange: boolean }
/** The two sign-in doors (N16): passengers by e-mail or mobile number, staff by company number and username. */
export type Credentials = { identifier: string } | { company_no: string; username: string };

export async function signIn(who: Credentials, password: string): Promise<LoginResult> {
  const device = { device_id: await deviceId(), app_version: "1.0.0" };
  const r = "identifier" in who
    ? await raw("POST", "/api/auth/login/individual", { identifier: who.identifier.trim(), password, ...device })
    : await raw("POST", "/api/auth/login/business", {
        company_no: who.company_no.trim(), username: who.username.trim().toLowerCase(), password,
        ...(PORTAL === "DRIVER" ? { portal: "DRIVER" } : {}), ...device });
  const data = await parse<{ mfa: LoginResult["mfa"]; password_change_required?: boolean } & Tokens>(r);
  await tokenStore.save({ access_token: data.access_token, refresh_token: data.refresh_token, access_expires_at: data.access_expires_at });
  return { mfa: data.mfa, passwordChange: !!data.password_change_required };
}

/** A closed account comes back with the same details (1085); the caller signs in afterwards. */
export async function reactivate(identifier: string, password: string): Promise<void> {
  await parse<{ ok: boolean }>(await raw("POST", "/api/auth/reactivate", { identifier: identifier.trim(), password }));
}

export async function signOut(): Promise<void> {
  try { await api.post("/api/auth/logout"); } catch { /* signed out locally either way */ }
  await tokenStore.clear();
}
