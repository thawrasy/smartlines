import { useEffect, useRef, useState, type ReactNode } from "react";
import { ActivityIndicator, Image, Pressable, ScrollView, StyleSheet, Text, TextInput, View, type TextInputProps, type TextStyle, type ViewStyle } from "react-native";
import { SafeAreaView, useSafeAreaInsets } from "react-native-safe-area-context";
import { color, font, radius, space } from "./theme";
import { useI18n } from "../i18n";
import { ApiError } from "../platform/api";
import { API_URL } from "../platform/config";
import { Icon, type IconName } from "./brand";

export function Screen({ children, scroll = true, padded = true }: { children: ReactNode; scroll?: boolean; padded?: boolean }) {
  const body = <View style={[{ gap: space(4) }, padded && { padding: space(4) }]}>{children}</View>;
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      {scroll ? <ScrollView keyboardShouldPersistTaps="handled">{body}</ScrollView> : <View style={{ flex: 1 }}>{body}</View>}
    </SafeAreaView>
  );
}

export function Title({ children, sub }: { children: ReactNode; sub?: string }) {
  return (
    <View style={{ gap: 4 }}>
      <Text style={s.title} accessibilityRole="header">{children}</Text>
      {sub ? <Text style={s.muted}>{sub}</Text> : null}
    </View>
  );
}

export function Card({ children, style }: { children: ReactNode; style?: ViewStyle }) {
  return <View style={[s.card, style]}>{children}</View>;
}

export function Button({ label, onPress, kind = "primary", disabled, busy, icon }: {
  label: string; onPress: () => void; kind?: "primary" | "tonal" | "text" | "danger"; disabled?: boolean; busy?: boolean; icon?: ReactNode;
}) {
  const bg = kind === "primary" ? color.primary : kind === "tonal" ? color.primarySoft : kind === "danger" ? color.errorSoft : "transparent";
  const fg = kind === "primary" ? "#fff" : kind === "danger" ? color.error : color.primary;
  return (
    <Pressable accessibilityRole="button" accessibilityState={{ disabled: !!disabled || !!busy }} disabled={disabled || busy}
               onPress={onPress} style={({ pressed }) => [s.button, { backgroundColor: bg, opacity: disabled ? 0.5 : pressed ? 0.85 : 1 }]}>
      {busy ? <ActivityIndicator color={fg} /> : <>{icon}<Text style={[s.buttonText, { color: fg }]}>{label}</Text></>}
    </Pressable>
  );
}

export function Field({ label, hint, ...input }: TextInputProps & { label: string; hint?: string }) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={s.label}>{label}</Text>
      <TextInput placeholderTextColor={color.muted} style={s.input} {...input} />
      {hint ? <Text style={s.small}>{hint}</Text> : null}
    </View>
  );
}

/** A password field with an eye inside it that shows the password only while it is held (owner's trial notes, October
 * 2026), hidden again on release or after a few seconds. */
export function PasswordField({ label, hint, ...input }: TextInputProps & { label: string; hint?: string }) {
  const { t } = useI18n();
  const [shown, setShown] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const show = () => { setShown(true); clearTimeout(timer.current); timer.current = setTimeout(() => setShown(false), 5000); };
  const hide = () => { setShown(false); clearTimeout(timer.current); };
  useEffect(() => () => clearTimeout(timer.current), []);
  return (
    <View style={{ gap: 6 }}>
      <Text style={s.label}>{label}</Text>
      <View style={{ justifyContent: "center" }}>
        <TextInput placeholderTextColor={color.muted} style={[s.input, { paddingEnd: 52 }]} autoCapitalize="none" autoCorrect={false}
                   {...input} secureTextEntry={!shown} />
        <Pressable onPressIn={show} onPressOut={hide} hitSlop={8} accessibilityRole="button" accessibilityLabel={t("common.holdToShow")}
                   accessibilityState={{ selected: shown }} style={{ position: "absolute", end: 8, padding: 8 }}>
          <Icon name={shown ? "eyeOff" : "eye"} size={22} tint={shown ? color.primary : color.muted} />
        </Pressable>
      </View>
      {hint ? <Text style={s.small}>{hint}</Text> : null}
    </View>
  );
}

export function Chip({ label, tone = "neutral" }: { label: string; tone?: "neutral" | "green" | "amber" | "red" | "blue" }) {
  const map = { neutral: [color.background, color.muted], green: [color.greenSoft, color.green], amber: [color.amberSoft, color.amber],
                red: [color.errorSoft, color.error], blue: [color.primarySoft, color.primary] } as const;
  return <Text style={[s.chip, { backgroundColor: map[tone][0], color: map[tone][1] }]}>{label}</Text>;
}

/** A carrier's name with its logo beside it, wherever the name is shown (1116). The logo is the carrier's own, added once
 * by the platform; its version in the address fetches a new logo at once. It is decorative next to the name. */
export function CarrierName({ name, uid, logo, style }: { name: string; uid?: string | null; logo?: string | null; style?: TextStyle }) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 6, flexShrink: 1 }}>
      {logo && uid ? (
        <View style={st.logo} accessible={false} importantForAccessibility="no-hide-descendants">
          <Image source={{ uri: `${API_URL}/api/public/companies/${uid}/logo?v=${logo}` }} style={st.logoImage} resizeMode="contain" />
        </View>
      ) : null}
      <Text style={[s.small, style]} numberOfLines={1}>{name}</Text>
    </View>
  );
}

const st = StyleSheet.create({
  logo: { backgroundColor: "#FFFFFF", borderWidth: 1, borderColor: color.outline, borderRadius: 5, paddingHorizontal: 4, paddingVertical: 2 },
  logoImage: { height: 18, width: 54 },
});

export function ErrorText({ error }: { error: unknown }) {
  const { t } = useI18n();
  if (!error) return null;
  const code = error instanceof ApiError ? error.code : "generic";
  const text = t(`errors.${code}`) === `errors.${code}` ? t("errors.generic") : t(`errors.${code}`);
  return <Text accessibilityRole="alert" style={[s.small, { color: color.error, backgroundColor: color.errorSoft, padding: 12, borderRadius: radius.sm }]}>{text}</Text>;
}

export function Loading() {
  return <View style={{ padding: 40, alignItems: "center" }}><ActivityIndicator color={color.primary} /></View>;
}

// Type follows the identity: Readex Pro for titles and figures, IBM Plex Sans Arabic for text and labels (theme.font).
export const s = StyleSheet.create({
  title: { fontSize: 28, fontFamily: font.displayBold, color: color.navy },
  h2: { fontSize: 18, fontFamily: font.display, color: color.text },
  muted: { color: color.muted, fontSize: 15, fontFamily: font.body },
  small: { color: color.muted, fontSize: 13, fontFamily: font.body },
  label: { color: color.text, fontSize: 14, fontFamily: font.medium },
  card: { backgroundColor: color.surface, borderRadius: radius.md, padding: space(4), gap: space(3),
          shadowColor: "#0F1B2D", shadowOpacity: 0.06, shadowRadius: 10, shadowOffset: { width: 0, height: 3 }, elevation: 1 },
  button: { minHeight: 52, borderRadius: radius.sm, alignItems: "center", justifyContent: "center", paddingHorizontal: space(4), flexDirection: "row", gap: 10 },
  buttonText: { fontSize: 17, fontFamily: font.display },
  input: { minHeight: 52, borderRadius: radius.sm, borderWidth: 1, borderColor: color.outline, backgroundColor: color.surface,
           paddingHorizontal: space(4), fontSize: 16, fontFamily: font.body, color: color.text, textAlign: "auto" },
  chip: { alignSelf: "flex-start", flexShrink: 0, paddingHorizontal: 10, paddingVertical: 4, borderRadius: 999, fontSize: 13, fontFamily: font.semibold, overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: space(2) },
  between: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: space(2) },
  section: { fontSize: 18, fontFamily: font.display, color: color.navy, marginTop: space(1) },
  price: { fontSize: 18, fontFamily: font.display, color: color.primary },
  mono: { fontFamily: font.mono, letterSpacing: 0.5, color: color.text },
});

/** One choice among a few: wrapped chips (cities, services, durations), the chosen one in the soft blue of the pills. */
export function Choice<T extends string | number>({ label, options, value, onChange }: {
  label?: string; options: { value: T; label: string }[]; value: T | null; onChange: (v: T) => void;
}) {
  return (
    <View style={{ gap: 6 }}>
      {label ? <Text style={s.label}>{label}</Text> : null}
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
        {options.map((o) => {
          const on = o.value === value;
          return (
            <Pressable key={String(o.value)} accessibilityRole="button" accessibilityState={{ selected: on }} onPress={() => onChange(o.value)}
                       style={{ paddingHorizontal: 14, paddingVertical: 9, borderRadius: 999, borderWidth: 1,
                                borderColor: on ? color.primary : color.outline, backgroundColor: on ? color.primarySoft : color.surface }}>
              <Text style={{ color: on ? color.primary : color.text, fontFamily: on ? font.semibold : font.body, fontSize: 14 }}>{o.label}</Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

/** A tappable list row with a chevron. */
export function Row({ title, sub, right, onPress }: { title: string; sub?: string; right?: ReactNode; onPress?: () => void }) {
  return (
    <Pressable accessibilityRole={onPress ? "button" : undefined} disabled={!onPress} onPress={onPress}
               style={({ pressed }) => [s.between, { paddingVertical: 12, borderBottomWidth: 1, borderColor: color.outline, opacity: pressed ? 0.7 : 1 }]}>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={s.label}>{title}</Text>
        {sub ? <Text style={s.small}>{sub}</Text> : null}
      </View>
      {right}
    </Pressable>
  );
}

export function Notice({ text, tone = "blue" }: { text: string; tone?: "blue" | "amber" | "green" }) {
  const bg = tone === "amber" ? color.amberSoft : tone === "green" ? color.greenSoft : color.primarySoft;
  const fg = tone === "amber" ? color.amber : tone === "green" ? color.green : color.primary;
  return <Text style={[s.small, { backgroundColor: bg, color: fg, padding: 12, borderRadius: radius.sm, overflow: "hidden" }]}>{text}</Text>;
}

/** Underlined tabs across the width (the booking card's trip types, upcoming and past trips). */
export function Tabs<T extends string>({ items, value, onChange }: { items: { key: T; label: string }[]; value: T; onChange: (k: T) => void }) {
  return (
    <View style={{ flexDirection: "row", borderBottomWidth: 1, borderColor: color.outline }} accessibilityRole="tablist">
      {items.map((i) => (
        <Pressable key={i.key} onPress={() => onChange(i.key)} accessibilityRole="tab" accessibilityState={{ selected: value === i.key }}
                   style={{ flex: 1, alignItems: "center", paddingVertical: 12, borderBottomWidth: 3, marginBottom: -1,
                            borderColor: value === i.key ? color.primary : "transparent" }}>
          <Text style={{ fontFamily: value === i.key ? font.display : font.medium, fontSize: 16, color: value === i.key ? color.navy : color.muted }}>{i.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

/** Where the passenger is in a booking (seats, passengers, payment): done steps turn green, the current one blue. */
export function Steps({ current, items }: { current: number; items: string[] }) {
  return (
    <View style={k.steps}>
      {items.map((label, i) => (
        <View key={i} style={{ flexGrow: i < items.length - 1 ? 1 : 0, flexShrink: 1, flexDirection: "row", alignItems: "center", gap: 6 }}
              accessibilityState={{ selected: i === current }} accessibilityLabel={`${i + 1}. ${label}`}>
          <View style={[k.stepDot, i < current && { backgroundColor: color.green }, i === current && { backgroundColor: color.primary }]}>
            {i < current ? <Icon name="check" size={14} tint="#fff" /> : <Text style={[k.stepNum, i <= current && { color: "#fff" }]}>{i + 1}</Text>}
          </View>
          <Text style={[k.stepLabel, i === current && { color: color.navy, fontFamily: font.display }]}>{label}</Text>
          {i < items.length - 1 ? <View style={[k.stepLine, i < current && { backgroundColor: color.green }]} /> : null}
        </View>
      ))}
    </View>
  );
}

/** One choice as a rounded pill (nationality, document type, how to pay). */
export function Pill({ label, on, onPress }: { label: string; on: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} accessibilityRole="radio" accessibilityState={{ checked: on }} style={[k.pill, on && k.pillOn]}>
      <Text style={[k.pillText, on && k.pillTextOn]}>{label}</Text>
    </Pressable>
  );
}

/** The bar fixed at the bottom of a checkout: what is chosen, the total and the next action. */
export function BottomBar({ children }: { children: ReactNode }) {
  const insets = useSafeAreaInsets();
  return <View style={[k.bar, { paddingBottom: 12 + insets.bottom }]}>{children}</View>;
}

const k = StyleSheet.create({
  steps: { flexDirection: "row", alignItems: "center", backgroundColor: color.surface, borderRadius: radius.md, paddingHorizontal: 12, paddingVertical: 12, gap: 4 },
  stepDot: { width: 24, height: 24, borderRadius: 12, backgroundColor: color.outline, alignItems: "center", justifyContent: "center" },
  stepNum: { fontFamily: font.display, fontSize: 12, color: color.muted },
  stepLabel: { fontFamily: font.medium, fontSize: 13, color: color.muted, flexShrink: 0 },
  stepLine: { flexGrow: 1, height: 2, borderRadius: 1, backgroundColor: color.outline, minWidth: 8 },
  pill: { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 999, borderWidth: 1, borderColor: color.outline, backgroundColor: color.surface },
  pillOn: { borderColor: color.primary, backgroundColor: color.primarySoft },
  pillText: { fontFamily: font.body, fontSize: 14, color: color.text },
  pillTextOn: { fontFamily: font.semibold, color: color.primary },
  svcIcon: { width: 52, height: 52, borderRadius: 26, backgroundColor: color.primarySoft, alignItems: "center", justifyContent: "center" },
  bar: { backgroundColor: color.surface, paddingHorizontal: 16, paddingTop: 12, gap: 10, borderTopWidth: 1, borderColor: color.outline,
         shadowColor: "#0F1B2D", shadowOpacity: 0.08, shadowRadius: 12, shadowOffset: { width: 0, height: -4 }, elevation: 8 },
});

/** The head of a service screen: back, the service's icon in its tinted circle (as on the services grid), title and hint. */
export function SvcHeader({ icon, title, sub, onBack }: { icon: IconName; title: string; sub?: string; onBack?: () => void }) {
  const { t } = useI18n();
  return (
    <View style={{ gap: 12 }}>
      {onBack ? (
        <Pressable onPress={onBack} accessibilityRole="button" accessibilityLabel={t("common.back")} hitSlop={12} style={{ alignSelf: "flex-start" }}>
          <Icon name="back" size={26} tint={color.primary} mirror />
        </Pressable>
      ) : null}
      <View style={{ flexDirection: "row", alignItems: "center", gap: 14 }}>
        <View style={k.svcIcon}><Icon name={icon} size={28} tint={color.primary} /></View>
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={[s.title, { fontSize: 24 }]} accessibilityRole="header">{title}</Text>
          {sub ? <Text style={s.small}>{sub}</Text> : null}
        </View>
      </View>
    </View>
  );
}

/** One record in a list (a parcel, a case, a request): a card with a title, a line under it, a status and a chevron. */
export function ListCard({ title, sub, right, onPress, children }: { title: string; sub?: string; right?: ReactNode; onPress?: () => void; children?: ReactNode }) {
  return (
    <Pressable accessibilityRole={onPress ? "button" : undefined} disabled={!onPress} onPress={onPress}
               style={({ pressed }) => [s.card, { gap: 8 }, pressed && { opacity: 0.85 }]}>
      <View style={s.between}>
        <Text style={[s.label, { flex: 1, fontFamily: font.semibold, fontSize: 15 }]} numberOfLines={2}>{title}</Text>
        {right}
        {onPress ? <Icon name="forward" size={18} tint={color.muted} mirror /> : null}
      </View>
      {sub ? <Text style={s.small}>{sub}</Text> : null}
      {children}
    </Pressable>
  );
}

/** Nothing here yet: the icon of the place, faded, over a short line. */
export function Empty({ icon, text }: { icon: IconName; text: string }) {
  return (
    <View style={{ alignItems: "center", gap: 8, paddingVertical: 18 }}>
      <View style={[k.svcIcon, { backgroundColor: color.background, borderWidth: 1, borderColor: color.outline }]}><Icon name={icon} size={26} tint={color.muted} /></View>
      <Text style={[s.muted, { textAlign: "center" }]}>{text}</Text>
    </View>
  );
}
