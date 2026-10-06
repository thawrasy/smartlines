import { useRef, useState } from "react";
import { Alert, Text, View } from "react-native";
import * as Device from "expo-device";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { deviceId } from "../../../platform/secure";
import { Button, Card, Chip, Choice, ErrorText, Field, Loading, Notice, Row, Screen, Title, s } from "../../../ui/kit";
import { useLoad } from "../../../ui/useLoad";

type Funding = "OWN" | "HEAD_WALLET" | "FAMILY_ACCOUNT";
interface Member {
  uid: string; relation: string; full_name: string; age: number; account_status: string; funding: Funding;
  per_trip_limit: number | null; daily_limit: number | null; monthly_limit: number | null;
}
interface Rule { uid: string; rule_type: string; days: number[] | null; start_time: string | null; end_time: string | null;
                 from_city?: string | null; to_city?: string | null; line?: string | null }
interface View_ {
  role: "HEAD" | "MEMBER" | null; family?: { uid: string; name: string }; account?: { balance: number };
  members?: Member[]; me?: Member; rules?: Rule[];
  requests?: { uid: string; status: string; device_label: string | null; member: string }[];
}

/** Family accounts (study 4.20) on the phone: join a family from this device, and for the head, approve such requests,
 *  hand out codes and move money into the family trips account. Members and rules are edited on the website. */
export default function Family() {
  const { t, money } = useI18n();
  const v = useLoad(() => api.get<View_>("/api/family"));
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const run = async (f: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await f(); v.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  if (v.loading && !v.data) return <Screen><Loading /></Screen>;
  const d = v.data;
  return (
    <Screen>
      <Title sub={t("family.subtitle")}>{d?.family?.name ?? t("family.title")}</Title>
      <ErrorText error={error ?? v.error} />
      {d && !d.role ? <Start run={run} busy={busy} /> : null}
      {d?.role === "MEMBER" && d.me ? <MemberView me={d.me} rules={d.rules ?? []} run={run} busy={busy} /> : null}
      {d?.role === "HEAD" ? <HeadView d={d} run={run} busy={busy} money={money} /> : null}
    </Screen>
  );
}

type Run = (f: () => Promise<unknown>) => Promise<void>;

function Start({ run, busy }: { run: Run; busy: boolean }) {
  const { t } = useI18n();
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  return (
    <>
      <Card>
        <Text style={s.h2}>{t("family.joinTitle")}</Text>
        <Text style={s.small}>{t("family.joinHint")}</Text>
        <Field label={t("family.code")} value={code} maxLength={8} autoCapitalize="characters" autoComplete="off"
               onChangeText={(x) => setCode(x.replace(/[^A-Za-z0-9]/g, "").toUpperCase())} />
        {sent ? <Notice tone="green" text={t("family.joinSent")} /> : null}
        <Button label={t("family.join")} busy={busy} disabled={code.length !== 8}
                onPress={() => run(async () => {
                  await api.post("/api/family/join", { code, device_id: await deviceId(),
                                                       device_label: [Device.manufacturer, Device.modelName].filter(Boolean).join(" ") || null });
                  setSent(true);
                })} />
      </Card>
      <Card>
        <Text style={s.h2}>{t("family.createTitle")}</Text>
        <Text style={s.small}>{t("family.createHint")}</Text>
        <Field label={t("family.name")} value={name} onChangeText={setName} maxLength={80} />
        <Button kind="tonal" label={t("family.create")} busy={busy} disabled={name.trim().length < 2}
                onPress={() => run(() => api.post("/api/family", { name: name.trim() }))} />
      </Card>
    </>
  );
}

function limits(m: Member, t: (k: string, v?: Record<string, string | number>) => string, money: (n: number) => string) {
  return [m.per_trip_limit != null ? `${t("family.perTrip")} ${money(m.per_trip_limit)}` : null,
          m.daily_limit != null ? `${t("family.daily")} ${money(m.daily_limit)}` : null,
          m.monthly_limit != null ? `${t("family.monthly")} ${money(m.monthly_limit)}` : null].filter(Boolean).join(" · ");
}

function ruleText(r: Rule, t: (k: string) => string, city: (c: string) => string) {
  if (r.rule_type === "TIME_WINDOW")
    return `${(r.days ?? []).map((x) => t(`family.day.${x}`)).join(" ")} ${r.start_time?.slice(0, 5) ?? ""}–${r.end_time?.slice(0, 5) ?? ""}`;
  if (r.rule_type === "ROUTE") return `${city(r.from_city ?? "")} ↔ ${city(r.to_city ?? "")}`;
  return r.line ?? "";
}

function MemberView({ me, rules, run, busy }: { me: Member; rules: Rule[]; run: Run; busy: boolean }) {
  const { t, money, city } = useI18n();
  return (
    <>
      <Card>
        <Text style={s.label}>{t("family.howYouPay")}</Text>
        <Text style={s.h2}>{t(`family.funding.${me.funding}`)}</Text>
        {limits(me, t, money) ? <Text style={s.small}>{limits(me, t, money)}</Text> : null}
      </Card>
      <Card>
        <Text style={s.h2}>{t("family.rulesTitle")}</Text>
        {rules.length === 0 ? <Text style={s.muted}>{t("family.noRules")}</Text>
          : rules.map((r) => <Row key={r.uid} title={t(`family.rule.${r.rule_type}`)} sub={ruleText(r, t, city)} />)}
      </Card>
      <Button kind="danger" label={t("family.leave")} busy={busy}
              onPress={() => Alert.alert(t("family.leave"), t("family.leaveConfirm"), [
                { text: t("common.cancel"), style: "cancel" },
                { text: t("family.leave"), style: "destructive", onPress: () => void run(() => api.post("/api/family/leave")) }])} />
    </>
  );
}

function HeadView({ d, run, busy, money }: { d: View_; run: Run; busy: boolean; money: (n: number) => string }) {
  const { t } = useI18n();
  const [amount, setAmount] = useState("");
  const [funding, setFunding] = useState<Record<string, Funding>>({});
  const [code, setCode] = useState<{ name: string; code: string } | null>(null);
  const idem = useRef(randomUUID());
  const minor = Math.round(Number(amount) * 100);
  const move = (dir: "topup" | "withdraw") => run(async () => {
    await api.post(`/api/family/account/${dir}`, { amount: minor, idempotency_key: idem.current });
    idem.current = randomUUID(); setAmount("");
  });
  const fundingOptions = (["HEAD_WALLET", "FAMILY_ACCOUNT", "OWN"] as Funding[]).map((f) => ({ value: f, label: t(`family.funding.${f}`) }));
  return (
    <>
      {(d.requests ?? []).filter((r) => r.status === "PENDING").map((r) => (
        <Card key={r.uid}>
          <Text style={s.h2}>{t("family.requestTitle", { name: r.member })}</Text>
          <Text style={s.small}>{t("family.requestHint", { device: r.device_label ?? "—" })}</Text>
          <Choice label={t("family.fundingCol")} options={fundingOptions} value={funding[r.uid] ?? "HEAD_WALLET"}
                  onChange={(f) => setFunding({ ...funding, [r.uid]: f })} />
          <View style={s.row}>
            <Button label={t("family.approve")} busy={busy}
                    onPress={() => run(() => api.post(`/api/family/requests/${r.uid}/approve`, { funding: funding[r.uid] ?? "HEAD_WALLET" }))} />
            <Button kind="text" label={t("family.reject")} onPress={() => run(() => api.post(`/api/family/requests/${r.uid}/reject`))} />
          </View>
        </Card>
      ))}
      <Card>
        <View style={s.between}>
          <Text style={s.h2}>{t("family.account")}</Text>
          <Text style={s.h2}>{money(d.account?.balance ?? 0)}</Text>
        </View>
        <Field label={t("family.amount")} value={amount} keyboardType="number-pad" onChangeText={(x) => setAmount(x.replace(/[^0-9]/g, ""))} />
        <View style={s.row}>
          <Button label={t("family.topup")} busy={busy} disabled={!(minor > 0)} onPress={() => move("topup")} />
          <Button kind="tonal" label={t("family.withdraw")} disabled={!(minor > 0)} onPress={() => move("withdraw")} />
        </View>
      </Card>
      {code ? (
        <Card>
          <Text style={s.h2}>{t("family.inviteTitle")}</Text>
          <Text style={[s.title, { letterSpacing: 4, textAlign: "center" }]} selectable>{code.code}</Text>
          <Text style={s.small}>{t("family.inviteHint", { name: code.name })}</Text>
        </Card>
      ) : null}
      <Card>
        <Text style={s.h2}>{t("family.members")}</Text>
        {(d.members ?? []).map((m) => (
          <Row key={m.uid} title={m.full_name} sub={`${t(`family.rel.${m.relation}`)} · ${t("family.age")} ${m.age} · ${t(`family.funding.${m.funding}`)}`}
               right={m.relation === "SELF" ? null : m.account_status === "LINKED" ? <Chip tone="green" label={t("family.linked")} />
                 : <Button kind="text" label={t("family.invite")}
                           onPress={() => run(async () => {
                             const r = await api.post<{ code: string }>(`/api/family/members/${m.uid}/invite`);
                             setCode({ name: m.full_name, code: r.code });
                           })} />} />
        ))}
        <Text style={s.small}>{t("family.webHint")}</Text>
      </Card>
    </>
  );
}
