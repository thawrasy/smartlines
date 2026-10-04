// Device integrity and transport security checks run at start-up.
import * as Device from "expo-device";
import { addSslPinningErrorListener, initializeSslPinning, isSslPinningAvailable } from "react-native-ssl-public-key-pinning";
import { API_PINS, API_URL } from "./config";

export interface Integrity { rooted: boolean; emulator: boolean; pinned: boolean; problem: string | null }

/**
 * Pins the API's public key (at least two pins: current and backup). A release build without pins refuses to talk
 * to the API at all rather than silently trusting any certificate authority.
 */
export async function secureTransport(): Promise<{ pinned: boolean; problem: string | null }> {
  if (!API_URL.startsWith("https://")) return { pinned: false, problem: __DEV__ ? null : "INSECURE_API_URL" };
  if (API_PINS.length < 2 || !isSslPinningAvailable()) {
    return { pinned: false, problem: __DEV__ ? null : "PINNING_NOT_CONFIGURED" };
  }
  const host = new URL(API_URL).hostname;
  await initializeSslPinning({ [host]: { includeSubdomains: false, publicKeyHashes: API_PINS } });
  addSslPinningErrorListener(() => { /* the request fails with a network error; nothing is sent */ });
  return { pinned: true, problem: null };
}

export async function checkIntegrity(): Promise<Integrity> {
  const rooted = await Device.isRootedExperimentalAsync().catch(() => false);
  const transport = await secureTransport();
  return { rooted, emulator: !Device.isDevice, pinned: transport.pinned, problem: transport.problem };
}
