import { useMemo, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

const DOCS = ["PASSPORT", "NATIONAL_ID", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER"];

interface Rule {
  id: number; country_code: string; country_role: string; nationality: string | null; doc_required: string[]; passport_min_days: number;
  security_approval: boolean; enforcement: string; valid_from: string | null; valid_to: string | null; legal_basis: string | null;
  note: string | null; label: string; version: number; status: string; created_by: string | null; approved_by: string | null; mine: boolean;
}
interface Req { international: boolean; docs: string[]; passport_min_days: number; exception: boolean; notes: string[]; rules: string[] }

/** Platform: travel documents of international trips. Passport by default; exceptions accept other documents for a
 * destination (or transit) country and nationality, are drafted by one officer and approved by another. */
export function TravelRules() {
  const { t, locale, date } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ rules: Rule[]; default: { docs: string[]; passport_min_days: number }; countries: { code: string; name: string }[] }>("/api/w/travel-rules"));
  const names = useMemo(() => new Intl.DisplayNames([locale], { type: "region" }), [locale]);
  const country = (c: string | null) => (c ? names.of(c) ?? c : t("wf.travel.anyNationality"));
  const doc = (k: string) => t(`checkout.idTypes.${k}`);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const blank = { country_code: "LB", country_role: "DESTINATION", nationality: "SY", doc_required: ["PASSPORT", "NATIONAL_ID"] as string[],
                  passport_min_days: 180, enforcement: "BLOCK", valid_from: "", valid_to: "", legal_basis: "", note: "", label: "" };
  const [f, setF] = useState(blank);
  const [q, setQ] = useState({ destination: "LB", nationality: "SY", on: new Date().toISOString().slice(0, 10) });
  const [res, setRes] = useState<Req | null>(null);
  const exception = !(f.doc_required.length === 1 && f.doc_required[0] === "PASSPORT");
  const codes = state.data?.countries.map((c) => c.code) ?? [];
  const countrySelect = (value: string, onChange: (v: string) => void, any = false) => (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      {any && <option value="">{t("wf.travel.anyNationality")}</option>}
      {[...codes].sort((a, b) => country(a).localeCompare(country(b), locale)).map((c) => <option key={c} value={c}>{country(c)}</option>)}
    </select>
  );
  const save = async () => {
    setError(null);
    try {
      await api.post("/api/w/travel-rules", { ...f, nationality: f.nationality || null, valid_from: f.valid_from || null, valid_to: f.valid_to || null,
                                              legal_basis: f.legal_basis || null, note: f.note || null });
      toast(t("wf.travel.drafted")); setOpen(false); setF(blank); state.reload();
    } catch (e) { setError(e); }
  };
  const act = async (r: Rule, what: "approve" | "retire") => {
    setError(null);
    try { await api.post(`/api/w/travel-rules/${r.id}/${what}`); toast(t(`wf.travel.${what}d`)); state.reload(); } catch (e) { setError(e); }
  };
  const check = async () => {
    try { setRes(await api.get<Req>("/api/w/travel-rules/check", q)); } catch (e) { setError(e); }
  };
  const d = (s: string | null) => (s ? date(`${s}T12:00:00Z`, { day: "numeric", month: "short", year: "numeric" }) : "…");
  return (
    <div className="stack">
      <div className="grid cols-2 wf-split">
        <div className="card stack">
          <h3>{t("wf.travel.defaultTitle")}</h3>
          <Loaded state={state}>{(s) => (
            <p className="muted" style={{ margin: 0 }}>{t("wf.travel.defaultText", { docs: (s.default?.docs ?? ["PASSPORT"]).map(doc).join(t("checkout.or")), days: s.default?.passport_min_days ?? 180 })}</p>
          )}</Loaded>
          <ul className="small muted plain">
            <li>• {t("wf.travel.rule1")}</li><li>• {t("wf.travel.rule2")}</li><li>• {t("wf.travel.rule3")}</li>
          </ul>
          <button className="btn" style={{ alignSelf: "flex-start" }} onClick={() => { setOpen(true); setError(null); }}><Icon name="add" />{t("wf.travel.add")}</button>
        </div>
        <div className="card stack">
          <h3>{t("wf.travel.checkTitle")}</h3>
          <div className="grid cols-3">
            <Field label={t("wf.travel.destination")}>{countrySelect(q.destination, (v) => setQ({ ...q, destination: v }))}</Field>
            <Field label={t("checkout.nationality")}>{countrySelect(q.nationality, (v) => setQ({ ...q, nationality: v }))}</Field>
            <Field label={t("wf.travel.on")}><input type="date" value={q.on} onChange={(e) => setQ({ ...q, on: e.target.value })} /></Field>
          </div>
          <button className="btn tonal" style={{ alignSelf: "flex-start" }} onClick={check}><Icon name="search" />{t("wf.travel.check")}</button>
          {res && (
            <div className={`alert ${res.exception ? "ok" : "info"}`}><Icon name={res.exception ? "verified" : "badge"} />
              <span>{res.international ? `${t("wf.travel.result", { docs: res.docs.map(doc).join(t("checkout.or")) })}${res.docs.includes("PASSPORT") && res.passport_min_days > 0 ? ` ${t("wf.travel.minDays", { n: res.passport_min_days })}.` : ""}` : t("wf.travel.domestic")}
                {res.rules.length > 0 && <> · {res.rules.join("، ")}</>}</span>
            </div>
          )}
        </div>
      </div>
      <ErrorBox error={error} />
      <div className="card stack">
        <h3>{t("wf.travel.rules")}</h3>
        <Loaded state={state}>{(s) => s.rules.length === 0 ? <Empty icon="public" title={t("wf.travel.none")} /> : (
          <div className="table-wrap"><table className="table">
            <thead><tr><th>{t("wf.travel.country")}</th><th>{t("checkout.nationality")}</th><th>{t("wf.travel.docs")}</th><th>{t("wf.travel.period")}</th>
              <th>{t("wf.travel.basis")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{s.rules.map((r) => (
              <tr key={r.id}>
                <td><strong>{country(r.country_code)}</strong><div className="small muted">{t(`wf.travel.role.${r.country_role}`)} · v{r.version}</div></td>
                <td>{country(r.nationality)}</td>
                <td><div className="row" style={{ gap: 4 }}>{r.doc_required.map((x) => <span key={x} className={`chip ${x === "PASSPORT" ? "outline" : "green"}`}>{doc(x)}</span>)}</div>
                  {r.doc_required.includes("PASSPORT") && r.passport_min_days > 0 && <div className="small muted">{t("wf.travel.minDays", { n: r.passport_min_days })}</div>}</td>
                <td className="small">{r.valid_from || r.valid_to ? `${d(r.valid_from)} → ${d(r.valid_to)}` : t("wf.travel.open")}</td>
                <td className="small"><div>{r.label}</div><div className="muted">{r.legal_basis}</div></td>
                <td><Status value={r.status} />{r.approved_by && <div className="small muted">{r.approved_by}</div>}</td>
                <td className="num">
                  <div className="row nowrap" style={{ justifyContent: "flex-end" }}>
                    {r.status === "DRAFT" && !r.mine && <button className="btn small" onClick={() => act(r, "approve")}>{t("wf.travel.approve")}</button>}
                    {r.status === "DRAFT" && r.mine && <span className="small muted">{t("wf.travel.awaiting")}</span>}
                    {r.status !== "RETIRED" && <button className="btn text small" onClick={() => act(r, "retire")}>{t("wf.travel.retire")}</button>}
                  </div>
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {open && (
        <Modal title={t("wf.travel.add")} onClose={() => setOpen(false)} wide
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={f.label.trim().length < 3 || f.doc_required.length === 0 || (exception && f.legal_basis.trim().length < 5)} onClick={save}>{t("wf.travel.saveDraft")}</button></>}>
          <div className="grid cols-3">
            <Field label={t("wf.travel.country")}>{countrySelect(f.country_code, (v) => setF({ ...f, country_code: v }))}</Field>
            <Field label={t("wf.travel.roleLabel")}>
              <select value={f.country_role} onChange={(e) => setF({ ...f, country_role: e.target.value })}>
                <option value="DESTINATION">{t("wf.travel.role.DESTINATION")}</option><option value="TRANSIT">{t("wf.travel.role.TRANSIT")}</option>
              </select>
            </Field>
            <Field label={t("checkout.nationality")}>{countrySelect(f.nationality, (v) => setF({ ...f, nationality: v }), true)}</Field>
          </div>
          <Field label={t("wf.travel.docs")} hint={t("wf.travel.docsHint")}>
            <div className="row" style={{ gap: 8 }}>
              {DOCS.map((k) => (
                <label key={k} className={`chip-select row nowrap${f.doc_required.includes(k) ? " on" : ""}`} style={{ padding: "0 12px", gap: 6 }}>
                  <input type="checkbox" checked={f.doc_required.includes(k)}
                         onChange={(e) => setF({ ...f, doc_required: e.target.checked ? [...f.doc_required, k] : f.doc_required.filter((x) => x !== k) })} />{doc(k)}
                </label>
              ))}
            </div>
          </Field>
          <div className="grid cols-3">
            <Field label={t("wf.travel.minDaysLabel")}><input type="number" min={0} max={730} value={f.passport_min_days} onChange={(e) => setF({ ...f, passport_min_days: Number(e.target.value) })} /></Field>
            <Field label={t("wf.travel.from")} hint={t("common.optional")}><input type="date" value={f.valid_from} onChange={(e) => setF({ ...f, valid_from: e.target.value })} /></Field>
            <Field label={t("wf.travel.to")} hint={t("common.optional")}><input type="date" value={f.valid_to} onChange={(e) => setF({ ...f, valid_to: e.target.value })} /></Field>
          </div>
          <Field label={t("wf.travel.enforcement")}>
            <select value={f.enforcement} onChange={(e) => setF({ ...f, enforcement: e.target.value })}>
              <option value="BLOCK">{t("wf.travel.block")}</option><option value="ALLOW_PENDING">{t("wf.travel.allowPending")}</option>
            </select>
          </Field>
          <Field label={t("wf.travel.labelField")}><input value={f.label} maxLength={120} onChange={(e) => setF({ ...f, label: e.target.value })} /></Field>
          <Field label={t("wf.travel.basis")} hint={exception ? t("wf.travel.basisRequired") : t("common.optional")}>
            <input value={f.legal_basis} maxLength={300} onChange={(e) => setF({ ...f, legal_basis: e.target.value })} />
          </Field>
          <Field label={t("wf.travel.note")} hint={t("wf.travel.noteHint")}><input value={f.note} maxLength={300} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
          <p className="small muted">{t("wf.travel.fourEyes")}</p>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}
