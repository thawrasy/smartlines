import { useState } from "react";
import { Pressable, Text, View } from "react-native";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, Choice, ErrorText, Field, Loading, Notice, Row, Screen, Title, s } from "../../../ui/kit";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Case { uid: string; ref: string; kind: string; category: string; status: string; subject: string; booking_ref: string | null;
                 created_at: string; replies?: number; csat?: number | null }
interface Message { kind: string; mine: boolean; body: string | null; created_at: string }
interface Ratable { ticket_uid: string; origin: string; destination: string; carrier_name: string; departure_at: string }

const KINDS = ["COMPLAINT", "INQUIRY", "CLAIM"] as const;
const CATS = ["DELAY", "CANCELLATION", "REFUND", "BAGGAGE", "STAFF", "VEHICLE", "SAFETY", "PAYMENT", "ACCOUNT", "OTHER"] as const;
const tone = (st: string) => (st === "RESOLVED" || st === "CLOSED" ? "green" : st === "REJECTED" ? "red" : st === "WAITING" ? "amber" : "blue");

function Stars({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <View style={{ flexDirection: "row", gap: 6 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <Pressable key={n} accessibilityRole="button" accessibilityLabel={`${n}`} onPress={() => onChange(n)} hitSlop={8}>
          <Text style={{ fontSize: 28, color: n <= value ? "#C9A227" : color.muted }}>★</Text>
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
      <Title sub={t("svc.support.sub")}>{t("svc.support.title")}</Title>
      <Button label={t("svc.support.new")} onPress={() => setMode("new")} />
      {(ratable.data?.tickets ?? []).map((tk) => <RateTrip key={tk.ticket_uid} trip={tk} done={ratable.reload} />)}
      {cases.loading && !cases.data ? <Loading /> : <ErrorText error={cases.error} />}
      {cases.data && cases.data.cases.length === 0 ? <Text style={s.muted}>{t("svc.support.none")}</Text> : null}
      {(cases.data?.cases ?? []).map((c) => (
        <Row key={c.uid} title={c.subject} sub={`${c.ref} · ${t(`svc.support.kind.${c.kind}`)}${c.replies ? ` · ${t("svc.support.replies", { n: c.replies })}` : ""}`}
             right={<Chip label={t(`status.${c.status}`)} tone={tone(c.status)} />} onPress={() => setMode(c.uid)} />
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
      <Text style={s.h2}>{t("svc.support.rate", { from: trip.origin, to: trip.destination })}</Text>
      <Text style={s.small}>{trip.carrier_name}</Text>
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
      <Title sub={t(`svc.support.kindHint.${kind}`)}>{t("svc.support.new")}</Title>
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
      <Title sub={c ? `${c.ref} · ${t(`svc.support.kind.${c.kind}`)}` : undefined}>{c?.subject ?? ""}</Title>
      <ErrorText error={error ?? v.error} />
      {c ? <Chip label={t(`status.${c.status}`)} tone={tone(c.status)} /> : null}
      {(v.data?.messages ?? []).length === 0 ? <Notice text={t("svc.support.noReplies")} /> : null}
      {(v.data?.messages ?? []).map((m, i) => (
        <Card key={i} style={{ alignSelf: m.mine ? "flex-end" : "flex-start", maxWidth: "90%" }}>
          <Text style={s.small}>{m.mine ? t("svc.support.you") : t("svc.support.team")}</Text>
          <Text>{m.body}</Text>
        </Card>
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
      <Button kind="text" label={t("svc.support.back")} onPress={back} />
    </Screen>
  );
}
