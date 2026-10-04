// Device keystore storage (iOS Keychain, Android Keystore-backed). Items are readable only while the device is
// unlocked, never synced to other devices or backups. Values over the keystore's comfortable size are split into
// chunks, so an offline pack of a full coach still lives in the keystore, not in plain files.
import * as SecureStore from "expo-secure-store";
import { getRandomBytes } from "expo-crypto";
import type { TokenStore, Tokens } from "../core/session";

const OPTS: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
const CHUNK = 1800;

export async function put(key: string, value: string): Promise<void> {
  const parts = Math.max(1, Math.ceil(value.length / CHUNK));
  const old = Number((await SecureStore.getItemAsync(`${key}.n`, OPTS)) ?? 0);
  for (let i = 0; i < parts; i++) await SecureStore.setItemAsync(`${key}.${i}`, value.slice(i * CHUNK, (i + 1) * CHUNK), OPTS);
  for (let i = parts; i < old; i++) await SecureStore.deleteItemAsync(`${key}.${i}`, OPTS);
  await SecureStore.setItemAsync(`${key}.n`, String(parts), OPTS);
}

export async function get(key: string): Promise<string | null> {
  const n = Number((await SecureStore.getItemAsync(`${key}.n`, OPTS)) ?? 0);
  if (!n) return null;
  const parts: string[] = [];
  for (let i = 0; i < n; i++) {
    const p = await SecureStore.getItemAsync(`${key}.${i}`, OPTS);
    if (p === null) return null;
    parts.push(p);
  }
  return parts.join("");
}

export async function remove(key: string): Promise<void> {
  const n = Number((await SecureStore.getItemAsync(`${key}.n`, OPTS)) ?? 0);
  for (let i = 0; i < n; i++) await SecureStore.deleteItemAsync(`${key}.${i}`, OPTS);
  await SecureStore.deleteItemAsync(`${key}.n`, OPTS);
}

export async function getJSON<T>(key: string): Promise<T | null> {
  const v = await get(key);
  return v ? (JSON.parse(v) as T) : null;
}

export const putJSON = (key: string, value: unknown) => put(key, JSON.stringify(value));

/** A random identifier for this installation, created once; the server binds the session to its hash. */
export async function deviceId(): Promise<string> {
  const existing = await get("device_id");
  if (existing) return existing;
  const bytes = getRandomBytes(24);
  const id = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  await put("device_id", id);
  return id;
}

export const tokenStore: TokenStore = {
  load: () => getJSON<Tokens>("session"),
  save: (t) => putJSON("session", t),
  clear: () => remove("session"),
};

/** Signs out locally: tokens and every cached ticket or pack are erased; the device id stays. */
export async function wipe(keys: string[]): Promise<void> {
  await remove("session");
  for (const k of keys) await remove(k);
}
