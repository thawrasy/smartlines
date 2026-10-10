import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

type Mode = "WEIGHT" | "VOLUME" | "WEIGHT_AND_VOLUME" | "FIXED" | "NEGOTIATED";
interface Tariff { uid: string; code: string; name: string; pricing_mode: Mode; currency: string; base_price: number; per_kg: number | null;
  per_m3: number | null; fixed_price: number | null; min_charge: number; max_weight_kg: number | null; status: string }
interface Offer { uid: string; status: string; trip_no: string; tariff_name: string; weight_kg: number; volume_m3: number; description: string;
  price: number | null; currency: string | null; valid_until: string | null; created_at: string }
const MODES: Mode[] = ["WEIGHT", "VOLUME", "WEIGHT_AND_VOLUME", "FIXED", "NEGOTIATED"];
const BLANK = { code: "", name: "", pricing_mode: "WEIGHT" as Mode, currency: "SYP", base_price: 0, per_kg: "", per_m3: "", fixed_price: "", min_charge: 0, max_weight_kg: "" };

/** The carrier's parcel prices and the prices it agrees with customers (owner's decision 3). Amounts in minor units. */
export default function CarrierParcels() {
  const { t, money, num, dateTime } = useI18n();
  const toast = useToast();
  const tariffs = useLoad((signal) => api.get<{ tariffs: Tariff[] }>("/api/carrier/parcels/tariffs", undefined, { signal }));
  const offers = useLoad((signal) => api.get<{ offers: Offer[] }>("/api/carrier/parcels/offers", undefined, { signal }));
  const [f, setF] = useState(BLANK);
  const [adding, setAdding] = useState(false);
  const [pricing, setPricing] = useState<Offer | null>(null);
  const [price, setPrice] = useState({ price: 0, valid_hours: 24, note: "" });
  const [error, setError] = useState<unknown>(null);
  const opt = (v: string) => (v === "" ? null : Number(v));
  const needs = (m: Mode) => ({ kg: m === "WEIGHT" || m === "WEIGHT_AND_VOLUME", m3: m === "VOLUME" || m === "WEIGHT_AND_VOLUME", fixed: m === "FIXED" });

  const save = async () => {
    setError(null);
    try {
      await api.post("/api/carrier/parcels/tariffs", { ...f, code: f.code.toUpperCase(), per_kg: opt(f.per_kg), per_m3: opt(f.per_m3),
        fixed_price: opt(f.fixed_price), max_weight_kg: opt(f.max_weight_kg) });
      toast(t("parcel.saved")); setAdding(false); setF(BLANK); tariffs.reload();
    } catch (e) { setError(e); }
  };
  const retire = async (uid: string) => { await api.post(`/api/carrier/parcels/tariffs/${uid}/retire`, {}); tariffs.reload(); };
  const offer = async () => {
    if (!pricing) return;
    setError(null);
    try { await api.post(`/api/carrier/parcels/offers/${pricing.uid}/price`, price); toast(t("parcel.priced")); setPricing(null); offers.reload(); }
    catch (e) { setError(e); }
  };
  const decline = async (uid: string) => { await api.post(`/api/carrier/parcels/offers/${uid}/decline`, {}); offers.reload(); };
  const n = needs(f.pricing_mode);

  return (
    <div className="stack">
      <PageHead title={t("parcel.carrierTitle")} sub={t("parcel.carrierSub")}>
        <button className="btn filled" onClick={() => setAdding(true)}><Icon name="add" />{t("parcel.newTariff")}</button>
      </PageHead>
      <Loaded state={tariffs}>{({ tariffs: list }) => (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("parcel.code")}</th><th>{t("parcel.name")}</th><th>{t("parcel.pricing")}</th><th>{t("parcel.rates")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{list.map((x) => (
            <tr key={x.uid}><td className="mono">{x.code}</td><td>{x.name}</td><td>{t(`parcel.mode.${x.pricing_mode}`)}</td>
              <td className="small">{[x.per_kg != null && `${money(x.per_kg, true, x.currency)}/kg`, x.per_m3 != null && `${money(x.per_m3, true, x.currency)}/m³`,
                x.fixed_price != null && money(x.fixed_price, true, x.currency)].filter(Boolean).join(" · ") || t("parcel.agreed")}</td>
              <td><Status value={x.status} /></td>
              <td>{x.status === "ACTIVE" && <button className="btn text" onClick={() => retire(x.uid)}>{t("parcel.retire")}</button>}</td></tr>
          ))}</tbody></table></div>
      )}</Loaded>

      <section className="card stack" aria-labelledby="offers-h">
        <h3 id="offers-h">{t("parcel.requests")}</h3>
        <Loaded state={offers}>{({ offers: list }) => list.length === 0 ? <p className="small muted">{t("parcel.noOffers")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table"><tbody>{list.map((o) => (
            <tr key={o.uid}><td className="small">{dateTime(o.created_at)}</td><td className="mono">{o.trip_no}</td><td>{o.tariff_name}</td>
              <td>{num(o.weight_kg)} kg · {num(o.volume_m3)} m³</td><td>{o.description}</td><td><Status value={o.status} /></td>
              <td>{o.price != null && o.currency ? money(o.price, true, o.currency) : "—"}</td>
              <td>{(o.status === "REQUESTED" || o.status === "OFFERED") && <>
                <button className="btn filled" onClick={() => { setPricing(o); setPrice({ price: o.price ?? 0, valid_hours: 24, note: "" }); }}>{t("parcel.offerPrice")}</button>
                <button className="btn text" onClick={() => decline(o.uid)}>{t("parcel.decline")}</button></>}</td></tr>
          ))}</tbody></table></div>
        )}</Loaded>
      </section>

      {adding && (
        <Modal title={t("parcel.newTariff")} onClose={() => setAdding(false)} wide actions={<button className="btn filled" onClick={save}>{t("common.save")}</button>}>
          <div className="grid cols-3">
            <Field label={t("parcel.code")}><input className="input ltr" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} /></Field>
            <Field label={t("parcel.name")}><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
            <Field label={t("parcel.pricing")}><select className="input" value={f.pricing_mode} onChange={(e) => setF({ ...f, pricing_mode: e.target.value as Mode })}>
              {MODES.map((m) => <option key={m} value={m}>{t(`parcel.mode.${m}`)}</option>)}</select></Field>
            {(n.kg || n.m3) && <Field label={t("parcel.base")}><input className="input" type="number" min={0} value={f.base_price} onChange={(e) => setF({ ...f, base_price: Number(e.target.value) })} /></Field>}
            {n.kg && <Field label={t("parcel.perKg")}><input className="input" type="number" min={0} value={f.per_kg} onChange={(e) => setF({ ...f, per_kg: e.target.value })} /></Field>}
            {n.m3 && <Field label={t("parcel.perM3")}><input className="input" type="number" min={0} value={f.per_m3} onChange={(e) => setF({ ...f, per_m3: e.target.value })} /></Field>}
            {n.fixed && <Field label={t("parcel.fixed")}><input className="input" type="number" min={0} value={f.fixed_price} onChange={(e) => setF({ ...f, fixed_price: e.target.value })} /></Field>}
            {f.pricing_mode !== "NEGOTIATED" && <Field label={t("parcel.minCharge")}><input className="input" type="number" min={0} value={f.min_charge} onChange={(e) => setF({ ...f, min_charge: Number(e.target.value) })} /></Field>}
            <Field label={t("parcel.maxWeight")}><input className="input" type="number" min={0} value={f.max_weight_kg} onChange={(e) => setF({ ...f, max_weight_kg: e.target.value })} /></Field>
          </div>
          <p className="small muted">{t(`parcel.modeHint.${f.pricing_mode}`)}</p>
          <ErrorBox error={error} />
        </Modal>
      )}
      {pricing && (
        <Modal title={t("parcel.offerPrice")} onClose={() => setPricing(null)} actions={<button className="btn filled" onClick={offer}>{t("parcel.offerPrice")}</button>}>
          <div className="grid cols-2">
            <Field label={t("parcel.price")}><input className="input" type="number" min={1} value={price.price} onChange={(e) => setPrice({ ...price, price: Number(e.target.value) })} /></Field>
            <Field label={t("parcel.validHours")}><input className="input" type="number" min={1} max={168} value={price.valid_hours} onChange={(e) => setPrice({ ...price, valid_hours: Number(e.target.value) })} /></Field>
          </div>
          <Field label={t("parcel.note")}><input className="input" value={price.note} onChange={(e) => setPrice({ ...price, note: e.target.value })} /></Field>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}
