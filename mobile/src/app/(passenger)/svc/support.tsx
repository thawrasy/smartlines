import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, CarrierName, Chip, Choice, Empty, ErrorText, Field, ListCard, Loading, Notice, Screen, SvcHeader, s } from "../../../ui/kit";
import { Icon } from "../../../ui/brand";
import { color, font } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Case { uid: string; ref: string; kind: string; category: string; status: string; subject: string; booking_ref: string | null;
                 created_at: string; replies?: number; csat?: number | null }
interface Message { kind: string; mine: boolean; body: string | null; created_at: string }
interface Ratable { ticket_uid: string; origin: string; destination: string; carrier_name: string; carrier_uid?: string | null; carrier_logo?: string | null; departure_at: string }

const KINDS = ["COMPLAINT", "INQUIRY", "CLAIM"] as const;
const CATS = ["DELAY", "CANCELLATION", "REFUND", "BAGGAGE", "STAFF", "VEHICLE", "SAFETY", "PAYMENT", "ACCOUNT", "OTHER"] as const;
const tone = (st: string) => (st === "RESOLVED" || st === "CLOSED" ? "green" : st === "REJECTED" ? "red" : st === "WAITING" ? "amber" : "blue");

function Stars({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <View style={{ flexDirection: "row", gap: 6 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <Pressable key={n} accessibilityRole="button" accessibilityLabel={`${n}`} onPress={() => onChange(n)} hitSlop={8}>
          <Text style={{ fontSize: 30, color: n <= value ? "#C9A227" : color.outline }}>★</Text>
        </Pressable>
      ))}
    </View>
  );
}

/** Support (study 7.6) on the phone: open a complaint, question or claim, follow the replies, and rate recent trips. */
export default function Support() {
  const { t } = useI18n();
  const cases = useLoad(() => api.get<{ cases: Case[] }>("/api/support/cases"));
  const ratable = useLoad(() => api.get<{ tickets: Ratable[] }>("/api/support/ratable"));
  const [mode, setMode] = useState<"list" | "new" | string>("list");
  if (mode === "new") return <NewCase done={() => { setMode("list"); cases.reload(); }} />;
  if (mode !== "list") return <Thread uid={mode} back={() => { setMode("list"); cases.reload(); }} />;
  return (
    <Screen>
      <SvcHeader icon="chat" title={t("svc.support.title")} sub={t("svc.support.sub")} onBack={() => router.back()} />
      <Button label={t("svc.support.new")} icon={<Icon name="plus" size={20} tint="#fff" />} onPress={() => setMode("new")} />
      {(ratable.data?.tickets ?? []).map((tk) => <RateTrip key={tk.ticket_uid} trip={tk} done={ratable.reload} />)}
      {cases.loading && !cases.data ? <Loading /> : <ErrorText error={cases.error} />}
      {cases.data && cases.data.cases.length === 0 ? <Empty icon="chat" text={t("svc.support.none")} /> : null}
      {(cases.data?.cases ?? []).map((c) => (
        <ListCard key={c.uid} title={c.subject} sub={`${t(`svc.support.kind.${c.kind}`)}${c.replies ? ` · ${t("svc.support.replies", { n: c.replies })}` : ""}`}
                  right={<Chip label={t(`status.${c.status}`)} tone={tone(c.status)} />} onPress={() => setMode(c.uid)}>
          <Text style={s.mono}>{c.ref}</Text>
        </ListCard>
      ))}
    </Screen>
  );
}

function RateTrip({ trip, done }: { trip: Ratable; done: () => void }) {
  const { t } = useI18n();
  const [stars, setStars] = useState(0);
  const [comment, setComment] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  return (
    <Card>
      <View style={s.row}><Icon name="ticket" size={20} tint={color.primary} /><Text style={[s.h2, { flex: 1 }]}>{t("svc.support.rate", { from: trip.origin, to: trip.destination })}</Text></View>
      <CarrierName name={trip.carrier_name} uid={trip.carrier_uid} logo={trip.carrier_logo} />
      <Stars value={stars} onChange={setStars} />
      {stars > 0 ? (
        <>
          <Field label={t("svc.support.comment")} value={comment} onChangeText={setComment} maxLength={1000} />
          <Button kind="tonal" label={t("svc.support.sendRating")} busy={busy} onPress={async () => {
            setBusy(true); setError(null);
            try { await api.post("/api/support/ratings", { ticket_uid: trip.ticket_uid, stars, comment: comment || null }); done(); }
            catch (e) { setError(e); } finally { setBusy(false); }
          }} />
        </>
      ) : null}
      <ErrorText error={error} />
    </Card>
  );
}

function NewCase({ done }: { done: () => void }) {
  const { t } = useI18n();
  const [kind, setKind] = useState<(typeof KINDS)[number]>("COMPLAINT");
  const [category, setCategory] = useState<(typeof CATS)[number]>("OTHER");
  const [subject, setSubject] = useState("");
  const [description, setDescription] = useState("");
  const [booking, setBooking] = useState("");
  const [amount, setAmount] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  return (
    <Screen>
      <SvcHeader icon="chat" title={t("svc.support.new")} sub={t(`svc.support.kindHint.${kind}`)} onBack={done} />
      <Choice label={t("svc.support.kindLabel")} options={KINDS.map((k) => ({ value: k, label: t(`svc.support.kind.${k}`) }))}
              value={kind} onChange={setKind} />
      <Choice label={t("svc.support.category")} options={CATS.map((c) => ({ value: c, label: t(`svc.support.cat.${c}`) }))}
              value={category} onChange={setCategory} />
      <Field label={t("svc.support.booking")} hint={kind === "CLAIM" ? t("svc.support.bookingRequired") : undefined} value={booking}
             autoCapitalize="characters" maxLength={12} onChangeText={(x) => setBooking(x.toUpperCase())} />
      <Field label={t("svc.support.subject")} value={subject} onChangeText={setSubject} maxLength={160} />
      <Field label={t("svc.support.description")} value={description} onChangeText={setDescription} maxLength={4000} multiline />
      {kind === "CLAIM" ? <Field label={t("svc.support.amount")} value={amount} keyboardType="number-pad" onChangeText={setAmount} /> : null}
      <ErrorText error={error} />
      <Button label={t("svc.support.send")} busy={busy} disabled={subject.trim().length < 4 || description.trim().length < 10}
              onPress={async () => {
                setBusy(true); setError(null);
                try {
                  await api.post("/api/support/cases", { kind, category, subject, description, booking_ref: booking || null,
                                                         claim_amount: kind === "CLAIM" && amount ? Number(amount) : null });
                  done();
                } catch (e) { setError(e); } finally { setBusy(false); }
              }} />
      <Button kind="text" label={t("svc.cancel")} onPress={done} />
    </Screen>
  );
}

function Thread({ uid, back }: { uid: string; back: () => void }) {
  const { t } = useI18n();
  const v = useLoad(() => api.get<{ case: Case; messages: Message[] }>(`/api/support/cases/${uid}`));
  const [reply, setReply] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const run = async (f: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await f(); v.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  if (v.loading && !v.data) return <Screen><Loading /></Screen>;
  const c = v.data?.case;
  return (
    <Screen>
      <SvcHeader icon="chat" title={c?.subject ?? ""} sub={c ? `${c.ref} · ${t(`svc.support.kind.${c.kind}`)}` : undefined} onBack={back} />
      <ErrorText error={error ?? v.error} />
      {c ? <Chip label={t(`status.${c.status}`)} tone={tone(c.status)} /> : null}
      {(v.data?.messages ?? []).length === 0 ? <Notice text={t("svc.support.noReplies")} /> : null}
      {(v.data?.messages ?? []).map((m, i) => (
        <View key={i} style={[ss.bubble, m.mine ? ss.mine : ss.team]}>
          <Text style={[ss.who, m.mine && { color: "#DCE7FD" }]}>{m.mine ? t("svc.support.you") : t("svc.support.team")}</Text>
          <Text style={[ss.body, m.mine && { color: "#fff" }]}>{m.body}</Text>
        </View>
      ))}
      {c && !["CLOSED", "REJECTED"].includes(c.status) ? (
        <>
          <Field label={t("svc.support.reply")} value={reply} onChangeText={setReply} maxLength={4000} multiline />
          <Button label={t("svc.support.send")} busy={busy} disabled={!reply.trim()}
                  onPress={() => run(async () => { await api.post(`/api/support/cases/${uid}/messages`, { body: reply }); setReply(""); })} />
        </>
      ) : null}
      {c && ["RESOLVED", "CLOSED"].includes(c.status) ? (
        <Card>
          <Text style={s.small}>{c.csat ? t("svc.support.thanks") : t("svc.support.csat")}</Text>
          <Stars value={c.csat ?? 0} onChange={(n) => run(() => api.post(`/api/support/cases/${uid}/satisfaction`, { score: n }))} />
        </Card>
      ) : null}
    </Screen>
  );
}

const ss = StyleSheet.create({
  bubble: { maxWidth: "86%", paddingHorizontal: 14, paddingVertical: 10, gap: 2 },
  mine: { alignSelf: "flex-end", backgroundColor: color.primary, borderRadius: 18, borderBottomRightRadius: 4 },
  team: { alignSelf: "flex-start", backgroundColor: color.surface, borderRadius: 18, borderBottomLeftRadius: 4, borderWidth: 1, borderColor: color.outline },
  who: { fontFamily: font.medium, fontSize: 12, color: color.muted },
  body: { fontFamily: font.body, fontSize: 15, color: color.text, lineHeight: 22 },
});
