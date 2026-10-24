import { useEffect, useRef, useState } from "react";
import { Alert, Image, Text, View } from "react-native";
import { router } from "expo-router";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useI18n, type Locale } from "../../i18n";
import { api, authHeaders } from "../../platform/api";
import { API_URL } from "../../platform/config";
import { useAuth } from "../../platform/auth";
import { Button, Card, Chip, ErrorText, Field, Loading, Screen, Tabs, s, PasswordField } from "../../ui/kit";
import { color, font } from "../../ui/theme";

const initials = (name?: string | null) => (name ?? "").trim().split(/\s+/).slice(0, 2).map((w) => w[0] ?? "").join("").toUpperCase() || "·";
import { useLoad } from "../../ui/useLoad";

interface Device { id: number; platform: string; app_version: string | null; last_seen_at: string | null; revoked_at: string | null; current: boolean }

/** The traveler's own photo, loaded from the API with the traveler's token (1096: only when the platform lets the traveler see it). */
function OwnPhoto() {
  const { t } = useI18n();
  const [headers, setHeaders] = useState<Record<string, string> | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => { void authHeaders().then(setHeaders); }, []);
  if (failed || !headers) return null;
  return (
    <Image accessibilityLabel={t("account.photoTitle")} resizeMode="cover" onError={() => setFailed(true)}
           source={{ uri: `${API_URL}/api/account/photo/image`, headers }}
           style={{ width: 160, height: 200, borderRadius: 12, alignSelf: "center" }} />
  );
}

/** The boarding photo (1086): taken once, with the front camera; the driver and the office compare it with the ID. */
function BoardingPhotoCard() {
  const { t, date } = useI18n();
  const status = useLoad(() => api.get<{ enabled: boolean; can_view: boolean; has_photo: boolean; taken_at: string | null }>("/api/account/photo"));
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
  // while the platform does not use the boarding photo, the app shows nothing of it (1096)
  if (status.data && !status.data.enabled) return null;
  return (
    <Card>
      <Text style={s.h2}>{t("account.photoTitle")}</Text>
      <ErrorText error={status.error ?? error} />
      {status.data?.has_photo ? (
        <>
          <Text style={s.small}>{t("account.photoOnFile", { date: date(status.data.taken_at ?? new Date().toISOString()) })}</Text>
          {status.data.can_view ? <OwnPhoto /> : null}
        </>
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
      {/* who is signed in: initials in the brand's circle, the name in the display face */}
      <View style={{ flexDirection: "row", alignItems: "center", gap: 14 }}>
        <View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: color.navy, alignItems: "center", justifyContent: "center" }}>
          <Text style={{ color: "#fff", fontFamily: font.displayBold, fontSize: 20 }}>{initials(me?.name)}</Text>
        </View>
        <View style={{ flex: 1 }}>
          <Text style={s.title} numberOfLines={1}>{me?.name ?? t("tabs.account")}</Text>
          {me?.email ? <Text style={s.muted} numberOfLines={1}>{me.email}</Text> : null}
        </View>
      </View>
      <ErrorText error={error ?? devices.error} />
      <Card>
        <Text style={s.h2}>{t("account.language")}</Text>
        <Tabs items={[{ key: "ar", label: t("account.arabic") }, { key: "en", label: t("account.english") }]} value={locale}
              onChange={(l) => { if (l !== locale) void choose(l as Locale); }} />
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
          <PasswordField label={t("common.password")} value={closePassword} onChangeText={setClosePassword}
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
