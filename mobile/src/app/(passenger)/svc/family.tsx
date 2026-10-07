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
  first_name?: string; last_name?: string; mobile?: string | null; id_type?: string | null; id_last4?: string | null; passport_expiry?: string | null;
}
interface Rule { uid: string; rule_type: string; days: number[] | null; start_time: string | null; end_time: string | null;
                 from_city?: string | null; to_city?: string | null; line?: string | null }
interface View_ {
  role: "HEAD" | "MEMBER" | null; family?: { uid: string; name: string }; account?: { balance: number };
  members?: Member[]; me?: Member; rules?: Rule[];
  requests?: { uid: string; status: string; device_label: string | null; member: string }[];
}

/** Family accounts (study 4.20) on the phone: join a family from this device; for the head, register members, set how
 *  each one pays, their limits, times and routes, approve link requests, hand out codes and fund the family trips account. */
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
  const [open, setOpen] = useState<{ member?: Member } | null>(null);   // the member being added (no member) or edited
  const idem = useRef(randomUUID());
  const minor = Math.round(Number(amount) * 100);
  const move = (dir: "topup" | "withdraw") => run(async () => {
    await api.post(`/api/family/account/${dir}`, { amount: minor, idempotency_key: idem.current });
    idem.current = randomUUID(); setAmount("");
  });
  const fundingOptions = (["HEAD_WALLET", "FAMILY_ACCOUNT", "OWN"] as Funding[]).map((f) => ({ value: f, label: t(`family.funding.${f}`) }));
  if (open) return <MemberEditor member={open.member} onClose={() => setOpen(null)} run={run} busy={busy} />;
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
               onPress={m.relation === "SELF" ? undefined : () => setOpen({ member: m })}
               right={m.relation === "SELF" ? null : m.account_status === "LINKED" ? <Chip tone="green" label={t("family.linked")} />
                 : <Button kind="text" label={t("family.invite")}
                           onPress={() => run(async () => {
                             const r = await api.post<{ code: string }>(`/api/family/members/${m.uid}/invite`);
                             setCode({ name: m.full_name, code: r.code });
                           })} />} />
        ))}
        <Button kind="tonal" label={t("family.addMember")} onPress={() => setOpen({})} />
      </Card>
    </>
  );
}

const RELATIONS = ["SPOUSE", "SON", "DAUGHTER", "FATHER", "MOTHER", "BROTHER", "SISTER", "GRANDCHILD", "GRANDPARENT", "OTHER"];
const DOCS = ["NATIONAL_ID", "PASSPORT", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER"];
const isDate = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v));
const toMinor = (v: string) => (v.trim() ? Math.round(Number(v) * 100) : null);
const fromMinor = (n: number | null | undefined) => (n ? String(n / 100) : "");

/** Adds a member, or edits one: contact, document, how their own purchases are paid, limits; and their times and routes. */
function MemberEditor({ member, onClose, run, busy }: { member?: Member; onClose: () => void; run: Run; busy: boolean }) {
  const { t } = useI18n();
  const edit = !!member;
  const [v, setV] = useState({
    relation: "SON", first_name: "", father_name: "", grandfather_name: "", last_name: "", nationality: "SY", birth_date: "",
    gender: "" as "" | "M" | "F", id_type: member?.id_type ?? "NATIONAL_ID", id_no: "", passport_expiry: member?.passport_expiry ?? "",
    mobile: "", funding: (member?.funding ?? "HEAD_WALLET") as Funding,
    per_trip_limit: fromMinor(member?.per_trip_limit), daily_limit: fromMinor(member?.daily_limit), monthly_limit: fromMinor(member?.monthly_limit),
  });
  const set = (patch: Partial<typeof v>) => setV((x) => ({ ...x, ...patch }));
  const syrian = v.nationality === "SY";
  const ok = edit || (!!v.first_name.trim() && !!v.last_name.trim() && isDate(v.birth_date) && /^[A-Z]{2}$/.test(v.nationality));
  const money = (k: "per_trip_limit" | "daily_limit" | "monthly_limit", label: string) => (
    <Field label={label} value={v[k]} keyboardType="number-pad" onChangeText={(x) => set({ [k]: x.replace(/[^0-9]/g, "") })} />
  );
  const save = () => run(async () => {
    const limits = { funding: v.funding, per_trip_limit: toMinor(v.per_trip_limit), daily_limit: toMinor(v.daily_limit), monthly_limit: toMinor(v.monthly_limit) };
    const doc = { ...(v.id_no.trim() ? { id_type: v.id_type, id_no: v.id_no.trim() } : {}), ...(isDate(v.passport_expiry) ? { passport_expiry: v.passport_expiry } : {}) };
    if (edit) {
      // 0 removes a limit
      await api.patch(`/api/family/members/${member!.uid}`, { ...limits, per_trip_limit: limits.per_trip_limit ?? 0, daily_limit: limits.daily_limit ?? 0,
                                                             monthly_limit: limits.monthly_limit ?? 0,
                                                             ...(v.mobile.trim() ? { mobile: v.mobile.trim() } : {}), ...doc });
    } else {
      await api.post("/api/family/members", { ...limits, relation: v.relation, first_name: v.first_name.trim(), father_name: v.father_name.trim() || null,
        grandfather_name: v.grandfather_name.trim() || null, last_name: v.last_name.trim(), nationality: v.nationality, birth_date: v.birth_date,
        gender: v.gender || null, mobile: v.mobile.trim() || null, ...doc });
    }
    onClose();
  });
  const remove = () => Alert.alert(t("common.remove"), t("family.removeConfirm", { name: member!.full_name }), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("common.remove"), style: "destructive", onPress: () => void run(async () => { await api.del(`/api/family/members/${member!.uid}`); onClose(); }) }]);
  return (
    <>
      <Button kind="text" label={t("common.back")} onPress={onClose} />
      <Card>
        <Text style={s.h2}>{edit ? member!.full_name : t("family.addMember")}</Text>
        {!edit ? (
          <>
            <Choice label={t("family.relation")} value={v.relation} onChange={(x) => set({ relation: x })}
                    options={RELATIONS.map((r) => ({ value: r, label: t(`family.rel.${r}`) }))} />
            <Choice label={t("trip.nationality")} value={syrian ? "SY" : "X"} onChange={(x) => set({ nationality: x === "SY" ? "SY" : "" })}
                    options={[{ value: "SY", label: t("trip.syrian") }, { value: "X", label: t("trip.otherNationality") }]} />
            {!syrian ? <Field label={t("trip.nationality")} value={v.nationality} placeholder="LB" maxLength={2} autoCapitalize="characters"
                              onChangeText={(x) => set({ nationality: x.toUpperCase().replace(/[^A-Z]/g, "") })} /> : null}
            <Field label={t("trip.first")} value={v.first_name} onChangeText={(x) => set({ first_name: x })} autoComplete="off" />
            {syrian ? <Field label={t("trip.father")} value={v.father_name} onChangeText={(x) => set({ father_name: x })} autoComplete="off" /> : null}
            {syrian ? <Field label={t("trip.grandfather")} value={v.grandfather_name} onChangeText={(x) => set({ grandfather_name: x })} autoComplete="off" /> : null}
            <Field label={t("trip.last")} value={v.last_name} onChangeText={(x) => set({ last_name: x })} autoComplete="off" />
            <Field label={t("pax.birthDate")} value={v.birth_date} placeholder="YYYY-MM-DD" maxLength={10} onChangeText={(x) => set({ birth_date: x.trim() })} />
            <Choice label={t("family.gender")} value={v.gender} onChange={(x) => set({ gender: x })}
                    options={[{ value: "M", label: t("family.male") }, { value: "F", label: t("family.female") }]} />
          </>
        ) : null}
        <Field label={t("family.mobile")} value={v.mobile} keyboardType="phone-pad" placeholder={member?.mobile ?? undefined}
               onChangeText={(x) => set({ mobile: x.trim() })} />
        <Choice label={t("family.docType")} value={v.id_type} onChange={(x) => set({ id_type: x })}
                options={DOCS.map((d) => ({ value: d, label: t(`trip.docTypes.${d}`) }))} />
        <Field label={t("trip.docNumber")} value={v.id_no} autoCapitalize="characters" autoComplete="off"
               placeholder={member?.id_last4 ? `•••• ${member.id_last4}` : undefined} onChangeText={(x) => set({ id_no: x })} />
        {v.id_type === "PASSPORT" ? <Field label={t("family.passportExpiry")} value={v.passport_expiry} placeholder="YYYY-MM-DD" maxLength={10}
                                           onChangeText={(x) => set({ passport_expiry: x.trim() })} /> : null}
        <Text style={s.small}>{t("family.docPrivacy")}</Text>
      </Card>
      <Card>
        <Text style={s.h2}>{t("family.moneyTitle")}</Text>
        <Choice label={t("family.fundingCol")} value={v.funding} onChange={(x) => set({ funding: x })}
                options={(["HEAD_WALLET", "FAMILY_ACCOUNT", "OWN"] as Funding[]).map((f) => ({ value: f, label: t(`family.funding.${f}`) }))} />
        {money("per_trip_limit", t("family.perTrip"))}
        {money("daily_limit", t("family.daily"))}
        {money("monthly_limit", t("family.monthly"))}
      </Card>
      <Button label={t("common.save")} busy={busy} disabled={!ok} onPress={save} />
      {edit ? <Rules member={member!} run={run} busy={busy} /> : null}
      {edit ? <Button kind="danger" label={t("common.remove")} onPress={remove} /> : null}
    </>
  );
}

/** A member's travel rules: weekday time windows and city routes; with no rule of a kind, that kind is not limited. */
function Rules({ member, run, busy }: { member: Member; run: Run; busy: boolean }) {
  const { t, city } = useI18n();
  const rules = useLoad(() => api.get<{ rules: Rule[] }>(`/api/family/members/${member.uid}/rules`), [member.uid]);
  const ref = useLoad(() => api.get<{ cities: { code: string }[] }>("/api/ref"));
  const lines = useLoad(() => api.get<{ lines: { id: number; code: string; name: string; city: string | null }[] }>("/api/family/lines"));
  const [type, setType] = useState<"TIME_WINDOW" | "ROUTE" | "LINE">("TIME_WINDOW");
  const [line, setLine] = useState<number | null>(null);
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5]);
  const [start, setStart] = useState("07:00");
  const [end, setEnd] = useState("15:00");
  const [from, setFrom] = useState<string | null>(null);
  const [to, setTo] = useState<string | null>(null);
  const hhmm = (x: string) => /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(x);
  const cities = (ref.data?.cities ?? []).map((c) => ({ value: c.code, label: city(c.code) }));
  const valid = type === "TIME_WINDOW" ? days.length > 0 && hhmm(start) && hhmm(end) && start < end
    : type === "LINE" ? line != null : !!from && !!to && from !== to;
  const add = () => run(async () => {
    await api.post(`/api/family/members/${member.uid}/rules`, type === "TIME_WINDOW"
      ? { rule_type: type, days: [...days].sort(), start_time: start, end_time: end }
      : type === "LINE" ? { rule_type: type, line_id: line }
      : { rule_type: type, from_city: from, to_city: to, both_ways: true });
    rules.reload();
  });
  const del = (r: Rule) => run(async () => { await api.del(`/api/family/rules/${r.uid}`); rules.reload(); });
  return (
    <Card>
      <Text style={s.h2}>{t("family.rulesTitle")}</Text>
      <Text style={s.small}>{t("family.rulesHint")}</Text>
      {rules.loading && !rules.data ? <Loading /> : null}
      {rules.data && rules.data.rules.length === 0 ? <Text style={s.muted}>{t("family.noRules")}</Text> : null}
      {(rules.data?.rules ?? []).map((r) => (
        <Row key={r.uid} title={t(`family.rule.${r.rule_type}`)} sub={ruleText(r, t, city)}
             right={<Button kind="text" label={t("common.remove")} onPress={() => del(r)} />} />
      ))}
      <Choice value={type} onChange={setType}
              options={[{ value: "TIME_WINDOW", label: t("family.ruleTime") }, { value: "ROUTE", label: t("family.ruleRoute") },
                        { value: "LINE", label: t("family.ruleLine") }]} />
      {type === "TIME_WINDOW" ? (
        <>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
            {[1, 2, 3, 4, 5, 6, 7].map((d) => (
              <Button key={d} kind={days.includes(d) ? "primary" : "tonal"} label={t(`family.day.${d}`)}
                      onPress={() => setDays(days.includes(d) ? days.filter((x) => x !== d) : [...days, d])} />
            ))}
          </View>
          <View style={s.row}>
            <View style={{ flex: 1 }}><Field label={t("family.from")} value={start} placeholder="07:00" maxLength={5} onChangeText={(x) => setStart(x.trim())} /></View>
            <View style={{ flex: 1 }}><Field label={t("family.to")} value={end} placeholder="15:00" maxLength={5} onChangeText={(x) => setEnd(x.trim())} /></View>
          </View>
        </>
      ) : type === "LINE" ? (
        <>
          <Choice label={t("family.line")} value={line} onChange={setLine}
                  options={(lines.data?.lines ?? []).map((l) => ({ value: l.id, label: `${l.code} · ${l.name}${l.city ? ` · ${city(l.city)}` : ""}` }))} />
          <Text style={s.small}>{t("family.lineHint")}</Text>
        </>
      ) : (
        <>
          <Choice label={t("family.fromCity")} value={from} onChange={setFrom} options={cities} />
          <Choice label={t("family.toCity")} value={to} onChange={setTo} options={cities.filter((c) => c.value !== from)} />
        </>
      )}
      <Button kind="tonal" label={t("family.addRule")} busy={busy} disabled={!valid} onPress={add} />
    </Card>
  );
}
