// The trip's real seat layout (rows, aisle, doors, WC) as the carrier defined it. Like the vehicle itself, the
// drawing never mirrors with the language: the driver sits front left.
import { Pressable, Text, View } from "react-native";
import { color, radius } from "./theme";
import { useI18n } from "../i18n";

export interface LayoutSeat { n: number; label: string; deck: number; row: number; col: number; cabin: string }
export interface SeatMapData { decks: string[][]; seats: LayoutSeat[] }

export function SeatMap({ map, free, selected, onToggle, max }: {
  map: SeatMapData; free: Map<number, boolean>; selected: number[]; onToggle: (n: number) => void; max: number;
}) {
  const { t } = useI18n();
  const at = new Map(map.seats.map((x) => [`${x.deck}:${x.row}:${x.col}`, x]));
  return (
    <View style={{ gap: 16, direction: "ltr" }}>
      {map.decks.map((rows, d) => (
        <View key={d} style={{ backgroundColor: color.primarySoft, borderRadius: 28, padding: 16, gap: 8, alignSelf: "center" }}>
          <View style={{ flexDirection: "row", justifyContent: "space-between" }}>
            <Text style={{ color: color.muted, fontSize: 12 }}>{d === 0 ? t("trip.driver") : ""}</Text>
            <Text style={{ color: color.muted, fontSize: 12 }}>{t("trip.front")}</Text>
          </View>
          {rows.map((line, r) => (
            <View key={r} style={{ flexDirection: "row", gap: 8 }}>
              {[...line].map((ch, c) => {
                const seat = at.get(`${d + 1}:${r + 1}:${c + 1}`);
                if (!seat) {
                  const aisle = rows.every((row) => row[c] === "_");
                  const label = ch === "D" ? "DOOR" : ch === "C" ? "WC" : ch === "R" ? "▲" : "";
                  return <View key={c} style={{ width: aisle ? 18 : 40, height: 40, borderRadius: radius.sm, alignItems: "center", justifyContent: "center",
                                                backgroundColor: label ? color.outline : "transparent" }}><Text style={{ fontSize: 9, color: color.muted }}>{label}</Text></View>;
                }
                const mine = selected.includes(seat.n), isFree = !!free.get(seat.n);
                return (
                  <Pressable key={c} accessibilityRole="button" accessibilityLabel={`${t("common.seat")} ${seat.label}`}
                             accessibilityState={{ selected: mine, disabled: !isFree }}
                             disabled={!isFree || (!mine && selected.length >= max)} onPress={() => onToggle(seat.n)}
                             style={{ width: 40, height: 40, borderRadius: 10, alignItems: "center", justifyContent: "center", borderWidth: seat.cabin === "ACCESSIBLE" ? 2 : 1,
                                      borderColor: mine ? color.primary : seat.cabin === "ACCESSIBLE" ? color.primary : color.outline,
                                      backgroundColor: mine ? color.primary : isFree ? color.surface : color.outline }}>
                    <Text style={{ fontSize: 12, fontWeight: "600", color: mine ? "#fff" : isFree ? color.text : color.muted }}>{seat.label}</Text>
                  </Pressable>
                );
              })}
            </View>
          ))}
        </View>
      ))}
    </View>
  );
}
