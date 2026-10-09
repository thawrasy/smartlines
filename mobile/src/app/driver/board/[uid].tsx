// Boarding scanner. Each code is read once per few seconds (the camera reports it many times a second).
import { useCallback, useRef, useState } from "react";
import { Text, View } from "react-native";
import { router, useFocusEffect, useLocalSearchParams } from "expo-router";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useI18n } from "../../../i18n";
import { loadPack, loadScans, scan, sync, type Outcome } from "../../../platform/boarding";
import { clockIsOff } from "../../../core/offlineBoarding";
import { Button, ErrorText, Screen, Title, s } from "../../../ui/kit";
import { color } from "../../../ui/theme";

const tone = (r: string) => (r === "OK" ? [color.greenSoft, color.green] : r === "DUPLICATE" || r === "NOT_IN_PACK" ? [color.amberSoft, color.amber] : [color.errorSoft, color.error]);

export default function Board() {
  const { t } = useI18n();
  const { uid } = useLocalSearchParams<{ uid: string }>();
  const [permission, requestPermission] = useCameraPermissions();
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [pending, setPending] = useState(0);
  const [error, setError] = useState<unknown>(null);
  const [syncing, setSyncing] = useState(false);
  const [clockOff, setClockOff] = useState(false);
  const last = useRef<{ data: string; at: number } | null>(null);
  const working = useRef(false);

  const refreshPending = useCallback(async () => setPending((await loadScans(uid)).filter((x) => !x.synced).length), [uid]);
  useFocusEffect(useCallback(() => {
    void refreshPending();
    void loadPack(uid).then((p) => setClockOff(clockIsOff(p)));
  }, [refreshPending, uid]));

  const onCode = async (data: string) => {
    const now = Date.now();
    if (working.current || (last.current && last.current.data === data && now - last.current.at < 3000)) return;
    last.current = { data, at: now };
    working.current = true;
    setError(null);
    try { setOutcome(await scan(uid, data)); await refreshPending(); } catch (e) { setError(e); } finally { working.current = false; }
  };
  const doSync = async () => {
    setSyncing(true); setError(null);
    try { setPending(await sync(uid)); } catch (e) { setError(e); } finally { setSyncing(false); }
  };

  if (!permission) return <Screen><Text style={s.muted}>{t("common.loading")}</Text></Screen>;
  if (!permission.granted) {
    return (
      <Screen>
        <Title>{t("driver.board")}</Title>
        <Text style={s.muted}>{t("driver.camera")}</Text>
        <Button label={t("driver.allow")} onPress={requestPermission} />
        <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      </Screen>
    );
  }
  const [bg, fg] = outcome ? tone(String(outcome.result)) : [color.surface, color.text];
  return (
    <Screen scroll={false}>
      <Title sub={t("driver.scan")}>{t("driver.board")}</Title>
      {clockOff ? <Text style={{ color: color.amber, fontWeight: "600" }}>{t("driver.clockOff")}</Text> : null}
      <View style={{ height: 320, borderRadius: 20, overflow: "hidden", backgroundColor: "#000" }}>
        <CameraView style={{ flex: 1 }} facing="back" barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
                    onBarcodeScanned={({ data }) => { void onCode(data); }} />
      </View>
      {outcome ? (
        <View accessibilityLiveRegion="assertive" style={{ backgroundColor: bg, borderRadius: 16, padding: 16, gap: 4 }}>
          <Text style={{ color: fg, fontSize: 22, fontWeight: "700" }}>{t(`driver.results.${outcome.result}`)}</Text>
          {outcome.name ? <Text style={{ color: fg, fontSize: 16 }}>{outcome.name}{outcome.seat ? ` · ${t("common.seat")} ${outcome.seat}` : ""}</Text> : null}
          {outcome.offline ? <Text style={{ color: fg, fontSize: 13 }}>{t("common.offline")}</Text> : null}
        </View>
      ) : null}
      <ErrorText error={error} />
      <View style={s.between}>
        <Text style={s.small}>{pending ? t("driver.pending", { n: pending }) : t("driver.synced")}</Text>
        {pending ? <Button kind="tonal" label={t("common.sync")} busy={syncing} onPress={doSync} /> : null}
      </View>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
    </Screen>
  );
}
