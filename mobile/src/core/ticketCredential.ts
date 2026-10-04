// Offline ticket credentials (T2): <"T2">.<base64url JSON claims>.<base64url Ed25519 signature>.
// The platform signs them on the server; the apps hold only the public key, which verifies but cannot create.
// Pure module (no React Native imports) so it is unit-tested with Node.
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

ed.hashes.sha512 = sha512; // React Native has no WebCrypto: give noble a synchronous SHA-512

export interface TicketClaims {
  v: 2;
  k: string; // ticket uid
  t: string; // trip uid
  s: string; // seat label
  n: string; // ticket name (first and last name)
  a: number; // boarding stop sequence
  b: number; // alighting stop sequence
  x: number; // expiry, unix seconds
}

export function fromBase64Url(text: string): Uint8Array {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function utf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

export type CredentialCheck =
  | { ok: true; claims: TicketClaims }
  | { ok: false; reason: "FORMAT" | "SIGNATURE" | "EXPIRED" };

/** Verifies a credential with the pinned public key. Never trusts the claims before the signature checks out. */
export function verifyCredential(token: string, publicKeyB64Url: string, nowSeconds = Date.now() / 1000): CredentialCheck {
  const parts = token.trim().split(".");
  if (parts.length !== 3 || parts[0] !== "T2") return { ok: false, reason: "FORMAT" };
  let valid = false;
  try {
    valid = ed.verify(fromBase64Url(parts[2]), new TextEncoder().encode(parts[1]), fromBase64Url(publicKeyB64Url));
  } catch {
    return { ok: false, reason: "SIGNATURE" };
  }
  if (!valid) return { ok: false, reason: "SIGNATURE" };
  let claims: TicketClaims;
  try {
    claims = JSON.parse(utf8(fromBase64Url(parts[1])));
  } catch {
    return { ok: false, reason: "FORMAT" };
  }
  if (claims.v !== 2 || typeof claims.k !== "string" || typeof claims.t !== "string") return { ok: false, reason: "FORMAT" };
  if (claims.x < nowSeconds) return { ok: false, reason: "EXPIRED" };
  return { ok: true, claims };
}

/** Reads the claims for display only (the passenger's own saved ticket). Boarding decisions use verifyCredential. */
export function readClaims(token: string): TicketClaims | null {
  const parts = token.trim().split(".");
  if (parts.length !== 3 || parts[0] !== "T2") return null;
  try {
    return JSON.parse(utf8(fromBase64Url(parts[1]))) as TicketClaims;
  } catch {
    return null;
  }
}
