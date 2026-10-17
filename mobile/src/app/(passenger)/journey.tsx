import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { bookingOptions } from "../../platform/payments";
import { saveBooking } from "../../platform/tickets";
import { Button, Card, CarrierName, Choice, ErrorText, Field, Loading, Notice, Row, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
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
  const p = useLocalSearchParams<{ kind: string; legs: string; picked: string; passengers: string }>();
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
  const brandFor = (i: number, d?: Detail) => brandOf[i] ?? (i > 0 && d?.connection_policy?.missed_connection !== "FREE_CHANGE" ? "FLEX" : "STANDARD");
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
        idempotency_key: key.current, pay_with: payWith, ...(connection ? { accept_risks: accepted } : {}),
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
      <Title sub={t(`jrn.kindDone.${kind}`, { n: done.bookings.length })}>{t(done.status === "CONFIRMED" ? "jrn.booked" : "jrn.reserved")}</Title>
      <Card>
        {done.bookings.map((b) => (
          <Row key={b.booking_ref} title={`${t("jrn.legN", { n: b.leg })} · ${b.booking_ref}`} sub={money(b.total)}
               onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: b.booking_ref } })} />
        ))}
        {done.totals.map((x) => <Text key={x.currency} style={s.h2}>{t("common.total")}: {money(x.total)}</Text>)}
      </Card>
      <Button kind="text" label={t("tabs.trips")} onPress={() => router.replace("/trips")} />
    </Screen>
  );

  if (trips.loading) return <Screen><Loading /></Screen>;
  if (!trips.data) return <Screen><ErrorText error={trips.error} /></Screen>;
  const total = trips.data.reduce((sum, d) => sum + d.price * pax, 0);
  return (
    <Screen>
      <Title sub={t("jrn.sub", { n: legs.length, pax })}>{t(`jrn.title.${kind}`)}</Title>
      {trips.data.map((d, i) => {
        const a = d.stops.find((x) => x.seq === d.from_seq), b = d.stops.find((x) => x.seq === d.to_seq);
        const prev = i > 0 ? trips.data![i - 1] : null;
        const prevArr = prev?.stops.find((x) => x.seq === prev.to_seq)?.sched_arr;
        return (
          <Card key={i}>
            {connection && prevArr && a?.sched_dep ? (
              <Text style={[s.small, { color: color.amber }]}>⇄ {t("conn.changeMinutes", { n: Math.round((Date.parse(a.sched_dep) - Date.parse(prevArr)) / 60000) })}</Text>
            ) : null}
            <Text style={s.h2}>{t("jrn.legN", { n: i + 1 })} · {a?.station_name} → {b?.station_name}</Text>
            <Text style={s.muted}>{a?.sched_dep ? `${date(a.sched_dep)} · ${time(a.sched_dep)}` : ""} → {b?.sched_arr ? time(b.sched_arr) : ""} · {d.trip.trip_code ?? d.trip.trip_no}</Text>
            <CarrierName name={d.trip.carrier_name} uid={d.trip.carrier_uid} logo={d.trip.carrier_logo} />
            <Text style={s.small}>{money(d.price)} × {pax}</Text>
            {connection && d.connection_policy ? <PolicyText p={d.connection_policy} /> : null}
            {connection ? (
              <Choice label={t("conn.fare")} value={brandFor(i, d)} onChange={(v) => setBrandOf((all) => ({ ...all, [i]: v }))}
                      options={["SAVER", "STANDARD", "FLEX"].map((c) => ({ value: c, label: t(`conn.brand.${c}`) }))} />
            ) : null}
          </Card>
        );
      })}
      <Text style={s.small}>{t("jrn.travellersHint")}</Text>
      {people.map((x, i) => {
        const set = (patch: Partial<Person>) => setPeople((all) => all.map((y, j) => (j === i ? { ...y, ...patch } : y)));
        const d = docs[nat(x)];
        const type = d?.docs.includes(x.id_type) ? x.id_type : d?.docs[0] ?? "PASSPORT";
        return (
          <Card key={i}>
            <Text style={s.h2}>{t("trip.passenger", { n: i + 1 })}</Text>
            <View style={s.row}>
              {[true, false].map((sy) => (
                <Pressable key={String(sy)} onPress={() => set({ syrian: sy })} accessibilityRole="radio" accessibilityState={{ checked: x.syrian === sy }}
                           style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                                    borderColor: x.syrian === sy ? color.primary : color.outline, backgroundColor: x.syrian === sy ? color.primarySoft : color.surface }}>
                  <Text>{t(sy ? "trip.syrian" : "trip.otherNationality")}</Text>
                </Pressable>
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
      <View style={s.between}><Text style={s.h2}>{t("common.total")}</Text><Text style={s.h2}>{money(total)}</Text></View>
      <Text style={s.small}>{t("jrn.fareNote")}</Text>
      {payLater ? (
        <View style={s.row} accessibilityRole="radiogroup">
          {(["WALLET", "PAY_LATER"] as const).map((o) => (
            <Pressable key={o} onPress={() => setPayWith(o)} accessibilityRole="radio" accessibilityState={{ checked: payWith === o }}
                       style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                                borderColor: payWith === o ? color.primary : color.outline, backgroundColor: payWith === o ? color.primarySoft : color.surface }}>
              <Text>{t(`opt.name.${o}`)}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}
      {connection ? <RiskNotice accepted={accepted} onChange={setAccepted}
                                flexible={trips.data.some((d, i) => i > 0 && d.connection_policy?.missed_connection !== "FREE_CHANGE")} /> : null}
      <Notice text={t("jrn.allOrNothing")} />
      <ErrorText error={error} />
      <Button label={t("jrn.book", { n: legs.length })} busy={busy} disabled={!people.every(complete) || (connection && !accepted)} onPress={book} />
    </Screen>
  );
}
