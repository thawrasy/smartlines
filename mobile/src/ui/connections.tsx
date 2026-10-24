import { useRef, useState } from "react";
import { Alert, Pressable, Text, View } from "react-native";
import { router } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n, zone } from "../i18n";
import { api } from "../platform/api";
import { saveBooking } from "../platform/tickets";
import { legsParam, pickedParam } from "../core/journey";
import { Button, Card, CarrierName, Chip, ErrorText, Loading, Notice, s } from "./kit";
import { color } from "./theme";
import { useLoad } from "./useLoad";

// Connections across carriers in the app (owner's request, October 2026; migration 1130): two trips through a city on
// the way where no trip runs direct, the carrier's policy for a missed trip shown with each, the risks accepted before
// booking; and a booking changed to another trip of its carrier from the booking screen.

export interface Policy { missed_connection: "FREE_CHANGE" | "FARE_RULES" | "NONE"; change_window_hours: number; note: string | null }
interface Leg {
  trip_uid: string; trip_no: string; trip_code: string | null; from_seq: number; to_seq: number; departs_at: string; arrives_at: string;
  from_station: string; to_station: string; from_city: string; to_city: string; price: number; carrier_name: string; carrier_uid: string;
  carrier_logo: string | null; policy: Policy;
}
interface Connection {
  legs: Leg[]; departs_at: string; arrives_at: string; carriers: number; price: number | null; bookable: boolean;
  change: { city: string; same_station: boolean; minutes: number; arrives_at: string; leaves_from: string };
}

const dayOf = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: zone() }).format(new Date(iso));

export function PolicyText({ p }: { p: Policy }) {
  const { t } = useI18n();
  return <Text style={s.small}>{t(`conn.policy.${p.missed_connection}`, { h: p.change_window_hours })}{p.note ? ` · ${p.note}` : ""}</Text>;
}

/** The connections between two cities on a day, under the trips of the results screen. */
export function Connections({ origin, destination, on, passengers }: { origin: string; destination: string; on: string; passengers: string }) {
  const { t, money, time } = useI18n();
  const res = useLoad(() => api.get<{ enabled: boolean; connections: Connection[] }>(
    `/api/trips/connections?origin=${origin}&destination=${destination}&on=${on}&passengers=${passengers}`), [origin, destination, on, passengers]);
  if (res.loading) return <Loading />;
  if (!res.data?.enabled) return <ErrorText error={res.error} />;
  const choose = (c: Connection) => router.push({ pathname: "/journey", params: {
    kind: "CONNECTION", passengers,
    legs: legsParam(c.legs.map((l) => ({ from: l.from_city, to: l.to_city, on: dayOf(l.departs_at) }))),
    picked: pickedParam(c.legs.map((l) => ({ uid: l.trip_uid, from: l.from_seq, to: l.to_seq }))) } });
  return (
    <View style={{ gap: 8 }}>
      <Text style={s.h2}>{t("conn.title", { from: t(`city.${origin}`), to: t(`city.${destination}`) })}</Text>
      {res.data.connections.length === 0 ? <Text style={s.muted}>{t("conn.none")}</Text> : null}
      {res.data.connections.map((c) => (
        <Pressable key={c.legs.map((l) => l.trip_uid).join("-")} disabled={!c.bookable} accessibilityRole="button" onPress={() => choose(c)}>
          <Card style={{ opacity: c.bookable ? 1 : 0.5 }}>
            <View style={s.between}>
              <Text style={s.h2}>{time(c.departs_at)} → {time(c.arrives_at)}</Text>
              {c.price != null ? <Text style={[s.h2, { color: color.primary }]}>{money(c.price)}</Text> : null}
            </View>
            <View style={s.row}>
              <Chip tone="blue" label={t("conn.via", { city: t(`city.${c.change.city}`) })} />
              <Chip tone={c.carriers > 1 ? "amber" : "neutral"} label={t(c.carriers > 1 ? "conn.carriers" : "conn.oneCarrier", { n: c.carriers })} />
            </View>
            {c.legs.map((l, i) => (
              <View key={l.trip_uid} style={{ gap: 2 }}>
                {i > 0 ? <Text style={[s.small, { color: c.change.same_station ? color.primary : color.amber }]}>
                  ⇄ {t(c.change.same_station ? "conn.changeSame" : "conn.changeOther",
                       { city: t(`city.${c.change.city}`), n: c.change.minutes, from: c.change.arrives_at, to: c.change.leaves_from })}</Text> : null}
                <Text style={s.label}>{t("jrn.legN", { n: i + 1 })} · {time(l.departs_at)} {l.from_station} → {time(l.arrives_at)} {l.to_station}</Text>
                <CarrierName name={l.carrier_name} uid={l.carrier_uid} logo={l.carrier_logo} style={s.small} />
                <PolicyText p={l.policy} />
              </View>
            ))}
            <Text style={[s.small, { color: color.primary }]}>{c.bookable ? `${t("conn.choose")} ›` : t("conn.soldOut")}</Text>
          </Card>
        </Pressable>
      ))}
    </View>
  );
}

/** The risks of a connection, accepted before booking it. */
export function RiskNotice({ accepted, onChange, flexible }: { accepted: boolean; onChange: (v: boolean) => void; flexible: boolean }) {
  const { t } = useI18n();
  return (
    <Card style={{ borderLeftWidth: 4, borderLeftColor: color.amber }}>
      <Text style={s.h2}>⚠ {t("conn.risks.title")}</Text>
      {["own", "late", "policy", "luggage", ...(flexible ? ["flexible"] : [])].map((k) => <Text key={k} style={s.small}>• {t(`conn.risks.${k}`)}</Text>)}
      <Pressable accessibilityRole="checkbox" accessibilityState={{ checked: accepted }} onPress={() => onChange(!accepted)}
                 style={{ flexDirection: "row", gap: 10, alignItems: "center", paddingVertical: 8 }}>
        <View style={{ width: 22, height: 22, borderRadius: 4, borderWidth: 2, borderColor: color.primary, backgroundColor: accepted ? color.primary : "transparent",
                       alignItems: "center", justifyContent: "center" }}>
          {accepted ? <Text style={{ color: "#fff", fontWeight: "700" }}>✓</Text> : null}
        </View>
        <Text style={[s.label, { flex: 1 }]}>{t("conn.risks.accept")}</Text>
      </Pressable>
    </Card>
  );
}

interface ChangeState {
  allowed: boolean; why: string | null; basis: "FREE_CHANGE" | "FARE_RULES" | null; fee: number; refund: number; missed: boolean;
  change_until?: string; policy: Policy;
}
interface ChangeTrip { trip_uid: string; trip_no: string; trip_code: string | null; from_seq: number; to_seq: number; departs_at: string; arrives_at: string;
                       price: number; seats_left: number; bookable: boolean }

/** Changing a booking to another trip of its carrier between the same cities. */
export function ChangeTripCard({ bookingRef }: { bookingRef: string }) {
  const { t, money, time, date, dateTime } = useI18n();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const key = useRef(randomUUID().replace(/-/g, ""));
  const opts = useLoad(() => (open ? api.get<{ change: ChangeState; trips: ChangeTrip[] }>(`/api/bookings/${bookingRef}/change-options`)
    : Promise.resolve(null)), [open, bookingRef]);
  if (!open) return <Button kind="tonal" label={t("conn.change.open")} onPress={() => setOpen(true)} />;
  const change = (x: ChangeTrip) => Alert.alert(t("conn.change.confirm", { code: x.trip_code ?? x.trip_no, time: time(x.departs_at) }), "", [
    { text: t("common.back"), style: "cancel" },
    { text: t("conn.change.pick"), onPress: async () => {
      setBusy(true); setError(null);
      try {
        const out = await api.post<{ booking_ref: string }>(`/api/bookings/${bookingRef}/change`,
          { trip_uid: x.trip_uid, from_seq: x.from_seq, to_seq: x.to_seq, idempotency_key: key.current });
        await saveBooking(out.booking_ref).catch(() => {});
        router.replace({ pathname: "/booking/[ref]", params: { ref: out.booking_ref } });
      } catch (e) { setError(e); } finally { setBusy(false); }
    } },
  ]);
  const d = opts.data;
  return (
    <Card>
      <Text style={s.h2}>{t("conn.change.title")}</Text>
      <ErrorText error={error ?? opts.error} />
      {opts.loading ? <Loading /> : null}
      {d ? (
        <View style={{ gap: 8 }}>
          {d.change.allowed
            ? <Notice tone={d.change.basis === "FREE_CHANGE" ? "green" : "blue"}
                      text={`${t(d.change.basis === "FREE_CHANGE" ? "conn.change.free" : "conn.change.rules", { fee: money(d.change.fee), refund: money(d.change.refund), cur: "" })}${d.change.missed && d.change.change_until ? ` ${t("conn.change.until", { at: dateTime(d.change.change_until) })}` : ""}`} />
            : <Notice tone="amber" text={t(`errors.${d.change.why ?? "CANNOT_CHANGE"}`)} />}
          <PolicyText p={d.change.policy} />
          {d.change.allowed && d.trips.length === 0 ? <Text style={s.muted}>{t("conn.change.noTrips")}</Text> : null}
          {d.change.allowed ? d.trips.map((x) => (
            <View key={x.trip_uid} style={s.between}>
              <Text style={[s.small, { flex: 1 }]}>{x.trip_code ?? x.trip_no} · {date(x.departs_at)} {time(x.departs_at)} → {time(x.arrives_at)} · {money(x.price)}</Text>
              <Button kind="primary" label={t("conn.change.pick")} disabled={busy || !x.bookable} onPress={() => change(x)} />
            </View>
          )) : null}
          {d.change.allowed ? <Text style={s.small}>{t("conn.change.how")}</Text> : null}
        </View>
      ) : null}
      <Button kind="text" label={t("common.back")} onPress={() => setOpen(false)} />
    </Card>
  );
}
