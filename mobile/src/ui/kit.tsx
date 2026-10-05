import type { ReactNode } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View, type TextInputProps, type ViewStyle } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { color, radius, space } from "./theme";
import { useI18n } from "../i18n";
import { ApiError } from "../platform/api";

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

export function Button({ label, onPress, kind = "primary", disabled, busy }: {
  label: string; onPress: () => void; kind?: "primary" | "tonal" | "text" | "danger"; disabled?: boolean; busy?: boolean;
}) {
  const bg = kind === "primary" ? color.primary : kind === "tonal" ? color.primarySoft : kind === "danger" ? color.errorSoft : "transparent";
  const fg = kind === "primary" ? "#fff" : kind === "danger" ? color.error : color.primary;
  return (
    <Pressable accessibilityRole="button" accessibilityState={{ disabled: !!disabled || !!busy }} disabled={disabled || busy}
               onPress={onPress} style={({ pressed }) => [s.button, { backgroundColor: bg, opacity: disabled ? 0.5 : pressed ? 0.85 : 1 }]}>
      {busy ? <ActivityIndicator color={fg} /> : <Text style={[s.buttonText, { color: fg }]}>{label}</Text>}
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

export function Chip({ label, tone = "neutral" }: { label: string; tone?: "neutral" | "green" | "amber" | "red" | "blue" }) {
  const map = { neutral: [color.background, color.muted], green: [color.greenSoft, color.green], amber: [color.amberSoft, color.amber],
                red: [color.errorSoft, color.error], blue: [color.primarySoft, color.primary] } as const;
  return <Text style={[s.chip, { backgroundColor: map[tone][0], color: map[tone][1] }]}>{label}</Text>;
}

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

export const s = StyleSheet.create({
  title: { fontSize: 26, fontWeight: "700", color: color.navy },
  h2: { fontSize: 18, fontWeight: "600", color: color.text },
  muted: { color: color.muted, fontSize: 15 },
  small: { color: color.muted, fontSize: 13 },
  label: { color: color.text, fontSize: 14, fontWeight: "500" },
  card: { backgroundColor: color.surface, borderRadius: radius.lg, borderWidth: 1, borderColor: color.outline, padding: space(4), gap: space(3) },
  button: { minHeight: 52, borderRadius: radius.md, alignItems: "center", justifyContent: "center", paddingHorizontal: space(4) },
  buttonText: { fontSize: 16, fontWeight: "600" },
  input: { minHeight: 52, borderRadius: radius.md, borderWidth: 1, borderColor: color.outline, backgroundColor: color.surface,
           paddingHorizontal: space(4), fontSize: 16, color: color.text, textAlign: "auto" },
  chip: { alignSelf: "flex-start", flexShrink: 0, paddingHorizontal: 10, paddingVertical: 4, borderRadius: 999, fontSize: 13, fontWeight: "600", overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: space(2) },
  between: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: space(2) },
});

/** One choice among a few: wrapped chips (cities, services, durations). */
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
                                borderColor: on ? color.primary : color.outline, backgroundColor: on ? color.primary : color.surface }}>
              <Text style={{ color: on ? "#fff" : color.text, fontWeight: on ? "600" : "400" }}>{o.label}</Text>
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
