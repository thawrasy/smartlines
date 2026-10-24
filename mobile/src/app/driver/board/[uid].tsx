// Boarding scanner. Each code is read once per few seconds (the camera reports it many times a second). A ticket without a
// code yet (paper printed long before departure, owner's decision O1) is typed in by its number and booking reference and
// boarded once the identity document is checked, online or from the offline pack.
import { useCallback, useRef, useState } from "react";
import { Switch, Text, TextInput, View } from "react-native";
import { router, useFocusEffect, useLocalSearchParams } from "expo-router";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useI18n } from "../../../i18n";
import { boardTyped, loadPack, loadScans, scan, sync, type Outcome } from "../../../platform/boarding";
import { clockIsOff } from "../../../core/offlineBoarding";
import { PassengerPhoto } from "../../../ui/PassengerPhoto";
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
  const [typed, setTyped] = useState({ ticketNo: "", bookingRef: "", checked: false });
  const [typing, setTyping] = useState(false);
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
  const onTyped = async () => {
    if (working.current) return;
    working.current = true; setError(null);
    try {
      const out = await boardTyped(uid, typed.ticketNo, typed.bookingRef);
      setOutcome(out);
      if (out.result === "OK") setTyped({ ticketNo: "", bookingRef: "", checked: false });
      await refreshPending();
    } catch (e) { setError(e); } finally { working.current = false; }
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
    <Screen>
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
      {outcome?.result === "OK" && outcome.ticket && !outcome.offline ? <PassengerPhoto tripUid={uid} ticketUid={outcome.ticket} /> : null}
      <View style={{ gap: 8 }}>
        <Button kind="text" label={t("driver.typed")} onPress={() => setTyping(!typing)} />
        {typing ? (
          <View style={{ gap: 8 }}>
            <Text style={s.small}>{t("driver.typedHint")}</Text>
            <TextInput style={s.input} autoCapitalize="characters" autoCorrect={false} placeholder={t("driver.ticketNo")}
                       accessibilityLabel={t("driver.ticketNo")} value={typed.ticketNo} onChangeText={(v) => setTyped({ ...typed, ticketNo: v })} />
            <TextInput style={s.input} autoCapitalize="characters" autoCorrect={false} placeholder={t("driver.bookingRef")}
                       accessibilityLabel={t("driver.bookingRef")} value={typed.bookingRef} onChangeText={(v) => setTyped({ ...typed, bookingRef: v })} />
            <View style={[s.between, { gap: 12 }]}>
              <Text style={[s.small, { flex: 1 }]}>{t("driver.identityChecked")}</Text>
              <Switch value={typed.checked} onValueChange={(v) => setTyped({ ...typed, checked: v })} accessibilityLabel={t("driver.identityChecked")} />
            </View>
            <Button label={t("driver.boardTyped")} onPress={onTyped}
                    disabled={!typed.checked || typed.ticketNo.trim().length < 3 || typed.bookingRef.trim().length < 4} />
          </View>
        ) : null}
      </View>
      <ErrorText error={error} />
      <View style={s.between}>
        <Text style={s.small}>{pending ? t("driver.pending", { n: pending }) : t("driver.synced")}</Text>
        {pending ? <Button kind="tonal" label={t("common.sync")} busy={syncing} onPress={doSync} /> : null}
      </View>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
    </Screen>
  );
}
