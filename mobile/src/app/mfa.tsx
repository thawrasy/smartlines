import { useState } from "react";
import { router } from "expo-router";
import { useI18n } from "../i18n";
import { useAuth } from "../platform/auth";
import { Button, ErrorText, Field, Screen, Title } from "../ui/kit";

export default function Mfa() {
  const { t } = useI18n();
  const { verifyMfa, signOut } = useAuth();
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const submit = async () => {
    setBusy(true); setError(null);
    try { await verifyMfa(code); router.replace("/"); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Screen>
      <Title>{t("auth.code")}</Title>
      <ErrorText error={error} />
      <Field label={t("auth.code")} value={code} onChangeText={setCode} keyboardType="number-pad" textContentType="oneTimeCode"
             autoComplete="one-time-code" maxLength={20} onSubmitEditing={submit} />
      <Button label={t("auth.verify")} onPress={submit} busy={busy} disabled={code.length < 6} />
      <Button label={t("common.cancel")} kind="text" onPress={async () => { await signOut(); router.replace("/login"); }} />
    </Screen>
  );
}
