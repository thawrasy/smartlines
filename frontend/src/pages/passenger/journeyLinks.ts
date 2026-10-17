import type { TripResult } from "../../api";

// A journey in the address (owner's request, October 2026; 1121): its kind, its legs (from, to, day) and the trips chosen
// so far, so the results page walks it leg by leg and the back button and a shared link keep it. The trips chosen are
// remembered for this tab only, to show them while the next leg is chosen.

export type JourneyKind = "ONE_WAY" | "ROUND_TRIP" | "MULTI_CITY" | "CONNECTION";
export interface JourneyLeg { from: string; to: string; on: string }
export interface Picked { uid: string; from: number; to: number }

export const MAX_LEGS = 6;
const LEG = /^([A-Z]{3})_([A-Z]{3})_(\d{4}-\d{2}-\d{2})$/;
const PICK = /^([0-9a-f-]{36}):(\d{1,3}):(\d{1,3})$/;

export const legsParam = (legs: JourneyLeg[]) => legs.map((l) => `${l.from}_${l.to}_${l.on}`).join(",");

export function parseLegs(s: string | null): JourneyLeg[] {
  if (!s) return [];
  const out: JourneyLeg[] = [];
  for (const part of s.split(",").slice(0, MAX_LEGS)) {
    const m = LEG.exec(part);
    if (!m) return [];
    out.push({ from: m[1], to: m[2], on: m[3] });
  }
  return out;
}

export const pickedParam = (p: Picked[]) => p.map((x) => `${x.uid}:${x.from}:${x.to}`).join(",");

export function parsePicked(s: string | null): Picked[] {
  if (!s) return [];
  const out: Picked[] = [];
  for (const part of s.split(",").slice(0, MAX_LEGS)) {
    const m = PICK.exec(part);
    if (!m) return [];
    out.push({ uid: m[1], from: Number(m[2]), to: Number(m[3]) });
  }
  return out;
}

const STORE = "masslak.journey.trips";

export function rememberTrip(trip: TripResult) {
  try {
    const all = JSON.parse(sessionStorage.getItem(STORE) ?? "{}") as Record<string, TripResult>;
    all[`${trip.uid}:${trip.from_seq}:${trip.to_seq}`] = trip;
    sessionStorage.setItem(STORE, JSON.stringify(all));
  } catch { /* the summary shows less, the journey still works */ }
}

export function rememberedTrip(p: Picked): TripResult | null {
  try {
    return (JSON.parse(sessionStorage.getItem(STORE) ?? "{}") as Record<string, TripResult>)[`${p.uid}:${p.from}:${p.to}`] ?? null;
  } catch { return null; }
}
