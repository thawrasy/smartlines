/**
 * A journey in the passenger app (owner's request, October 2026; migration 1121): one way, a round trip, or several
 * places one after the other, chosen trip by trip and booked together. The same address form as the website
 * (legs=DAM_ALP_2026-10-16,ALP_DAM_2026-10-18 and picked=<trip uid>:<from>:<to>,...), so a shared link opens the same
 * journey in either.
 */
export type JourneyKind = "ONE_WAY" | "ROUND_TRIP" | "MULTI_CITY";
export interface JourneyLeg { from: string; to: string; on: string }
export interface Picked { uid: string; from: number; to: number }

export const MAX_LEGS = 6;
const LEG = /^([A-Z]{3})_([A-Z]{3})_(\d{4}-\d{2}-\d{2})$/;
const PICK = /^([0-9a-f-]{36}):(\d{1,3}):(\d{1,3})$/;

export const legsParam = (legs: JourneyLeg[]): string => legs.map((l) => `${l.from}_${l.to}_${l.on}`).join(",");

/** The legs of an address; nothing when any part is malformed, so a broken link starts again instead of half-working. */
export function parseLegs(s: string | null | undefined): JourneyLeg[] {
  if (!s) return [];
  const out: JourneyLeg[] = [];
  for (const part of s.split(",").slice(0, MAX_LEGS)) {
    const m = LEG.exec(part);
    if (!m) return [];
    out.push({ from: m[1], to: m[2], on: m[3] });
  }
  return out;
}

export const pickedParam = (p: Picked[]): string => p.map((x) => `${x.uid}:${x.from}:${x.to}`).join(",");

export function parsePicked(s: string | null | undefined): Picked[] {
  if (!s) return [];
  const out: Picked[] = [];
  for (const part of s.split(",").slice(0, MAX_LEGS)) {
    const m = PICK.exec(part);
    if (!m) return [];
    out.push({ uid: m[1], from: Number(m[2]), to: Number(m[3]) });
  }
  return out;
}

/** The legs a search form asks for: a round trip comes back the way it went; several places need two to six trips,
 *  each between two different cities, each on the day of the one before or later. */
export function journeyLegs(kind: JourneyKind, first: JourneyLeg, back: string | null, more: JourneyLeg[]): JourneyLeg[] | null {
  const legs = kind === "ONE_WAY" ? [first] : kind === "ROUND_TRIP" ? (back ? [first, { from: first.to, to: first.from, on: back }] : [])
    : [first, ...more];
  if (legs.length === 0 || legs.length > MAX_LEGS || (kind === "MULTI_CITY" && legs.length < 2)) return null;
  for (let i = 0; i < legs.length; i++) {
    const l = legs[i];
    if (!l.from || !l.to || l.from === l.to || (i > 0 && l.on < legs[i - 1].on)) return null;
  }
  return legs;
}

/** Whether a trip can follow the one chosen before it: it leaves once the other has arrived. */
export const canFollow = (previousArrives: string | null | undefined, departs: string): boolean =>
  !previousArrives || new Date(departs).getTime() >= new Date(previousArrives).getTime();

/** The trips chosen so far on this phone, by uid: what the next step shows of them and when they arrive. */
export interface ChosenTrip { uid: string; code: string; departs_at: string; arrives_at: string }
const chosen = new Map<string, ChosenTrip>();
export const rememberTrip = (x: ChosenTrip): void => { chosen.set(x.uid, x); };
export const rememberedTrip = (uid: string): ChosenTrip | undefined => chosen.get(uid);
