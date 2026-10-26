import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// Vehicle placards and roadside checks (owner's note N48, migration 1169): each vehicle carries one placard with its
// movement code on the windscreen and the rear. It is printed once (A3 by default, A4 for small vehicles); a lost or
// copied placard is revoked with its reason and the next serial printed. The checks made on the company's vehicles are
// listed below, without the officer's account.

interface Row { uid: string; plate_no: string; passenger_seats: number | null; status: string; serial: number | null; issued_at: string | null;
  issued_by: string | null; revoked: number; last_check: string | null }
interface Check { uid: string; created_at: string; status: string; result: string; outcome: string | null; movement_kind: string | null;
  movement_ref: string | null; warnings: string[]; sampled: number | null; plate_no: string; body: string | null; note: string | null }

export function CarrierPlacards() {
  const { t, date } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<{ vehicles: Row[] }>("/api/carrier/placards", undefined, { signal }));
  const checks = useLoad((signal) => api.get<{ checks: Check[] }>("/api/carrier/roadside-checks", undefined, { signal }));
  const [revoking, setRevoking] = useState<{ v: Row; reason: string } | null>(null);
  const [size, setSize] = useState<"A3" | "A4">("A3");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, after: () => void = () => undefined) => {
    setBusy(true); setError(null);
    try { await fn(); after(); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <PageHead title={t("plc.title")} sub={t("plc.sub")}>
        <Field label={t("plc.size")}>
          <select className="input" value={size} onChange={(e) => setSize(e.target.value as "A3" | "A4")}>
            <option value="A3">{t("plc.a3")}</option><option value="A4">{t("plc.a4")}</option>
          </select>
        </Field>
      </PageHead>
      {!revoking && <ErrorBox error={error} />}
      <Loaded state={state}>{({ vehicles }) => vehicles.length === 0 ? <div className="card"><Empty icon="directions_car" title={t("common.noData")} /></div> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("plc.plate")}</th><th>{t("common.status")}</th><th>{t("plc.placard")}</th><th>{t("plc.lastCheck")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{vehicles.map((v) => (
            <tr key={v.uid}>
              <td className="mono">{v.plate_no}</td><td><Status value={v.status} /></td>
              <td className="small">{v.serial ? <>{t("plc.serial", { n: v.serial })}<div className="muted">{v.issued_at && date(v.issued_at)} · {v.issued_by}</div></>
                : <span className="chip outline">{t("plc.none")}</span>}
                {v.revoked > 0 && <div className="muted">{t("plc.revokedCount", { n: v.revoked })}</div>}</td>
              <td className="small">{v.last_check ? date(v.last_check) : "—"}</td>
              <td><div className="row nowrap" style={{ gap: 4 }}>
                {v.serial ? <>
                  <a className="btn tonal small" href={`/api/carrier/vehicles/${v.uid}/placard.pdf?size=${size}`} download><Icon name="print" size={18} />{t("plc.print")}</a>
                  <button className="btn text small" onClick={() => { setError(null); setRevoking({ v, reason: "" }); }}>{t("plc.revoke")}</button>
                </> : <button className="btn small" disabled={busy} onClick={() => run(() => api.post(`/api/carrier/vehicles/${v.uid}/placard`))}>
                  <Icon name="qr_code_2" size={18} />{t("plc.issue")}</button>}
              </div></td>
            </tr>))}</tbody>
        </table></div>)}</Loaded>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("plc.checks")}</h3>
        <Loaded state={checks}>{({ checks: rows }) => rows.length === 0 ? <Empty icon="qr_code_scanner" title={t("gov.noChecks")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("gov.when")}</th><th>{t("plc.plate")}</th><th>{t("gov.movement")}</th><th>{t("gov.body")}</th><th>{t("gov.result")}</th><th>{t("gov.warnings")}</th><th>{t("plc.note")}</th></tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.uid}><td className="small">{date(c.created_at)}</td><td className="mono">{c.plate_no}</td>
                <td className="small">{c.movement_kind ? `${t(`gov.mk.${c.movement_kind}`)} ${c.movement_ref ?? ""}` : "—"}</td>
                <td className="mono small">{c.body ?? "—"}</td>
                <td className="small">{t(`gov.res.${c.result}`)}{c.outcome && <div className="muted">{t(`gov.out.${c.outcome}`)}</div>}</td>
                <td className="small">{c.warnings.length ? c.warnings.map((w) => t(`gov.warn.${w}`)).join(", ") : "—"}</td>
                <td className="small">{c.note ?? "—"}</td></tr>))}</tbody>
          </table></div>)}</Loaded>
      </div>
      {revoking && (
        <Modal title={t("plc.revokeTitle", { plate: revoking.v.plate_no })} onClose={() => setRevoking(null)}
               actions={<><button className="btn text" onClick={() => setRevoking(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || revoking.reason.trim().length < 3}
                         onClick={() => run(() => api.post(`/api/carrier/vehicles/${revoking.v.uid}/placard/revoke`, { reason: revoking.reason }), () => setRevoking(null))}>
                   {t("plc.revoke")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <p className="small muted" style={{ margin: 0 }}>{t("plc.revokeHint")}</p>
            <Field label={t("plc.reason")}><input className="input" maxLength={300} value={revoking.reason} onChange={(e) => setRevoking({ ...revoking, reason: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
