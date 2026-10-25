import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";
import { VehicleModels } from "./VehicleModels";

type Kind = "banks" | "insurers";
interface Branch { uid: string; name_ar: string; name_en: string; branch_code: string | null; swift_bic: string | null; is_head_office: boolean;
                   status: string; entered_by_name: string | null; reviewed_by_name: string | null }
interface Entry {
  uid: string; code: string; name_ar: string; name_en: string; status: string; verification_status: string; source: string;
  address: Record<string, string>; phone: string | null; fax: string | null; email: string | null; website: string | null; notes: string | null;
  hidden_from_companies: boolean; entered_by_name: string | null; reviewed_by_name: string | null; reviewed_at: string | null;
  pending_changes: Record<string, unknown> | null; pending_by_name: string | null;
  short_name?: string | null; bank_type?: string; swift_bic?: string | null; swift_status?: string; swift_reported?: string | null; iban_bank_code?: string | null;
  branches?: Branch[]; ownership?: string; insurance_kind?: string; licence_no?: string | null; lat?: number | null; lng?: number | null;
}

const BANK_FIELDS = ["code", "name_ar", "name_en", "short_name", "bank_type", "swift_bic", "swift_status", "iban_bank_code", "phone", "fax", "email", "website", "notes"] as const;
const INSURER_FIELDS = ["code", "name_ar", "name_en", "ownership", "insurance_kind", "licence_no", "phone", "fax", "email", "website", "notes", "lat", "lng"] as const;
const LATIN = ["code", "swift_bic", "iban_bank_code", "phone", "fax", "email", "website", "lat", "lng"];
const CHOICES: Record<string, string[]> = {
  bank_type: ["PRIVATE", "PUBLIC", "ISLAMIC", "CENTRAL"], swift_status: ["TO_VERIFY", "VERIFIED", "INVALID"],
  ownership: ["PRIVATE", "PUBLIC"], insurance_kind: ["CONVENTIONAL", "TAKAFUL", "REINSURANCE"],
};

/** Bank and insurer registries (owner's requests N6 and N9, 1156): staff enter or import an entry, another person reviews
 *  it before companies see it, and a change to a reviewed entry waits as a proposal for a second person. */
export function RegistriesPage() {
  const { t } = useI18n();
  const [kind, setKind] = useState<Kind | "vehicles">("banks");
  return (
    <div className="stack">
      <PageHead title={t("reg.title")} sub={t("reg.sub")} />
      <div className="segmented" role="tablist" aria-label={t("reg.title")} style={{ alignSelf: "flex-start" }}>
        {(["banks", "insurers", "vehicles"] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={kind === k} className={kind === k ? "on" : ""} onClick={() => setKind(k)}>
            <Icon name={k === "banks" ? "account_balance" : k === "insurers" ? "health_and_safety" : "directions_bus"} size={18} />{t(`reg.tab.${k}`)}
          </button>
        ))}
      </div>
      {kind === "vehicles" ? <VehicleModels /> : <Registry key={kind} kind={kind} />}
    </div>
  );
}

function Registry({ kind }: { kind: Kind }) {
  const { t, locale, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Record<Kind, Entry[]>>(`/api/admin/registry/${kind}`).then((r) => r[kind]), [kind]);
  const [edit, setEdit] = useState<Entry | "new" | null>(null);
  const [branchOf, setBranchOf] = useState<Entry | null>(null);
  const [filter, setFilter] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const file = useRef<HTMLInputElement>(null);
  const act = async (fn: () => Promise<unknown>, done?: string) => {
    setBusy(true); setError(null);
    try { await fn(); if (done) toast(done); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const load = async (f: File) => {
    const form = new FormData();
    form.append("file", f);
    await act(async () => {
      const out = await api.upload<{ created: string[]; skipped: string[] }>(`/api/admin/registry/${kind}/import`, form);
      toast(t("reg.imported", { n: out.created.length, s: out.skipped.length }));
    });
    if (file.current) file.current.value = "";
  };
  const name = (e: { name_ar: string; name_en: string }) => locale === "ar" ? e.name_ar : e.name_en;
  return (
    <div className="card">
      <div className="card-title" style={{ flexWrap: "wrap", gap: 8 }}>
        <h3>{t(`reg.tab.${kind}`)}</h3>
        <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
          <input className="input" style={{ width: 200, maxWidth: "100%" }} aria-label={t("common.search")} placeholder={t("common.search")} value={filter} onChange={(e) => setFilter(e.target.value)} />
          <input ref={file} type="file" accept=".xlsx" hidden aria-label={t("reg.import")} onChange={(e) => e.target.files?.[0] && load(e.target.files[0])} />
          <button className="btn outlined small" disabled={busy} onClick={() => file.current?.click()}><Icon name="upload_file" />{t("reg.import")}</button>
          <button className="btn small" onClick={() => { setError(null); setEdit("new"); }}><Icon name="add" />{t("reg.add")}</button>
        </div>
      </div>
      <p className="small muted">{t(`reg.hint.${kind}`)}</p>
      <ErrorBox error={!edit && !branchOf ? error : null} />
      <Loaded state={state}>{(list) => {
        const q = filter.trim().toLowerCase();
        const shown = q ? list.filter((e) => `${e.code} ${e.name_ar} ${e.name_en}`.toLowerCase().includes(q)) : list;
        return shown.length === 0 ? <Empty icon={kind === "banks" ? "account_balance" : "health_and_safety"} title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("reg.code")}</th><th>{t("reg.name")}</th><th>{kind === "banks" ? "SWIFT" : t("reg.kind")}</th>
              <th>{t("reg.review")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{shown.map((e) => (
              <tr key={e.uid}>
                <td className="mono small ltr">{e.code}{e.source === "IMPORT" && <div className="chip small">{t("reg.fromFile")}</div>}</td>
                <td>{name(e)}<div className="small muted">{locale === "ar" ? e.name_en : e.name_ar}</div>
                  {e.hidden_from_companies && <span className="chip small">{t("reg.hidden")}</span>}
                  {kind === "banks" && (e.branches?.length ?? 0) > 0 && <div className="small muted">{t("reg.branches", { n: e.branches?.length ?? 0 })}</div>}</td>
                <td className="small">{kind === "banks"
                  ? <><span className="mono ltr">{e.swift_bic ?? e.swift_reported ?? "—"}</span> <span className="muted">{t(`reg.choice.${e.swift_status ?? "TO_VERIFY"}`)}</span></>
                  : <>{t(`reg.choice.${e.insurance_kind}`)} · {t(`reg.choice.${e.ownership}`)}</>}</td>
                <td className="small">{t("reg.enteredBy", { name: e.entered_by_name ?? "—" })}
                  {e.reviewed_by_name && <div className="muted">{t("reg.reviewedBy", { name: e.reviewed_by_name })} {e.reviewed_at ? dateTime(e.reviewed_at) : ""}</div>}
                  {e.pending_changes && <div className="chip wheat">{t("reg.changeWaiting", { name: e.pending_by_name ?? "—" })}: {Object.keys(e.pending_changes).map((k) => t(`reg.f.${k}`)).join(", ")}</div>}</td>
                <td><Status value={e.status} /><div className="small muted">{t(`reg.ver.${e.verification_status}`)}</div></td>
                <td><div className="row nowrap" style={{ gap: 4 }}>
                  {(e.status === "PENDING_REVIEW" || e.pending_changes) && <>
                    <button className="btn tonal small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/registry/${kind}/${e.uid}/review`, { decision: "ACCEPT" }), t("reg.accepted"))}>{t("reg.accept")}</button>
                    <button className="btn text small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/registry/${kind}/${e.uid}/review`, { decision: "REJECT" }), t("reg.rejected"))}>{t("admin.reject")}</button>
                  </>}
                  {(e.status === "PENDING_REVIEW" || e.status === "ACTIVE") && !e.pending_changes &&
                    <button className="btn text small" onClick={() => { setError(null); setEdit(e); }}>{e.status === "ACTIVE" ? t("reg.propose") : t("common.edit")}</button>}
                  {kind === "banks" && e.status !== "REJECTED" && e.status !== "RETIRED" &&
                    <button className="btn text small" onClick={() => { setError(null); setBranchOf(e); }}>{t("reg.branchesBtn")}</button>}
                  {e.status === "ACTIVE" && <button className="btn text small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/registry/${kind}/${e.uid}/retire`), t("common.saved"))}>{t("reg.retire")}</button>}
                </div></td>
              </tr>
            ))}</tbody>
          </table></div>
        );
      }}</Loaded>
      {edit && <EntryForm kind={kind} entry={edit === "new" ? null : edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); state.reload(); }} />}
      {branchOf && <Branches bank={branchOf} onClose={() => { setBranchOf(null); state.reload(); }} />}
    </div>
  );
}

function EntryForm({ kind, entry, onClose, onDone }: { kind: Kind; entry: Entry | null; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const fields: readonly string[] = kind === "banks" ? BANK_FIELDS : INSURER_FIELDS;
  const [form, setForm] = useState<Record<string, string>>(() => Object.fromEntries(fields.map((f) => {
    const v = entry ? (entry as unknown as Record<string, unknown>)[f] : CHOICES[f]?.[0];
    return [f, v === null || v === undefined ? "" : String(v)];
  })));
  const [address, setAddress] = useState<string>(() => Object.entries(entry?.address ?? {}).map(([k, v]) => `${k}: ${v}`).join("\n"));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setBusy(true); setError(null);
    const body: Record<string, unknown> = {};
    for (const f of fields) {
      const v = form[f].trim();
      body[f] = v === "" ? null : (f === "lat" || f === "lng") ? Number(v) : (f === "code" || f === "swift_bic" || f === "iban_bank_code") ? v.toUpperCase() : v;
    }
    body.address = Object.fromEntries(address.split("\n").map((l) => l.split(":")).filter((p) => p.length >= 2 && p[0].trim())
      .map(([k, ...rest]) => [k.trim(), rest.join(":").trim()]));
    try {
      if (entry) await api.put(`/api/admin/registry/${kind}/${entry.uid}`, body);
      else await api.post(`/api/admin/registry/${kind}`, body);
      toast(entry?.status === "ACTIVE" ? t("reg.proposed") : t("common.saved"));
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={entry ? (entry.status === "ACTIVE" ? t("reg.propose") : t("common.edit")) : t("reg.add")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !form.code || !form.name_ar || !form.name_en} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        {entry?.status === "ACTIVE" && <div className="alert info"><Icon name="rule" /><span>{t("reg.proposeNote")}</span></div>}
        <div className="grid cols-2">
          {fields.map((f) => (
            <Field key={f} label={t(`reg.f.${f}`)}>
              {CHOICES[f]
                ? <select className="input" value={form[f]} onChange={(e) => setForm({ ...form, [f]: e.target.value })}>
                    {CHOICES[f].map((c) => <option key={c} value={c}>{t(`reg.choice.${c}`)}</option>)}</select>
                : <input className={`input${LATIN.includes(f) ? " ltr" : ""}`} dir={f === "name_ar" ? "rtl" : undefined} value={form[f]}
                         disabled={f === "code" && !!entry && entry.status === "ACTIVE"} onChange={(e) => setForm({ ...form, [f]: e.target.value })} />}
            </Field>
          ))}
        </div>
        <Field label={t("reg.f.address")} hint={t("reg.addressHint")}><textarea className="input" rows={4} value={address} onChange={(e) => setAddress(e.target.value)} /></Field>
      </div>
    </Modal>
  );
}

function Branches({ bank, onClose }: { bank: Entry; onClose: () => void }) {
  const { t, locale } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ banks: Entry[] }>("/api/admin/registry/banks").then((r) => r.banks.find((b) => b.uid === bank.uid)?.branches ?? []), [bank.uid]);
  const [form, setForm] = useState({ name_ar: "", name_en: "", branch_code: "", swift_bic: "", is_head_office: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const act = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true); setError(null);
    try { await fn(); toast(done); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${t("reg.branchesBtn")} · ${locale === "ar" ? bank.name_ar : bank.name_en}`} onClose={onClose} wide
           actions={<button className="btn" onClick={onClose}>{t("common.close")}</button>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Loaded state={state}>{(list) => list.length === 0 ? <Empty icon="store" title={t("reg.noBranches")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("reg.name")}</th><th>{t("reg.f.branch_code")}</th><th>SWIFT</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{list.map((b) => (
              <tr key={b.uid}><td>{locale === "ar" ? b.name_ar : b.name_en}{b.is_head_office && <span className="chip small">{t("reg.headOffice")}</span>}
                <div className="small muted">{t("reg.enteredBy", { name: b.entered_by_name ?? "—" })}</div></td>
                <td className="mono ltr small">{b.branch_code ?? "—"}</td><td className="mono ltr small">{b.swift_bic ?? "—"}</td><td><Status value={b.status} /></td>
                <td>{b.status === "PENDING_REVIEW" && <div className="row nowrap" style={{ gap: 4 }}>
                  <button className="btn tonal small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/registry/branches/${b.uid}/review`, { decision: "ACCEPT" }), t("reg.accepted"))}>{t("reg.accept")}</button>
                  <button className="btn text small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/registry/branches/${b.uid}/review`, { decision: "REJECT" }), t("reg.rejected"))}>{t("admin.reject")}</button>
                </div>}</td></tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
        <h4>{t("reg.addBranch")}</h4>
        <div className="grid cols-2">
          <Field label={t("reg.f.name_ar")}><input className="input" dir="rtl" value={form.name_ar} onChange={(e) => setForm({ ...form, name_ar: e.target.value })} /></Field>
          <Field label={t("reg.f.name_en")}><input className="input" value={form.name_en} onChange={(e) => setForm({ ...form, name_en: e.target.value })} /></Field>
          <Field label={t("reg.f.branch_code")}><input className="input ltr" value={form.branch_code} onChange={(e) => setForm({ ...form, branch_code: e.target.value.toUpperCase() })} /></Field>
          <Field label={t("reg.f.swift_bic")}><input className="input ltr" value={form.swift_bic} onChange={(e) => setForm({ ...form, swift_bic: e.target.value.toUpperCase() })} /></Field>
        </div>
        <label className="row"><input type="checkbox" checked={form.is_head_office} onChange={(e) => setForm({ ...form, is_head_office: e.target.checked })} />{t("reg.headOffice")}</label>
        <div><button className="btn tonal" disabled={busy || form.name_ar.length < 2 || form.name_en.length < 2}
          onClick={() => act(() => api.post(`/api/admin/registry/banks/${bank.uid}/branches`,
            { ...form, branch_code: form.branch_code || null, swift_bic: form.swift_bic || null }), t("common.saved"))}><Icon name="add" />{t("reg.addBranch")}</button></div>
      </div>
    </Modal>
  );
}
