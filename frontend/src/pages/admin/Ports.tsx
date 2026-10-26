import { useRef, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, useLoad, useToast } from "../../components/ui";

// Border crossings and airports (owner's note N45, migration 1168): loaded from the owner's approved workbook and tied
// to the United Nations geography. Each port keeps its fixed code; its names, status, place, position and station are
// edited with a reason, and every change is kept in its history.

type Kind = "LAND_BORDER" | "INTL_AIRPORT" | "LOCAL_AIRPORT";
interface Port { code: string; kind: Kind; name_ar: string; name_en: string; counterpart_name_ar: string | null; counterpart_name_en: string | null;
  counterpart_country: string | null; iata_code: string | null; lat: number | null; lng: number | null; status: string; status_confirmed: boolean;
  governorate_en: string | null; governorate_ar: string | null; sub_district: string; sub_district_en: string; sub_district_ar: string;
  place: string | null; place_en: string | null; place_ar: string | null; station: string | null; position_source: string; match_quality: string;
  review_note: string | null; edited_by_hand: boolean; changes: number }
interface Change { changed_at: string; field: string; old_value: string | null; new_value: string | null; reason: string | null; changed_by: string | null; by_file: string | null }

export function AdminPorts() {
  const { t, locale: lang, dateTime, num } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ ports: Port[]; last_file: { file_name: string | null; imported_at: string } | null }>("/api/admin/ports"));
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [edit, setEdit] = useState<Port | null>(null);
  const [form, setForm] = useState<Record<string, string>>({});
  const [history, setHistory] = useState<{ code: string; changes: Change[] } | null>(null);
  const name = (p: { name_ar: string; name_en: string }) => (lang === "ar" ? p.name_ar : p.name_en);

  const upload = async () => {
    const f = fileRef.current?.files?.[0];
    if (!f) return;
    setBusy(true); setError(null);
    try {
      const fd = new FormData(); fd.append("file", f);
      const out = await api.upload<{ already_loaded: boolean; counts: { added?: number; updated?: number; kept_edited?: string[] } }>("/api/admin/ports/import", fd);
      toast(out.already_loaded ? t("ports.alreadyLoaded") : t("ports.loaded", { added: out.counts.added ?? 0, updated: out.counts.updated ?? 0, kept: out.counts.kept_edited?.length ?? 0 }));
      if (fileRef.current) fileRef.current.value = "";
      state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const open = (p: Port) => {
    setEdit(p); setError(null);
    setForm({ name_ar: p.name_ar, name_en: p.name_en, counterpart_name_ar: p.counterpart_name_ar ?? "", counterpart_name_en: p.counterpart_name_en ?? "",
      status: p.status, status_confirmed: p.status_confirmed ? "1" : "", place: "", lat: "", lng: "", station: p.station ?? "", review_note: p.review_note ?? "", reason: "" });
  };
  const save = async () => {
    if (!edit) return;
    setBusy(true); setError(null);
    const body: Record<string, unknown> = { reason: form.reason };
    for (const k of ["name_ar", "name_en", "counterpart_name_ar", "counterpart_name_en", "review_note"]) {
      const before = (edit as unknown as Record<string, string | null>)[k] ?? "";
      if (form[k] !== before && form[k].trim()) body[k] = form[k].trim();
    }
    if (form.status !== edit.status) body.status = form.status;
    if (!!form.status_confirmed !== edit.status_confirmed) body.status_confirmed = !!form.status_confirmed;
    if (form.place.trim()) body.place = form.place.trim().toUpperCase();
    if (form.lat && form.lng) { body.lat = Number(form.lat); body.lng = Number(form.lng); }
    if (form.station !== (edit.station ?? "")) body.station = form.station.trim();
    try {
      await api.put(`/api/admin/ports/${edit.code}`, body);
      setEdit(null); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const showHistory = async (code: string) => {
    setHistory({ code, changes: (await api.get<{ changes: Change[] }>(`/api/admin/ports/${code}/history`)).changes });
  };
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setForm({ ...form, [k]: e.target.value });

  return (
    <div className="stack">
      <PageHead title={t("ports.title")} sub={t("ports.sub")} />
      <div className="card stack">
        <ErrorBox error={!edit ? error : null} />
        <div className="row wrap">
          <input ref={fileRef} type="file" accept=".xlsx" className="input" aria-label={t("ports.file")} />
          <button className="btn" disabled={busy} onClick={upload}><Icon name="upload_file" />{t("ports.loadBtn")}</button>
        </div>
        <p className="small muted">{t("ports.loadHint")}</p>
      </div>
      <Loaded state={state}>{({ ports, last_file }) => (<>
        <div className="grid cols-3">
          <Stat icon="flag" label={t("ports.kinds.LAND_BORDER")} value={num(ports.filter((p) => p.kind === "LAND_BORDER").length)} />
          <Stat icon="flight_takeoff" label={t("ports.kinds.INTL_AIRPORT")} value={num(ports.filter((p) => p.kind === "INTL_AIRPORT").length)} tone="blue" />
          <Stat icon="flight_land" label={t("ports.kinds.LOCAL_AIRPORT")} value={num(ports.filter((p) => p.kind === "LOCAL_AIRPORT").length)} tone="wheat" />
        </div>
        {last_file && <p className="small muted">{t("ports.lastFile", { file: last_file.file_name ?? "—", at: dateTime(last_file.imported_at) })}</p>}
        {ports.length === 0 ? <div className="card"><Empty icon="flag" title={t("ports.none")} /></div> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("ports.code")}</th><th>{t("ports.name")}</th><th>{t("ports.counterpart")}</th><th>{t("ports.area")}</th><th>{t("ports.place")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{ports.map((p) => (
              <tr key={p.code} style={{ opacity: p.status === "CLOSED" ? 0.55 : 1 }}>
                <td className="mono ltr">{p.code}{p.iata_code && <div className="small muted">IATA {p.iata_code}</div>}</td>
                <td>{name(p)}<div className="small muted">{t(`ports.kinds.${p.kind}`)}</div></td>
                <td className="small">{p.counterpart_name_en ? <>{lang === "ar" ? p.counterpart_name_ar ?? p.counterpart_name_en : p.counterpart_name_en} <span className="mono">({p.counterpart_country})</span></> : "—"}</td>
                <td className="small">{lang === "ar" ? p.governorate_ar : p.governorate_en}<div className="muted">{lang === "ar" ? p.sub_district_ar : p.sub_district_en}</div></td>
                <td className="small">{p.place ? <>{lang === "ar" ? p.place_ar : p.place_en} <span className="mono">{p.place}</span></> : t("ports.noPlace")}
                  <div className="muted">{t(`ports.quality.${p.match_quality}`)}</div></td>
                <td><span className={`chip ${p.status === "ACTIVE" ? "green" : p.status === "CLOSED" ? "red" : "wheat"}`}>{t(`ports.status.${p.status}`)}</span>
                  {!p.status_confirmed && <div className="small muted">{t("ports.unconfirmed")}</div>}</td>
                <td className="nowrap">
                  <button className="btn text small" onClick={() => open(p)}>{t("common.edit")}</button>
                  {p.changes > 0 && <button className="btn text small" onClick={() => showHistory(p.code)}>{t("ports.history")} ({num(p.changes)})</button>}
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </>)}</Loaded>
      {edit && (
        <Modal title={`${edit.code} · ${name(edit)}`} onClose={() => setEdit(null)}
               actions={<><button className="btn text" onClick={() => setEdit(null)}>{t("common.cancel")}</button><button className="btn" disabled={busy || form.reason.trim().length < 3} onClick={save}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <p className="small muted">{t("ports.codeFixed")}</p>
            <div className="grid cols-2">
              <Field label={t("ports.nameAr")}><input className="input" dir="rtl" value={form.name_ar} onChange={set("name_ar")} /></Field>
              <Field label={t("ports.nameEn")}><input className="input ltr" value={form.name_en} onChange={set("name_en")} /></Field>
              {edit.kind === "LAND_BORDER" && <>
                <Field label={t("ports.counterpartAr")}><input className="input" dir="rtl" value={form.counterpart_name_ar} onChange={set("counterpart_name_ar")} /></Field>
                <Field label={t("ports.counterpartEn")}><input className="input ltr" value={form.counterpart_name_en} onChange={set("counterpart_name_en")} /></Field>
              </>}
              <Field label={t("common.status")}><select className="input" value={form.status} onChange={set("status")}>{["ACTIVE", "RESTRICTED", "CLOSED"].map((s) => <option key={s} value={s}>{t(`ports.status.${s}`)}</option>)}</select></Field>
              <Field label={t("ports.confirmed")}><select className="input" value={form.status_confirmed} onChange={set("status_confirmed")}><option value="">{t("common.no")}</option><option value="1">{t("common.yes")}</option></select></Field>
              <Field label={t("ports.newPlace")} hint={t("ports.newPlaceHint")}><input className="input ltr mono" value={form.place} onChange={set("place")} /></Field>
              <Field label={t("ports.station")}><input className="input ltr mono" value={form.station} onChange={set("station")} /></Field>
              <Field label={t("ports.surveyLat")}><input className="input ltr" type="number" step="0.000001" value={form.lat} onChange={set("lat")} /></Field>
              <Field label={t("ports.surveyLng")}><input className="input ltr" type="number" step="0.000001" value={form.lng} onChange={set("lng")} /></Field>
            </div>
            <Field label={t("ports.note")}><input className="input" value={form.review_note} onChange={set("review_note")} /></Field>
            <Field label={t("ports.reason")}><input className="input" value={form.reason} onChange={set("reason")} /></Field>
          </div>
        </Modal>
      )}
      {history && (
        <Modal title={`${t("ports.history")} · ${history.code}`} onClose={() => setHistory(null)} actions={<button className="btn" onClick={() => setHistory(null)}>{t("common.close")}</button>}>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("ports.field")}</th><th>{t("ports.before")}</th><th>{t("ports.after")}</th><th>{t("ports.by")}</th><th>{t("common.reason")}</th></tr></thead>
            <tbody>{history.changes.map((c, i) => (
              <tr key={i}><td className="small">{dateTime(c.changed_at)}</td><td className="mono small">{c.field}</td>
                <td className="small">{c.old_value ?? "—"}</td><td className="small">{c.new_value ?? "—"}</td>
                <td className="small ltr">{c.changed_by ?? "—"}{c.by_file && <div className="muted">{t("ports.byFile", { file: c.by_file })}</div>}</td>
                <td className="small">{c.reason ?? "—"}</td></tr>
            ))}</tbody>
          </table></div>
        </Modal>
      )}
    </div>
  );
}
