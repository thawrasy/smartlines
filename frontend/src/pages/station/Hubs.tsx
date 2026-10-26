import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, Field, Icon, Loaded, Modal, useErrorText, useLoad, useToast } from "../../components/ui";

// Screens on the station's own network (owner's note N46; migration 1179; docs/design/STATION_DISPLAYS_LAN.md). One
// display hub inside the station talks to the platform, outbound only, and serves the boards to the screens' players
// over the LAN. Here the administration makes the hub's one-time code, approves each player that asked the hub for a
// screen (its hardware address and fixed IP become the screen's), gives screens their code and group, and sees what
// the hub reported. The same panel serves the station portal and the platform.

interface Hub { uid: string; label: string; created_at: string; last_contact_at: string | null; online: boolean; version: string | null;
  revoked_at: string | null; revoke_reason: string | null; screens: number }
interface Player { uid: string; hub: string; mac: string; ip: string; status: "WAITING" | "APPROVED" | "REJECTED";
  first_seen: string; last_seen: string; screen: string | null }
interface NetScreen { uid: string; label: string; kind: string; code: string | null; group: string | null; hub: string | null;
  mac: string | null; ip: string | null; last_seen_at: string | null; online: boolean }
interface HubEvent { kind: string; hub: string; mac: string | null; ip: string | null; seconds: number | null; screen: string | null; at: string }
interface HubsView { hubs: Hub[]; players: Player[]; screens: NetScreen[]; events: HubEvent[] }

export interface HubsApi {
  load: (signal: AbortSignal) => Promise<HubsView>;
  pairing: (label: string) => Promise<{ code: string; expires_at: string }>;
  revoke: (hub: string, reason: string) => Promise<unknown>;
  decide: (player: string, approve: boolean, screen?: string) => Promise<unknown>;
  network: (screen: string, body: { code: string | null; group: string | null; fixed_ip?: string | null }) => Promise<unknown>;
  release: (screen: string) => Promise<unknown>;
}

export function stationHubsApi(stationUid: string): HubsApi {
  return {
    load: (signal) => api.get<HubsView>("/api/station/hubs", { station_uid: stationUid }, { signal }),
    pairing: (label) => api.post("/api/station/hubs/pairing", { station_uid: stationUid, label }),
    revoke: (hub, reason) => api.post(`/api/station/hubs/${hub}/revoke`, { reason }),
    decide: (player, approve, screen) => api.post(`/api/station/hubs/players/${player}`, { approve, screen_uid: screen }),
    network: (screen, body) => api.put(`/api/station/hubs/screens/${screen}`, body),
    release: (screen) => api.del(`/api/station/hubs/screens/${screen}/player`),
  };
}

export function platformHubsApi(stationUid: string): HubsApi {
  const hubs = `/api/admin/boarding/stations/${stationUid}/hubs`;
  return {
    load: (signal) => api.get<HubsView>(hubs, undefined, { signal }),
    pairing: (label) => api.post(`${hubs}/pairing`, { label }),
    revoke: (hub, reason) => api.post(`${hubs}/${hub}/revoke`, { reason }),
    decide: (player, approve, screen) => api.post(`${hubs}/players/${player}`, { approve, screen_uid: screen }),
    network: (screen, body) => api.put(`${hubs}/screens/${screen}`, body),
    release: (screen) => api.del(`${hubs}/screens/${screen}/player`),
  };
}

export function HubsPanel({ calls }: { calls: HubsApi }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => calls.load(signal));
  const [label, setLabel] = useState("");
  const [code, setCode] = useState<{ code: string; expires_at: string } | null>(null);
  const [approving, setApproving] = useState<{ player: Player; screen: string } | null>(null);
  const [editing, setEditing] = useState<{ screen: NetScreen; code: string; group: string; ip: string } | null>(null);
  const [revoking, setRevoking] = useState<{ hub: Hub; reason: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async (call: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try { await call(); toast(done); state.reload(); return true; } catch (e) { toast(errorText(e)); return false; } finally { setBusy(false); }
  };
  return (
    <div className="card stack">
      <div>
        <h3 style={{ margin: 0 }}><Icon name="hub" /> {t("hub.title")}</h3>
        <p className="small muted" style={{ margin: "4px 0 0" }}>{t("hub.sub")}</p>
      </div>
      <Loaded state={state}>{(v) => (
        <>
          <div className="stack">
            <h4 style={{ margin: 0 }}>{t("hub.hubs")}</h4>
            {v.hubs.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("hub.noHub")}</p> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("hub.label")}</th><th>{t("hub.contact")}</th><th>{t("hub.screens")}</th><th>{t("common.actions")}</th></tr></thead>
                <tbody>{v.hubs.map((h) => (
                  <tr key={h.uid}>
                    <td>{h.label}{h.version && <div className="small muted mono ltr">v{h.version}</div>}</td>
                    <td className="small">{h.revoked_at ? <span className="chip">{t("hub.revoked")}: {h.revoke_reason}</span>
                      : <><span className={`chip ${h.online ? "green" : "outline"}`}>{h.online ? t("hub.online") : t("hub.offline")}</span>
                          {h.last_contact_at && <div className="muted">{dateTime(h.last_contact_at)}</div>}</>}</td>
                    <td>{h.screens}</td>
                    <td>{!h.revoked_at && <button className="btn text small" onClick={() => setRevoking({ hub: h, reason: "" })}>{t("hub.revoke")}</button>}</td>
                  </tr>))}</tbody>
              </table></div>
            )}
            <form className="row" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault();
              void (async () => { setBusy(true); try { setCode(await calls.pairing(label)); setLabel(""); state.reload(); } catch (err) { toast(errorText(err)); } finally { setBusy(false); } })(); }}>
              <div className="grow"><Field label={t("hub.newLabel")} required>
                <input className="input" required maxLength={60} value={label} onChange={(e) => setLabel(e.target.value)} placeholder={t("hub.newLabelHint")} />
              </Field></div>
              <button className="btn tonal" disabled={busy || !label.trim()}><Icon name="add" />{t("hub.pair")}</button>
            </form>
          </div>

          <div className="stack">
            <h4 style={{ margin: 0 }}>{t("hub.players")}</h4>
            {v.players.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("hub.noPlayer")}</p> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("hub.address")}</th><th>{t("hub.hub")}</th><th>{t("common.status")}</th><th>{t("hub.seen")}</th><th>{t("common.actions")}</th></tr></thead>
                <tbody>{v.players.map((p) => (
                  <tr key={p.uid}>
                    <td className="mono ltr small">{p.mac}<div className="muted">{p.ip}</div></td>
                    <td className="small">{p.hub}</td>
                    <td><span className={`chip ${p.status === "APPROVED" ? "green" : p.status === "REJECTED" ? "red" : "wheat"}`}>{t(`hub.status.${p.status}`)}</span>{p.screen && <div className="small muted">{p.screen}</div>}</td>
                    <td className="small">{dateTime(p.last_seen)}</td>
                    <td>{p.status === "WAITING" && <div className="row nowrap" style={{ gap: 4 }}>
                      <button className="btn small" onClick={() => setApproving({ player: p, screen: "" })}>{t("hub.approve")}</button>
                      <button className="btn text small" disabled={busy} onClick={() => run(() => calls.decide(p.uid, false), t("hub.rejected"))}>{t("hub.reject")}</button>
                    </div>}</td>
                  </tr>))}</tbody>
              </table></div>
            )}
          </div>

          <div className="stack">
            <h4 style={{ margin: 0 }}>{t("hub.screensTitle")}</h4>
            {v.screens.length === 0 ? <Empty icon="tv" title={t("hub.noScreens")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("hub.screen")}</th><th>{t("hub.code")}</th><th>{t("hub.group")}</th><th>{t("hub.player")}</th><th>{t("common.actions")}</th></tr></thead>
                <tbody>{v.screens.map((s) => (
                  <tr key={s.uid}>
                    <td>{s.label}<div className="small muted">{t(`scr.kind.${s.kind}`)}</div></td>
                    <td className="mono">{s.code ?? "—"}</td>
                    <td className="small">{s.group ?? "—"}</td>
                    <td className="small">{s.mac ? <><span className="mono ltr">{s.mac}</span><div className="muted mono ltr">{s.ip} · {s.hub}</div>
                      <span className={`chip ${s.online ? "green" : "outline"}`}>{s.online ? t("hub.online") : t("hub.offline")}</span></> : "—"}</td>
                    <td><div className="row nowrap" style={{ gap: 4 }}>
                      <button className="btn text small" onClick={() => setEditing({ screen: s, code: s.code ?? "", group: s.group ?? "", ip: s.ip ?? "" })}>{t("common.edit")}</button>
                      {s.mac && <button className="btn text small" disabled={busy} onClick={() => run(() => calls.release(s.uid), t("hub.released"))}>{t("hub.release")}</button>}
                    </div></td>
                  </tr>))}</tbody>
              </table></div>
            )}
            <p className="small muted" style={{ margin: 0 }}>{t("hub.openHint")}</p>
          </div>

          {v.events.length > 0 && (
            <div className="stack">
              <h4 style={{ margin: 0 }}>{t("hub.events")}</h4>
              <ul className="small" style={{ margin: 0, paddingInlineStart: 20 }}>{v.events.slice(0, 15).map((e, i) => (
                <li key={i}>{dateTime(e.at)} · {e.hub} · {t(`hub.event.${e.kind}`, { seconds: e.seconds ?? 0 })}
                  {e.mac && <span className="mono ltr"> {e.mac}</span>}{e.ip && <span className="mono ltr"> {e.ip}</span>}{e.screen && ` · ${e.screen}`}</li>))}</ul>
            </div>
          )}

          {code && (
            <Modal title={t("hub.codeTitle")} onClose={() => setCode(null)} actions={<button className="btn" onClick={() => setCode(null)}>{t("common.close")}</button>}>
              <p style={{ marginTop: 0 }}>{t("hub.codeHint")}</p>
              <div className="mono ltr" style={{ fontSize: 34, fontWeight: 800, letterSpacing: 4, textAlign: "center" }}>{code.code}</div>
              <p className="small muted">{t("hub.codeExpires", { at: dateTime(code.expires_at) })}</p>
              <pre className="mono ltr small" style={{ whiteSpace: "pre-wrap" }}>{`sudo ./deploy/hub-install.sh --platform ${location.origin} --code ${code.code}`}</pre>
            </Modal>
          )}
          {approving && (
            <Modal title={t("hub.approveTitle")} onClose={() => setApproving(null)}
              actions={<><button className="btn text" onClick={() => setApproving(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={busy || !approving.screen}
                  onClick={async () => { if (await run(() => calls.decide(approving.player.uid, true, approving.screen), t("hub.approved"))) setApproving(null); }}>{t("hub.approve")}</button></>}>
              <p className="mono ltr" style={{ marginTop: 0 }}>{approving.player.mac} · {approving.player.ip}</p>
              <Field label={t("hub.screen")} required>
                <select className="input" required value={approving.screen} onChange={(e) => setApproving({ ...approving, screen: e.target.value })}>
                  <option value="">{t("hub.pickScreen")}</option>
                  {v.screens.filter((s) => s.code).map((s) => <option key={s.uid} value={s.uid}>{s.code} · {s.label}</option>)}
                </select>
              </Field>
              <p className="small muted">{t("hub.approveHint")}</p>
            </Modal>
          )}
          {editing && (
            <Modal title={editing.screen.label} onClose={() => setEditing(null)}
              actions={<><button className="btn text" onClick={() => setEditing(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={busy} onClick={async () => {
                  const body = { code: editing.code.trim() || null, group: editing.group.trim() || null,
                                 ...(editing.screen.mac && editing.ip.trim() !== (editing.screen.ip ?? "") ? { fixed_ip: editing.ip.trim() || null } : {}) };
                  if (await run(() => calls.network(editing.screen.uid, body), t("common.saved"))) setEditing(null); }}>{t("common.save")}</button></>}>
              <div className="grid cols-2">
                <Field label={t("hub.code")} hint={t("hub.codeFieldHint")}>
                  <input className="input mono ltr" maxLength={16} value={editing.code} onChange={(e) => setEditing({ ...editing, code: e.target.value.toUpperCase() })} placeholder="DEP-1" />
                </Field>
                <Field label={t("hub.group")} optional>
                  <input className="input" maxLength={40} value={editing.group} onChange={(e) => setEditing({ ...editing, group: e.target.value })} />
                </Field>
                {editing.screen.mac && (
                  <Field label={t("hub.fixedIp")} hint={t("hub.fixedIpHint")}>
                    <input className="input mono ltr" maxLength={45} value={editing.ip} onChange={(e) => setEditing({ ...editing, ip: e.target.value })} />
                  </Field>
                )}
              </div>
            </Modal>
          )}
          {revoking && (
            <Modal title={t("hub.revokeTitle", { name: revoking.hub.label })} onClose={() => setRevoking(null)}
              actions={<><button className="btn text" onClick={() => setRevoking(null)}>{t("common.cancel")}</button>
                <button className="btn danger" disabled={busy || revoking.reason.trim().length < 3}
                  onClick={async () => { if (await run(() => calls.revoke(revoking.hub.uid, revoking.reason), t("hub.revokedDone"))) setRevoking(null); }}>{t("hub.revoke")}</button></>}>
              <p style={{ marginTop: 0 }}>{t("hub.revokeHint")}</p>
              <Field label={t("hub.reason")} required>
                <input className="input" required maxLength={300} value={revoking.reason} onChange={(e) => setRevoking({ ...revoking, reason: e.target.value })} />
              </Field>
            </Modal>
          )}
        </>
      )}</Loaded>
    </div>
  );
}
