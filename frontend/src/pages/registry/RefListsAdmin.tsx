import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";
import { type EditField, RecordEditor } from "../../components/RecordEditor";
import { Swatch } from "../../components/RefLists";

// The colour and axle lists (1174), kept by the platform: companies pick from them and never type a colour or an axle
// count. An entry is added, renamed with a reason, or retired; nothing is deleted, and every edit is kept.

interface ColourRow { code: string; name_en: string; name_ar: string; hex: string | null; sort_order: number; status: string; used: number }
interface AxleRow { code: string; kind: "VEHICLE" | "TRAILER"; axles: number | null; driven_axles: number | null; name_en: string; name_ar: string;
  sort_order: number; status: string; source: string; used: number }
type ListKind = "colours" | "axles";

export function RefListsAdmin() {
  const { t, locale } = useI18n();
  const state = useLoad((signal) => api.get<{ colours: ColourRow[]; axles: AxleRow[] }>("/api/admin/reference-lists", undefined, { signal }));
  const [adding, setAdding] = useState<ListKind | null>(null);
  const [editing, setEditing] = useState<{ kind: ListKind; code: string; title: string } | null>(null);
  const name = (x: { name_en: string; name_ar: string }) => (locale === "ar" ? x.name_ar : x.name_en);
  const fields = (kind: ListKind): EditField[] => [
    { key: "name_en", label: t("lists.nameEn"), ltr: true }, { key: "name_ar", label: t("lists.nameAr") },
    ...(kind === "colours" ? [{ key: "hex", label: t("lists.hex"), ltr: true }] : []),
    { key: "sort_order", label: t("lists.order"), kind: "number" as const },
    { key: "status", label: t("common.status"), kind: "select" as const,
      options: ["ACTIVE", "RETIRED"].map((s) => ({ value: s, label: t(`status.${s}`) })) },
  ];
  return (
    <div className="stack">
      <p className="muted">{t("lists.sub")}</p>
      <Loaded state={state}>{(d) => (<>
        <div className="card">
          <div className="card-title"><h3><Icon name="palette" /> {t("lists.colours")}</h3>
            <button className="btn" onClick={() => setAdding("colours")}><Icon name="add" />{t("lists.addColour")}</button></div>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("lists.colour")}</th><th>{t("lists.code")}</th><th>{t("lists.nameEn")}</th><th>{t("lists.nameAr")}</th>
              <th className="num">{t("lists.used")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{d.colours.map((c) => (
              <tr key={c.code}><td><Swatch hex={c.hex} size={22} /></td><td className="ltr small">{c.code}</td><td className="ltr">{c.name_en}</td><td>{c.name_ar}</td>
                <td className="num">{c.used.toLocaleString("en-US")}</td><td><Status value={c.status} /></td>
                <td><button className="btn text small" aria-label={`${t("edit.edit")} ${name(c)}`}
                            onClick={() => setEditing({ kind: "colours", code: c.code, title: name(c) })}><Icon name="edit" />{t("edit.edit")}</button></td></tr>))}</tbody>
          </table></div>
        </div>
        <div className="card">
          <div className="card-title"><h3><Icon name="local_shipping" /> {t("lists.axles")}</h3>
            <button className="btn" onClick={() => setAdding("axles")}><Icon name="add" />{t("lists.addAxle")}</button></div>
          <p className="small muted">{t("lists.axleHint")}</p>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("lists.code")}</th><th>{t("lists.kind")}</th><th className="num">{t("lists.axleCount")}</th><th className="num">{t("lists.driven")}</th>
              <th>{t("lists.name")}</th><th className="num">{t("lists.used")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{d.axles.map((a) => (
              <tr key={a.code}><td className="ltr"><b>{a.code}</b></td><td className="small">{t(`lists.kinds.${a.kind}`)}{a.source === "LEGACY" ? ` · ${t("lists.legacy")}` : ""}</td>
                <td className="num">{a.axles ?? "—"}</td><td className="num">{a.driven_axles ?? "—"}</td><td>{name(a)}</td>
                <td className="num">{a.used.toLocaleString("en-US")}</td><td><Status value={a.status} /></td>
                <td><button className="btn text small" aria-label={`${t("edit.edit")} ${a.code}`}
                            onClick={() => setEditing({ kind: "axles", code: a.code, title: a.code })}><Icon name="edit" />{t("edit.edit")}</button></td></tr>))}</tbody>
          </table></div>
        </div>
      </>)}</Loaded>
      {adding && <AddEntry kind={adding} onClose={() => setAdding(null)} onDone={() => { setAdding(null); state.reload(); }} />}
      {editing && <RecordEditor title={`${t("edit.edit")} · ${editing.title}`} url={`/api/admin/reference-lists/${editing.kind}/${encodeURIComponent(editing.code)}`}
        record="entry" fields={fields(editing.kind)} regulated={["name_en", "name_ar"]} onClose={() => { setEditing(null); state.reload(); }} />}
    </div>
  );
}

function AddEntry({ kind, onClose, onDone }: { kind: ListKind; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [f, setF] = useState({ code: "", name_en: "", name_ar: "", hex: "", sort_order: "100" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/admin/reference-lists/${kind}`, { code: f.code.trim(), name_en: f.name_en.trim(), name_ar: f.name_ar.trim(),
        sort_order: Number(f.sort_order) || 100, ...(kind === "colours" ? { hex: f.hex.trim() || null } : {}) });
      toast(t("common.saved")); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const input = (k: keyof typeof f, label: string, ltr = true, hint?: string) => (
    <Field label={label} hint={hint}><input className={`input${ltr ? " ltr" : ""}`} value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} /></Field>);
  return (
    <Modal title={kind === "colours" ? t("lists.addColour") : t("lists.addAxle")} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !f.code || f.name_en.length < 2 || f.name_ar.length < 2} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div className="grid cols-2">
          {input("code", t("lists.code"), true, kind === "colours" ? t("lists.colourCodeHint") : t("lists.axleCodeHint"))}
          {input("sort_order", t("lists.order"))}
          {input("name_en", t("lists.nameEn"))}{input("name_ar", t("lists.nameAr"), false)}
          {kind === "colours" && <Field label={t("lists.hex")} hint={t("lists.hexHint")}>
            <div className="row" style={{ gap: 8, alignItems: "center" }}>
              <input className="input ltr" value={f.hex} placeholder="#RRGGBB" onChange={(e) => setF({ ...f, hex: e.target.value })} />
              <Swatch hex={/^#[0-9a-fA-F]{6}$/.test(f.hex) ? f.hex : null} size={28} /></div></Field>}
        </div>
      </div>
    </Modal>
  );
}
