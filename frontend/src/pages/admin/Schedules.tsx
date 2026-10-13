import { Fragment, useState } from "react";
import { api } from "../../api";
import { useAuth } from "../../auth";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, useLoad, useToast } from "../../components/ui";
import { RequestStatus, stageName, usePattern, type PatternLike, type ScheduleRequest } from "../carrier/Schedules";

// Requests for regular trips (owner's decision, October 2026; migration 1117). Carriers ask for regular trips, their
// changes, stops and trips made by hand; each request passes the approval stages of the settings: the platform first,
// and later the government authorities the law names (the Ministry of Transport, the Interior, the traffic police),
// whose members decide their stages. The platform organizes the numbers: it may give another number than the one
// asked for. What passes the stages, the notice, the horizon and the patterns are settings, so a new rule needs no
// new release.

type Stage = { by: "PLATFORM" | "AUTHORITY"; authority?: string };
interface AdminRequest extends ScheduleRequest {
  company_uid: string; company_name: string; company_logo: string | null; waiting_for: Stage | null; may_decide: boolean;
  suggested_number?: number | null; designator?: string | null;
  decisions: { step: number; stage: Stage; decision: string; by: string; authority: string | null; number: number | null; note: string | null; at: string }[];
}
interface Rules { approval_stages: Stage[]; approval_kinds: string[]; min_notice_days: number; horizon_days: number; recurrences: string[] }
interface Authority { code: string; name: string; type: string; active: boolean; members: { uid: string; email: string; name: string }[] }

function Detail({ r }: { r: AdminRequest }) {
  const { t, date, money, station } = useI18n();
  const pattern = usePattern();
  const p = r.proposal as Record<string, unknown> & PatternLike;
  const day = (d: string) => date(`${d}T12:00:00Z`, d.startsWith(String(new Date().getFullYear())) ? {} : { year: "numeric" });
  const rows: [string, string][] = [];
  if (r.route) rows.push([t("schedadm.detail.route"), `${station(r.route.origin_code, r.route.origin)} → ${station(r.route.dest_code, r.route.destination)} (${r.route.code})`]);
  if (typeof p.departure_time === "string") rows.push([t("schedadm.detail.time"), p.departure_time]);
  if (typeof p.recurrence === "string") rows.push([t("schedadm.detail.pattern"), pattern.text(p)]);
  if (typeof p.from === "string") rows.push([t("schedadm.detail.period"),
    `${day(p.from)} – ${typeof p.until === "string" ? day(p.until) : t("sched.noEnd")}`]);
  if (r.effective_from) rows.push([t("schedadm.detail.effective"), day(r.effective_from)]);
  if (r.kind !== "NEW" && r.schedule_code) rows.unshift([t("trip.number"), `${r.schedule_code}${r.schedule_time ? ` · ${r.schedule_time}` : ""}`]);
  if (r.kind === "CHANGE" && "until" in p) rows.push([t("sched.end"), typeof p.until === "string" ? t("sched.untilDate", { date: day(p.until) }) : t("sched.noEnd")]);
  if (r.kind === "CHANGE" && typeof p.base_price === "number") rows.push([t("sched.price"), money(p.base_price)]);
  if (r.kind === "CHANGE" && typeof p.auto_publish === "boolean") rows.push([t("sched.publish"), p.auto_publish ? "✓" : "✗"]);
  if (Array.isArray(p.skip_dates) && p.skip_dates.length > 0) rows.push([t("sched.skip"), (p.skip_dates as string[]).map((x) => day(x)).join(" · ")]);
  if (r.plate_no) rows.push([t("schedadm.detail.vehicle"), r.plate_no]);
  if (typeof p.trip_type === "string") rows.push([t("schedadm.detail.type"), `${t(`sched.type.${p.trip_type}`)} · ${t(`sched.dir.${String(p.direction)}`)}`]);
  if (r.proposed_number) rows.push([t("schedadm.detail.number"), String(r.proposed_number)]);
  if (r.trip_code || r.trip_no) rows.push([t("trip.number"), r.trip_code ?? r.trip_no ?? ""]);
  return <dl className="kv">{rows.map(([k, v], i) => <Fragment key={i}><dt>{k}</dt><dd>{v}</dd></Fragment>)}</dl>;
}

function RequestCard({ r, onDone }: { r: AdminRequest; onDone: () => void }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const [number, setNumber] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const decide = async (approve: boolean) => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ status: string }>(`/api/admin/schedules/requests/${r.uid}/decide`,
        { approve, note: note || null, number: number ? Number(number) : null });
      toast(out.status === "PENDING" ? t("schedadm.movedOn") : approve ? t("schedadm.approved") : t("schedadm.refused"));
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const canNumber = r.kind === "NEW" && r.waiting_for?.by === "PLATFORM";
  return (
    <div className="card stack">
      <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
        <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
          <span className="chip outline">{t(`sched.kind.${r.kind}`)}</span>
          <CarrierName name={r.company_name} uid={r.company_uid} logo={r.company_logo} strong />
          <span className="small muted">{r.requested_by_name} · {dateTime(r.requested_at)}</span>
        </div>
        <RequestStatus r={r} />
      </div>
      <Detail r={r} />
      {r.note && <div className="small">“{r.note}”</div>}
      <div className="row" style={{ gap: 6, flexWrap: "wrap" }} aria-label={t("schedadm.stages")}>
        {r.approval_stages.map((s, i) => {
          const d = r.decisions.find((x) => x.step === i + 1);
          return <span key={i} className={`chip ${d ? (d.decision === "APPROVED" ? "green" : "red") : i === r.step && r.status === "PENDING" ? "wheat" : "outline"}`}
                       title={d ? `${d.by}${d.note ? `: ${d.note}` : ""}` : undefined}>
            {d ? <Icon name={d.decision === "APPROVED" ? "check" : "close"} size={14} /> : null}{i + 1}. {stageName(t, s)}</span>;
        })}
      </div>
      {r.status === "PENDING" && (r.may_decide ? (
        <div className="stack tight">
          {canNumber && (
            <Field label={t("schedadm.give")} hint={`${t("schedadm.giveHint")}${r.suggested_number ? ` ${t("schedadm.suggested", { code: `${r.designator ?? ""} ${r.suggested_number}` })}` : ""}`}>
              <input className="input ltr" inputMode="numeric" style={{ maxWidth: 160 }} value={number} placeholder={String(r.proposed_number ?? r.suggested_number ?? "")}
                     onChange={(e) => setNumber(e.target.value.replace(/\D/g, "").slice(0, 4))} />
            </Field>
          )}
          <Field label={t("schedadm.note")}><input className="input" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
          <div className="row" style={{ gap: 8 }}>
            <button className="btn" disabled={busy} onClick={() => decide(true)}><Icon name="check" />{t("schedadm.approve")}</button>
            <button className="btn text" disabled={busy} onClick={() => decide(false)}>{t("schedadm.refuse")}</button>
          </div>
          <ErrorBox error={error} />
        </div>
      ) : <div className="small muted">{t("schedadm.notYours")} ({t("schedadm.waiting", { who: stageName(t, r.waiting_for) })})</div>)}
      {r.status === "REJECTED" && r.decision_note && <div className="small" style={{ color: "var(--error)" }}>{t("sched.reason", { reason: r.decision_note })}</div>}
      {r.result?.trip_code && <div className="small">{t("sched.given", { code: r.result.trip_code })}</div>}
    </div>
  );
}

function Requests({ status }: { status: "PENDING" | "DECIDED" }) {
  const { t } = useI18n();
  const state = useLoad(() => api.get<{ requests: AdminRequest[]; authorities: string[] }>("/api/admin/schedules/requests", { status }), [status]);
  return (
    <Loaded state={state}>{({ requests }) => requests.length === 0
      ? <div className="card"><Empty icon="pending_actions" title={t(status === "PENDING" ? "schedadm.none" : "schedadm.noneDecided")} /></div>
      : <div className="stack">{requests.map((r) => <RequestCard key={r.uid} r={r} onDone={state.reload} />)}</div>}</Loaded>
  );
}

function Settings() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ rules: Rules; authorities: Authority[] }>("/api/admin/schedules/settings"));
  const [stages, setStages] = useState<Stage[] | null>(null);
  const [email, setEmail] = useState<Record<string, string>>({});
  const [error, setError] = useState<unknown>(null);
  const save = async (key: string, value: unknown) => {
    setError(null);
    try { await api.put(`/api/admin/schedules/settings/${key}`, { value }); toast(t("schedadm.saved")); state.reload(); } catch (e) { setError(e); }
  };
  const run = async (call: () => Promise<unknown>, msg: string) => {
    setError(null);
    try { await call(); toast(msg); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <Loaded state={state}>{({ rules, authorities }) => {
      const list = stages ?? rules.approval_stages;
      const edit = (i: number, s: Stage) => setStages(list.map((x, j) => (j === i ? s : x)));
      const move = (i: number, d: number) => { const n = [...list]; [n[i], n[i + d]] = [n[i + d], n[i]]; setStages(n); };
      const toggle = (key: "approval_kinds" | "recurrences", v: string) =>
        save(key, rules[key].includes(v) ? rules[key].filter((x) => x !== v) : [...rules[key], v]);
      return (
        <div className="stack">
          <ErrorBox error={error} />
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("schedadm.settingsTitle")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t("schedadm.stagesHint")}</p>
            {list.map((s, i) => (
              <div key={i} className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <strong>{i + 1}.</strong>
                <select className="input" style={{ maxWidth: 220 }} aria-label={`${t("schedadm.stages")} ${i + 1}`} value={s.by}
                        onChange={(e) => edit(i, e.target.value === "PLATFORM" ? { by: "PLATFORM" } : { by: "AUTHORITY", authority: authorities[0]?.code })}>
                  <option value="PLATFORM">{t("schedadm.by.PLATFORM")}</option>
                  <option value="AUTHORITY" disabled={authorities.length === 0}>{t("schedadm.by.AUTHORITY")}</option>
                </select>
                {s.by === "AUTHORITY" && (
                  <select className="input" style={{ maxWidth: 260 }} aria-label={t("schedadm.by.AUTHORITY")} value={s.authority}
                          onChange={(e) => edit(i, { by: "AUTHORITY", authority: e.target.value })}>
                    {authorities.map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
                  </select>
                )}
                <button className="btn text small" disabled={i === 0} onClick={() => move(i, -1)}>{t("schedadm.up")}</button>
                <button className="btn text small" disabled={i === list.length - 1} onClick={() => move(i, 1)}>{t("schedadm.down")}</button>
                <button className="btn text small" disabled={list.length === 1} onClick={() => setStages(list.filter((_, j) => j !== i))}>{t("schedadm.remove")}</button>
              </div>
            ))}
            <div className="row" style={{ gap: 8 }}>
              <button className="btn tonal small" disabled={list.length >= 6} onClick={() => setStages([...list, { by: "PLATFORM" }])}><Icon name="add" />{t("schedadm.addStage")}</button>
              <button className="btn small" disabled={!stages} onClick={() => save("approval_stages", list).then(() => setStages(null))}>{t("schedadm.save")}</button>
            </div>
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("schedadm.kinds")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t("schedadm.kindsHint")}</p>
            <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
              {["NEW", "CHANGE", "STOP", "TRIP"].map((k) => (
                <label key={k} className="row" style={{ gap: 6 }}><input type="checkbox" checked={rules.approval_kinds.includes(k)} onChange={() => toggle("approval_kinds", k)} />
                  {t(`sched.needs.${k}`)}</label>))}
            </div>
            <h3 style={{ margin: 0 }}>{t("schedadm.recurrences")}</h3>
            <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
              {["DAILY", "WEEKLY", "MONTHLY"].map((k) => (
                <label key={k} className="row" style={{ gap: 6 }}><input type="checkbox" checked={rules.recurrences.includes(k)} onChange={() => toggle("recurrences", k)} />
                  {t(`sched.rec.${k}`)}</label>))}
            </div>
            <div className="grid cols-2">
              <Field label={t("schedadm.noticeDays")} hint={t("schedadm.noticeHint")}>
                <input className="input ltr" type="number" min={0} max={90} defaultValue={rules.min_notice_days}
                       onBlur={(e) => Number(e.target.value) !== rules.min_notice_days && save("min_notice_days", Number(e.target.value))} />
              </Field>
              <Field label={t("schedadm.horizonDays")} hint={t("schedadm.horizonHint")}>
                <input className="input ltr" type="number" min={7} max={120} defaultValue={rules.horizon_days}
                       onBlur={(e) => Number(e.target.value) !== rules.horizon_days && save("horizon_days", Number(e.target.value))} />
              </Field>
            </div>
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("schedadm.authorities")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t("schedadm.authoritiesHint")}</p>
            {authorities.map((a) => (
              <div key={a.code} className="stack tight" style={{ borderTop: "1px solid var(--divider)", paddingTop: 8 }}>
                <div className="row" style={{ gap: 8 }}><strong className="mono">{a.code}</strong><span>{a.name}</span></div>
                <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                  <span className="small muted">{t("schedadm.members")}:</span>
                  {a.members.length === 0 ? <span className="small muted">{t("schedadm.noMembers")}</span> : a.members.map((m) => (
                    <button key={m.uid} className="chip outline" aria-label={`${m.email} ×`}
                            onClick={() => run(() => api.del(`/api/admin/authorities/${a.code}/members/${m.uid}`), t("schedadm.memberRemoved"))}>{m.email} ×</button>))}
                </div>
                <div className="row" style={{ gap: 8 }}>
                  <input className="input ltr" style={{ maxWidth: 280 }} type="email" aria-label={`${t("schedadm.addMember")} · ${a.code}`} placeholder={t("schedadm.addMember")}
                         value={email[a.code] ?? ""} onChange={(e) => setEmail({ ...email, [a.code]: e.target.value })} />
                  <button className="btn tonal small" disabled={!email[a.code]}
                          onClick={() => run(() => api.post(`/api/admin/authorities/${a.code}/members`, { email: email[a.code] }), t("schedadm.memberAdded"))
                            .then(() => setEmail({ ...email, [a.code]: "" }))}><Icon name="add" />{t("schedadm.addMember")}</button>
                </div>
              </div>
            ))}
          </div>
        </div>
      );
    }}</Loaded>
  );
}

export function AdminSchedules() {
  const { t } = useI18n();
  const { can } = useAuth();
  const tabs = (["pending", "decided", ...(can("schedule.settings") ? ["settings"] : [])] as const) as readonly ("pending" | "decided" | "settings")[];
  const [tab, setTab] = useState<"pending" | "decided" | "settings">("pending");
  return (
    <div className="stack">
      <PageHead title={t("schedadm.title")} sub={t("schedadm.sub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {tabs.map((v) => <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`schedadm.tab.${v}`)}</button>)}
      </div>
      {tab === "pending" && <Requests status="PENDING" />}
      {tab === "decided" && <Requests status="DECIDED" />}
      {tab === "settings" && <Settings />}
    </div>
  );
}
