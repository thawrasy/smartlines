// The trip's real seat layout (rows, aisle, doors, WC) as the carrier defined it, drawn as the coach seen from above
// (identity 1.2): a rounded front with the wheel, free seats outlined in the route's blue, the passenger's own seats in
// the green the boarding pass uses for the seat, taken seats greyed. Like the vehicle itself, the drawing never
// mirrors with the language: the driver sits front left.
import { Pressable, StyleSheet, Text, View } from "react-native";
import { color, font, radius } from "./theme";
import { Icon } from "./brand";
import { useI18n } from "../i18n";

export interface LayoutSeat { n: number; label: string; deck: number; row: number; col: number; cabin: string }
export interface SeatMapData { decks: string[][]; seats: LayoutSeat[] }

const SEAT = 42, GAP = 8, AISLE = 20;

export function SeatMap({ map, free, selected, onToggle, max }: {
  map: SeatMapData; free: Map<number, boolean>; selected: number[]; onToggle: (n: number) => void; max: number;
}) {
  const { t } = useI18n();
  const at = new Map(map.seats.map((x) => [`${x.deck}:${x.row}:${x.col}`, x]));
  const accessible = map.seats.some((x) => x.cabin === "ACCESSIBLE");
  return (
    <View style={{ gap: 14 }}>
      <View style={{ gap: 16, direction: "ltr", alignItems: "center" }}>
        {map.decks.map((rows, d) => (
          <View key={d} style={st.coach}>
            <View style={st.front}>
              {d === 0 ? <View style={st.driver} accessibilityLabel={t("trip.driver")}><Icon name="wheel" size={24} tint={color.muted} /></View> : <View />}
              <Text style={st.frontLabel}>{t("trip.front")}</Text>
            </View>
            {rows.map((line, r) => (
              <View key={r} style={{ flexDirection: "row", gap: GAP }}>
                {[...line].map((ch, c) => {
                  const seat = at.get(`${d + 1}:${r + 1}:${c + 1}`);
                  if (!seat) {
                    const aisle = rows.every((row) => row[c] === "_");
                    const label = ch === "D" ? t("trip.door") : ch === "C" ? t("trip.wc") : ch === "R" ? "▲" : "";
                    return <View key={c} style={[st.gap, { width: aisle ? AISLE : SEAT }, label ? st.fixture : null]}>
                             {label ? <Text style={st.fixtureText}>{label}</Text> : null}</View>;
                  }
                  const mine = selected.includes(seat.n), isFree = !!free.get(seat.n), acc = seat.cabin === "ACCESSIBLE";
                  return (
                    <Pressable key={c} accessibilityRole="button" accessibilityLabel={`${t("common.seat")} ${seat.label}`}
                               accessibilityState={{ selected: mine, disabled: !isFree }}
                               disabled={!isFree || (!mine && selected.length >= max)} onPress={() => onToggle(seat.n)}
                               style={({ pressed }) => [st.seat, isFree ? st.free : st.taken, acc && isFree && st.acc, mine && st.mine, pressed && { opacity: 0.8 }]}>
                      <Text style={[st.seatText, !isFree && { color: "#8A94A3" }, mine && { color: "#fff" }]}>{seat.label}</Text>
                      <View style={[st.back, mine ? { backgroundColor: "#095C3E" } : !isFree ? { backgroundColor: "#CBD2DC" } : null]} />
                    </Pressable>
                  );
                })}
              </View>
            ))}
          </View>
        ))}
      </View>
      <View style={st.legend}>
        <Key style={[st.free]} label={t("trip.legend.free")} />
        <Key style={[st.mine]} label={t("trip.legend.mine")} />
        <Key style={[st.taken]} label={t("trip.legend.taken")} />
        {accessible ? <Key style={[st.free, st.acc]} label={t("trip.legend.accessible")} /> : null}
      </View>
    </View>
  );
}

function Key({ style, label }: { style: object[]; label: string }) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 6 }}>
      <View style={[st.keySeat, ...style]} />
      <Text style={st.keyText}>{label}</Text>
    </View>
  );
}

const st = StyleSheet.create({
  coach: { backgroundColor: color.surface, borderWidth: 1.5, borderColor: color.outline, borderTopLeftRadius: 44, borderTopRightRadius: 44,
           borderBottomLeftRadius: 18, borderBottomRightRadius: 18, paddingHorizontal: 16, paddingTop: 14, paddingBottom: 18, gap: GAP,
           shadowColor: "#0F1B2D", shadowOpacity: 0.06, shadowRadius: 10, shadowOffset: { width: 0, height: 3 }, elevation: 1 },
  front: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingBottom: 10, marginBottom: 4,
           borderBottomWidth: 1, borderStyle: "dashed", borderColor: color.outline },
  driver: { width: SEAT, height: 34, alignItems: "center", justifyContent: "center" },
  frontLabel: { fontFamily: font.medium, fontSize: 12, color: color.muted, paddingHorizontal: 6 },
  gap: { height: SEAT, borderRadius: radius.sm, alignItems: "center", justifyContent: "center" },
  fixture: { backgroundColor: color.background, borderWidth: 1, borderColor: color.outline },
  fixtureText: { fontFamily: font.medium, fontSize: 10, color: color.muted },
  seat: { width: SEAT, height: SEAT, borderRadius: 10, borderWidth: 1.5, alignItems: "center", justifyContent: "center", overflow: "hidden" },
  free: { backgroundColor: color.surface, borderColor: "#9DBEF7" },
  acc: { borderColor: color.primary, borderWidth: 2.5 },
  mine: { backgroundColor: color.green, borderColor: color.green },
  taken: { backgroundColor: "#E6EAF0", borderColor: "#E6EAF0" },
  seatText: { fontFamily: font.display, fontSize: 13, color: color.navy },
  back: { position: "absolute", bottom: 0, left: 6, right: 6, height: 4, borderTopLeftRadius: 3, borderTopRightRadius: 3, backgroundColor: "#DCE7FD" },
  legend: { flexDirection: "row", flexWrap: "wrap", justifyContent: "center", columnGap: 16, rowGap: 8 },
  keySeat: { width: 18, height: 18, borderRadius: 5, borderWidth: 1.5 },
  keyText: { fontFamily: font.body, fontSize: 13, color: color.muted },
});
