// The identity's own pieces (identity 1.2): the lockup in the interface's language, the trip line that joins two cities,
// and the line icons of the tab bar and the booking card.
import { I18nManager, View } from "react-native";
import Svg, { Circle, Line, Path, SvgXml } from "react-native-svg";
import { useI18n } from "../i18n";
import { LOCKUP_AR, LOCKUP_AR_RATIO, LOCKUP_AR_WHITE, LOCKUP_EN, LOCKUP_EN_RATIO } from "./logos";
import { color } from "./theme";

/** The lockup: Arabic only in the Arabic interface, English only in the English one. */
export function Lockup({ height = 30, white = false }: { height?: number; white?: boolean }) {
  const { locale } = useI18n();
  const ar = locale === "ar";
  const xml = ar ? (white ? LOCKUP_AR_WHITE : LOCKUP_AR) : LOCKUP_EN;
  const ratio = ar ? LOCKUP_AR_RATIO : LOCKUP_EN_RATIO;
  return (
    <View accessible accessibilityRole="image" accessibilityLabel={ar ? "مسلك" : "masslak"}>
      <SvgXml xml={xml} width={height * ratio} height={height} />
    </View>
  );
}

/** The trip line: the logo drawn straight, a blue origin, a straight route and a green arrival. The origin sits where
 * reading starts, so the line follows the layout direction; stops between are white rings. */
export function TripLine({ width = 120, height = 18, stops = 0, mono = false }: { width?: number; height?: number; stops?: number; mono?: boolean }) {
  // drawn in the layout's direction (the one the cities beside it are laid out in), not the language's
  const r = height * 0.3, y = height / 2;
  const [a, b] = I18nManager.isRTL ? [width - r - 2, r + 2] : [r + 2, width - r - 2];
  const line = mono ? "#000" : color.route;
  return (
    <Svg width={width} height={height} accessibilityElementsHidden importantForAccessibility="no">
      <Line x1={a} y1={y} x2={b} y2={y} stroke={line} strokeWidth={height * 0.16} strokeLinecap="round" />
      {Array.from({ length: stops }, (_, i) => (
        <Circle key={i} cx={a + ((b - a) * (i + 1)) / (stops + 1)} cy={y} r={r * 0.55} fill="#fff" stroke={line} strokeWidth={height * 0.09} />
      ))}
      {mono
        ? <><Circle cx={a} cy={y} r={r} fill="#fff" stroke="#000" strokeWidth={height * 0.12} /><Circle cx={b} cy={y} r={r * 1.05} fill="#000" /></>
        : <><Circle cx={a} cy={y} r={r} fill={color.route} stroke="#fff" strokeWidth={height * 0.08} />
            <Circle cx={b} cy={y} r={r} fill={color.arrival} stroke="#fff" strokeWidth={height * 0.08} /></>}
    </Svg>
  );
}

/** A stop dot: blue for where a trip starts, green for where it arrives. */
export function Stop({ kind, size = 10 }: { kind: "origin" | "arrival"; size?: number }) {
  return <View style={{ width: size, height: size, borderRadius: size / 2, backgroundColor: kind === "origin" ? color.route : color.arrival }} />;
}

const PATHS = {
  search: "M10.5 4a6.5 6.5 0 1 1 0 13a6.5 6.5 0 0 1 0-13zM15.5 15.5L20 20",
  ticket: "M4 7.5A1.5 1.5 0 0 1 5.5 6h13A1.5 1.5 0 0 1 20 7.5V10a2 2 0 0 0 0 4v2.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 16.5V14a2 2 0 0 0 0-4zM14 6v12",
  grid: "M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z",
  wallet: "M4 7.5A2.5 2.5 0 0 1 6.5 5H18v3M4 7.5V17a2 2 0 0 0 2 2h13a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1H6.5A2.5 2.5 0 0 1 4 7.5zM16 13.5h1.5",
  user: "M12 4.5a3.5 3.5 0 1 1 0 7a3.5 3.5 0 0 1 0-7zM5 19.5a7 7 0 0 1 14 0",
  swap: "M7 7h11l-3-3M17 17H6l3 3",
  calendar: "M5 6.5h14v13H5zM5 10.5h14M9 4v4M15 4v4",
  chevron: "M7 10l5 5 5-5",
  back: "M15 5l-7 7 7 7",
  close: "M6 6l12 12M18 6L6 18",
  minus: "M6 12h12",
  plus: "M6 12h12M12 6v12",
} as const;
export type IconName = keyof typeof PATHS;

/** A line icon on the 24-unit grid of the identity (1.5 stroke, round ends); it mirrors where a direction matters. */
export function Icon({ name, size = 22, tint = color.text, mirror = false }: { name: IconName; size?: number; tint?: string; mirror?: boolean }) {
  const flip = mirror && I18nManager.isRTL;
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" style={flip ? { transform: [{ scaleX: -1 }] } : undefined}
         accessibilityElementsHidden importantForAccessibility="no">
      <Path d={PATHS[name]} fill="none" stroke={tint} strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}
