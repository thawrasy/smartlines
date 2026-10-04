import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n, type Locale } from "../../i18n";
import { api } from "../../platform/api";
import { useAuth } from "../../platform/auth";
import { Button, Card, Chip, ErrorText, Screen, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";

interface Device { id: number; platform: string; app_version: string | null; last_seen_at: string | null; revoked_at: string | null; current: boolean }

export function AccountBody() {
  const { t, locale, setLocale, date } = useI18n();
  const { me, signOut } = useAuth();
  const devices = useLoad(() => api.get<{ devices: Device[] }>("/api/account/devices"));
  const [error, setError] = useState<unknown>(null);
  const choose = async (l: Locale) => {
    if (await setLocale(l)) Alert.alert(t("account.language"), t("account.restart"));
  };
  const revoke = async (d: Device) => {
    setError(null);
    try { await api.post(`/api/account/devices/${d.id}/revoke`); devices.reload(); } catch (e) { setError(e); }
  };
  return (
    <>
      <Title sub={me?.email ?? undefined}>{me?.name ?? t("tabs.account")}</Title>
      <ErrorText error={error ?? devices.error} />
      <Card>
        <Text style={s.h2}>{t("account.language")}</Text>
        <View style={s.row}>
          <Button kind={locale === "en" ? "primary" : "tonal"} label={t("account.english")} onPress={() => choose("en")} />
          <Button kind={locale === "ar" ? "primary" : "tonal"} label={t("account.arabic")} onPress={() => choose("ar")} />
        </View>
      </Card>
      <Card>
        <Text style={s.h2}>{t("account.devices")}</Text>
        {(devices.data?.devices ?? []).filter((d) => !d.revoked_at).map((d) => (
          <View key={d.id} style={s.between}>
            <View>
              <Text style={s.label}>{d.platform} {d.app_version ?? ""}</Text>
              {d.last_seen_at ? <Text style={s.small}>{date(d.last_seen_at)}</Text> : null}
            </View>
            {d.current ? <Chip tone="green" label={t("account.thisDevice")} /> : <Button kind="text" label={t("common.signOut")} onPress={() => revoke(d)} />}
          </View>
        ))}
      </Card>
      <Button kind="danger" label={t("common.signOut")} onPress={async () => { await signOut(); router.replace("/login"); }} />
    </>
  );
}

export default function Account() {
  return <Screen><AccountBody /></Screen>;
}
