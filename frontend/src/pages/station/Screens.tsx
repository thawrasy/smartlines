import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, Field, Icon, Loaded, Modal, useErrorText, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";

// Display screens (owner's decision, October 2026; migration 1120). The station shows its departures and its arrivals
// on separate screens, each headed with its word. The platform decides which kinds a station may show; the station's
// administration registers its screens here, gives each a kind and a place, and distributes them: each screen opens
// its own link full screen on its display, and reports when it was last seen. The same panel serves the station portal
// and the platform (where a station has no administration yet). The API and the database check everything again.

export type ScreenKind = "DEPARTURES" | "ARRIVALS" | "COMBINED";
export const SCREEN_KINDS: ScreenKind[] = ["DEPARTURES", "ARRIVALS", "COMBINED"];
const ICON: Record<ScreenKind, IconName> = { DEPARTURES: "flight_takeoff", ARRIVALS: "flight_land", COMBINED: "departure_board" };

interface Screen {
  uid: string; kind: ScreenKind; label: string; active: boolean; allowed: boolean;
  last_seen_at: string | null; online: boolean; created_at: string; updated_at: string;
}
interface ScreensView { boards_on: boolean; displays: boolean; kinds: ScreenKind[]; screens: Screen[] }
type Change = { kind?: ScreenKind; label?: string; active?: boolean };

export interface ScreensApi {
  load: (signal: AbortSignal) => Promise<ScreensView>;
  add: (kind: ScreenKind, label: string) => Promise<unknown>;
  change: (uid: string, change: Change) => Promise<unknown>;
  remove: (uid: string) => Promise<unknown>;
}

/** The station portal's calls: the station is named in each request. */
export function stationScreensApi(stationUid: string): ScreensApi {
  return {
    load: (signal) => api.get<ScreensView>("/api/station/screens", { station_uid: stationUid }, { signal }),
    add: (kind, label) => api.post("/api/station/screens", { station_uid: stationUid, kind, label }),
    change: (uid, change) => api.patch(`/api/station/screens/${uid}`, change),
    remove: (uid) => api.del(`/api/station/screens/${uid}`),
  };
}

/** The platform's calls, where a station has no administration yet. */
export function platformScreensApi(stationUid: string): ScreensApi {
  return {
    load: (signal) => api.get<ScreensView>(`/api/admin/boarding/stations/${stationUid}/screens`, undefined, { signal }),
    add: (kind, label) => api.post(`/api/admin/boarding/stations/${stationUid}/screens`, { kind, label }),
    change: (uid, change) => api.patch(`/api/admin/boarding/stations/${stationUid}/screens/${uid}`, change),
    remove: (uid) => api.del(`/api/admin/boarding/stations/${stationUid}/screens/${uid}`),
  };
}

export function ScreensPanel({ calls }: { calls: ScreensApi }) {
  const { t, date, time } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => calls.load(signal));   // a new station remounts the panel (its key)
  const [kind, setKind] = useState<ScreenKind | "">("");
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<Screen | null>(null);
  const [removing, setRemoving] = useState<Screen | null>(null);
  const run = async (call: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try { await call(); toast(done); state.reload(); return true; } catch (e) { toast(errorText(e)); return false; } finally { setBusy(false); }
  };
  const copy = async (uid: string) => {
    const link = `${window.location.origin}/screen/${uid}`;
    try { await navigator.clipboard.writeText(link); toast(t("scr.copied")); } catch { toast(link); }
  };
  return (
    <Loaded state={state}>{(v) => {
      const allowed = SCREEN_KINDS.filter((k) => v.kinds.includes(k));
      const chosen = kind && allowed.includes(kind) ? kind : allowed[0];
      const add = async (e: FormEvent) => {
        e.preventDefault();
        if (chosen && await run(() => calls.add(chosen, label.trim()), t("scr.added"))) setLabel("");
      };
      const seen = (s: Screen) => !s.active ? <span className="chip">{t("scr.stopped")}</span>
        : !s.allowed ? <span className="chip red">{t("scr.kindOff")}</span>
        : s.online ? <span className="chip green"><Icon name="check_circle" size={16} />{t("scr.online")}</span>
        : s.last_seen_at ? <span className="small muted">{t("scr.seen", { when: `${date(s.last_seen_at, { day: "numeric", month: "short" })} ${time(s.last_seen_at)}` })}</span>
        : <span className="small muted">{t("scr.never")}</span>;
      return (
        <div className="stack">
          {(!v.boards_on || !v.displays) && <div className="alert warn small"><Icon name="info" />{t("scr.off")}</div>}
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("scr.add")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t("scr.allowed", { kinds: allowed.map((k) => t(`scr.kind.${k}`)).join(" · ") })}</p>
            <form className="row" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }} onSubmit={add}>
              <Field label={t("scr.kindLabel")}>
                <select className="input" value={chosen ?? ""} onChange={(e) => setKind(e.target.value as ScreenKind)}>
                  {allowed.map((k) => <option key={k} value={k}>{t(`scr.kind.${k}`)}</option>)}
                </select>
              </Field>
              <Field label={t("scr.place")}>
                <input className="input" value={label} maxLength={60} onChange={(e) => setLabel(e.target.value)} />
              </Field>
              <button className="btn" disabled={busy || !chosen || !label.trim()}><Icon name="add" />{t("scr.addBtn")}</button>
            </form>
            <p className="small muted" style={{ margin: 0 }}>{t("scr.placeHint")}</p>
          </div>
          {SCREEN_KINDS.filter((k) => allowed.includes(k) || v.screens.some((s) => s.kind === k)).map((k) => {
            const list = v.screens.filter((s) => s.kind === k);
            return (
              <section key={k} className="card stack" aria-label={t(`scr.group.${k}`)}>
                <div className="row" style={{ gap: 8 }}>
                  <Icon name={ICON[k]} /><h3 style={{ margin: 0 }}>{t(`scr.group.${k}`)}</h3><span className="chip outline">{list.length}</span>
                </div>
                {!allowed.includes(k) && <div className="alert warn small"><Icon name="warning" />{t("scr.notAllowed")}</div>}
                {list.length === 0 ? <p className="small muted" style={{ margin: 0 }}>{t("scr.noneOfKind")}</p> : (
                  <div className="table-wrap" tabIndex={0}><table className="table">
                    <thead><tr><th>{t("scr.place")}</th><th>{t("scr.state")}</th><th>{t("scr.link")}</th><th /></tr></thead>
                    <tbody>{list.map((s) => (
                      <tr key={s.uid}>
                        <td><strong>{s.label}</strong></td>
                        <td>{seen(s)}</td>
                        <td className="text-nowrap">
                          <Link className="btn text small" to={`/screen/${s.uid}`} target="_blank" rel="noopener"><Icon name="open_in_new" />{t("scr.open")}</Link>
                          <button className="btn text small" onClick={() => copy(s.uid)}><Icon name="content_copy" />{t("scr.copy")}</button>
                        </td>
                        <td className="num text-nowrap">
                          <button className="btn text small" disabled={busy} onClick={() => setEditing(s)}><Icon name="edit" />{t("scr.edit")}</button>
                          <button className="btn text small" disabled={busy}
                                  onClick={() => run(() => calls.change(s.uid, { active: !s.active }), t(s.active ? "scr.stoppedDone" : "scr.startedDone"))}>
                            <Icon name={s.active ? "pause" : "play_arrow"} />{t(s.active ? "scr.stop" : "scr.start")}</button>
                          <button className="btn text small" disabled={busy} onClick={() => setRemoving(s)}><Icon name="delete" />{t("scr.remove")}</button>
                        </td>
                      </tr>
                    ))}</tbody>
                  </table></div>
                )}
              </section>
            );
          })}
          {v.screens.length === 0 && <Empty icon="tv" title={t("scr.none")} hint={t("scr.noneHint")} />}
          {editing && (
            <EditScreen screen={editing} kinds={allowed} busy={busy} onClose={() => setEditing(null)}
                        onSave={async (change) => { if (await run(() => calls.change(editing.uid, change), t("scr.saved"))) setEditing(null); }} />
          )}
          {removing && (
            <Modal title={t("scr.removeTitle", { label: removing.label })} onClose={() => setRemoving(null)}
              actions={<><button className="btn text" onClick={() => setRemoving(null)}>{t("common.cancel")}</button>
                <button className="btn danger" disabled={busy}
                        onClick={async () => { if (await run(() => calls.remove(removing.uid), t("scr.removed"))) setRemoving(null); }}>
                  <Icon name="delete" />{t("scr.remove")}</button></>}>
              <p style={{ margin: 0 }}>{t("scr.removeHint")}</p>
            </Modal>
          )}
        </div>
      );
    }}</Loaded>
  );
}

function EditScreen({ screen, kinds, busy, onClose, onSave }: {
  screen: Screen; kinds: ScreenKind[]; busy: boolean; onClose: () => void; onSave: (change: Change) => void;
}) {
  const { t } = useI18n();
  const [label, setLabel] = useState(screen.label);
  const [kind, setKind] = useState<ScreenKind>(kinds.includes(screen.kind) ? screen.kind : kinds[0] ?? screen.kind);
  const change: Change = {
    ...(label.trim() !== screen.label ? { label: label.trim() } : {}),
    ...(kind !== screen.kind ? { kind } : {}),
  };
  return (
    <Modal title={t("scr.editTitle", { label: screen.label })} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
        <button className="btn" disabled={busy || !label.trim() || Object.keys(change).length === 0} onClick={() => onSave(change)}>{t("common.save")}</button></>}>
      <div className="stack">
        <Field label={t("scr.kindLabel")}>
          <select className="input" value={kind} onChange={(e) => setKind(e.target.value as ScreenKind)}>
            {kinds.map((k) => <option key={k} value={k}>{t(`scr.kind.${k}`)}</option>)}
          </select>
        </Field>
        <Field label={t("scr.place")} hint={t("scr.placeHint")}>
          <input className="input" value={label} maxLength={60} onChange={(e) => setLabel(e.target.value)} />
        </Field>
        <p className="small muted" style={{ margin: 0 }}>{t("scr.sameLink")}</p>
      </div>
    </Modal>
  );
}

interface Administered { station_uid: string; station_code: string; station_name: string }

export function StationScreens() {
  const { t, station: placeName } = useI18n();
  const state = useLoad((signal) => api.get<{ administered: Administered[] }>("/api/station/overview", undefined, { signal }));
  const [chosen, setChosen] = useState<string>("");
  return (
    <div className="stack">
      <PageHead title={t("scr.title")} sub={t("scr.sub")} />
      <Loaded state={state}>{(o) => {
        if (o.administered.length === 0) return <div className="card"><Empty icon="tv" title={t("bays.notAdmin")} hint={t("bays.notAdminHint")} /></div>;
        const uid = chosen || o.administered[0].station_uid;
        return (
          <>
            {o.administered.length > 1 && (
              <div className="card"><Field label={t("st.station")}>
                <select className="input" value={uid} onChange={(e) => setChosen(e.target.value)}>
                  {o.administered.map((a) => <option key={a.station_uid} value={a.station_uid}>{a.station_code} · {placeName(a.station_code, a.station_name)}</option>)}
                </select>
              </Field></div>
            )}
            <ScreensPanel key={uid} calls={stationScreensApi(uid)} />
          </>
        );
      }}</Loaded>
    </div>
  );
}
