import { useState } from "react";
import { Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../i18n";
import { useAuth } from "../platform/auth";
import { ApiError, guestStart, reactivate } from "../platform/api";
import { VARIANT } from "../platform/config";
import { Button, ErrorText, Field, Screen, Title, s, PasswordField } from "../ui/kit";
import { Lockup, TripLine } from "../ui/brand";

// The passenger app uses the individuals' door; the driver's and the operator's apps the business door (N16)
const STAFF = VARIANT !== "passenger";

export default function Login() {
  const { t, locale } = useI18n();
  const { signIn, firstPassword, guest } = useAuth();
  const [identifier, setIdentifier] = useState("");
  const [companyNo, setCompanyNo] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [fresh, setFresh] = useState({ next: "", confirm: "" });
  const [temporary, setTemporary] = useState(false);
  // booking without an account (N18): the passenger app only; an e-mail, then the code sent to it
  const [asGuest, setAsGuest] = useState(false);
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const ready = STAFF ? !!companyNo && !!username && !!password : !!identifier && !!password;
  const finish = async () => {
    if (await signIn(STAFF ? { company_no: companyNo, username } : { identifier }, password)) { setTemporary(true); return; }
    setPassword("");
    router.replace("/");
  };
  const choose = async () => {
    setBusy(true); setError(null);
    try { await firstPassword(password, fresh.next); setPassword(""); setFresh({ next: "", confirm: "" }); router.replace("/"); }
    catch (e) { setError(e); } finally { setBusy(false); }
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
  const sendCode = async () => {
    setBusy(true); setError(null);
    try { await guestStart(email, locale); setSent(true); setCode(""); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const guestIn = async () => {
    setBusy(true); setError(null);
    try { await guest(email, code); router.replace("/"); } catch (e) { setError(e); } finally { setBusy(false); }
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
      {temporary ? (
        <>
          <Text style={s.muted}>{t("auth.firstPassword")}</Text>
          <PasswordField label={t("auth.newPassword")} value={fresh.next} onChangeText={(v) => setFresh({ ...fresh, next: v })}
                         textContentType="newPassword" autoComplete="new-password" />
          <PasswordField label={t("auth.confirmPassword")} value={fresh.confirm} onChangeText={(v) => setFresh({ ...fresh, confirm: v })}
                         textContentType="newPassword" autoComplete="new-password" onSubmitEditing={choose} />
          {fresh.confirm && fresh.confirm !== fresh.next ? <Text style={s.muted}>{t("auth.passwordMismatch")}</Text> : null}
          <Button label={t("auth.savePassword")} onPress={choose} busy={busy}
                  disabled={fresh.next.length < 12 || fresh.confirm !== fresh.next} />
        </>
      ) : asGuest ? (
        <>
          <Text style={s.muted}>{t(sent ? "guest.codeSub" : "guest.sub", { email: email.trim() })}</Text>
          {!sent ? (
            <Field label={t("guest.email")} value={email} onChangeText={setEmail} autoCapitalize="none" autoCorrect={false}
                   keyboardType="email-address" textContentType="emailAddress" autoComplete="email" onSubmitEditing={sendCode} />
          ) : (
            <Field label={t("guest.code")} value={code} onChangeText={(v) => setCode(v.replace(/\D/g, ""))} keyboardType="number-pad"
                   maxLength={6} textContentType="oneTimeCode" autoComplete="one-time-code" onSubmitEditing={guestIn} />
          )}
          <Button label={t(sent ? "guest.continue" : "guest.send")} onPress={sent ? guestIn : sendCode} busy={busy}
                  disabled={sent ? code.length !== 6 : !/^\S+@\S+\.\S+$/.test(email.trim())} />
          {sent ? <Button kind="text" label={t("guest.resend")} onPress={sendCode} disabled={busy} /> : null}
          <Text style={s.muted}>{t("guest.note")}</Text>
          <Button kind="text" label={t("guest.haveAccount")} onPress={() => { setAsGuest(false); setError(null); }} />
        </>
      ) : (
        <>
          {STAFF ? (
            <>
              <Field label={t("auth.companyNo")} value={companyNo} onChangeText={(v) => setCompanyNo(v.replace(/\D/g, ""))}
                     keyboardType="number-pad" maxLength={8} autoCorrect={false} />
              <Field label={t("auth.username")} value={username} onChangeText={setUsername} autoCapitalize="none" autoCorrect={false}
                     textContentType="username" autoComplete="username" />
            </>
          ) : (
            <Field label={t("auth.identifier")} value={identifier} onChangeText={setIdentifier} autoCapitalize="none" autoCorrect={false}
                   keyboardType="email-address" textContentType="username" autoComplete="username" />
          )}
          <PasswordField label={t("common.password")} value={password} onChangeText={setPassword} textContentType="password"
                 autoComplete="current-password" onSubmitEditing={submit} />
          <Button label={t("common.signIn")} onPress={submit} busy={busy} disabled={!ready} />
          {closed && !STAFF ? <Button kind="tonal" label={t("auth.reactivate")} onPress={reopen} busy={busy} disabled={!ready} /> : null}
          {!STAFF ? <Button kind="text" label={t("guest.link")} onPress={() => { setAsGuest(true); setError(null); }} /> : null}
        </>
      )}
    </Screen>
  );
}
