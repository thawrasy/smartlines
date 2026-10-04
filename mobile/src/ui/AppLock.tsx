// App lock: after five minutes in the background the app asks for the device biometric or passcode before showing
// tickets or the wallet again. While in the app switcher the content is covered so a snapshot shows nothing.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { AppState, Text, View } from "react-native";
import * as LocalAuthentication from "expo-local-authentication";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useI18n } from "../i18n";
import { useAuth } from "../platform/auth";
import { Button } from "./kit";
import { color } from "./theme";

const LOCK_AFTER_MS = 5 * 60 * 1000;

export function AppLock({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const { status } = useAuth();
  const [locked, setLocked] = useState(false);
  const [covered, setCovered] = useState(false);
  const [noLock, setNoLock] = useState(false);
  const leftAt = useRef<number | null>(null);
  const insets = useSafeAreaInsets();

  useEffect(() => {
    void LocalAuthentication.getEnrolledLevelAsync().then((l) => setNoLock(l === LocalAuthentication.SecurityLevel.NONE));
    const sub = AppState.addEventListener("change", (next) => {
      if (next === "active") {
        setCovered(false);
        if (leftAt.current && Date.now() - leftAt.current > LOCK_AFTER_MS && status === "signedIn") setLocked(true);
        leftAt.current = null;
      } else {
        setCovered(true);
        leftAt.current ??= Date.now();
      }
    });
    return () => sub.remove();
  }, [status]);

  const unlock = async () => {
    const level = await LocalAuthentication.getEnrolledLevelAsync();
    if (level === LocalAuthentication.SecurityLevel.NONE) { setLocked(false); return; }   // nothing to check against
    const r = await LocalAuthentication.authenticateAsync({ promptMessage: t("security.unlockPrompt"), disableDeviceFallback: false });
    if (r.success) setLocked(false);
  };

  if (locked) {
    return (
      <View style={{ flex: 1, alignItems: "center", justifyContent: "center", gap: 24, padding: 32, backgroundColor: color.navy }}>
        <Text style={{ color: "#fff", fontSize: 22, fontWeight: "700" }}>{t("security.locked")}</Text>
        <View style={{ alignSelf: "stretch" }}><Button label={t("security.unlock")} onPress={unlock} /></View>
      </View>
    );
  }
  return (
    <View style={{ flex: 1 }}>
      {noLock && status === "signedIn" ? (
        <Text style={{ backgroundColor: color.amberSoft, color: color.amber, padding: 10, paddingTop: insets.top + 10, fontSize: 13 }}>{t("security.noPasscode")}</Text>
      ) : null}
      {children}
      {covered ? <View style={{ position: "absolute", top: 0, bottom: 0, left: 0, right: 0, backgroundColor: color.navy }} /> : null}
    </View>
  );
}
