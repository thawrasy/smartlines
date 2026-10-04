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
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
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
  get: <T>(path: string) => request<T>("GET", path),
  post: <T>(path: string, body: unknown = {}) => request<T>("POST", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
};

export interface LoginResult { mfa: "VERIFY" | "ENROLL" | null }

export async function signIn(identifier: string, password: string): Promise<LoginResult> {
  const r = await raw("POST", "/api/auth/login", {
    identifier: identifier.trim(), password, portal: PORTAL, device_id: await deviceId(), app_version: "1.0.0",
  });
  const data = await parse<{ mfa: LoginResult["mfa"] } & Tokens>(r);
  await tokenStore.save({ access_token: data.access_token, refresh_token: data.refresh_token, access_expires_at: data.access_expires_at });
  return { mfa: data.mfa };
}

export async function signOut(): Promise<void> {
  try { await api.post("/api/auth/logout"); } catch { /* signed out locally either way */ }
  await tokenStore.clear();
}
