import { useState } from "react";
import { Text } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../i18n";
import { useAuth } from "../platform/auth";
import { ApiError } from "../platform/api";
import { VARIANT } from "../platform/config";
import { Button, ErrorText, Field, Screen, Title, s } from "../ui/kit";

export default function Login() {
  const { t } = useI18n();
  const { signIn } = useAuth();
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await signIn(identifier, password);
      setPassword("");
      router.replace("/");
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const enrol = error instanceof ApiError && error.code === "MFA_ENROLL_ON_WEB";
  return (
    <Screen>
      <Title sub={t(`app.${VARIANT}`)}>{t("auth.title")}</Title>
      {enrol ? <Text style={s.muted}>{t("auth.enrollOnWeb")}</Text> : <ErrorText error={error} />}
      <Field label={t("common.email")} value={identifier} onChangeText={setIdentifier} autoCapitalize="none" autoCorrect={false}
             keyboardType="email-address" textContentType="username" autoComplete="username" />
      <Field label={t("common.password")} value={password} onChangeText={setPassword} secureTextEntry textContentType="password"
             autoComplete="current-password" onSubmitEditing={submit} />
      <Button label={t("common.signIn")} onPress={submit} busy={busy} disabled={!identifier || !password} />
    </Screen>
  );
}
