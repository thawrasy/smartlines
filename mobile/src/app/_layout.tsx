// Root: providers in dependency order, then a start-up integrity check before any screen talks to the API.
import { useEffect, useState } from "react";
import { Text, View } from "react-native";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { I18nProvider, useI18n } from "../i18n";
import { AuthProvider } from "../platform/auth";
import { checkIntegrity, type Integrity } from "../platform/integrity";
import { VARIANT } from "../platform/config";
import { AppLock } from "../ui/AppLock";
import { Loading } from "../ui/kit";
import { color } from "../ui/theme";

function Gate() {
  const { t } = useI18n();
  const [integrity, setIntegrity] = useState<Integrity | null>(null);
  useEffect(() => {
    void checkIntegrity().then(setIntegrity, () => setIntegrity({ rooted: false, emulator: false, pinned: false, problem: "CHECK_FAILED" }));
  }, []);
  if (!integrity) return <Loading />;
  // No pinned, encrypted channel in a release build: refuse rather than send credentials over it.
  if (integrity.problem) return <Notice text={t("security.insecure")} />;
  // A driver phone that is rooted could forge boarding records offline.
  if (integrity.rooted && VARIANT === "driver") return <Notice text={t("security.driverRooted")} />;
  return (
    <AuthProvider>
      <AppLock>
        {integrity.rooted ? <Text style={{ backgroundColor: color.amberSoft, color: color.amber, padding: 10, paddingTop: 48, fontSize: 13 }}>{t("security.rooted")}</Text> : null}
        <Stack screenOptions={{ headerShown: false }} />
      </AppLock>
    </AuthProvider>
  );
}

function Notice({ text }: { text: string }) {
  return (
    <View style={{ flex: 1, alignItems: "center", justifyContent: "center", padding: 32, backgroundColor: color.background }}>
      <Text style={{ color: color.error, fontSize: 17, textAlign: "center" }}>{text}</Text>
    </View>
  );
}

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <I18nProvider>
        <StatusBar style="dark" />
        <Gate />
      </I18nProvider>
    </SafeAreaProvider>
  );
}
