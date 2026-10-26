import { useState, type ReactNode } from "react";
import { Modal, Pressable, ScrollView, StyleSheet, Switch, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { router } from "expo-router";
import { useI18n, zone } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Loading, s } from "../../ui/kit";
import { Icon, Lockup, Stop } from "../../ui/brand";
import { color, font, radius } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { MAX_LEGS, journeyLegs, legsParam, type JourneyKind, type JourneyLeg } from "../../core/journey";

/** Calendar date in the market's time zone, n days from today, as YYYY-MM-DD (1061). */
const dayIso = (n: number) => new Date(Date.now() + n * 86400000).toLocaleDateString("en-CA", { timeZone: zone() });
const DAYS = 30;

interface Ref { cities: { code: string }[]; fare_brands?: { code: string; rules: { refundable?: boolean; changeable?: boolean; bags_included?: number } }[];
              booking?: { max_seats: number; max_adults?: number; max_children?: number } }
// the class of the seats (N34): a seat's cabin in the vehicle's layout; any class unless the traveller picks one
const CABINS = ["ANY", "ECONOMY", "BUSINESS", "VIP", "ACCESSIBLE"] as const;
type Cabin = (typeof CABINS)[number];
interface Points { program: { redeem: unknown } | null; account: { balance: number } | null }
type Sheet = null | { pick: "origin" | "destination" | number } | "dates" | "pax";

// The booking card (identity 1.2, owner's request): trip type tabs, the two cities with their origin and arrival dots
// and a swap button, the travel dates, travellers and class, and booking with points; one blue button. One way, a round
// trip or several places (1121); the seats of a booking are capped by the platform (1122); lap infants have no seat.
export default function Book() {
  const { t, date, city, locale } = useI18n();
  const ref = useLoad(() => api.get<Ref>("/api/ref"));
  const limits = useLoad(() => api.get<{ max_seats: number }>("/api/bookings/limits").then((r) => r.max_seats).catch(() => 4));
  const pts = useLoad(() => api.get<Points>("/api/loyalty").catch(() => ({ program: null, account: null }) as Points));
  const [kind, setKind] = useState<JourneyKind>("ROUND_TRIP");
  const [origin, setOrigin] = useState("DAM");
  const [destination, setDestination] = useState("ALP");
  const [on, setOn] = useState(dayIso(0));
  const [back, setBack] = useState(dayIso(2));
  const [more, setMore] = useState<JourneyLeg[]>([{ from: "ALP", to: "", on: dayIso(2) }]);
  const [pax, setPax] = useState({ adults: 1, children: 0, infantSeat: 0, infantLap: 0 });
  const [brand, setBrand] = useState("STANDARD");
  const [cabin, setCabin] = useState<Cabin>("ANY");
  const [withPoints, setWithPoints] = useState(false);
  const [sheet, setSheet] = useState<Sheet>(null);
  const max = limits.data ?? ref.data?.booking?.max_seats ?? 9;
  const maxAdults = ref.data?.booking?.max_adults ?? 4, maxChildren = ref.data?.booking?.max_children ?? 6;
  const seats = pax.adults + pax.children + pax.infantSeat;
  const cities = (ref.data?.cities ?? []).map((c) => c.code);
  const brands = ref.data?.fare_brands?.length ? ref.data.fare_brands : [{ code: "STANDARD", rules: {} }];
  const pointsOn = !!pts.data?.program?.redeem && (pts.data?.account?.balance ?? 0) > 0;
  const chain = more.map((l, i) => ({ ...l, from: i === 0 ? destination : more[i - 1].to }));
  const legs = journeyLegs(kind, { from: origin, to: destination, on }, back, chain);
  const go = () => {
    if (!legs) return;
    // the travellers by type go to the search too, which applies the platform's limits (N34)
    const extra = { passengers: String(seats), laps: String(pax.infantLap), brand, adults: String(pax.adults),
                    children: String(pax.children), infantSeat: String(pax.infantSeat), ...(cabin !== "ANY" ? { cabin } : {}),
                    ...(withPoints ? { points: "1" } : {}) };
    if (kind === "ONE_WAY") router.push({ pathname: "/results", params: { origin, destination, on, ...extra } });
    else router.push({ pathname: "/results", params: { kind, legs: legsParam(legs), ...extra } });
  };
  const setLeg = (i: number, patch: Partial<JourneyLeg>) => setMore((all) => all.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const day = (d: string) => date(`${d}T12:00:00Z`);
  const datesText = kind === "ROUND_TRIP" ? range(on, back, locale) : day(on);
  const paxText = t("book.summary", { n: seats + pax.infantLap, cls: `${t(`book.cabin.${cabin}`)} · ${t(`conn.brand.${brand}`)}` });

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      <ScrollView contentContainerStyle={st.page} keyboardShouldPersistTaps="handled">
        <Lockup height={30} />
        <Text style={st.title} accessibilityRole="header">{t("book.title")}</Text>
        <View style={st.tabs} accessibilityRole="tablist">
          {(["ROUND_TRIP", "ONE_WAY", "MULTI_CITY"] as JourneyKind[]).map((k) => (
            <Pressable key={k} onPress={() => setKind(k)} accessibilityRole="tab" accessibilityState={{ selected: kind === k }}
                       style={[st.tab, kind === k && st.tabOn]}>
              <Text style={[st.tabText, kind === k && st.tabTextOn]}>{t(`book.mode.${k}`)}</Text>
            </Pressable>
          ))}
        </View>
        {ref.loading ? <Loading /> : (
          <View style={{ gap: 14 }}>
            <View style={st.cities}>
              <CityBox label={t("search.origin")} code={origin} name={city(origin)} stop="origin" onPress={() => setSheet({ pick: "origin" })} />
              <CityBox label={t("search.destination")} code={destination} name={city(destination)} stop="arrival" onPress={() => setSheet({ pick: "destination" })} />
              <View style={st.swapWrap} pointerEvents="box-none">
                <Pressable onPress={() => { setOrigin(destination); setDestination(origin); }} accessibilityRole="button"
                           accessibilityLabel={t("book.swap")} style={st.swap}>
                  <Icon name="swap" size={22} tint={color.primary} />
                </Pressable>
              </View>
            </View>
            {kind === "MULTI_CITY" ? chain.map((l, i) => (
              <View key={i} style={st.cities}>
                <CityBox label={t("jrn.legN", { n: i + 2 })} code={l.from} name={city(l.from)} stop="origin" />
                <CityBox label={t("search.destination")} code={l.to} name={l.to ? city(l.to) : t("book.choose")} stop="arrival" onPress={() => setSheet({ pick: i })} />
              </View>
            )) : null}
            {kind === "MULTI_CITY" ? (
              <View style={s.between}>
                {chain.length + 1 < MAX_LEGS ? <Button kind="text" label={`+ ${t("jrn.addPlace")}`} onPress={() => setMore([...more, { from: "", to: "", on: chain[chain.length - 1].on }])} /> : <View />}
                {chain.length > 1 ? <Button kind="text" label={t("common.remove")} onPress={() => setMore(more.slice(0, -1))} /> : null}
              </View>
            ) : null}
            <FieldBox label={kind === "ROUND_TRIP" ? t("book.dates") : t("search.date")} value={datesText} onPress={() => setSheet("dates")}
                      icon={<Icon name="calendar" size={26} tint={color.primary} />} />
            <FieldBox label={t("book.paxClass")} value={paxText} onPress={() => setSheet("pax")}
                      icon={<Icon name="chevron" size={24} tint={color.primary} />} />
          </View>
        )}
      </ScrollView>

      <View style={st.foot}>
        {pointsOn ? (
          <View style={s.between}>
            <Text style={st.pointsText}>{t("book.withPoints")}</Text>
            <Switch value={withPoints} onValueChange={setWithPoints} trackColor={{ true: color.primary, false: color.outline }} thumbColor="#fff"
                    accessibilityLabel={t("book.withPoints")} />
          </View>
        ) : null}
        <Button label={t("book.search")} disabled={!legs} onPress={go} icon={<Icon name="search" size={22} tint="#fff" />} />
      </View>

      <BottomSheet open={sheet !== null && typeof sheet === "object"} title={t("book.chooseCity")} onClose={() => setSheet(null)}>
        <View style={{ gap: 8 }}>
          {cities.filter((c) => {
            if (!sheet || typeof sheet !== "object") return true;
            if (sheet.pick === "origin") return c !== destination;
            if (sheet.pick === "destination") return c !== origin;
            return c !== chain[sheet.pick].from;
          }).map((c) => (
            <Pressable key={c} accessibilityRole="button" style={st.cityRow} onPress={() => {
              if (sheet && typeof sheet === "object") {
                if (sheet.pick === "origin") setOrigin(c); else if (sheet.pick === "destination") setDestination(c); else setLeg(sheet.pick, { to: c });
              }
              setSheet(null);
            }}>
              <Text style={st.cityName}>{city(c)}</Text>
              <Text style={st.code}>{c}</Text>
            </Pressable>
          ))}
        </View>
      </BottomSheet>

      <BottomSheet open={sheet === "dates"} title={kind === "ROUND_TRIP" ? t("book.dates") : t("search.date")} onClose={() => setSheet(null)}
                   action={t("book.done")}>
        <Text style={st.section}>{t("book.departure")}</Text>
        <DayGrid from={dayIso(0)} value={on} onChange={(d) => { setOn(d); if (back < d) setBack(d); }} day={day} />
        {kind === "ROUND_TRIP" ? (<><Text style={st.section}>{t("jrn.returnDate")}</Text><DayGrid from={on} value={back} onChange={setBack} day={day} /></>) : null}
        {kind === "MULTI_CITY" ? chain.map((l, i) => (
          <View key={i}>
            <Text style={st.section}>{t("jrn.legN", { n: i + 2 })} · {l.to ? city(l.to) : ""}</Text>
            <DayGrid from={i === 0 ? on : chain[i - 1].on} value={l.on} onChange={(d) => setLeg(i, { on: d })} day={day} />
          </View>
        )) : null}
      </BottomSheet>

      <BottomSheet open={sheet === "pax"} title={t("book.paxClass")} onClose={() => setSheet(null)} action={t("book.continue")}>
        <Text style={st.section}>{t("book.travellersTitle")}</Text>
        <Counter title={t("book.adults")} sub={t("book.adultsAge")} value={pax.adults} min={Math.max(1, pax.infantLap)} max={Math.min(maxAdults, pax.adults + (max - seats))}
                 onChange={(v) => setPax({ ...pax, adults: v, infantLap: Math.min(pax.infantLap, v) })} />
        <Counter title={t("book.children")} sub={t("book.childrenAge")} value={pax.children} min={0} max={Math.min(maxChildren, pax.children + (max - seats))}
                 onChange={(v) => setPax({ ...pax, children: v })} />
        <Counter title={t("book.infantLap")} sub={t("book.infantLapSub")} value={pax.infantLap} min={0} max={pax.adults}
                 onChange={(v) => setPax({ ...pax, infantLap: v })} />
        <Counter title={t("book.infantSeat")} sub={t("book.infantSeatSub")} value={pax.infantSeat} min={0} max={pax.infantSeat + (max - seats)}
                 onChange={(v) => setPax({ ...pax, infantSeat: v })} />
        {seats >= max ? <Text style={s.small}>{t("jrn.seatLimit", { n: max })}</Text> : null}
        <Text style={s.small}>{t("book.limits", { adults: maxAdults, children: maxChildren, seats: max })}</Text>
        <View style={st.rule} />
        <Text style={st.section}>{t("book.cabin.label")}</Text>
        {CABINS.map((c) => (
          <Pressable key={c} onPress={() => setCabin(c)} accessibilityRole="radio" accessibilityState={{ checked: cabin === c }} style={st.radioRow}>
            <Text style={[st.counterTitle, { flex: 1 }]}>{t(`book.cabin.${c}`)}</Text>
            <View style={[st.radio, cabin === c && st.radioOn]}>{cabin === c ? <View style={st.radioDot} /> : null}</View>
          </Pressable>
        ))}
        <View style={st.rule} />
        <Text style={st.section}>{t("book.class")}</Text>
        {brands.map((b) => (
          <Pressable key={b.code} onPress={() => setBrand(b.code)} accessibilityRole="radio" accessibilityState={{ checked: brand === b.code }} style={st.radioRow}>
            <View style={{ flex: 1 }}>
              <Text style={st.counterTitle}>{t(`conn.brand.${b.code}`)}</Text>
              <Text style={s.small}>{[b.rules.refundable ? t("book.refundable") : t("book.notRefundable"),
                                     b.rules.bags_included ? t("book.bags", { n: b.rules.bags_included }) : null].filter(Boolean).join(" · ")}</Text>
            </View>
            <View style={[st.radio, brand === b.code && st.radioOn]}>{brand === b.code ? <View style={st.radioDot} /> : null}</View>
          </Pressable>
        ))}
      </BottomSheet>
    </SafeAreaView>
  );
}

/** A short range of two days: "18 – 20 Oct", or "30 Oct – 2 Nov" across months (day and month only, Latin digits). */
function range(from: string, to: string, locale: string) {
  const f = new Intl.DateTimeFormat(locale === "ar" ? "ar-SY-u-nu-latn" : "en-GB", { day: "numeric", month: "long", timeZone: "UTC" });
  const parts = (d: string) => {
    const p = f.formatToParts(new Date(`${d}T12:00:00Z`));
    return { day: p.find((x) => x.type === "day")?.value ?? "", month: p.find((x) => x.type === "month")?.value ?? "" };
  };
  const a = parts(from), b = parts(to);
  return a.month === b.month ? `${a.day} – ${b.day} ${a.month}` : `${a.day} ${a.month} – ${b.day} ${b.month}`;
}

function CityBox({ label, code, name, stop, onPress }: { label: string; code: string; name: string; stop: "origin" | "arrival"; onPress?: () => void }) {
  return (
    <Pressable onPress={onPress} disabled={!onPress} accessibilityRole="button" accessibilityLabel={`${label} ${name}`} style={st.cityBox}>
      <View style={st.cityTop}><Stop kind={stop} size={10} /><Text style={st.boxLabel}>{label}</Text><View style={{ width: 10 }} /></View>
      <Text style={st.cityBig} numberOfLines={1} adjustsFontSizeToFit>{name}</Text>
      <Text style={st.code}>{code}</Text>
    </Pressable>
  );
}

function FieldBox({ label, value, icon, onPress }: { label: string; value: string; icon: ReactNode; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={`${label}: ${value}`} style={st.field}>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={st.boxLabel}>{label}</Text>
        <Text style={st.fieldValue} numberOfLines={1}>{value}</Text>
      </View>
      {icon}
    </Pressable>
  );
}

function Counter({ title, sub, value, min, max, onChange }: { title: string; sub: string; value: number; min: number; max: number; onChange: (v: number) => void }) {
  const less = value > min, more = value < max;
  return (
    <View style={st.counterRow}>
      <View style={{ flex: 1 }}>
        <Text style={st.counterTitle}>{title}</Text>
        <Text style={s.small}>{sub}</Text>
      </View>
      <View style={st.counter}>
        <Pressable disabled={!less} onPress={() => onChange(value - 1)} accessibilityRole="button" accessibilityLabel={`${title} −`}
                   style={[st.round, !less && st.roundOff]}><Icon name="minus" size={20} tint={less ? "#fff" : color.muted} /></Pressable>
        <Text style={st.count}>{value}</Text>
        <Pressable disabled={!more} onPress={() => onChange(value + 1)} accessibilityRole="button" accessibilityLabel={`${title} +`}
                   style={[st.round, !more && st.roundOff]}><Icon name="plus" size={20} tint={more ? "#fff" : color.muted} /></Pressable>
      </View>
    </View>
  );
}

function DayGrid({ from, value, onChange, day }: { from: string; value: string; onChange: (d: string) => void; day: (d: string) => string }) {
  const days = Array.from({ length: DAYS }, (_, n) => dayIso(n)).filter((d) => d >= from);
  return (
    <View style={st.days}>
      {days.map((d) => (
        <Pressable key={d} onPress={() => onChange(d)} accessibilityRole="button" accessibilityState={{ selected: d === value }}
                   style={[st.dayCell, d === value && st.dayOn]}>
          <Text style={[st.dayText, d === value && { color: "#fff" }]}>{day(d)}</Text>
        </Pressable>
      ))}
    </View>
  );
}

function BottomSheet({ open, title, onClose, action, children }: { open: boolean; title: string; onClose: () => void; action?: string; children: ReactNode }) {
  return (
    <Modal visible={open} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={st.scrim} onPress={onClose} accessibilityLabel="close" />
      <View style={st.sheet}>
        <View style={s.between}>
          <Text style={s.h2}>{title}</Text>
          <Pressable onPress={onClose} accessibilityRole="button" hitSlop={12}><Icon name="close" size={22} tint={color.muted} /></Pressable>
        </View>
        <ScrollView contentContainerStyle={{ gap: 6, paddingBottom: 8 }}>{children}</ScrollView>
        {action ? <Button label={action} onPress={onClose} /> : null}
      </View>
    </Modal>
  );
}

const st = StyleSheet.create({
  page: { padding: 20, gap: 18, paddingBottom: 28 },
  title: { fontFamily: font.displayBold, fontSize: 32, color: color.navy, marginTop: 6 },
  tabs: { flexDirection: "row", borderBottomWidth: 1, borderColor: color.outline },
  tab: { flex: 1, alignItems: "center", paddingVertical: 12, borderBottomWidth: 3, borderColor: "transparent", marginBottom: -1 },
  tabOn: { borderColor: color.primary },
  tabText: { fontFamily: font.medium, fontSize: 16, color: color.muted },
  tabTextOn: { fontFamily: font.display, color: color.navy },
  cities: { flexDirection: "row", gap: 14 },
  cityBox: { flex: 1, backgroundColor: color.surface, borderRadius: radius.sm, paddingVertical: 16, paddingHorizontal: 12, alignItems: "center", gap: 4 },
  cityTop: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", alignSelf: "stretch" },
  boxLabel: { fontFamily: font.body, fontSize: 14, color: color.muted },
  cityBig: { fontFamily: font.displayBold, fontSize: 26, color: color.navy },
  code: { fontFamily: font.mono, fontSize: 13, color: color.muted, letterSpacing: 1 },
  swapWrap: { position: "absolute", top: 0, bottom: 0, left: 0, right: 0, alignItems: "center", justifyContent: "center" },
  swap: { width: 48, height: 48, borderRadius: 24, backgroundColor: color.surface, alignItems: "center", justifyContent: "center",
          shadowColor: "#0F1B2D", shadowOpacity: 0.16, shadowRadius: 8, shadowOffset: { width: 0, height: 2 }, elevation: 4 },
  field: { flexDirection: "row", alignItems: "center", gap: 12, backgroundColor: color.surface, borderRadius: radius.sm, paddingVertical: 14, paddingHorizontal: 18 },
  fieldValue: { fontFamily: font.display, fontSize: 18, color: color.text },
  foot: { borderTopWidth: 1, borderColor: color.outline, backgroundColor: color.background, padding: 20, paddingTop: 14, gap: 14 },
  pointsText: { fontFamily: font.medium, fontSize: 17, color: color.text },
  scrim: { flex: 1, backgroundColor: "rgba(11,31,63,0.35)" },
  sheet: { backgroundColor: color.surface, borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: 20, gap: 12, maxHeight: "82%" },
  section: { fontFamily: font.body, fontSize: 14, color: color.muted, marginTop: 8 },
  counterRow: { flexDirection: "row", alignItems: "center", paddingVertical: 10 },
  counterTitle: { fontFamily: font.display, fontSize: 17, color: color.text },
  counter: { flexDirection: "row", alignItems: "center", gap: 16 },
  round: { width: 40, height: 40, borderRadius: 20, backgroundColor: color.navy, alignItems: "center", justifyContent: "center" },
  roundOff: { backgroundColor: "#E3E8EF" },
  count: { fontFamily: font.display, fontSize: 18, color: color.text, minWidth: 18, textAlign: "center" },
  rule: { height: 1, backgroundColor: color.outline, marginVertical: 8 },
  radioRow: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 10 },
  radio: { width: 24, height: 24, borderRadius: 12, borderWidth: 2, borderColor: "#8C96A5", alignItems: "center", justifyContent: "center" },
  radioOn: { borderColor: color.primary },
  radioDot: { width: 12, height: 12, borderRadius: 6, backgroundColor: color.primary },
  cityRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingVertical: 14, borderBottomWidth: 1, borderColor: color.outline },
  cityName: { fontFamily: font.display, fontSize: 18, color: color.text },
  days: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  dayCell: { paddingHorizontal: 12, paddingVertical: 10, borderRadius: radius.sm, borderWidth: 1, borderColor: color.outline, backgroundColor: color.surface },
  dayOn: { backgroundColor: color.primary, borderColor: color.primary },
  dayText: { fontFamily: font.medium, fontSize: 14, color: color.text },
});
