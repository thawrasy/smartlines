import { useState } from "react";
import { api, type MeTraveller, type SavedTraveller } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, PasswordInput, useLoad, useToast } from "../../components/ui";
import { NameFields, blankName, nameBody, nameValid, type NameDraft } from "../../components/NameFields";

const DOC = /^[0-9A-Za-z \-/]{4,24}$/;
const DOC_TYPES = ["NATIONAL_ID", "PASSPORT", "RESIDENCE", "OTHER"] as const;

/** The account holder's own document (N18): with it the booking form fills the traveller "Me". The number is sent once
 *  and kept encrypted; only its last four come back. */
export function MyDocumentCard() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<MeTraveller>("/api/account/me-traveller"));
  const [form, setForm] = useState<{ birth_date: string; gender: string; id_type: string; id_no: string; id_expiry: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  return (
    <Loaded state={state}>{(m) => {
      const f = form ?? { birth_date: m.birth_date ?? "", gender: m.gender ?? "", id_type: m.id_type ?? (m.nationality === "SY" ? "NATIONAL_ID" : "PASSPORT"),
                          id_no: "", id_expiry: m.id_expiry ?? "" };
      const set = (patch: Partial<typeof f>) => setForm({ ...f, ...patch });
      const ok = !!f.birth_date && !!f.gender && DOC.test(f.id_no.trim());
      const save = async () => {
        setBusy(true); setError(null);
        try {
          await api.put("/api/account/document", { birth_date: f.birth_date, gender: f.gender, id_type: f.id_type, id_no: f.id_no.trim(),
                                                    id_expiry: f.id_expiry || null });
          toast(t("common.saved")); setForm(null); state.reload();
        } catch (e) { setError(e); } finally { setBusy(false); }
      };
      return (
        <div className="card stack" aria-labelledby="my-doc">
          <div className="row between"><h3 id="my-doc">{t("trav.myDoc")}</h3>
            {m.ready ? <span className="chip green"><Icon name="verified" size={16} />{t("trav.ready")}</span> : <span className="chip">{t("trav.notReady")}</span>}</div>
          <p className="small muted">{t("trav.myDocSub")}</p>
          {m.has_document && <p className="small">{t(`checkout.idTypes.${m.id_type ?? "OTHER"}`)} <span className="ltr mono">•••• {m.id_no_last4}</span></p>}
          <ErrorBox error={error} />
          <div className="grid cols-3">
            <Field label={t("pax.birthDate")}><input className="input ltr" type="date" value={f.birth_date} onChange={(e) => set({ birth_date: e.target.value })} /></Field>
            <Field label={t("trav.gender")}>
              <select className="input" value={f.gender} onChange={(e) => set({ gender: e.target.value })}>
                <option value="">—</option><option value="M">{t("trav.male")}</option><option value="F">{t("trav.female")}</option>
              </select>
            </Field>
            <Field label={t("checkout.idType")}>
              <select className="input" value={f.id_type} onChange={(e) => set({ id_type: e.target.value })}>
                {DOC_TYPES.map((k) => <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
              </select>
            </Field>
            <Field label={t("checkout.docNumber")} hint={m.has_document ? t("trav.docAgain") : undefined}>
              <input className="input ltr" maxLength={24} autoComplete="off" value={f.id_no} aria-invalid={f.id_no !== "" && !DOC.test(f.id_no.trim())}
                     onChange={(e) => set({ id_no: e.target.value })} />
            </Field>
            <Field label={`${t("trav.expiry")} (${t("common.optional")})`}>
              <input className="input ltr" type="date" value={f.id_expiry} onChange={(e) => set({ id_expiry: e.target.value })} />
            </Field>
          </div>
          <div className="row"><button className="btn" disabled={busy || !ok} onClick={save}>{t("common.save")}</button></div>
        </div>
      );
    }}</Loaded>
  );
}

type Draft = { name: NameDraft; label: string; birth_date: string; gender: string; id_type: string; id_no: string; id_expiry: string; consent: boolean };
const blankDraft = (): Draft => ({ name: blankName(), label: "", birth_date: "", gender: "", id_type: "NATIONAL_ID", id_no: "", id_expiry: "", consent: false });
const draftOf = (s: SavedTraveller): Draft => ({
  name: { ...blankName(), nationality: s.nationality, first_name: s.first_name, father_name: s.father_name ?? "", grandfather_name: s.grandfather_name ?? "",
          last_name: s.last_name, first_name_latin: s.first_name_latin ?? "", father_name_latin: s.father_name_latin ?? "",
          grandfather_name_latin: s.grandfather_name_latin ?? "", last_name_latin: s.last_name_latin ?? "" },
  label: s.label ?? "", birth_date: s.birth_date ?? "", gender: s.gender ?? "", id_type: s.id_type ?? "NATIONAL_ID", id_no: "",
  id_expiry: s.id_expiry ?? "", consent: false,
});

/** Companions the passenger books for again (N18), kept only with the passenger's confirmation that the person agrees. */
export function SavedTravellersCard() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ travellers: SavedTraveller[]; limit: number }>("/api/account/travellers"));
  const [edit, setEdit] = useState<{ uid: string | null; draft: Draft } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, after?: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); toast(t("common.saved")); after?.(); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const d = edit?.draft;
  const set = (patch: Partial<Draft>) => edit && setEdit({ ...edit, draft: { ...edit.draft, ...patch } });
  const valid = !!d && nameValid(d.name) && d.consent && (d.id_no === "" || DOC.test(d.id_no.trim()));
  const body = (x: Draft) => {
    const n = nameBody(x.name);
    delete n.mother_name;
    return { ...n, label: x.label.trim() || null, birth_date: x.birth_date || null, gender: x.gender || null,
             id_type: x.id_no.trim() || edit?.uid ? x.id_type : null, id_no: x.id_no.trim() || null, id_expiry: x.id_expiry || null, consent: x.consent };
  };
  return (
    <Loaded state={state}>{({ travellers, limit }) => (
      <div className="card stack" aria-labelledby="saved-trav">
        <div className="row between"><h3 id="saved-trav">{t("trav.saved")}</h3>
          <button className="btn tonal small" disabled={travellers.length >= limit} onClick={() => { setError(null); setEdit({ uid: null, draft: blankDraft() }); }}>
            <Icon name="person_add" />{t("trav.add")}</button></div>
        <p className="small muted">{t("trav.savedSub", { n: limit })}</p>
        {!edit && <ErrorBox error={error} />}
        {travellers.length === 0 ? <Empty icon="group" title={t("trav.none")} /> : (
          <div className="stack tight">{travellers.map((s) => (
            <div key={s.uid} className="row between" style={{ borderBottom: "1px solid var(--outline-variant)", paddingBottom: 8 }}>
              <span><strong>{[s.first_name, s.father_name, s.grandfather_name, s.last_name].filter(Boolean).join(" ")}</strong>
                {s.label && <span className="chip outline" style={{ marginInlineStart: 8 }}>{s.label}</span>}
                {s.id_last4 && <span className="small muted ltr" style={{ marginInlineStart: 8 }}>•••• {s.id_last4}</span>}</span>
              <span className="row">
                <button className="btn text small" onClick={() => { setError(null); setEdit({ uid: s.uid, draft: draftOf(s) }); }}>{t("common.edit")}</button>
                <button className="btn text small" disabled={busy} onClick={() => run(() => api.del(`/api/account/travellers/${s.uid}`))}>{t("common.remove")}</button>
              </span>
            </div>
          ))}</div>
        )}
        {edit && d && (
          <Modal wide title={edit.uid ? t("trav.edit") : t("trav.add")} onClose={() => setEdit(null)}
                 actions={<><button className="btn text" onClick={() => setEdit(null)}>{t("common.cancel")}</button>
                   <button className="btn" disabled={busy || !valid} onClick={() => run(() => (edit.uid ? api.put(`/api/account/travellers/${edit.uid}`, body(d))
                     : api.post("/api/account/travellers", body(d))), () => setEdit(null))}>{t("common.save")}</button></>}>
            <div className="stack">
              <ErrorBox error={error} />
              <Field label={`${t("trav.label")} (${t("common.optional")})`}>
                <input className="input" maxLength={40} value={d.label} onChange={(e) => set({ label: e.target.value })} />
              </Field>
              <NameFields value={d.name} onChange={(name) => set({ name })} />
              <div className="grid cols-3">
                <Field label={`${t("pax.birthDate")} (${t("common.optional")})`}><input className="input ltr" type="date" value={d.birth_date} onChange={(e) => set({ birth_date: e.target.value })} /></Field>
                <Field label={`${t("trav.gender")} (${t("common.optional")})`}>
                  <select className="input" value={d.gender} onChange={(e) => set({ gender: e.target.value })}>
                    <option value="">—</option><option value="M">{t("trav.male")}</option><option value="F">{t("trav.female")}</option>
                  </select>
                </Field>
                <Field label={t("checkout.idType")}>
                  <select className="input" value={d.id_type} onChange={(e) => set({ id_type: e.target.value })}>
                    {DOC_TYPES.map((k) => <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
                  </select>
                </Field>
                <Field label={`${t("checkout.docNumber")} (${t("common.optional")})`} hint={edit.uid ? t("trav.docAgain") : undefined}>
                  <input className="input ltr" maxLength={24} autoComplete="off" value={d.id_no} onChange={(e) => set({ id_no: e.target.value })} />
                </Field>
                <Field label={`${t("trav.expiry")} (${t("common.optional")})`}><input className="input ltr" type="date" value={d.id_expiry} onChange={(e) => set({ id_expiry: e.target.value })} /></Field>
              </div>
              <label className="check small"><input type="checkbox" checked={d.consent} onChange={(e) => set({ consent: e.target.checked })} />{t("trav.consent")}</label>
            </div>
          </Modal>
        )}
      </div>
    )}</Loaded>
  );
}

/** A guest keeps the bookings by turning the guest account into a full one (N18): the name in parts and a password. */
export function ClaimCard() {
  const { t } = useI18n();
  const { refresh } = useAuth();
  const toast = useToast();
  const [name, setName] = useState<NameDraft>(blankName());
  const [pw, setPw] = useState({ password: "", password_confirm: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const differs = pw.password_confirm !== "" && pw.password !== pw.password_confirm;
  const submit = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/account/claim", { name: nameBody(name), ...pw }); toast(t("guest.claimed")); await refresh(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="card stack" aria-labelledby="claim">
      <h3 id="claim">{t("guest.claimTitle")}</h3>
      <p className="small muted">{t("guest.claimSub")}</p>
      <ErrorBox error={error} />
      <NameFields value={name} onChange={setName} />
      <div className="grid cols-2">
        <Field label={t("common.password")} hint={t("auth.passwordHint")}>
          <PasswordInput autoComplete="new-password" value={pw.password} onChange={(e) => setPw({ ...pw, password: e.target.value })} />
        </Field>
        <Field label={t("account.repeat")}>
          <PasswordInput autoComplete="new-password" value={pw.password_confirm} aria-invalid={differs} onChange={(e) => setPw({ ...pw, password_confirm: e.target.value })} />
        </Field>
      </div>
      <div className="row"><button className="btn" disabled={busy || !nameValid(name) || pw.password.length < 12 || pw.password !== pw.password_confirm}
                                   onClick={submit}>{t("guest.claim")}</button></div>
    </div>
  );
}
