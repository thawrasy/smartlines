import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";
import { PlacePicker, type PickedPlace } from "../../components/PlacePicker";

// Places surveyed in the field (1125): the platform proposes a place the United Nations file does not hold, with its
// sub-district (or its city, for a neighbourhood), names, position and the day of the survey; a second person of the
// platform accepts it, and only then is it used, or rejects it with a reason.

interface Proposed {
  pcode: string; kind: string; status: string; name_en: string; name_ar: string; lat: number; lng: number; surveyed_on: string;
  survey_note: string | null; proposed_at: string; reviewed_at: string | null; review_note: string | null; proposed_by: string | null;
  reviewed_by: string | null; mine: boolean; sub_district: string; sub_district_en: string; sub_district_ar: string;
  city_en: string | null; city_ar: string | null;
}

const today = () => new Date().toISOString().slice(0, 10);

export function FieldSurveys({ waiting, onChange }: { waiting: number; onChange: () => void }) {
  const { t, locale, date } = useI18n();
  const toast = useToast();
  const list = useLoad((signal) => api.get<{ places: Proposed[] }>("/api/admin/geo/proposed", undefined, { signal }), [waiting]);
  const blank = { kind: "COMMUNITY", sub_district: "", name_en: "", name_ar: "", lat: "", lng: "", surveyed_on: today(), note: "", not_duplicate: false };
  const [f, setF] = useState(blank);
  const [city, setCity] = useState<PickedPlace | null>(null);
  const [open, setOpen] = useState(false);
  const [reviewing, setReviewing] = useState<{ place: Proposed; accept: boolean } | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [areaName, setAreaName] = useState<string | null>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) =>
    setF({ ...f, [k]: e.target.type === "checkbox" ? (e.target as HTMLInputElement).checked : e.target.value });
  const name = (en: string | null, ar: string | null) => (locale === "ar" ? ar : en) ?? "";
  const close = () => { setOpen(false); setReviewing(null); setError(null); setNote(""); };
  // the sub-district a position lies in, by the boundaries when loaded, else by the nearest place
  const locate = async () => {
    setError(null);
    try {
      const at = await api.get<{ sub_district: { pcode: string; name_en: string; name_ar: string } | null }>("/api/geo/locate", { lat: f.lat, lng: f.lng });
      if (at.sub_district) { setF({ ...f, sub_district: at.sub_district.pcode }); setAreaName(name(at.sub_district.name_en, at.sub_district.name_ar)); }
    } catch (e) { setError(e); }
  };
  const propose = async () => {
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ pcode: string }>("/api/admin/geo/places", {
        kind: f.kind, sub_district: f.kind === "COMMUNITY" ? f.sub_district : undefined, city: f.kind === "NEIGHBOURHOOD" ? city?.pcode : undefined,
        name_en: f.name_en, name_ar: f.name_ar, lat: Number(f.lat), lng: Number(f.lng), surveyed_on: f.surveyed_on, note: f.note || undefined,
        not_duplicate: f.not_duplicate });
      toast(t("geo.proposedAs", { code: out.pcode })); close(); setF(blank); setCity(null); setAreaName(null); onChange(); list.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const review = async () => {
    if (!reviewing) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/admin/geo/places/${reviewing.place.pcode}/review`, { accept: reviewing.accept, note: note || undefined });
      toast(t("common.saved")); close(); onChange(); list.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const ready = f.name_en.trim().length >= 2 && f.name_ar.trim().length >= 2 && f.lat && f.lng && f.surveyed_on
    && (f.kind === "COMMUNITY" ? /^SY[0-9]{6}$/.test(f.sub_district) : !!city);

  return (
    <div className="card stack">
      <div className="row" style={{ justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
        <div>
          <h3 style={{ margin: 0 }}>{t("geo.field")}</h3>
          <p className="small muted" style={{ margin: 0 }}>{t("geo.fieldHint")}</p>
        </div>
        <button className="btn" onClick={() => setOpen(true)}><Icon name="add_location" />{t("geo.propose")}</button>
      </div>
      <Loaded state={list}>{({ places }) => places.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("geo.noProposals")}</p> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("geo.place")}</th><th>{t("geo.where")}</th><th>{t("geo.code")}</th><th>{t("geo.surveyed")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{places.map((p) => (
            <tr key={p.pcode}>
              <td><strong>{name(p.name_en, p.name_ar)}</strong>{p.survey_note && <div className="small muted">{p.survey_note}</div>}</td>
              <td className="small">{p.city_en ? `${name(p.city_en, p.city_ar)} · ` : ""}{name(p.sub_district_en, p.sub_district_ar)}
                <div><span className="mono muted ltr">{p.lat}, {p.lng}</span></div></td>
              <td className="mono small">{p.pcode}</td>
              <td className="small">{date(`${p.surveyed_on}T12:00:00Z`)}<div className="muted">{p.proposed_by}</div></td>
              <td><span className={`chip ${p.status === "ACTIVE" ? "green" : p.status === "REJECTED" ? "red" : "wheat"}`}>{t(`geo.placeStatus.${p.status}`)}</span>
                {p.review_note && <div className="small muted">{p.review_note}</div>}</td>
              <td>{p.status === "PROPOSED" && (p.mine ? <span className="small muted">{t("geo.waitsOther")}</span> : (
                <span className="row" style={{ gap: 4 }}>
                  <button className="btn text small" onClick={() => { setReviewing({ place: p, accept: true }); setNote(""); }}>{t("geo.accept")}</button>
                  <button className="btn text small" onClick={() => { setReviewing({ place: p, accept: false }); setNote(""); }}>{t("geo.reject")}</button>
                </span>))}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("geo.propose")} onClose={close} wide
               actions={<><button className="btn text" onClick={close}>{t("common.cancel")}</button>
                 <button className="btn filled" disabled={busy || !ready} onClick={propose}>{t("geo.propose")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("geo.kind")}>
                <select className="input" value={f.kind} onChange={set("kind")}>
                  <option value="COMMUNITY">{t("geo.levelName.4")}</option>
                  <option value="NEIGHBOURHOOD">{t("geo.neighbourhood")}</option>
                </select>
              </Field>
              <Field label={t("geo.surveyed")}><input className="input ltr" type="date" max={today()} value={f.surveyed_on} onChange={set("surveyed_on")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={`${t("geo.nameEn")}`}><input className="input ltr" value={f.name_en} onChange={set("name_en")} /></Field>
              <Field label={`${t("geo.nameAr")}`}><input className="input" dir="rtl" value={f.name_ar} onChange={set("name_ar")} /></Field>
            </div>
            <div className="grid cols-2">
              <Field label={t("admin.lat")}><input className="input ltr" type="number" step="0.000001" value={f.lat} onChange={set("lat")} /></Field>
              <Field label={t("admin.lng")}><input className="input ltr" type="number" step="0.000001" value={f.lng} onChange={set("lng")} /></Field>
            </div>
            {f.kind === "COMMUNITY" ? (
              <div className="row" style={{ gap: 8, alignItems: "flex-end", flexWrap: "wrap" }}>
                <Field label={t("geo.subDistrictCode")} hint={areaName ?? undefined}>
                  <input className="input mono ltr" value={f.sub_district} placeholder="SY020000" onChange={(e) => { setF({ ...f, sub_district: e.target.value.toUpperCase() }); setAreaName(null); }} />
                </Field>
                <button type="button" className="btn outlined" disabled={!f.lat || !f.lng} onClick={locate}><Icon name="my_location" />{t("geo.fromPosition")}</button>
              </div>
            ) : <PlacePicker label={t("geo.cityOfNeighbourhood")} value={city} onPick={setCity} />}
            <Field label={`${t("geo.surveyNote")} (${t("common.optional")})`}><textarea className="input" rows={2} maxLength={1000} value={f.note} onChange={set("note")} /></Field>
            <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={f.not_duplicate} onChange={set("not_duplicate")} />{t("geo.notDuplicate")}</label>
          </div>
        </Modal>
      )}
      {reviewing && (
        <Modal title={t(reviewing.accept ? "geo.acceptTitle" : "geo.rejectTitle", { name: name(reviewing.place.name_en, reviewing.place.name_ar) })} onClose={close}
               actions={<><button className="btn text" onClick={close}>{t("common.cancel")}</button>
                 <button className="btn filled" disabled={busy || (!reviewing.accept && note.trim().length < 5)} onClick={review}>{t(reviewing.accept ? "geo.accept" : "geo.reject")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <p className="small muted" style={{ margin: 0 }}>{t(reviewing.accept ? "geo.acceptHint" : "geo.rejectHint")}</p>
            <Field label={reviewing.accept ? `${t("geo.reviewNote")} (${t("common.optional")})` : t("geo.reviewNote")}>
              <textarea className="input" rows={2} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
            </Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
