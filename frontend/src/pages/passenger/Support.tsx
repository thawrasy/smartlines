import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

interface Case {
  uid: string; ref: string; kind: string; category: string; status: string; subject: string; booking_ref: string | null;
  claim_amount: number | null; approved_amount: number | null; payout_status: string; resolution: string | null; csat: number | null;
  created_at: string; replies?: number;
}
interface Message { kind: string; mine: boolean; body: string | null; created_at: string }
interface Ratable { ticket_uid: string; ticket_no: string; trip_no: string; departure_at: string; origin: string; destination: string; carrier_name: string }

const KINDS = ["COMPLAINT", "INQUIRY", "CLAIM"] as const;

function Stars({ value, onChange, label }: { value: number; onChange: (v: number) => void; label: string }) {
  return (
    <div className="row" role="radiogroup" aria-label={label} style={{ gap: 2 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} type="button" className="btn text icon" role="radio" aria-checked={value === n} aria-label={`${n}`}
                onClick={() => onChange(n)} style={{ color: n <= value ? "var(--wheat, #c9a227)" : "var(--muted, #999)", padding: 2 }}>
          <Icon name="star" size={26} />
        </button>
      ))}
    </div>
  );
}

function RateTrip({ trip, done }: { trip: Ratable; done: () => void }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const [stars, setStars] = useState(0);
  const [comment, setComment] = useState("");
  const [error, setError] = useState<unknown>(null);
  const send = async () => {
    setError(null);
    try {
      await api.post("/api/support/ratings", { ticket_uid: trip.ticket_uid, stars, comment: comment || null });
      toast(t("support.rated")); done();
    } catch (e) { setError(e); }
  };
  return (
    <div className="card stack tight">
      <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
        <div><strong>{trip.origin} → {trip.destination}</strong><div className="small muted">{trip.carrier_name} · {dateTime(trip.departure_at)}</div></div>
        <Stars value={stars} onChange={setStars} label={t("support.stars")} />
      </div>
      {stars > 0 && (
        <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
          <input className="input" style={{ flex: 1, minWidth: 200 }} maxLength={1000} placeholder={t("support.comment")}
                 value={comment} onChange={(e) => setComment(e.target.value)} />
          <button className="btn" onClick={send}>{t("support.sendRating")}</button>
        </div>
      )}
      {error ? <ErrorBox error={error} /> : null}
    </div>
  );
}

function NewCase({ onClose, created }: { onClose: () => void; created: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [kind, setKind] = useState<(typeof KINDS)[number]>("COMPLAINT");
  const [form, setForm] = useState({ category: "OTHER", subject: "", description: "", booking_ref: "", claim_amount: "" });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const cats = ["DELAY", "CANCELLATION", "REFUND", "BAGGAGE", "STAFF", "VEHICLE", "SAFETY", "PAYMENT", "ACCOUNT", "OTHER"];
  const set = (k: keyof typeof form) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ ref: string }>("/api/support/cases", {
        kind, category: form.category, subject: form.subject, description: form.description,
        booking_ref: form.booking_ref.trim() || null,
        claim_amount: kind === "CLAIM" && form.claim_amount ? Math.round(Number(form.claim_amount)) : null,
      });
      toast(t("support.opened", { ref: r.ref })); created();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("support.new")} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
                      <button className="btn" disabled={busy || form.subject.length < 4 || form.description.length < 10} onClick={submit}>{t("support.send")}</button></>}>
      <div className="stack">
        <div className="segmented" role="tablist">
          {KINDS.map((k) => <button key={k} role="tab" aria-selected={kind === k} className={kind === k ? "on" : ""} onClick={() => setKind(k)}>{t(`support.kind.${k}`)}</button>)}
        </div>
        <p className="small muted" style={{ margin: 0 }}>{t(`support.kindHint.${kind}`)}</p>
        <Field label={t("support.category")}>
          <select className="input" value={form.category} onChange={set("category")}>
            {cats.map((c) => <option key={c} value={c}>{t(`support.cat.${c}`)}</option>)}
          </select>
        </Field>
        <Field label={t("support.booking")} hint={kind === "CLAIM" ? t("support.bookingRequired") : t("support.bookingHint")}>
          <input className="input mono ltr" maxLength={12} value={form.booking_ref} onChange={set("booking_ref")} placeholder="ABC123" />
        </Field>
        <Field label={t("support.subject")}><input className="input" maxLength={160} value={form.subject} onChange={set("subject")} /></Field>
        <Field label={t("support.description")}><textarea className="input" rows={5} maxLength={4000} value={form.description} onChange={set("description")} /></Field>
        {kind === "CLAIM" && (
          <Field label={t("support.claimAmount")}><input className="input mono ltr" inputMode="numeric" value={form.claim_amount} onChange={set("claim_amount")} /></Field>
        )}
        {error ? <ErrorBox error={error} /> : null}
      </div>
    </Modal>
  );
}

function Thread({ uid, onClose, changed }: { uid: string; onClose: () => void; changed: () => void }) {
  const { t, dateTime, money } = useI18n();
  const state = useLoad(() => api.get<{ case: Case; messages: Message[] }>(`/api/support/cases/${uid}`), [uid]);
  const [reply, setReply] = useState("");
  const [error, setError] = useState<unknown>(null);
  const send = async () => {
    setError(null);
    try { await api.post(`/api/support/cases/${uid}/messages`, { body: reply }); setReply(""); state.reload(); changed(); }
    catch (e) { setError(e); }
  };
  const rate = async (score: number) => {
    try { await api.post(`/api/support/cases/${uid}/satisfaction`, { score }); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("support.request")} onClose={onClose} wide>
      <Loaded state={state}>{({ case: c, messages }) => (
        <div className="stack">
          <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
            <div><strong>{c.subject}</strong><div className="small muted"><span className="mono ltr">{c.ref}</span> · {t(`support.kind.${c.kind}`)} · {t(`support.cat.${c.category}`)}{c.booking_ref ? <> · <span className="mono ltr">{c.booking_ref}</span></> : null}</div></div>
            <Status value={c.status} />
          </div>
          {c.kind === "CLAIM" && (
            <div className="small">{t("support.claimed")}: <span className="mono">{money(c.claim_amount ?? 0)}</span>
              {c.approved_amount != null && <> · {t("support.approved")}: <span className="mono">{money(c.approved_amount)}</span></>}
              {c.payout_status === "PAID" && <> · <strong>{t("support.paid")}</strong></>}</div>
          )}
          <div className="stack tight" style={{ maxHeight: 360, overflowY: "auto" }}>
            {messages.length === 0 && <div className="small muted">{t("support.noReplies")}</div>}
            {messages.map((m, i) => (
              <div key={i} className="card" style={{ alignSelf: m.mine ? "flex-end" : "flex-start", maxWidth: "85%",
                                                     background: m.mine ? "var(--surface-2, #f3f6fb)" : undefined }}>
                <div className="small muted">{m.mine ? t("support.you") : t("support.team")} · {dateTime(m.created_at)}</div>
                <div style={{ whiteSpace: "pre-wrap" }}>{m.body}</div>
              </div>
            ))}
          </div>
          {c.resolution && <div className="alert info"><strong>{t("support.resolution")}:</strong> {c.resolution}</div>}
          {["CLOSED", "REJECTED"].includes(c.status) ? null : (
            <div className="row" style={{ gap: 8 }}>
              <textarea className="input" rows={2} style={{ flex: 1 }} maxLength={4000} value={reply} onChange={(e) => setReply(e.target.value)}
                        placeholder={t("support.replyPlaceholder")} />
              <button className="btn" disabled={!reply.trim()} onClick={send}><Icon name="send" />{t("support.send")}</button>
            </div>
          )}
          {["RESOLVED", "CLOSED"].includes(c.status) && (
            <div className="row" style={{ gap: 8, alignItems: "center" }}>
              <span className="small">{c.csat ? t("support.thanksCsat") : t("support.csat")}</span>
              <Stars value={c.csat ?? 0} onChange={rate} label={t("support.csat")} />
            </div>
          )}
          {error ? <ErrorBox error={error} /> : null}
        </div>
      )}</Loaded>
    </Modal>
  );
}

export default function Support() {
  const { t, date } = useI18n();
  const cases = useLoad(() => api.get<{ cases: Case[] }>("/api/support/cases"));
  const ratable = useLoad(() => api.get<{ tickets: Ratable[] }>("/api/support/ratable"));
  const [creating, setCreating] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  return (
    <div className="page stack">
      <PageHead title={t("support.title")} sub={t("support.subtitle")}>
        <button className="btn" onClick={() => setCreating(true)}><Icon name="add" />{t("support.new")}</button>
      </PageHead>
      {(ratable.data?.tickets.length ?? 0) > 0 && (
        <section className="stack tight">
          <h3 style={{ margin: 0 }}>{t("support.rateTitle")}</h3>
          {ratable.data!.tickets.map((tk) => <RateTrip key={tk.ticket_uid} trip={tk} done={ratable.reload} />)}
        </section>
      )}
      <Loaded state={cases}>{({ cases: list }) => list.length === 0 ? (
        <Empty icon="support_agent" title={t("support.none")} hint={t("support.noneHint")} />
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-wrap" tabIndex={0} style={{ border: "none" }}><table className="table">
            <thead><tr><th>{t("support.ref")}</th><th>{t("support.subject")}</th><th>{t("support.kindLabel")}</th><th>{t("support.status")}</th><th>{t("support.opened_on")}</th><th /></tr></thead>
            <tbody>
              {list.map((c) => (
                <tr key={c.uid} className="clickable" onClick={() => setOpen(c.uid)}>
                  <td className="mono ltr">{c.ref}</td>
                  <td>{c.subject}{(c.replies ?? 0) > 0 && <span className="badge" style={{ marginInlineStart: 8 }}><Icon name="forum" size={14} /> {c.replies}</span>}</td>
                  <td>{t(`support.kind.${c.kind}`)}</td>
                  <td><Status value={c.status} /></td>
                  <td>{date(c.created_at)}</td>
                  <td><Icon name="chevron_right" flip /></td>
                </tr>
              ))}
            </tbody>
          </table></div>
        </div>
      )}</Loaded>
      {creating && <NewCase onClose={() => setCreating(false)} created={() => { setCreating(false); cases.reload(); }} />}
      {open && <Thread uid={open} onClose={() => setOpen(null)} changed={cases.reload} />}
    </div>
  );
}
