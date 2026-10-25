// The roadside officer's app (owner's notes N47 and N48, migration 1169). The camera reads the movement code on the
// vehicle's placard, from a distance and while the vehicle moves (the code is the smallest QR symbol, printed across the
// whole page). The server answers with the vehicle and its current movement within what the officer's body may see, and
// opens a check; the officer may ask for a sample of passengers drawn by the server, or for all of them, and closes the
// check with its outcome. A code can also be typed. Each code is read once per few seconds.
import { useRef, useState } from "react";
import { Text, TextInput, View } from "react-native";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { useAuth } from "../../platform/auth";
import { vehicleCode } from "../../core/vehicleCode";
import { Button, Card, Chip, Choice, ErrorText, Loading, Notice, Screen, Tabs, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";
import { color } from "../../ui/theme";

interface Body { code: string; kind: string; name_ar: string | null; name_en: string | null; scopes: string[] }
interface Movement { kind: string; ref: string; status: string; departure_at: string | null; origin?: string | null; destination?: string | null;
  seats?: number | null; sold?: number | null; boarded?: number | null; crew: { role: string; name: string; licence_expiry: string | null }[];
  cargo?: { parcels: number; load_kg: number } | null; manifest_issued?: boolean | null }
interface Scan { check: string; result: string; warnings: string[]; body: string | null; movement: Movement | null; movement_hidden: boolean;
  vehicle: { plate_no: string; type: string; make: string | null; model: string | null; seats: number | null; status: string; carrier: string; carrier_status: string } }
interface Person { ticket: string; seat: number | null; boarded: boolean; name: string | null }
interface Check { uid: string; created_at: string; status: string; result: string; outcome: string | null; movement_ref: string | null; plate_no: string; carrier: string; body: string | null }
type Outcome = "CHECKED" | "ISSUE" | "ABSENT";

export default function Officer() {
  const { t, locale, dateTime } = useI18n();
  const { signOut } = useAuth();
  const [tab, setTab] = useState<"scan" | "mine">("scan");
  const bodies = useLoad(() => api.get<{ bodies: Body[]; platform: boolean }>("/api/roadside/bodies"));
  const mine = useLoad(() => tab === "mine" ? api.get<{ checks: Check[] }>("/api/roadside/checks") : Promise.resolve({ checks: [] as Check[] }), [tab]);
  const [permission, requestPermission] = useCameraPermissions();
  const [body, setBody] = useState<string | null>(null);
  const [scan, setScan] = useState<Scan | null>(null);
  const [people, setPeople] = useState<Person[] | null>(null);
  const [namesHidden, setNamesHidden] = useState(false);
  const [marks, setMarks] = useState<Record<string, Outcome>>({});
  const [note, setNote] = useState("");
  const [typed, setTyped] = useState("");
  const [closed, setClosed] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const last = useRef<{ code: string; at: number } | null>(null);
  const working = useRef(false);

  const list = bodies.data?.bodies ?? [];
  const acting = body ?? (list.length === 1 ? list[0].code : null);
  const needBody = list.length > 1 && !acting;
  const name = (b: Body) => (locale === "ar" ? b.name_ar : b.name_en) || b.code;

  const read = async (raw: string) => {
    const code = vehicleCode(raw);
    const now = Date.now();
    if (!code || working.current || scan || needBody || (last.current && last.current.code === code && now - last.current.at < 4000)) return;
    last.current = { code, at: now };
    working.current = true; setBusy(true); setError(null);
    try {
      setScan(await api.post<Scan>("/api/roadside/scan", { code, ...(acting ? { body: acting } : {}) }));
      setPeople(null); setMarks({}); setNote(""); setClosed(null); setTyped("");
    } catch (e) { setError(e); } finally { working.current = false; setBusy(false); }
  };
  const draw = async (mode: "SAMPLE" | "FULL") => {
    if (!scan) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ people: Person[]; names_hidden: boolean }>(`/api/roadside/checks/${scan.check}/sample`, { mode });
      setPeople(r.people); setNamesHidden(r.names_hidden);
      setMarks(Object.fromEntries(r.people.map((p) => [p.ticket, "CHECKED" as Outcome])));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const issues = Object.values(marks).some((m) => m !== "CHECKED");
  const close = async (outcome: "CLEAR" | "ISSUES") => {
    if (!scan) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/roadside/checks/${scan.check}/close`, {
        outcome, note: note.trim() || undefined, people: Object.entries(marks).map(([ticket, o]) => ({ ticket, outcome: o })) });
      setClosed(outcome);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const next = () => { setScan(null); setPeople(null); setMarks({}); setNote(""); setClosed(null); last.current = null; };

  if (bodies.loading && !bodies.data) return <Loading />;
  const tone = !scan ? null : scan.result !== "VALID" ? "red" : scan.warnings.length ? "amber" : "green";
  const [bg, fg] = tone === "red" ? [color.errorSoft, color.error] : tone === "amber" ? [color.amberSoft, color.amber] : [color.greenSoft, color.green];
  return (
    <Screen>
      <View style={s.between}>
        <Title sub={acting ?? undefined}>{t("officer.title")}</Title>
        <Button kind="text" label={t("common.signOut")} onPress={() => { void signOut(); }} />
      </View>
      <Tabs items={[{ key: "scan", label: t("officer.scan") }, { key: "mine", label: t("officer.mine") }]} value={tab} onChange={setTab} />
      <ErrorText error={error ?? bodies.error} />
      {tab === "mine" ? (
        mine.loading ? <Loading /> : (mine.data?.checks ?? []).length === 0 ? <Notice text={t("officer.none")} /> : (
          <View style={{ gap: 8 }}>{(mine.data?.checks ?? []).map((c) => (
            <Card key={c.uid}>
              <View style={s.between}><Text style={{ fontWeight: "700", fontSize: 16 }}>{c.plate_no}</Text>
                <Chip label={t(`officer.res.${c.result}`)} tone={c.result === "VALID" ? (c.outcome === "ISSUES" ? "amber" : "green") : "red"} /></View>
              <Text style={s.small}>{c.carrier}{c.movement_ref ? ` · ${c.movement_ref}` : ""}{c.body ? ` · ${c.body}` : ""}</Text>
              <Text style={s.small}>{dateTime(c.created_at)} · {c.outcome ? t(`officer.out.${c.outcome}`) : t("officer.open")}</Text>
            </Card>))}</View>)
      ) : (
        <>
          {list.length === 0 && !bodies.data?.platform ? <Notice tone="amber" text={t("officer.noBody")} /> : null}
          {list.length > 1 ? (
            <Choice label={t("officer.body")} value={acting ?? ""} onChange={(v) => setBody(v || null)}
                    options={list.map((b) => ({ value: b.code, label: name(b) }))} />
          ) : null}
          {!scan ? (
            !permission ? <Loading /> : !permission.granted ? (
              <Card>
                <Text style={s.muted}>{t("officer.camera")}</Text>
                <Button label={t("officer.allow")} onPress={requestPermission} />
              </Card>
            ) : (
              <>
                <View style={{ height: 380, borderRadius: 20, overflow: "hidden", backgroundColor: "#000" }}>
                  <CameraView style={{ flex: 1 }} facing="back" autofocus="on" barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
                              onBarcodeScanned={({ data }) => { void read(data); }} />
                </View>
                <Text style={s.small}>{needBody ? t("officer.pickBody") : busy ? t("common.loading") : t("officer.aim")}</Text>
              </>
            )
          ) : null}
          {!scan ? (
            <View style={{ gap: 8 }}>
              <TextInput style={s.input} autoCapitalize="characters" autoCorrect={false} maxLength={24} placeholder={t("officer.typed")}
                         accessibilityLabel={t("officer.typed")} value={typed} onChangeText={setTyped} />
              <Button kind="tonal" label={t("officer.check")} busy={busy} disabled={!vehicleCode(typed) || needBody} onPress={() => { void read(typed); }} />
            </View>
          ) : (
            <>
              <View accessibilityLiveRegion="assertive" style={{ backgroundColor: bg, borderRadius: 16, padding: 16, gap: 4 }}>
                <Text style={{ color: fg, fontSize: 26, fontWeight: "800", letterSpacing: 1 }}>{scan.vehicle.plate_no}</Text>
                <Text style={{ color: fg, fontSize: 18, fontWeight: "700" }}>{t(`officer.res.${scan.result}`)}</Text>
                <Text style={{ color: fg }}>{scan.vehicle.carrier}{scan.vehicle.seats ? ` · ${t("officer.seats", { n: scan.vehicle.seats })}` : ""}</Text>
                {scan.warnings.map((w) => <Text key={w} style={{ color: fg, fontWeight: "600" }}>• {t(`officer.warn.${w}`)}</Text>)}
              </View>
              {scan.movement ? (
                <Card>
                  <Text style={{ fontWeight: "700", fontSize: 16 }}>{t(`officer.mk.${scan.movement.kind}`)} {scan.movement.ref}</Text>
                  {scan.movement.origin || scan.movement.destination ? <Text>{scan.movement.origin ?? "?"} → {scan.movement.destination ?? "?"}</Text> : null}
                  {scan.movement.departure_at ? <Text style={s.small}>{t("officer.departs", { at: dateTime(scan.movement.departure_at) })} · {scan.movement.status}</Text> : null}
                  <Text>{t("officer.counts", { sold: scan.movement.sold ?? 0, boarded: scan.movement.boarded ?? 0, seats: scan.movement.seats ?? scan.vehicle.seats ?? 0 })}</Text>
                  {scan.movement.crew.map((c, i) => <Text key={i} style={s.small}>{t(`officer.role.${c.role}`)}: {c.name}{c.licence_expiry ? ` · ${t("officer.licence", { d: c.licence_expiry })}` : ""}</Text>)}
                  {scan.movement.cargo ? <Text style={s.small}>{t("officer.cargo", { n: scan.movement.cargo.parcels, kg: scan.movement.cargo.load_kg })}</Text> : null}
                </Card>
              ) : scan.movement_hidden ? <Notice text={t("officer.hidden")} /> : null}
              {closed ? (
                <>
                  <Notice tone="green" text={t("officer.closed", { outcome: t(`officer.out.${closed}`) })} />
                  <Button label={t("officer.next")} onPress={next} />
                </>
              ) : (
                <>
                  {scan.movement?.kind === "SCHEDULED_TRIP" && !people ? (
                    <View style={{ gap: 8 }}>
                      <Button kind="tonal" label={t("officer.sample")} busy={busy} onPress={() => { void draw("SAMPLE"); }} />
                      <Button kind="text" label={t("officer.full")} disabled={busy} onPress={() => { void draw("FULL"); }} />
                    </View>
                  ) : null}
                  {people ? (
                    <View style={{ gap: 8 }}>
                      <Text style={s.small}>{namesHidden ? t("officer.namesHidden") : t("officer.drawn", { n: people.length })}</Text>
                      {people.map((p) => (
                        <Card key={p.ticket}>
                          <Text style={{ fontWeight: "700" }}>{p.seat ? t("officer.seat", { n: p.seat }) : "—"}{p.name ? ` · ${p.name}` : ""}</Text>
                          <Text style={s.small}>{p.boarded ? t("officer.boarded") : t("officer.notBoarded")}</Text>
                          <Choice label={t("officer.result")} value={marks[p.ticket] ?? "CHECKED"} onChange={(v) => setMarks({ ...marks, [p.ticket]: v as Outcome })}
                                  options={(["CHECKED", "ISSUE", "ABSENT"] as const).map((o) => ({ value: o, label: t(`officer.person.${o}`) }))} />
                        </Card>))}
                    </View>
                  ) : null}
                  <TextInput style={[s.input, { minHeight: 64 }]} multiline maxLength={1000} placeholder={t("officer.note")} accessibilityLabel={t("officer.note")}
                             value={note} onChangeText={setNote} />
                  <Button label={t("officer.closeClear")} busy={busy} disabled={issues} onPress={() => { void close("CLEAR"); }} />
                  <Button kind="tonal" label={t("officer.closeIssues")} disabled={busy || (!issues && !note.trim())} onPress={() => { void close("ISSUES"); }} />
                </>
              )}
            </>
          )}
        </>
      )}
    </Screen>
  );
}
