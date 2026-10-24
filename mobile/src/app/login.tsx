import { useState } from "react";
import { Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../i18n";
import { useAuth } from "../platform/auth";
import { ApiError, reactivate } from "../platform/api";
import { VARIANT } from "../platform/config";
import { Button, ErrorText, Field, Screen, Title, s, PasswordField } from "../ui/kit";
import { Lockup, TripLine } from "../ui/brand";

export default function Login() {
  const { t } = useI18n();
  const { signIn } = useAuth();
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const finish = async () => {
    await signIn(identifier, password);
    setPassword("");
    router.replace("/");
  };
  const submit = async () => {
    setBusy(true); setError(null);
    try { await finish(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  // a closed account (1085) opens again with the same details: reactivate, then sign in
  const reopen = async () => {
    setBusy(true); setError(null);
    try { await reactivate(identifier, password); await finish(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const enrol = error instanceof ApiError && error.code === "MFA_ENROLL_ON_WEB";
  const closed = error instanceof ApiError && error.code === "ACCOUNT_DEACTIVATED";
  return (
    <Screen>
      {/* the lockup in the interface's language and the trip line, then the form: the first screen is the brand's */}
      <View style={{ alignItems: "center", gap: 18, paddingTop: 36, paddingBottom: 12 }}>
        <Lockup height={48} />
        <TripLine width={180} height={18} />
      </View>
      <Title sub={t(`app.${VARIANT}`)}>{t("auth.title")}</Title>
      {enrol ? <Text style={s.muted}>{t("auth.enrollOnWeb")}</Text> : <ErrorText error={error} />}
      <Field label={t("common.email")} value={identifier} onChangeText={setIdentifier} autoCapitalize="none" autoCorrect={false}
             keyboardType="email-address" textContentType="username" autoComplete="username" />
      <PasswordField label={t("common.password")} value={password} onChangeText={setPassword} textContentType="password"
             autoComplete="current-password" onSubmitEditing={submit} />
      <Button label={t("common.signIn")} onPress={submit} busy={busy} disabled={!identifier || !password} />
      {closed ? <Button kind="tonal" label={t("auth.reactivate")} onPress={reopen} busy={busy} disabled={!identifier || !password} /> : null}
    </Screen>
  );
}
