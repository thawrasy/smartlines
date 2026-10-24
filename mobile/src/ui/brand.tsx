// The identity's own pieces (identity 1.2): the lockup in the interface's language, the trip line that joins two cities,
// and the line icons of the tab bar and the booking card.
import { I18nManager, View } from "react-native";
import Svg, { Circle, Line, Path, SvgXml } from "react-native-svg";
import { useI18n } from "../i18n";
import { LOCKUP_AR, LOCKUP_AR_RATIO, LOCKUP_AR_WHITE, LOCKUP_EN, LOCKUP_EN_RATIO, LOCKUP_EN_WHITE } from "./logos";
import { color } from "./theme";

/** The lockup: Arabic only in the Arabic interface, English only in the English one. */
export function Lockup({ height = 30, white = false }: { height?: number; white?: boolean }) {
  const { locale, t } = useI18n();
  const ar = locale === "ar";
  const xml = ar ? (white ? LOCKUP_AR_WHITE : LOCKUP_AR) : (white ? LOCKUP_EN_WHITE : LOCKUP_EN);
  const ratio = ar ? LOCKUP_AR_RATIO : LOCKUP_EN_RATIO;
  return (
    <View accessible accessibilityRole="image" accessibilityLabel={t("brand.name")}>
      <SvgXml xml={xml} width={height * ratio} height={height} />
    </View>
  );
}

/** The trip line: the logo drawn straight, a blue origin, a straight route and a green arrival. The origin sits where
 * reading starts, so the line follows the layout direction; stops between are white rings. */
export function TripLine({ width = 120, height = 18, stops = 0, mono = false, dark = false }: { width?: number; height?: number; stops?: number; mono?: boolean; dark?: boolean }) {
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
        : <><Circle cx={a} cy={y} r={r} fill={dark ? color.origin : color.route} stroke={dark ? color.navy : "#fff"} strokeWidth={height * 0.08} />
            <Circle cx={b} cy={y} r={r} fill={color.arrival} stroke={dark ? color.navy : "#fff"} strokeWidth={height * 0.08} /></>}
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
  forward: "M9 5l7 7-7 7",
  close: "M6 6l12 12M18 6L6 18",
  minus: "M6 12h12",
  plus: "M6 12h12M12 6v12",
  pass: "M4 6.5h16v11H4zM4 10h16M7.5 14h4",
  parcel: "M4 8l8-4 8 4v8l-8 4-8-4zM4 8l8 4 8-4M12 12v8M8 6l8 4",
  car: "M5 16.5V12l2-4.5h10l2 4.5v4.5M4 16.5h16M7.5 19v-2.5M16.5 19v-2.5M7 13h1.5M15.5 13H17",
  key: "M14.5 9.5a4 4 0 1 1-1.2 2.9L5 20.7V17h2.5v-2.5H10l1.6-1.6",
  pin: "M12 20.5s-6-5.5-6-10a6 6 0 0 1 12 0c0 4.5-6 10-6 10zM12 8.5a2 2 0 1 1 0 4a2 2 0 0 1 0-4z",
  people: "M9 4.5a3 3 0 1 1 0 6a3 3 0 0 1 0-6zM3.5 19a5.5 5.5 0 0 1 11 0M16 5a3 3 0 0 1 0 5.8M17.5 13.5A5 5 0 0 1 21 19",
  chat: "M5 5.5h14v10H10l-4 3.5v-3.5H5z",
  wheel: "M12 3.5a8.5 8.5 0 1 1 0 17a8.5 8.5 0 0 1 0-17zM12 9.5a2.5 2.5 0 1 1 0 5a2.5 2.5 0 0 1 0-5zM3.6 11h5.9M14.5 11h5.9M12 14.5v6",
  clock: "M12 4a8 8 0 1 1 0 16a8 8 0 0 1 0-16zM12 8v4.5l3 2",
  check: "M5 12.5l4.5 4.5L19 7.5",
  eye: "M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12zM12 9a3 3 0 1 1 0 6a3 3 0 0 1 0-6z",
  eyeOff: "M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12zM12 9a3 3 0 1 1 0 6a3 3 0 0 1 0-6zM4 4l16 16",
  card: "M3.5 6.5h17v11h-17zM3.5 10h17M7 14.5h3",
  bus: "M6 4.5h12a1.5 1.5 0 0 1 1.5 1.5v11H4.5V6A1.5 1.5 0 0 1 6 4.5zM4.5 11.5h15M8 17v2.5M16 17v2.5M7.5 14.5h1M15.5 14.5h1",
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
