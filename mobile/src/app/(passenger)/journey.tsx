import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { bookingOptions } from "../../platform/payments";
import { saveBooking } from "../../platform/tickets";
import { BottomBar, Button, Card, CarrierName, Chip, ErrorText, Field, Loading, Notice, Pill, Screen, Steps, Title, s } from "../../ui/kit";
import { Icon, TripLine } from "../../ui/brand";
import { color, font } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { parseLegs, parsePicked, type JourneyKind } from "../../core/journey";
import { PolicyText, RiskNotice, type Policy } from "../../ui/connections";

// A journey checked out in the app (owner's request, October 2026; 1121): the trips chosen leg by leg, the same travellers
// on every trip with seats given side by side, paid at once from the wallet or reserved to pay at the counter where the
// platform opened it. Each trip becomes its own booking, all of the same journey; nothing is booked unless every trip is.
// A connection through a city on the way (1130) shows each carrier's policy for a missed trip and the change time, takes a
// fare per trip (a changeable one for the later trips where needed), and is booked once the traveller accepted its risks.

interface Detail {
  price: number; from_seq: number; to_seq: number;
  trip: { trip_no: string; trip_code?: string | null; carrier_name: string; carrier_uid?: string; carrier_logo?: string | null; currency: string };
  stops: { seq: number; station_name: string; sched_dep: string | null; sched_arr: string | null }[];
  connection_policy?: Policy;
}
interface Docs { international: boolean; docs: string[]; passport_min_days: number; exception: boolean; notes: string[]; departs: string }
interface Out { journey_uid: string; status: string; bookings: { leg: number; booking_ref: string; total: number; status: string }[]; totals: { currency: string; total: number }[] }
interface Person { syrian: boolean; country: string; first_name: string; father_name: string; grandfather_name: string; last_name: string;
                   id_type: string; id_no: string; passport_expiry: string }
const blank: Person = { syrian: true, country: "", first_name: "", father_name: "", grandfather_name: "", last_name: "", id_type: "PASSPORT", id_no: "", passport_expiry: "" };
const minExpiry = (d: Docs) => { const x = new Date(`${d.departs}T12:00:00Z`); x.setUTCDate(x.getUTCDate() + d.passport_min_days); return x.toISOString().slice(0, 10); };

export default function Journey() {
  const { t, money, time, date } = useI18n();
  const p = useLocalSearchParams<{ kind: string; legs: string; picked: string; passengers: string; brand?: string }>();
  const kind = (p.kind ?? "ROUND_TRIP") as JourneyKind;
  const legs = parseLegs(p.legs);
  const picked = parsePicked(p.picked);
  const pax = Math.max(1, Number(p.passengers) || 1);
  const trips = useLoad(() => Promise.all(picked.map((x) => api.get<Detail>(`/api/trips/${x.uid}?from_seq=${x.from}&to_seq=${x.to}`))), [p.picked]);
  const ref = useLoad(() => api.get<{ countries: string[] }>("/api/ref"));
  const opts = useLoad(bookingOptions);
  const [people, setPeople] = useState<Person[]>(() => Array.from({ length: pax }, () => ({ ...blank })));
  const [payWith, setPayWith] = useState<"WALLET" | "PAY_LATER">("WALLET");
  const [docs, setDocs] = useState<Record<string, Docs>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [done, setDone] = useState<Out | null>(null);
  const key = useRef(randomUUID().replace(/-/g, ""));
  const connection = kind === "CONNECTION";
  const [accepted, setAccepted] = useState(false);
  const [brandOf, setBrandOf] = useState<Record<number, string>>({});
  // a later trip of a connection takes a changeable fare unless its carrier changes a missed trip free
  const brandFor = (i: number, d?: Detail) => brandOf[i] ?? (i > 0 && d?.connection_policy?.missed_connection !== "FREE_CHANGE" ? "FLEX" : p.brand ?? "STANDARD");
  const nat = (x: Person) => (x.syrian ? "SY" : x.country);
  const nats = useMemo(() => [...new Set(["SY", ...people.map(nat)])].filter((c) => /^[A-Z]{2}$/.test(c)), [people]);
  // the documents a nationality needs: those of the first international trip of the journey, where there is one
  useEffect(() => {
    nats.filter((c) => !(c in docs)).forEach((c) => {
      Promise.all(picked.map((x) => api.get<Docs>(`/api/trips/${x.uid}/documents?from_seq=${x.from}&to_seq=${x.to}&nationality=${c}`)))
        .then((all) => setDocs((cur) => ({ ...cur, [c]: all.find((d) => d.international) ?? all[0] }))).catch(() => {});
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nats.join(","), p.picked]);

  if (legs.length === 0 || picked.length !== legs.length) {
    return <Screen><Notice tone="amber" text={t("jrn.incomplete")} /><Button kind="text" label={t("common.back")} onPress={() => router.back()} /></Screen>;
  }
  const countries = new Set(ref.data?.countries ?? []);
  const docOk = (x: Person) => {
    const d = docs[nat(x)];
    if (!d) return false;
    if (!d.international) return true;
    return d.docs.includes(x.id_type) && /^[0-9A-Za-z \-/]{4,24}$/.test(x.id_no.trim())
      && (x.id_type !== "PASSPORT" || (/^\d{4}-\d{2}-\d{2}$/.test(x.passport_expiry) && x.passport_expiry >= minExpiry(d)));
  };
  const complete = (x: Person) => !!x.first_name.trim() && !!x.last_name.trim()
    && (x.syrian ? !!x.father_name.trim() && !!x.grandfather_name.trim() : countries.has(x.country) && x.country !== "SY") && docOk(x);
  const payLater = (opts.data ?? []).some((o) => o.code === "PAY_LATER");

  const book = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<Out>("/api/journeys", {
        kind, legs: picked.map((x, i) => ({ trip_uid: x.uid, from_seq: x.from, to_seq: x.to, ...(connection ? { fare_brand: brandFor(i, trips.data?.[i]) } : {}) })),
        idempotency_key: key.current, pay_with: payWith, ...(p.brand ? { fare_brand: p.brand } : {}), ...(connection ? { accept_risks: accepted } : {}),
        passengers: people.map((x) => {
          const d = docs[nat(x)];
          return { nationality: nat(x), first_name: x.first_name.trim(), last_name: x.last_name.trim(),
                   father_name: x.father_name.trim() || null, grandfather_name: x.grandfather_name.trim() || null,
                   ...(d?.international ? { id_type: x.id_type, id_no: x.id_no.trim(), passport_expiry: x.id_type === "PASSPORT" ? x.passport_expiry : null } : {}) };
        }),
      });
      for (const b of out.bookings) if (b.status === "CONFIRMED") await saveBooking(b.booking_ref).catch(() => {});   // tickets work offline
      setDone(out);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (done) return (
    <Screen>
      <View style={js.doneHead}>
        <View style={[js.doneIcon, done.status !== "CONFIRMED" && { backgroundColor: color.amberSoft }]}>
          <Icon name={done.status === "CONFIRMED" ? "check" : "clock"} size={34} tint={done.status === "CONFIRMED" ? color.green : color.amber} />
        </View>
        <Text style={s.title} accessibilityRole="header">{t(done.status === "CONFIRMED" ? "jrn.booked" : "jrn.reserved")}</Text>
        <Text style={s.muted}>{t(`jrn.kindDone.${kind}`, { n: done.bookings.length })}</Text>
      </View>
      {done.bookings.map((b) => (
        <Pressable key={b.booking_ref} onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: b.booking_ref } })}
                   accessibilityRole="button" style={({ pressed }) => [s.card, js.doneRow, pressed && { opacity: 0.85 }]}>
          <View style={{ flex: 1, gap: 4, alignItems: "flex-start" }}>
            <Chip tone="blue" label={t("jrn.legN", { n: b.leg })} />
            <Text style={js.ref}>{b.booking_ref}</Text>
          </View>
          <Text style={js.price}>{money(b.total)}</Text>
          <Icon name="forward" size={20} tint={color.muted} mirror />
        </Pressable>
      ))}
      {done.totals.map((x) => (
        <View key={x.currency} style={s.between}><Text style={s.label}>{t("common.total")}</Text><Text style={js.total}>{money(x.total)}</Text></View>
      ))}
      <Button label={t("tabs.trips")} onPress={() => router.replace("/trips")} />
    </Screen>
  );

  if (trips.loading) return <Screen><Loading /></Screen>;
  if (!trips.data) return <Screen><ErrorText error={trips.error} /></Screen>;
  const total = trips.data.reduce((sum, d) => sum + d.price * pax, 0);
  const named = people.every(complete);
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={js.page}>
        <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel={t("common.back")} hitSlop={12} style={{ alignSelf: "flex-start" }}>
          <Icon name="back" size={26} tint={color.primary} mirror />
        </Pressable>
        <Title sub={t("jrn.sub", { n: legs.length, pax })}>{t(`jrn.title.${kind}`)}</Title>
        <Steps current={named ? 2 : 1} items={[t("trip.step.trips"), t("trip.step.names"), t("trip.step.pay")]} />

        {trips.data.map((d, i) => {
          const a = d.stops.find((x) => x.seq === d.from_seq), b = d.stops.find((x) => x.seq === d.to_seq);
          const prev = i > 0 ? trips.data![i - 1] : null;
          const prevArr = prev?.stops.find((x) => x.seq === prev.to_seq)?.sched_arr;
          return (
            <View key={i} style={{ gap: 10 }}>
              {connection && prevArr && a?.sched_dep ? (
                <View style={js.change}>
                  <Icon name="clock" size={16} tint={color.amber} />
                  <Text style={js.changeText}>{t("conn.changeMinutes", { n: Math.round((Date.parse(a.sched_dep) - Date.parse(prevArr)) / 60000) })}</Text>
                </View>
              ) : null}
              <Card>
                <View style={s.between}>
                  <Chip tone="blue" label={t("jrn.legN", { n: i + 1 })} />
                  <Text style={s.small}>{a?.sched_dep ? date(a.sched_dep) : ""}</Text>
                </View>
                <View style={js.route}>
                  <View style={js.end}>
                    <Text style={js.time}>{a?.sched_dep ? time(a.sched_dep) : "—"}</Text>
                    <Text style={js.station} numberOfLines={2}>{a?.station_name}</Text>
                  </View>
                  <TripLine width={80} height={16} stops={Math.min(Math.max(0, d.to_seq - d.from_seq - 1), 3)} />
                  <View style={js.end}>
                    <Text style={js.time}>{b?.sched_arr ? time(b.sched_arr) : "—"}</Text>
                    <Text style={js.station} numberOfLines={2}>{b?.station_name}</Text>
                  </View>
                </View>
                <View style={[s.between, js.foot]}>
                  <View style={{ flexShrink: 1, gap: 2, alignItems: "flex-start" }}>
                    <CarrierName name={d.trip.carrier_name} uid={d.trip.carrier_uid} logo={d.trip.carrier_logo} />
                    <Text style={js.code}>{d.trip.trip_code ?? d.trip.trip_no}</Text>
                  </View>
                  <Text style={js.price}>{money(d.price)} × {pax}</Text>
                </View>
                {connection && d.connection_policy ? <PolicyText p={d.connection_policy} /> : null}
                {connection ? (
                  <View style={{ gap: 6 }}>
                    <Text style={s.label}>{t("conn.fare")}</Text>
                    <View style={js.wrap}>{["SAVER", "STANDARD", "FLEX"].map((c) => (
                      <Pill key={c} on={brandFor(i, d) === c} label={t(`conn.brand.${c}`)} onPress={() => setBrandOf((all) => ({ ...all, [i]: c }))} />
                    ))}</View>
                  </View>
                ) : null}
              </Card>
            </View>
          );
        })}

        <Text style={s.small}>{t("jrn.travellersHint")}</Text>
        {people.map((x, i) => {
          const set = (patch: Partial<Person>) => setPeople((all) => all.map((y, j) => (j === i ? { ...y, ...patch } : y)));
          const d = docs[nat(x)];
          const type = d?.docs.includes(x.id_type) ? x.id_type : d?.docs[0] ?? "PASSPORT";
          const ok = complete(x);
          return (
            <Card key={i}>
              <View style={s.row}>
                <View style={[js.num, ok && { backgroundColor: color.greenSoft }]}>
                  {ok ? <Icon name="check" size={16} tint={color.green} /> : <Text style={js.numText}>{i + 1}</Text>}
                </View>
                <Text style={js.h}>{t("trip.passenger", { n: i + 1 })}</Text>
              </View>
              <View style={js.wrap}>
                {[true, false].map((sy) => (
                  <Pill key={String(sy)} on={x.syrian === sy} label={t(sy ? "trip.syrian" : "trip.otherNationality")} onPress={() => set({ syrian: sy })} />
                ))}
              </View>
              {!x.syrian ? <Field label={t("trip.nationality")} value={x.country} placeholder="LB" maxLength={2} autoCapitalize="characters"
                                  onChangeText={(v) => set({ country: v.toUpperCase().replace(/[^A-Z]/g, "") })} /> : null}
              <Field label={t("trip.first")} value={x.first_name} onChangeText={(v) => set({ first_name: v })} autoComplete="off" />
              {x.syrian ? <Field label={t("trip.father")} value={x.father_name} onChangeText={(v) => set({ father_name: v })} autoComplete="off" /> : null}
              {x.syrian ? <Field label={t("trip.grandfather")} value={x.grandfather_name} onChangeText={(v) => set({ grandfather_name: v })} autoComplete="off" /> : null}
              <Field label={t("trip.last")} value={x.last_name} onChangeText={(v) => set({ last_name: v })} autoComplete="off" />
              {d?.international ? (
                <View style={{ gap: 8 }}>
                  <Text style={s.small}>{d.exception ? t("trip.docException", { docs: d.docs.map((k) => t(`trip.docTypes.${k}`)).join(" / ") })
                                                     : t("trip.passportNeeded", { days: d.passport_min_days })}</Text>
                  <Field label={t("trip.docNumber")} value={x.id_no} onChangeText={(v) => set({ id_no: v, id_type: type })} autoComplete="off" autoCapitalize="characters" />
                  {type === "PASSPORT" ? <Field label={t("trip.passportExpiry", { date: minExpiry(d) })} value={x.passport_expiry} placeholder="YYYY-MM-DD" maxLength={10}
                                                onChangeText={(v) => set({ passport_expiry: v.trim(), id_type: type })} /> : null}
                </View>
              ) : null}
            </Card>
          );
        })}

        {payLater ? (
          <View style={{ gap: 6 }} accessibilityRole="radiogroup">
            <Text style={js.h}>{t("trip.payWith")}</Text>
            <View style={js.wrap}>
              {(["WALLET", "PAY_LATER"] as const).map((o) => <Pill key={o} on={payWith === o} label={t(`opt.name.${o}`)} onPress={() => setPayWith(o)} />)}
            </View>
          </View>
        ) : null}
        {connection ? <RiskNotice accepted={accepted} onChange={setAccepted}
                                  flexible={trips.data.some((d, i) => i > 0 && d.connection_policy?.missed_connection !== "FREE_CHANGE")} /> : null}
        <Notice text={t("jrn.allOrNothing")} />
        <ErrorText error={error} />
      </ScrollView>

      <BottomBar>
        <View style={s.between}>
          <View style={{ flex: 1, gap: 2, alignItems: "flex-start" }}>
            <Text style={s.label}>{t("common.total")}</Text>
            <Text style={s.small} numberOfLines={2}>{t("jrn.fareNote")}</Text>
          </View>
          <Text style={js.total}>{money(total)}</Text>
        </View>
        <Button label={t("jrn.book", { n: legs.length })} busy={busy} disabled={!named || (connection && !accepted)} onPress={book} />
      </BottomBar>
    </SafeAreaView>
  );
}

const js = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 28 },
  h: { fontFamily: font.display, fontSize: 18, color: color.navy },
  wrap: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  route: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 8 },
  end: { flex: 1, alignItems: "center", gap: 2 },
  time: { fontFamily: font.displayBold, fontSize: 24, color: color.navy },
  station: { fontFamily: font.body, fontSize: 12.5, color: color.muted, textAlign: "center" },
  foot: { borderTopWidth: 1, borderColor: color.outline, paddingTop: 10 },
  code: { fontFamily: font.mono, fontSize: 13, color: color.text, letterSpacing: 0.5 },
  price: { fontFamily: font.display, fontSize: 16, color: color.primary },
  total: { fontFamily: font.displayBold, fontSize: 22, color: color.navy },
  change: { flexDirection: "row", alignItems: "center", gap: 6, alignSelf: "center", backgroundColor: color.amberSoft, paddingHorizontal: 12, paddingVertical: 6, borderRadius: 999 },
  changeText: { fontFamily: font.semibold, fontSize: 13, color: color.amber },
  num: { width: 28, height: 28, borderRadius: 14, backgroundColor: color.primarySoft, alignItems: "center", justifyContent: "center" },
  numText: { fontFamily: font.display, fontSize: 14, color: color.primary },
  doneHead: { alignItems: "center", gap: 8, paddingVertical: 16 },
  doneIcon: { width: 72, height: 72, borderRadius: 36, backgroundColor: color.greenSoft, alignItems: "center", justifyContent: "center" },
  doneRow: { flexDirection: "row", alignItems: "center", gap: 12 },
  ref: { fontFamily: font.mono, fontSize: 16, color: color.navy, letterSpacing: 1 },
});
