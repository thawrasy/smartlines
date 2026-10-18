import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView, useSafeAreaInsets } from "react-native-safe-area-context";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { bookingOptions, openPayment, usable as offered, type BookingOption, type PayWith } from "../../../platform/payments";
import { saveBooking } from "../../../platform/tickets";
import { Button, Card, CarrierName, Chip, Choice, ErrorText, Field, Loading, Notice, Screen, s } from "../../../ui/kit";
import { Icon, TripLine } from "../../../ui/brand";
import { SeatMap, type SeatMapData } from "../../../ui/SeatMap";
import { color, font, radius } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Detail {
  seat_map: SeatMapData | null; price: number; from_seq: number; to_seq: number; seats: { seat_no: number; free: boolean }[];
  trip: { trip_no: string; trip_code?: string | null; carrier_name: string; carrier_uid?: string; carrier_logo?: string | null; currency: string; hold_min: number; departs_at?: string; trip_type?: string };
  categories?: Band[]; family_offers?: { code: string; name: string; min_members: number; discount_type: string; discount_value: number }[];
  stops: { seq: number; station_name: string; sched_dep: string | null; sched_arr: string | null }[];
}
type Category = "ADULT" | "CHILD" | "INFANT";
interface Band { category: Category; min_age: number; max_age: number | null; seat_required: boolean; needs_adult: boolean; fare: number }
interface Member { uid: string; relation: string; first_name: string; father_name: string | null; grandfather_name: string | null;
                   last_name: string; full_name: string; nationality: string; birth_date: string; id_type: string | null; id_last4: string | null }
interface Fam { role: "HEAD" | "MEMBER" | null; members?: Member[]; me?: Member; account?: { balance: number } }
interface Quote { total: number; lines: { passenger: number; category: Category; seat: boolean; fare: number }[];
                  family_offer?: { name: string; discount: number } }
interface Names {
  birth_date: string; member_uid: string | null;
  syrian: boolean; country: string; first_name: string; father_name: string; grandfather_name: string; last_name: string;
  id_type: string; id_no: string; passport_expiry: string;           // international trips
}
const blank: Names = { birth_date: "", member_uid: null, syrian: true, country: "", first_name: "", father_name: "", grandfather_name: "", last_name: "",
                       id_type: "PASSPORT", id_no: "", passport_expiry: "" };
// What a nationality needs on this segment: a passport on international trips unless an approved exception applies
interface Docs { international: boolean; docs: string[]; passport_min_days: number; exception: boolean; notes: string[]; departs: string }
const minExpiry = (d: Docs) => { const x = new Date(`${d.departs}T12:00:00Z`); x.setUTCDate(x.getUTCDate() + d.passport_min_days); return x.toISOString().slice(0, 10); };
const docOk = (x: Names, d?: Docs) => !d?.international || (d.docs.includes(x.id_type) && /^[0-9A-Za-z \-/]{4,24}$/.test(x.id_no.trim())
  && (x.id_type !== "PASSPORT" || (/^\d{4}-\d{2}-\d{2}$/.test(x.passport_expiry) && x.passport_expiry >= minExpiry(d))));

const ageOn = (birth: string, on: Date) => {
  const b = new Date(`${birth}T12:00:00Z`);
  let a = on.getUTCFullYear() - b.getUTCFullYear();
  if (on.getUTCMonth() < b.getUTCMonth() || (on.getUTCMonth() === b.getUTCMonth() && on.getUTCDate() < b.getUTCDate())) a -= 1;
  return a;
};
/** The fare category a date of birth gives on the travel day, by the carrier's age bands (4.19). */
const categoryOf = (bands: Band[], birth: string, on: Date): Category | null => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(birth) || Number.isNaN(Date.parse(birth))) return null;
  const a = ageOn(birth, on);
  if (a < 0) return null;
  return bands.find((b) => a >= b.min_age && (b.max_age == null || a < b.max_age))?.category ?? "ADULT";
};
const fromMember = (m: Member): Names => ({
  ...blank, member_uid: m.uid, birth_date: m.birth_date, syrian: m.nationality === "SY", country: m.nationality === "SY" ? "" : m.nationality,
  first_name: m.first_name, father_name: m.father_name ?? "", grandfather_name: m.grandfather_name ?? "", last_name: m.last_name,
});

export default function Trip() {
  const { t, money, time } = useI18n();
  const insets = useSafeAreaInsets();
  const p = useLocalSearchParams<{ uid: string; from_seq: string; to_seq: string; passengers: string; laps?: string; brand?: string; points?: string }>();
  const brand = p.brand || "STANDARD";               // the class chosen on the booking card
  const max = Number(p.passengers) || 1;
  const detail = useLoad(() => api.get<Detail>(`/api/trips/${p.uid}?from_seq=${p.from_seq}&to_seq=${p.to_seq}`), [p.uid, p.from_seq, p.to_seq]);
  const wallet = useLoad(() => api.get<{ balance: number }>("/api/wallet"));
  const opts = useLoad(bookingOptions);
  const [payWith, setPayWith] = useState<PayWith | null>(null);
  const ref = useLoad(() => api.get<{ countries: string[] }>("/api/ref"));
  const [selected, setSelected] = useState<number[]>([]);
  const [hold, setHold] = useState<{ hold_token: string; expires_at: string } | null>(null);
  const [names, setNames] = useState<Record<string, Names>>({});
  const [laps, setLaps] = useState(Math.min(Number(p.laps) || 0, max));   // infants on an adult's lap: no seat
  const [payFrom, setPayFrom] = useState<"WALLET" | "FAMILY_ACCOUNT">("WALLET");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoteError, setQuoteError] = useState<unknown>(null);
  const fam = useLoad(() => api.get<Fam>("/api/family").catch(() => ({ role: null }) as Fam));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const idem = useRef(randomUUID());
  const [docs, setDocs] = useState<Record<string, Docs>>({});
  const nat = (x?: Names) => (!x || x.syrian ? "SY" : x.country);
  const nats = [...new Set(["SY", ...Object.values(names).map(nat)])].filter((c) => /^[A-Z]{2}$/.test(c));
  useEffect(() => {
    nats.filter((c) => !(c in docs)).forEach((c) => {
      api.get<Docs>(`/api/trips/${p.uid}/documents?from_seq=${p.from_seq}&to_seq=${p.to_seq}&nationality=${c}`)
        .then((r) => setDocs((cur) => ({ ...cur, [c]: r }))).catch(() => {});
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nats.join(","), p.uid]);
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(id); }, []);

  const free = useMemo(() => new Map((detail.data?.seats ?? []).map((x) => [x.seat_no, x.free])), [detail.data]);
  // Trips created before seat layouts existed have no map: draw a plain 2+2 coach from the seat numbers, as the website does
  const seatMap = useMemo<SeatMapData | null>(() => {
    const d = detail.data;
    if (!d) return null;
    if (d.seat_map) return d.seat_map;
    const rows = Math.ceil(d.seats.length / 4);
    return { decks: [Array.from({ length: rows }, () => "SS_SS")],
             seats: d.seats.map((x, i) => ({ n: x.seat_no, label: String(x.seat_no), deck: 1, row: Math.floor(i / 4) + 1, col: [1, 2, 4, 5][i % 4], cabin: "STANDARD" })) };
  }, [detail.data]);
  const label = (n: number) => seatMap?.seats.find((x) => x.n === n)?.label ?? String(n);
  const left = hold ? Math.max(0, Math.round((new Date(hold.expires_at).getTime() - now) / 1000)) : 0;
  const countries = new Set(ref.data?.countries ?? []);
  const complete = (x?: Names) => !!x && !!x.first_name.trim() && !!x.last_name.trim()
    && (x.syrian ? !!x.father_name.trim() && !!x.grandfather_name.trim() : countries.has(x.country) && x.country !== "SY")
    && (!!x.member_uid || docOk(x, docs[nat(x)]));            // a family member's stored document is used when none is typed

  const bands = detail.data?.categories ?? [];
  const lapAllowed = bands.some((b) => b.category === "INFANT" && !b.seat_required);
  const travel = new Date(detail.data?.stops.find((x) => x.seq === detail.data?.from_seq)?.sched_dep ?? Date.now());
  const keys = [...selected.map((n) => `s${n}`), ...Array.from({ length: laps }, (_, i) => `l${i}`)];
  const register = fam.data?.role === "HEAD" ? fam.data.members ?? [] : fam.data?.me ? [fam.data.me] : [];
  const body = (x: Names, seat: number | null) => {
    const d = docs[nat(x)];
    return { seat_no: seat, nationality: x.syrian ? "SY" : x.country, first_name: x.first_name.trim(), last_name: x.last_name.trim(),
             father_name: x.father_name.trim() || null, grandfather_name: x.grandfather_name.trim() || null,
             birth_date: x.birth_date || null, family_member_uid: x.member_uid,
             ...(d?.international && x.id_no.trim() ? { id_type: x.id_type, id_no: x.id_no.trim(), passport_expiry: x.id_type === "PASSPORT" ? x.passport_expiry : null } : {}) };
  };
  const travellers = () => keys.map((k) => body(names[k] ?? blank, k.startsWith("s") ? Number(k.slice(1)) : null));
  const quoteKey = hold ? JSON.stringify([keys.map((k) => [k, names[k]?.birth_date, names[k]?.member_uid]), payFrom]) : "";
  useEffect(() => {
    if (!hold) return;
    const id = setTimeout(() => {
      const ps = keys.map((k) => { const x = names[k] ?? blank;
        return { seat_no: k.startsWith("s") ? Number(k.slice(1)) : null, nationality: x.syrian ? "SY" : x.country || "SY", birth_date: x.birth_date || null, family_member_uid: x.member_uid }; });
      api.post<Quote>("/api/bookings/quote", { trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), fare_brand: brand, passengers: ps, pay_from: payFrom })
        .then((q) => { setQuote(q); setQuoteError(null); }).catch((e) => { setQuote(null); setQuoteError(e); });
    }, 400);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quoteKey]);

  const doHold = async () => {
    setBusy(true); setError(null);
    try {
      setHold(await api.post("/api/holds", { trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), seat_nos: selected }));
      setNames(Object.fromEntries(selected.map((n) => [`s${n}`, names[`s${n}`] ?? blank])));
    } catch (e) { setError(e); detail.reload(); } finally { setBusy(false); }
  };
  const pay = async () => {
    if (!hold) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ booking_ref: string; status: string }>("/api/bookings", {
        hold_token: hold.hold_token, trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), fare_brand: brand, idempotency_key: idem.current,
        passengers: travellers(), pay_from: payFrom, pay_with: payFrom === "FAMILY_ACCOUNT" ? "WALLET" : chosen?.code ?? "WALLET",
      });
      if (out.status === "PENDING_PAYMENT") {
        // card, instalments and financing: the seats are reserved and the passenger goes on to the provider's page;
        // pay later: the booking screen says where and until when to pay
        const provider = chosen?.providers?.[0];
        if (provider) await openPayment(out.booking_ref, provider.code, randomUUID()).catch(() => {});
      } else {
        await saveBooking(out.booking_ref).catch(() => {});
      }
      router.replace({ pathname: "/booking/[ref]", params: { ref: out.booking_ref } });
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (detail.loading) return <Screen><Loading /></Screen>;
  if (!detail.data) return <Screen><ErrorText error={detail.error} /><Button kind="text" label={t("common.back")} onPress={() => router.back()} /></Screen>;
  const d = detail.data;
  const from = d.stops.find((x) => x.seq === d.from_seq), to = d.stops.find((x) => x.seq === d.to_seq);
  const total = quote?.total ?? d.price * selected.length;
  const usable = (o: BookingOption) => offered(o, total, d.trip.trip_type);
  const options = opts.data ?? [];
  const chosen = options.find((o) => o.code === payWith && usable(o)) ?? options.find(usable) ?? null;
  // the family account pays at once, so only the wallet option goes with it
  const familyPays = payFrom === "FAMILY_ACCOUNT";
  const hint = (o: BookingOption) => !usable(o) ? (total < o.min_amount ? t("opt.from", { amount: money(o.min_amount) }) : "")
    : t(`opt.hint.${o.code}`, { h: o.hold_hours ?? 24, m: o.cutoff_minutes ?? 120, provider: o.providers?.[0]?.name ?? "" });
  const payLabel = !chosen || chosen.code === "WALLET" ? t("trip.pay", { amount: money(total) })
    : chosen.code === "PAY_LATER" ? t("opt.reserve") : t("opt.continue", { amount: money(total) });
  const catLabel = (c: Category) => { const b = bands.find((x) => x.category === c);
    return b ? `${t(`pax.cat.${c}`)} · ${(b.max_age == null ? t("pax.agesFrom", { from: b.min_age }) : t("pax.ages", { from: b.min_age, to: b.max_age }))} · ${money(b.fare)}` : t(`pax.cat.${c}`); };
  const named = keys.every((k) => complete(names[k]));
  const step = !hold ? 0 : named ? 2 : 1;
  const between = Math.max(0, d.to_seq - d.from_seq - 1);
  const pill = (on: boolean) => [ts.pill, on && ts.pillOn];
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={ts.page}>
        <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel={t("common.back")} hitSlop={12} style={{ alignSelf: "flex-start" }}>
          <Icon name="back" size={26} tint={color.primary} mirror />
        </Pressable>

        <View style={ts.head} accessibilityRole="header">
          <View style={s.between}>
            <Text style={ts.code}>{d.trip.trip_code ?? d.trip.trip_no}</Text>
            <Text style={ts.brand}>{t(`conn.brand.${brand}`)}</Text>
          </View>
          <View style={ts.route}>
            <View style={ts.end}>
              <Text style={ts.time}>{from?.sched_dep ? time(from.sched_dep) : "—"}</Text>
              <Text style={ts.station} numberOfLines={2}>{from?.station_name}</Text>
            </View>
            <TripLine width={84} height={18} stops={Math.min(between, 3)} dark />
            <View style={ts.end}>
              <Text style={ts.time}>{to?.sched_arr ? time(to.sched_arr) : "—"}</Text>
              <Text style={ts.station} numberOfLines={2}>{to?.station_name}</Text>
            </View>
          </View>
          <View style={[s.between, ts.headFoot]}>
            <CarrierName name={d.trip.carrier_name} uid={d.trip.carrier_uid} logo={d.trip.carrier_logo} style={{ color: "#DCE3EC", fontFamily: font.medium, fontSize: 14 }} />
            <Text style={ts.per}>{t("trip.perSeat", { amount: money(d.price) })}</Text>
          </View>
        </View>

        <Steps current={step} />

        {bands.length ? (
          <View style={{ gap: 6 }}>
            <Text style={s.label}>{t("trip.fares")}</Text>
            <View style={ts.wrap}>{bands.map((b) => <Chip key={b.category} tone="blue" label={catLabel(b.category)} />)}</View>
          </View>
        ) : null}
        {(d.family_offers ?? []).map((o) => <Notice key={o.code} tone="green" text={`${o.name} · ${t("pax.familyOfferHint", { n: o.min_members })}`} />)}
        <ErrorText error={error} />

        {!hold ? (
          <>
            <View style={s.between}>
              <Text style={ts.h}>{t("trip.seats")}</Text>
              <Text style={s.small}>{t("extra.seatsChosen", { n: selected.length, max })}</Text>
            </View>
            <SeatMap map={seatMap!} free={free} selected={selected} max={max}
                     onToggle={(n) => setSelected((cur) => (cur.includes(n) ? cur.filter((x) => x !== n) : [...cur, n]))} />
          </>
        ) : (
          <>
            <View style={[ts.timer, left < 60 && { backgroundColor: color.errorSoft }]}>
              <Icon name="clock" size={18} tint={left < 60 ? color.error : color.amber} />
              <Text style={[ts.timerText, left < 60 && { color: color.error }]}>
                {t("trip.held", { t: `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}` })}
              </Text>
            </View>
            <Text style={s.small}>{t("trip.namesHint")}</Text>
            {keys.map((k, i) => {
              const x = names[k] ?? blank;
              const set = (patch: Partial<Names>) => setNames({ ...names, [k]: { ...x, ...patch } });
              const lap = k.startsWith("l");
              const cat = categoryOf(bands, x.birth_date, travel);
              const taken = new Set(keys.filter((o) => o !== k).map((o) => names[o]?.member_uid).filter(Boolean));
              const locked = !!x.member_uid;
              const done = complete(x);
              return (
                <Card key={k}>
                  <View style={s.between}>
                    <View style={s.row}>
                      <View style={[ts.num, done && { backgroundColor: color.greenSoft }]}>
                        {done ? <Icon name="check" size={16} tint={color.green} /> : <Text style={ts.numText}>{i + 1}</Text>}
                      </View>
                      <Text style={ts.h}>{t("trip.passenger", { n: i + 1 })}</Text>
                    </View>
                    {lap ? <Chip tone="neutral" label={t("pax.lapInfant")} /> : (
                      <View style={ts.seatTag}><Text style={ts.seatTagLabel}>{t("common.seat")}</Text><Text style={ts.seatTagValue}>{label(Number(k.slice(1)))}</Text></View>
                    )}
                  </View>
                  {lap && i === keys.length - 1 ? <Button kind="text" label={t("common.remove")} onPress={() => setLaps(laps - 1)} /> : null}
                  {register.length ? (
                    <Choice label={t("family.pickMember")} value={x.member_uid ?? ""}
                            options={[{ value: "", label: "—" }, ...register.filter((m) => !taken.has(m.uid)).map((m) => ({ value: m.uid, label: m.full_name }))]}
                            onChange={(uid) => { const m = register.find((r) => r.uid === uid); set(m ? fromMember(m) : { ...blank }); }} />
                  ) : null}
                  {locked ? <Notice text={t("family.fromRegister")} /> : null}
                  <Field label={`${t("pax.birthDate")} (${t("pax.birthHint")})`} value={x.birth_date} placeholder="YYYY-MM-DD" maxLength={10} editable={!locked}
                         onChangeText={(v) => set({ birth_date: v.trim() })} />
                  <Text style={s.small}>{t("pax.category")}: {cat ? t(`pax.cat.${cat}`) : t("pax.categoryUnknown")}{quote?.lines[i] ? ` · ${money(quote.lines[i].fare)}` : ""}</Text>
                  <View style={s.row}>
                    {[true, false].map((sy) => (
                      <Pressable key={String(sy)} onPress={() => set({ syrian: sy })} accessibilityRole="radio" accessibilityState={{ checked: x.syrian === sy }}
                                 style={pill(x.syrian === sy)}>
                        <Text style={[ts.pillText, x.syrian === sy && ts.pillTextOn]}>{t(sy ? "trip.syrian" : "trip.otherNationality")}</Text>
                      </Pressable>
                    ))}
                  </View>
                  {!x.syrian ? <Field label={t("trip.nationality")} value={x.country} placeholder="LB" maxLength={2} autoCapitalize="characters"
                                      onChangeText={(v) => set({ country: v.toUpperCase().replace(/[^A-Z]/g, "") })} /> : null}
                  <Field label={t("trip.first")} value={x.first_name} onChangeText={(v) => set({ first_name: v })} autoComplete="off" editable={!locked} />
                  {x.syrian ? <Field label={t("trip.father")} value={x.father_name} onChangeText={(v) => set({ father_name: v })} autoComplete="off" editable={!locked} /> : null}
                  {x.syrian ? <Field label={t("trip.grandfather")} value={x.grandfather_name} onChangeText={(v) => set({ grandfather_name: v })} autoComplete="off" editable={!locked} /> : null}
                  <Field label={t("trip.last")} value={x.last_name} onChangeText={(v) => set({ last_name: v })} autoComplete="off" editable={!locked} />
                  {docs[nat(x)]?.international ? (() => {
                    const d = docs[nat(x)];
                    const type = d.docs.includes(x.id_type) ? x.id_type : d.docs[0];
                    return (
                      <View style={{ gap: 8 }}>
                        <Text style={s.small}>{d.exception ? t("trip.docException", { docs: d.docs.map((k) => t(`trip.docTypes.${k}`)).join(" / ") })
                                                           : t("trip.passportNeeded", { days: d.passport_min_days })}{d.notes.length ? ` ${d.notes.join(" ")}` : ""}</Text>
                        {d.docs.length > 1 ? (
                          <View style={ts.wrap}>{d.docs.map((k) => (
                            <Pressable key={k} onPress={() => set({ id_type: k })} accessibilityRole="radio" accessibilityState={{ checked: type === k }} style={pill(type === k)}>
                              <Text style={[ts.pillText, type === k && ts.pillTextOn]}>{t(`trip.docTypes.${k}`)}</Text>
                            </Pressable>
                          ))}</View>
                        ) : null}
                        <Field label={t("trip.docNumber")} value={x.id_no} onChangeText={(v) => set({ id_no: v, id_type: type })} autoComplete="off" autoCapitalize="characters" />
                        {type === "PASSPORT" ? <Field label={t("trip.passportExpiry", { date: minExpiry(d) })} value={x.passport_expiry} placeholder="YYYY-MM-DD"
                                                      onChangeText={(v) => set({ passport_expiry: v.trim(), id_type: type })} maxLength={10} /> : null}
                      </View>
                    );
                  })() : null}
                </Card>
              );
            })}
            {lapAllowed && laps < selected.length ? <Button kind="tonal" label={t("pax.addLapInfant")} onPress={() => setLaps(laps + 1)} /> : null}
            {fam.data?.role === "HEAD" && fam.data.account ? (
              <Choice label={t("family.payFrom")} value={payFrom} onChange={setPayFrom}
                      options={[{ value: "WALLET", label: t("family.funding.OWN") },
                                { value: "FAMILY_ACCOUNT", label: `${t("family.funding.FAMILY_ACCOUNT")} · ${money(fam.data.account.balance)}` }]} />
            ) : null}
            {fam.data?.role === "MEMBER" ? <Notice text={t("family.paidByHead")} /> : null}
            {quote?.family_offer ? <Notice tone="green" text={`${quote.family_offer.name} −${money(quote.family_offer.discount)}`} /> : null}
            <ErrorText error={quoteError} />
            {opts.data && options.length === 0 ? <Notice tone="amber" text={t("opt.noneOpen")} /> : null}
            {!familyPays && options.length > 1 ? (
              <View style={{ gap: 8 }} accessibilityRole="radiogroup" accessibilityLabel={t("opt.title")}>
                <Text style={ts.h}>{t("trip.payWith")}</Text>
                {options.map((o) => {
                  const on = chosen?.code === o.code, ok = usable(o);
                  return (
                    <Pressable key={o.code} disabled={!ok} onPress={() => setPayWith(o.code)} accessibilityRole="radio"
                               accessibilityState={{ checked: on, disabled: !ok }}
                               style={[ts.option, on && ts.optionOn, !ok && { opacity: 0.55 }]}>
                      <View style={[ts.radio, on && ts.radioOn]}>{on ? <View style={ts.radioDot} /> : null}</View>
                      <View style={{ flex: 1, gap: 2 }}>
                        <Text style={ts.optionName}>{t(`opt.name.${o.code}`)}</Text>
                        {hint(o) ? <Text style={s.small}>{hint(o)}</Text> : null}
                      </View>
                    </Pressable>
                  );
                })}
              </View>
            ) : null}
            {wallet.data && payFrom === "WALLET" && (familyPays || (chosen?.code ?? "WALLET") === "WALLET")
              ? <View style={s.row}><Icon name="wallet" size={18} tint={color.muted} /><Text style={s.small}>{t("trip.balance", { amount: money(wallet.data.balance) })}</Text></View> : null}
            {p.points === "1" && payFrom === "WALLET" && wallet.data ? (
              <PointsToWallet need={Math.max(0, total - wallet.data.balance)} onDone={wallet.reload} />
            ) : null}
          </>
        )}
      </ScrollView>

      <View style={[ts.bar, { paddingBottom: 12 + insets.bottom }]}>
        <View style={s.between}>
          {!hold ? (
            <View style={{ flex: 1, gap: 2, alignItems: "flex-start" }}>
              <Text style={s.small}>{t("trip.chosen")}</Text>
              <Text style={selected.length ? ts.barSeats : s.muted} numberOfLines={1}>{selected.length ? selected.map(label).join(" · ") : t("trip.none")}</Text>
            </View>
          ) : <Text style={s.label}>{t("common.total")}</Text>}
          <Text style={ts.barTotal}>{money(total)}</Text>
        </View>
        {!hold
          ? <Button label={t("trip.hold")} busy={busy} disabled={selected.length !== max} onPress={doHold} />
          : <Button label={familyPays ? t("trip.pay", { amount: money(total) }) : payLabel} busy={busy}
                    disabled={left === 0 || !quote || !named || (!!opts.data && !chosen)} onPress={pay} />}
      </View>
    </SafeAreaView>
  );
}

/** Where the passenger is in the booking: seats, then the passengers' names, then paying. */
function Steps({ current }: { current: number }) {
  const { t } = useI18n();
  const items = [t("trip.step.seats"), t("trip.step.names"), t("trip.step.pay")];
  return (
    <View style={ts.steps}>
      {items.map((label, i) => (
        <View key={i} style={{ flex: 1, flexDirection: "row", alignItems: "center", gap: 6 }}
              accessibilityState={{ selected: i === current }} accessibilityLabel={`${i + 1}. ${label}`}>
          <View style={[ts.stepDot, i < current && { backgroundColor: color.green }, i === current && { backgroundColor: color.primary }]}>
            {i < current ? <Icon name="check" size={14} tint="#fff" /> : <Text style={[ts.stepNum, i <= current && { color: "#fff" }]}>{i + 1}</Text>}
          </View>
          <Text style={[ts.stepLabel, i === current && { color: color.navy, fontFamily: font.display }]} numberOfLines={1}>{label}</Text>
          {i < items.length - 1 ? <View style={[ts.stepLine, i < current && { backgroundColor: color.green }]} /> : null}
        </View>
      ))}
    </View>
  );
}

const ts = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 28 },
  head: { backgroundColor: color.navy, borderRadius: radius.lg, padding: 18, gap: 14 },
  code: { fontFamily: font.mono, fontSize: 15, color: "#fff", letterSpacing: 1 },
  brand: { fontFamily: font.semibold, fontSize: 13, color: color.navy, backgroundColor: color.origin, paddingHorizontal: 10, paddingVertical: 3, borderRadius: 999, overflow: "hidden" },
  route: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 8 },
  end: { flex: 1, alignItems: "center", gap: 2 },
  time: { fontFamily: font.displayBold, fontSize: 26, color: "#fff" },
  station: { fontFamily: font.body, fontSize: 13, color: "#B8C2CF", textAlign: "center" },
  headFoot: { borderTopWidth: 1, borderColor: "#24385A", paddingTop: 12 },
  per: { fontFamily: font.display, fontSize: 15, color: "#fff" },
  h: { fontFamily: font.display, fontSize: 18, color: color.navy },
  wrap: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  steps: { flexDirection: "row", alignItems: "center", backgroundColor: color.surface, borderRadius: radius.md, paddingHorizontal: 12, paddingVertical: 12, gap: 6 },
  stepDot: { width: 24, height: 24, borderRadius: 12, backgroundColor: color.outline, alignItems: "center", justifyContent: "center" },
  stepNum: { fontFamily: font.display, fontSize: 12, color: color.muted },
  stepLabel: { fontFamily: font.medium, fontSize: 13, color: color.muted, flexShrink: 1 },
  stepLine: { flex: 1, height: 2, borderRadius: 1, backgroundColor: color.outline, minWidth: 8 },
  timer: { flexDirection: "row", alignItems: "center", gap: 8, alignSelf: "flex-start", backgroundColor: color.amberSoft, paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999 },
  timerText: { fontFamily: font.semibold, fontSize: 14, color: color.amber },
  num: { width: 28, height: 28, borderRadius: 14, backgroundColor: color.primarySoft, alignItems: "center", justifyContent: "center" },
  numText: { fontFamily: font.display, fontSize: 14, color: color.primary },
  seatTag: { flexDirection: "row", alignItems: "baseline", gap: 6, backgroundColor: color.greenSoft, paddingHorizontal: 12, paddingVertical: 4, borderRadius: radius.sm },
  seatTagLabel: { fontFamily: font.body, fontSize: 12, color: color.green },
  seatTagValue: { fontFamily: font.displayBold, fontSize: 18, color: "#00391F" },
  pill: { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 999, borderWidth: 1, borderColor: color.outline, backgroundColor: color.surface },
  pillOn: { borderColor: color.primary, backgroundColor: color.primarySoft },
  pillText: { fontFamily: font.body, fontSize: 14, color: color.text },
  pillTextOn: { fontFamily: font.semibold, color: color.primary },
  option: { flexDirection: "row", alignItems: "center", gap: 12, padding: 14, borderRadius: radius.md, borderWidth: 1.5, borderColor: color.outline, backgroundColor: color.surface },
  optionOn: { borderColor: color.primary, backgroundColor: "#F3F7FE" },
  optionName: { fontFamily: font.display, fontSize: 16, color: color.text },
  radio: { width: 22, height: 22, borderRadius: 11, borderWidth: 2, borderColor: color.outline, alignItems: "center", justifyContent: "center" },
  radioOn: { borderColor: color.primary },
  radioDot: { width: 10, height: 10, borderRadius: 5, backgroundColor: color.primary },
  bar: { backgroundColor: color.surface, paddingHorizontal: 16, paddingTop: 12, gap: 10, borderTopWidth: 1, borderColor: color.outline,
         shadowColor: "#0F1B2D", shadowOpacity: 0.08, shadowRadius: 12, shadowOffset: { width: 0, height: -4 }, elevation: 8 },
  barSeats: { fontFamily: font.display, fontSize: 17, color: color.green },
  barTotal: { fontFamily: font.displayBold, fontSize: 22, color: color.navy },
});

interface PointsView { program: { point_value: number; redeem: { min_points: number; step: number } | null } | null; account: { balance: number } | null }

/** Booking with points (booking card, identity 1.2): the points the payment needs, within the balance and the programme's
 * steps, are turned into wallet credit (1103) just before the wallet pays the booking. */
function PointsToWallet({ need, onDone }: { need: number; onDone: () => void }) {
  const { t, money } = useI18n();
  const v = useLoad(() => api.get<PointsView>("/api/loyalty").catch(() => ({ program: null, account: null }) as PointsView));
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<number | null>(null);
  const [error, setError] = useState<unknown>(null);
  const prog = v.data?.program, acc = v.data?.account;
  if (!prog?.redeem || !acc || prog.point_value <= 0) return null;
  const { min_points: min, step } = prog.redeem;
  const wanted = Math.ceil(need / prog.point_value / step) * step;          // the points that cover what the wallet lacks
  const n = Math.min(Math.floor(acc.balance / step) * step, Math.max(wanted, min));
  const redeem = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ value: number }>("/api/loyalty/redeem", { points: n, idempotency_key: randomUUID() });
      setDone(r.value); v.reload(); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Card>
      <Text style={s.h2}>{t("book.pointsTitle")}</Text>
      <Text style={s.small}>{t("book.pointsBalance", { points: acc.balance, amount: money(acc.balance * prog.point_value) })}</Text>
      {done !== null ? <Notice tone="green" text={t("book.pointsUsed", { amount: money(done) })} />
        : need > 0 && n >= min ? <Button kind="tonal" label={t("book.pointsUse", { points: n })} busy={busy} onPress={redeem} /> : null}
      <ErrorText error={error} />
    </Card>
  );
}
