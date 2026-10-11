import { useRef, useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useI18n, type Locale } from "../../i18n";
import { api } from "../../platform/api";
import { useAuth } from "../../platform/auth";
import { Button, Card, Chip, ErrorText, Field, Loading, Screen, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";

interface Device { id: number; platform: string; app_version: string | null; last_seen_at: string | null; revoked_at: string | null; current: boolean }

/** The boarding photo (1086): taken once, with the front camera; the driver and the office compare it with the ID. */
function BoardingPhotoCard() {
  const { t, date } = useI18n();
  const status = useLoad(() => api.get<{ has_photo: boolean; taken_at: string | null }>("/api/account/photo"));
  const [permission, requestPermission] = useCameraPermissions();
  const cam = useRef<CameraView>(null);
  const [shooting, setShooting] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const shoot = async () => {
    setBusy(true); setError(null);
    try {
      const pic = await cam.current?.takePictureAsync({ quality: 0.7, skipProcessing: true });
      if (!pic) return;
      const form = new FormData();
      form.append("file", { uri: pic.uri, name: "photo.jpg", type: "image/jpeg" } as unknown as Blob);
      await api.upload("/api/account/photo", form);
      setShooting(false);
      status.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  if (status.loading && !status.data) return <Card><Loading /></Card>;
  return (
    <Card>
      <Text style={s.h2}>{t("account.photoTitle")}</Text>
      <ErrorText error={status.error ?? error} />
      {status.data?.has_photo ? (
        <Text style={s.small}>{t("account.photoOnFile", { date: date(status.data.taken_at ?? new Date().toISOString()) })}</Text>
      ) : !shooting ? (
        <>
          <Text style={s.small}>{t("account.photoNone")}</Text>
          <Button label={t("account.photoTake")} onPress={() => setShooting(true)} />
        </>
      ) : !permission?.granted ? (
        <Button label={t("account.photoAllow")} onPress={requestPermission} />
      ) : (
        <>
          <Text style={s.small}>{t("account.photoHow")}</Text>
          <View style={{ height: 320, borderRadius: 16, overflow: "hidden", backgroundColor: "#000" }}>
            <CameraView ref={cam} style={{ flex: 1 }} facing="front" />
          </View>
          <Button label={t("account.photoShoot")} busy={busy} onPress={shoot} />
          <Button kind="text" label={t("common.cancel")} onPress={() => setShooting(false)} />
        </>
      )}
    </Card>
  );
}

export function AccountBody() {
  const { t, locale, setLocale, date } = useI18n();
  const { me, signOut } = useAuth();
  const devices = useLoad(() => api.get<{ devices: Device[] }>("/api/account/devices"));
  const [error, setError] = useState<unknown>(null);
  const [closePassword, setClosePassword] = useState("");
  const [closeError, setCloseError] = useState<unknown>(null);
  const [closing, setClosing] = useState(false);
  const choose = async (l: Locale) => {
    if (await setLocale(l)) Alert.alert(t("account.language"), t("account.restart"));
  };
  const revoke = async (d: Device) => {
    setError(null);
    try { await api.post(`/api/account/devices/${d.id}/revoke`); devices.reload(); } catch (e) { setError(e); }
  };
  // keeps the data (1085): the sessions end and the same details reopen the account at the next sign-in
  const closeAccount = async () => {
    setClosing(true); setCloseError(null);
    try {
      await api.post("/api/account/deactivate", { password: closePassword });
      await signOut(); router.replace("/login");
    } catch (e) { setCloseError(e); setClosing(false); }
  };
  const confirmClose = () => Alert.alert(t("account.close"), t("account.closeConfirm"), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("account.closeAction"), style: "destructive", onPress: closeAccount },
  ]);
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
      {me?.portal === "PASSENGER" ? <BoardingPhotoCard /> : null}
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
      {me?.portal === "PASSENGER" ? (
        <Card>
          <Text style={s.h2}>{t("account.close")}</Text>
          <Text style={s.small}>{t("account.closeText")}</Text>
          <ErrorText error={closeError} />
          <Field label={t("common.password")} value={closePassword} onChangeText={setClosePassword} secureTextEntry
                 textContentType="password" />
          <Button kind="danger" label={t("account.closeAction")} onPress={confirmClose} busy={closing}
                  disabled={!closePassword} />
        </Card>
      ) : null}
      <Button kind="danger" label={t("common.signOut")} onPress={async () => { await signOut(); router.replace("/login"); }} />
    </>
  );
}

export default function Account() {
  return <Screen><AccountBody /></Screen>;
}
