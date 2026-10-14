import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// Corrections of the published names (1127): a word of the names in the United Nations file written as it is known
// locally and internationally ("Quamishli" is Qamishli, "Tadmor" is Palmyra), in the areas under a code or the whole
// country; applied at once to every name that carries it and again after each newer file. The published name stays,
// and is still found by search.

interface Correction { id: number; lang: string; wrong: string; correct: string; scope_pcode: string | null; scope_en: string | null;
  scope_ar: string | null; reason: string; set_at: string; set_by: string | null; places: number }

export function NameCorrections({ onChange }: { onChange: () => void }) {
  const { t, locale, num } = useI18n();
  const toast = useToast();
  const list = useLoad((signal) => api.get<{ corrections: Correction[] }>("/api/admin/geo/names", undefined, { signal }));
  const blank = { lang: "en", wrong: "", correct: "", scope: "", reason: "" };
  const [f, setF] = useState(blank);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const save = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ changed: number }>("/api/admin/geo/names", { ...f, scope: f.scope || undefined });
      toast(t("geo.namesChanged", { n: out.changed })); setOpen(false); setF(blank); list.reload(); onChange();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const remove = async (c: Correction) => {
    setError(null);
    try { const out = await api.del<{ changed: number }>(`/api/admin/geo/names/${c.id}`); toast(t("geo.namesChanged", { n: out.changed })); list.reload(); onChange(); }
    catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
        <div>
          <h3 style={{ margin: 0 }}>{t("geo.names")}</h3>
          <p className="small muted" style={{ margin: 0 }}>{t("geo.namesHint")}</p>
        </div>
        <button className="btn outlined" onClick={() => setOpen(true)}><Icon name="edit" />{t("geo.nameAdd")}</button>
      </div>
      <ErrorBox error={error} />
      <Loaded state={list}>{({ corrections }) => (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("geo.published")}</th><th>{t("geo.correctName")}</th><th>{t("geo.scope")}</th><th className="num">{t("geo.places")}</th><th /></tr></thead>
          <tbody>{corrections.map((c) => (
            <tr key={c.id}>
              <td className={c.lang === "en" ? "ltr" : undefined}>{c.wrong}</td>
              <td className={c.lang === "en" ? "ltr" : undefined}><strong>{c.correct}</strong><div className="small muted">{c.reason}</div></td>
              <td className="small">{c.scope_pcode ? <>{(locale === "ar" ? c.scope_ar : c.scope_en) ?? ""} <span className="mono muted">{c.scope_pcode}</span></> : t("geo.country")}</td>
              <td className="num">{num(c.places)}</td>
              <td><button className="btn text small" onClick={() => remove(c)}>{t("geo.nameRemove")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("geo.nameAdd")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn filled" disabled={busy || f.wrong.trim().length < 2 || !f.correct.trim() || f.reason.trim().length < 3} onClick={save}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("geo.nameLang")}>
                <select className="input" value={f.lang} onChange={set("lang")}><option value="en">{t("geo.langEn")}</option><option value="ar">{t("geo.langAr")}</option></select>
              </Field>
              <Field label={`${t("geo.scope")} (${t("common.optional")})`} hint={t("geo.scopeHint")}>
                <input className="input mono ltr" placeholder="SY0405" value={f.scope} onChange={(e) => setF({ ...f, scope: e.target.value.toUpperCase() })} />
              </Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("geo.published")}><input className="input" dir={f.lang === "ar" ? "rtl" : "ltr"} value={f.wrong} onChange={set("wrong")} /></Field>
              <Field label={t("geo.correctName")}><input className="input" dir={f.lang === "ar" ? "rtl" : "ltr"} value={f.correct} onChange={set("correct")} /></Field>
            </div>
            <Field label={t("geo.reason")}><input className="input" value={f.reason} onChange={set("reason")} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
