import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Government bodies (owner's note N47, migration 1169): the register of the state's bodies, what each may see (a scope is
// in force only once a second person approved it), the platform accounts that check at the roadside for it, and the
// latest roadside checks across the network (N48). Members are added through the regular trips module's routes.

interface Scope { id: number; category: string; legal_basis: string; valid_from: string; valid_to: string; approved: boolean; created_by: string | null; approved_by: string | null }
interface Body { code: string; kind: string; name: string; name_ar: string | null; name_en: string | null; active: boolean; members: number;
  scopes: Scope[]; member_list: { uid: string; email: string; added_at: string }[] }
interface Data { bodies: Body[]; kinds: string[]; categories: string[] }
interface Check { uid: string; created_at: string; status: string; result: string; outcome: string | null; movement_kind: string | null;
  movement_ref: string | null; warnings: string[]; sample_mode: string | null; sampled: number | null; plate_no: string; carrier: string;
  body: string | null; inspector: string | null }

export function AdminAuthorities() {
  const { t, date, locale } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Data>("/api/admin/authorities", undefined, { signal }));
  const checks = useLoad((signal) => api.get<{ checks: Check[] }>("/api/admin/authorities/checks", undefined, { signal }));
  const [tab, setTab] = useState<"bodies" | "checks">("bodies");
  const [adding, setAdding] = useState<{ code: string; kind: string; name_ar: string; name_en: string; default_scopes: boolean } | null>(null);
  const [scope, setScope] = useState<{ code: string; category: string; legal_basis: string; days: string } | null>(null);
  const [member, setMember] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, after: () => void = () => undefined) => {
    setBusy(true); setError(null);
    try { await fn(); after(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const name = (b: Body) => (locale === "ar" ? b.name_ar : b.name_en) || b.name;
  return (
    <div className="stack">
      <PageHead title={t("gov.title")} sub={t("gov.sub")}>
        <button className="btn" onClick={() => { setError(null); setAdding({ code: "", kind: "INTERIOR", name_ar: "", name_en: "", default_scopes: true }); }}>
          <Icon name="add" />{t("gov.add")}</button>
      </PageHead>
      <div className="row" role="tablist" style={{ gap: 8 }}>
        {(["bodies", "checks"] as const).map((k) => (
          <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "tonal"} small`} onClick={() => setTab(k)}>{t(`gov.tab.${k}`)}</button>))}
      </div>
      {!adding && !scope && <ErrorBox error={error} />}
      {tab === "bodies" && <Loaded state={state}>{(d) => d.bodies.length === 0 ? <div className="card"><Empty icon="account_balance" title={t("gov.none")} /></div> : (
        <div className="stack">{d.bodies.map((b) => (
          <div key={b.code} className="card stack">
            <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
              <div><h3 style={{ margin: 0 }}>{name(b)} <span className="chip outline mono">{b.code}</span></h3>
                <div className="small muted">{t(`gov.kind.${b.kind}`)} · {b.active ? t("gov.active") : t("gov.inactive")}</div></div>
              <div className="row" style={{ gap: 4 }}>
                <button className="btn tonal small" onClick={() => { setError(null); setScope({ code: b.code, category: d.categories[0], legal_basis: "", days: "365" }); }}>
                  <Icon name="add" size={18} />{t("gov.addScope")}</button>
                <button className="btn text small" disabled={busy} onClick={() => run(() => api.put(`/api/admin/authorities/${b.code}`, { active: !b.active }))}>
                  {b.active ? t("gov.deactivate") : t("gov.activate")}</button>
              </div>
            </div>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("gov.scope")}</th><th>{t("gov.basis")}</th><th>{t("gov.valid")}</th><th>{t("gov.approval")}</th><th /></tr></thead>
              <tbody>{b.scopes.length === 0 ? <tr><td colSpan={5} className="muted small">{t("gov.noScopes")}</td></tr> : b.scopes.map((s) => (
                <tr key={s.id}><td>{t(`gov.cat.${s.category}`)}</td><td className="small">{s.legal_basis}</td>
                  <td className="small mono">{s.valid_from} → {s.valid_to}</td>
                  <td className="small">{s.approved ? <span className="chip">{t("gov.approvedBy", { who: s.approved_by ?? "" })}</span>
                    : <span className="chip outline">{t("gov.waiting", { who: s.created_by ?? "" })}</span>}</td>
                  <td>{!s.approved && <button className="btn text small" disabled={busy}
                    onClick={() => run(() => api.post(`/api/admin/authorities/${b.code}/scopes/${s.id}/approve`))}>{t("gov.approve")}</button>}</td></tr>))}</tbody>
            </table></div>
            <div className="stack" style={{ gap: 6 }}>
              <strong className="small">{t("gov.members")}</strong>
              <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                {b.member_list.length === 0 && <span className="small muted">{t("gov.noMembers")}</span>}
                {b.member_list.map((m) => (
                  <button key={m.uid} className="chip outline" title={t("gov.removeMember")} disabled={busy}
                          onClick={() => run(() => api.del(`/api/admin/authorities/${b.code}/members/${m.uid}`))}>{m.email} ×</button>))}
              </div>
              <div className="row" style={{ gap: 6 }}>
                <input className="input ltr" style={{ maxWidth: 320 }} type="email" placeholder={t("gov.memberEmail")} aria-label={t("gov.memberEmail")}
                       value={member[b.code] ?? ""} onChange={(e) => setMember({ ...member, [b.code]: e.target.value })} />
                <button className="btn tonal small" disabled={busy || !(member[b.code] ?? "").includes("@")}
                        onClick={() => run(() => api.post(`/api/admin/authorities/${b.code}/members`, { email: member[b.code] }), () => setMember({ ...member, [b.code]: "" }))}>
                  {t("gov.addMember")}</button>
              </div>
              <div className="small muted">{t("gov.memberHint")}</div>
            </div>
          </div>))}</div>)}</Loaded>}
      {tab === "checks" && <Loaded state={checks}>{({ checks: rows }) => rows.length === 0 ? <div className="card"><Empty icon="qr_code_scanner" title={t("gov.noChecks")} /></div> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("gov.when")}</th><th>{t("plc.plate")}</th><th>{t("plc.carrier")}</th><th>{t("gov.movement")}</th><th>{t("gov.body")}</th><th>{t("gov.result")}</th><th>{t("gov.warnings")}</th><th>{t("gov.inspector")}</th></tr></thead>
          <tbody>{rows.map((c) => (
            <tr key={c.uid}><td className="small">{date(c.created_at)}</td><td className="mono">{c.plate_no}</td><td>{c.carrier}</td>
              <td className="small">{c.movement_kind ? `${t(`gov.mk.${c.movement_kind}`)} ${c.movement_ref ?? ""}` : "—"}</td>
              <td className="mono small">{c.body ?? "—"}</td>
              <td className="small">{t(`gov.res.${c.result}`)}{c.outcome && <div className="muted">{t(`gov.out.${c.outcome}`)}</div>}</td>
              <td className="small">{c.warnings.length ? c.warnings.map((w) => t(`gov.warn.${w}`)).join(", ") : "—"}</td>
              <td className="small">{c.inspector ?? "—"}</td></tr>))}</tbody>
        </table></div>)}</Loaded>}
      {adding && (
        <Modal title={t("gov.add")} onClose={() => setAdding(null)}
               actions={<><button className="btn text" onClick={() => setAdding(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !/^[A-Z][A-Z0-9-]{1,23}$/.test(adding.code) || adding.name_ar.trim().length < 2 || adding.name_en.trim().length < 2}
                         onClick={() => run(() => api.post("/api/admin/authorities", adding), () => setAdding(null))}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("gov.code")} hint={t("gov.codeHint")}><input className="input ltr mono" maxLength={24} value={adding.code}
                onChange={(e) => setAdding({ ...adding, code: e.target.value.toUpperCase().replace(/[^A-Z0-9-]/g, "") })} /></Field>
              <Field label={t("gov.kindCol")}>
                <select className="input" value={adding.kind} onChange={(e) => setAdding({ ...adding, kind: e.target.value })}>
                  {(state.data?.kinds ?? []).map((k) => <option key={k} value={k}>{t(`gov.kind.${k}`)}</option>)}
                </select></Field>
              <Field label={t("gov.nameAr")}><input className="input" dir="rtl" maxLength={200} value={adding.name_ar} onChange={(e) => setAdding({ ...adding, name_ar: e.target.value })} /></Field>
              <Field label={t("gov.nameEn")}><input className="input ltr" maxLength={200} value={adding.name_en} onChange={(e) => setAdding({ ...adding, name_en: e.target.value })} /></Field>
            </div>
            <label className="check"><input type="checkbox" checked={adding.default_scopes} onChange={(e) => setAdding({ ...adding, default_scopes: e.target.checked })} />{t("gov.defaults")}</label>
          </div>
        </Modal>
      )}
      {scope && (
        <Modal title={t("gov.addScope")} onClose={() => setScope(null)}
               actions={<><button className="btn text" onClick={() => setScope(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || scope.legal_basis.trim().length < 3}
                         onClick={() => run(() => api.post(`/api/admin/authorities/${scope.code}/scopes`, { category: scope.category, legal_basis: scope.legal_basis, days: Number(scope.days) || 365 }),
                                        () => setScope(null))}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("gov.scope")}>
              <select className="input" value={scope.category} onChange={(e) => setScope({ ...scope, category: e.target.value })}>
                {(state.data?.categories ?? []).map((c) => <option key={c} value={c}>{t(`gov.cat.${c}`)}</option>)}
              </select></Field>
            <Field label={t("gov.basis")} hint={t("gov.basisHint")}><input className="input" maxLength={300} value={scope.legal_basis} onChange={(e) => setScope({ ...scope, legal_basis: e.target.value })} /></Field>
            <Field label={t("gov.days")}><input className="input ltr" inputMode="numeric" maxLength={4} value={scope.days} onChange={(e) => setScope({ ...scope, days: e.target.value.replace(/\D/g, "") })} /></Field>
            <div className="small muted">{t("gov.secondPerson")}</div>
          </div>
        </Modal>
      )}
    </div>
  );
}
