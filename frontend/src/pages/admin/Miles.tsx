import { useEffect, useState } from "react";
import { api } from "../../api";
import { toMinor, useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// The miles programme in the platform portal (owner's note 19, migration 1166): name and unit, tiers and their
// multipliers, the chart of miles per pair of stations, award tickets, partners with their contract numbers and the
// partners corner, and the two switches (award redemption, promoted display), both off in the first phase.

interface Data {
  programme: { code: string; name: string; name_ar: string | null; unit_en: string; unit_ar: string | null; point_value: number; currency: string; expiry_months: number };
  tiers: { code: string; name: string; min_points: number; multiplier: string }[];
  chart: { id: number; from_code: string; from_name: string; to_code: string; to_name: string; miles: number; network_route: string | null; valid_from: string }[];
  awards: { uid: string; from_code: string; to_code: string; miles: number; fee: number; reduced_amount: number; currency: string; carrier: string | null; seats_per_trip: number | null }[];
  partners: { id: number; name: string; partner_type: string; status: string; contract_ref: string | null; corner_note: string | null; promoted: boolean; promoted_until: string | null }[];
  award_redemption: boolean; promoted_display: boolean;
}
type Partner = Data["partners"][number];

export function AdminMiles() {
  const { t, money, num } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Data>("/api/admin/miles", undefined, { signal }));
  const [prog, setProg] = useState({ name: "", name_ar: "", unit_en: "", unit_ar: "", expiry_months: "24" });
  const [form, setForm] = useState<"chart" | "award" | null>(null);
  const [pair, setPair] = useState({ from_station: "", to_station: "", miles: "", fee: "", reduced_amount: "" });
  const [partner, setPartner] = useState<Partner | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => {
    const p = state.data?.programme;
    if (p) setProg({ name: p.name, name_ar: p.name_ar ?? "", unit_en: p.unit_en, unit_ar: p.unit_ar ?? "", expiry_months: String(p.expiry_months) });
  }, [state.data]);
  const run = async (fn: () => Promise<unknown>, after?: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); after?.(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const minor = (v: string) => toMinor(v || 0);
  const savePair = () => run(() => form === "chart"
    ? api.post("/api/admin/miles/chart", { from_station: pair.from_station, to_station: pair.to_station, miles: Number(pair.miles) })
    : api.post("/api/admin/miles/awards", { from_station: pair.from_station, to_station: pair.to_station, miles: Number(pair.miles),
                                            fee: minor(pair.fee), reduced_amount: minor(pair.reduced_amount) }), () => setForm(null));
  return (
    <div className="stack">
      <PageHead title={t("miles.adminTitle")} sub={t("miles.adminSub")} />
      <ErrorBox error={error} />
      <Loaded state={state}>{(d) => (
        <>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("miles.programme")}</h3>
            <div className="grid cols-2">
              <Field label={t("miles.nameEn")}><input className="input" value={prog.name} onChange={(e) => setProg({ ...prog, name: e.target.value })} /></Field>
              <Field label={t("miles.nameAr")}><input className="input" dir="rtl" value={prog.name_ar} onChange={(e) => setProg({ ...prog, name_ar: e.target.value })} /></Field>
              <Field label={t("miles.unitEn")}><input className="input" value={prog.unit_en} onChange={(e) => setProg({ ...prog, unit_en: e.target.value })} /></Field>
              <Field label={t("miles.unitAr")}><input className="input" dir="rtl" value={prog.unit_ar} onChange={(e) => setProg({ ...prog, unit_ar: e.target.value })} /></Field>
              <Field label={t("miles.expiry")}><input className="input mono" inputMode="numeric" value={prog.expiry_months} onChange={(e) => setProg({ ...prog, expiry_months: e.target.value.replace(/\D/g, "") })} /></Field>
            </div>
            <div><button className="btn" disabled={busy} onClick={() => run(() => api.put("/api/admin/miles/programme", { ...prog, expiry_months: Number(prog.expiry_months) }))}>{t("common.save")}</button></div>
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("miles.switches")}</h3>
            {(["award_redemption", "promoted_display"] as const).map((k) => (
              <label key={k} className="check"><input type="checkbox" checked={d[k]} disabled={busy}
                onChange={(e) => run(() => api.put("/api/admin/miles/settings", { [k]: e.target.checked }))} />{t(`miles.switch_${k}`)}</label>
            ))}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("miles.tiers")}</h3>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("miles.tier")}</th><th>{t("miles.minMiles")}</th><th>{t("miles.multiplier")}</th><th /></tr></thead>
              <tbody>{d.tiers.map((x) => <TierRow key={x.code} tier={x} busy={busy}
                onSave={(min_points, multiplier) => run(() => api.put(`/api/admin/miles/tiers/${encodeURIComponent(x.code)}`, { min_points, multiplier }))} />)}</tbody>
            </table></div>
          </div>
          <div className="card stack">
            <div className="row between"><h3 style={{ margin: 0 }}>{t("miles.chart")}</h3>
              <button className="btn outlined small" onClick={() => { setPair({ from_station: "", to_station: "", miles: "", fee: "", reduced_amount: "" }); setForm("chart"); }}><Icon name="add" />{t("miles.addPair")}</button></div>
            {d.chart.length === 0 ? <Empty icon="route" title={t("miles.noChart")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("miles.pair")}</th><th>{t("miles.miles")}</th><th /></tr></thead>
                <tbody>{d.chart.map((c) => (
                  <tr key={c.id}><td><span className="mono">{c.from_code}</span> – <span className="mono">{c.to_code}</span><div className="small muted">{c.from_name} – {c.to_name}</div></td>
                    <td className="mono">{num(c.miles)}</td>
                    <td><button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/admin/miles/chart/${c.id}/retire`, {}))}>{t("miles.retire")}</button></td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
          <div className="card stack">
            <div className="row between"><h3 style={{ margin: 0 }}>{t("miles.awards")}</h3>
              <button className="btn outlined small" onClick={() => { setPair({ from_station: "", to_station: "", miles: "", fee: "", reduced_amount: "" }); setForm("award"); }}><Icon name="add" />{t("miles.addAward")}</button></div>
            {d.awards.length === 0 ? <Empty icon="redeem" title={t("miles.noAwards")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("miles.pair")}</th><th>{t("miles.miles")}</th><th>{t("miles.fee")}</th><th>{t("miles.reduced")}</th><th /></tr></thead>
                <tbody>{d.awards.map((a) => (
                  <tr key={a.uid}><td className="mono">{a.from_code} – {a.to_code}{a.carrier && <div className="small muted">{a.carrier}</div>}</td>
                    <td className="mono">{num(a.miles)}</td><td className="mono">{money(a.fee)}</td><td className="mono">{money(a.reduced_amount)}</td>
                    <td><button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/admin/miles/awards/${a.uid}/retire`, {}))}>{t("miles.retire")}</button></td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("miles.partners")}</h3>
            {d.partners.length === 0 ? <Empty icon="storefront" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("miles.partner")}</th><th>{t("miles.contract")}</th><th>{t("common.status")}</th><th>{t("miles.promoted")}</th><th /></tr></thead>
                <tbody>{d.partners.map((p) => (
                  <tr key={p.id}><td>{p.name}<div className="small muted">{t(`miles.type.${p.partner_type}`)}</div></td><td className="mono small">{p.contract_ref ?? "—"}</td>
                    <td>{t(`miles.status.${p.status}`)}</td><td>{p.promoted ? t("miles.yes") : "—"}</td>
                    <td><button className="btn text small" onClick={() => { setError(null); setPartner(p); }}>{t("common.edit")}</button></td></tr>
                ))}</tbody>
              </table></div>)}
          </div>
        </>
      )}</Loaded>
      {form && (
        <Modal title={t(form === "chart" ? "miles.addPair" : "miles.addAward")} onClose={() => setForm(null)}
               actions={<><button className="btn text" onClick={() => setForm(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !pair.from_station || !pair.to_station || !pair.miles} onClick={savePair}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("miles.fromStation")}><input className="input ltr mono" value={pair.from_station} onChange={(e) => setPair({ ...pair, from_station: e.target.value.toUpperCase() })} /></Field>
              <Field label={t("miles.toStation")}><input className="input ltr mono" value={pair.to_station} onChange={(e) => setPair({ ...pair, to_station: e.target.value.toUpperCase() })} /></Field>
              <Field label={t("miles.miles")}><input className="input mono" inputMode="numeric" value={pair.miles} onChange={(e) => setPair({ ...pair, miles: e.target.value.replace(/\D/g, "") })} /></Field>
              {form === "award" && <>
                <Field label={t("miles.fee")}><input className="input mono" inputMode="decimal" value={pair.fee} onChange={(e) => setPair({ ...pair, fee: e.target.value })} /></Field>
                <Field label={t("miles.reduced")}><input className="input mono" inputMode="decimal" value={pair.reduced_amount} onChange={(e) => setPair({ ...pair, reduced_amount: e.target.value })} /></Field>
              </>}
            </div>
          </div>
        </Modal>
      )}
      {partner && <PartnerModal p={partner} busy={busy} error={error} onClose={() => setPartner(null)}
        onSave={(body) => run(() => api.put(`/api/admin/miles/partners/${partner.id}`, body), () => setPartner(null))} />}
    </div>
  );
}

function TierRow({ tier, busy, onSave }: { tier: Data["tiers"][number]; busy: boolean; onSave: (min: number, mult: number) => void }) {
  const { t } = useI18n();
  const [min, setMin] = useState(String(tier.min_points));
  const [mult, setMult] = useState(tier.multiplier);
  return (
    <tr><td>{tier.name}<div className="small muted mono">{tier.code}</div></td>
      <td><input className="input mono" inputMode="numeric" style={{ maxWidth: 140 }} aria-label={t("miles.minMiles")} value={min} onChange={(e) => setMin(e.target.value.replace(/\D/g, ""))} /></td>
      <td><input className="input mono" inputMode="decimal" style={{ maxWidth: 100 }} aria-label={t("miles.multiplier")} value={mult} onChange={(e) => setMult(e.target.value)} /></td>
      <td><button className="btn text small" disabled={busy} onClick={() => onSave(Number(min), Number(mult))}>{t("common.save")}</button></td></tr>
  );
}

function PartnerModal({ p, busy, error, onClose, onSave }: { p: Partner; busy: boolean; error: unknown; onClose: () => void; onSave: (body: object) => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({ contract_ref: p.contract_ref ?? "", corner_note: p.corner_note ?? "", promoted: p.promoted, promoted_until: p.promoted_until ?? "", status: p.status });
  return (
    <Modal title={p.name} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy} onClick={() => onSave({ ...f, promoted_until: f.promoted_until || null })}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Field label={t("miles.contract")}><input className="input ltr mono" value={f.contract_ref} onChange={(e) => setF({ ...f, contract_ref: e.target.value })} /></Field>
        <Field label={t("common.status")}>
          <select className="input" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
            {["PENDING", "ACTIVE", "SUSPENDED", "ENDED"].map((s) => <option key={s} value={s}>{t(`miles.status.${s}`)}</option>)}
          </select>
        </Field>
        <Field label={t("miles.cornerNote")}><input className="input" maxLength={300} value={f.corner_note} onChange={(e) => setF({ ...f, corner_note: e.target.value })} /></Field>
        <label className="check"><input type="checkbox" checked={f.promoted} onChange={(e) => setF({ ...f, promoted: e.target.checked })} />{t("miles.promoted")}</label>
        <Field label={t("miles.promotedUntil")}><input className="input" type="date" value={f.promoted_until} onChange={(e) => setF({ ...f, promoted_until: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}
