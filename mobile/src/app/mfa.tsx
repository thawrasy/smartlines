import { useEffect, useState } from "react";
import { Linking, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../i18n";
import { api } from "../platform/api";
import { useAuth, type MfaMethod } from "../platform/auth";
import { Button, Choice, ErrorText, Field, Loading, Notice, Screen, Title, s } from "../ui/kit";

interface Methods { available: MfaMethod[]; usable: MfaMethod[]; sent_to: Partial<Record<MfaMethod, string>>; account_mobile: string | null }
interface Sent { sent_to: string; resend_in: number }

/** Second step of sign-in (owner's decision 2): a code from an authenticator app, a code sent by text or WhatsApp
 *  message, or a recovery code; or the first set-up of one of the methods the platform opened. */
export default function Mfa() {
  const { t } = useI18n();
  const { mfaStep, verifyMfa, refresh, signOut } = useAuth();
  const enrol = mfaStep === "ENROLL";
  const [methods, setMethods] = useState<Methods | null>(null);
  const [method, setMethod] = useState<MfaMethod | null>(null);
  const [code, setCode] = useState("");
  const [mobile, setMobile] = useState("");
  const [secret, setSecret] = useState<{ secret: string; uri: string } | null>(null);
  const [sent, setSent] = useState<Sent | null>(null);
  const [wait, setWait] = useState(0);
  const [recovery, setRecovery] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    api.get<Methods>("/api/auth/mfa/methods").then((m) => {
      setMethods(m);
      const choices = enrol ? m.available : m.usable;
      if (choices.length === 1) setMethod(choices[0]);
    }).catch(setError);
  }, [enrol]);

  useEffect(() => {
    if (wait <= 0) return;
    const id = setTimeout(() => setWait(wait - 1), 1000);
    return () => clearTimeout(id);
  }, [wait]);

  useEffect(() => {
    if (!enrol || method !== "TOTP" || secret) return;
    api.post<{ secret: string; uri: string }>("/api/auth/mfa/enroll", { method: "TOTP" }).then(setSecret).catch(setError);
  }, [enrol, method, secret]);

  const send = async () => {
    if (!method || method === "TOTP") return;
    setBusy(true); setError(null);
    try {
      const r = enrol && !sent
        ? await api.post<Sent>("/api/auth/mfa/enroll", { method, mobile: mobile.trim() || null })
        : await api.post<Sent>("/api/auth/mfa/send", { method });
      setSent(r); setWait(r.resend_in);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  const submit = async () => {
    setBusy(true); setError(null);
    try {
      if (enrol) {
        const r = await api.post<{ recovery_codes: string[] | null }>("/api/auth/mfa/confirm", { code: code.replace(/\s/g, ""), method });
        if (r.recovery_codes) { setRecovery(r.recovery_codes); return; }
        await refresh();
      } else {
        await verifyMfa(code, method);
      }
      router.replace("/");
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (recovery) {
    return (
      <Screen>
        <Title sub={t("mfa.savedText")}>{t("mfa.savedTitle")}</Title>
        <View style={{ gap: 4 }}>{recovery.map((c) => <Text key={c} style={[s.label, { fontFamily: "monospace" }]} selectable>{c}</Text>)}</View>
        <Button label={t("mfa.continue")} onPress={async () => { await refresh(); router.replace("/"); }} />
      </Screen>
    );
  }
  const choices = methods ? (enrol ? methods.available : methods.usable) : [];
  const message = method === "SMS" || method === "WHATSAPP";
  const ready = method === "TOTP" ? (!enrol || !!secret) : message ? !!sent : true;
  return (
    <Screen>
      <Title sub={t(method ? `mfa.text.${mfaStep}.${method}` : "mfa.choose")}>{t(enrol ? "mfa.enrolTitle" : "auth.verify")}</Title>
      {!methods && !error ? <Loading /> : null}
      {choices.length > 1 ? (
        <Choice options={choices.map((m) => ({ value: m, label: t(`mfa.method.${m}`) }))} value={method}
                onChange={(m) => { setMethod(m); setSent(null); setCode(""); setError(null); }} />
      ) : null}
      {enrol && method === "TOTP" && secret ? (
        <View style={{ gap: 8 }}>
          <Text style={s.small}>{t("mfa.manual")}</Text>
          <Text style={[s.label, { fontFamily: "monospace" }]} selectable>{secret.secret.match(/.{1,4}/g)?.join(" ")}</Text>
          <Button kind="tonal" label={t("mfa.openApp")} onPress={() => { void Linking.openURL(secret.uri).catch(() => undefined); }} />
        </View>
      ) : null}
      {enrol && message && !sent ? (
        <Field label={t("mfa.mobile")} hint={methods?.account_mobile ? t("mfa.mobileHint", { mobile: methods.account_mobile }) : undefined}
               value={mobile} onChangeText={setMobile} keyboardType="phone-pad" autoComplete="tel" />
      ) : null}
      {message ? (
        <View style={{ gap: 6 }}>
          <Button kind="tonal" label={`${t(sent ? "mfa.resend" : "mfa.send")}${wait > 0 ? ` (${wait})` : ""}`}
                  onPress={send} busy={busy} disabled={wait > 0} />
          {sent || (!enrol && methods?.sent_to[method!]) ? <Notice text={t("mfa.sentTo", { to: sent?.sent_to ?? methods?.sent_to[method!] ?? "" })} /> : null}
        </View>
      ) : null}
      <ErrorText error={error} />
      {method || !enrol ? (
        <>
          <Field label={t("auth.code")} value={code} onChangeText={setCode} keyboardType={method || enrol ? "number-pad" : "default"}
                 textContentType="oneTimeCode" autoComplete="one-time-code" maxLength={20} onSubmitEditing={submit} editable={ready} />
          <Button label={t("auth.verify")} onPress={submit} busy={busy} disabled={!ready || code.length < 6} />
        </>
      ) : null}
      <Button label={t("common.cancel")} kind="text" onPress={async () => { await signOut(); router.replace("/login"); }} />
    </Screen>
  );
}
