import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, Field, Icon, Loaded, Modal, useErrorText, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";
import { HubsPanel, stationHubsApi } from "./Hubs";

// Display screens (owner's decision, October 2026; migration 1120). The station shows its departures and its arrivals
// on separate screens, each headed with its word. The platform decides which kinds a station may show; the station's
// administration registers its screens here, gives each a kind and a place, and distributes them: each screen opens
// its own link full screen on its display, and reports when it was last seen. The same panel serves the station portal
// and the platform (where a station has no administration yet). The API and the database check everything again.
// 1129: a screen may show only some bays or carriers; a display is paired by the short code it shows at /screen/pair;
// a screen that stops reading its board is marked unseen here, and the administration is told.

export type ScreenKind = "DEPARTURES" | "ARRIVALS" | "COMBINED";
export const SCREEN_KINDS: ScreenKind[] = ["DEPARTURES", "ARRIVALS", "COMBINED"];
const ICON: Record<ScreenKind, IconName> = { DEPARTURES: "flight_takeoff", ARRIVALS: "flight_land", COMBINED: "departure_board" };

interface Carrier { uid: string; name: string }
interface Screen {
  uid: string; kind: ScreenKind; label: string; active: boolean; allowed: boolean;
  last_seen_at: string | null; online: boolean; unseen?: boolean; created_at: string; updated_at: string;
  bays?: string[]; carriers?: Carrier[];
}
interface ScreensView { boards_on: boolean; displays: boolean; kinds: ScreenKind[]; screens: Screen[];
  unseen_minutes?: number; bays?: string[]; carriers?: Carrier[] }
type Change = { kind?: ScreenKind; label?: string; active?: boolean };

export interface ScreensApi {
  load: (signal: AbortSignal) => Promise<ScreensView>;
  add: (kind: ScreenKind, label: string) => Promise<unknown>;
  change: (uid: string, change: Change) => Promise<unknown>;
  remove: (uid: string) => Promise<unknown>;
  filter: (uid: string, bays: string[], carriers: string[]) => Promise<unknown>;
  pair: (uid: string, code: string) => Promise<unknown>;
}

/** The station portal's calls: the station is named in each request. */
export function stationScreensApi(stationUid: string): ScreensApi {
  return {
    load: (signal) => api.get<ScreensView>("/api/station/screens", { station_uid: stationUid }, { signal }),
    add: (kind, label) => api.post("/api/station/screens", { station_uid: stationUid, kind, label }),
    change: (uid, change) => api.patch(`/api/station/screens/${uid}`, change),
    remove: (uid) => api.del(`/api/station/screens/${uid}`),
    filter: (uid, bays, carriers) => api.put(`/api/station/screens/${uid}/filter`, { bays, carriers }),
    pair: (uid, code) => api.post(`/api/station/screens/${uid}/pair`, { code }),
  };
}

/** The platform's calls, where a station has no administration yet. */
export function platformScreensApi(stationUid: string): ScreensApi {
  return {
    load: (signal) => api.get<ScreensView>(`/api/admin/boarding/stations/${stationUid}/screens`, undefined, { signal }),
    add: (kind, label) => api.post(`/api/admin/boarding/stations/${stationUid}/screens`, { kind, label }),
    change: (uid, change) => api.patch(`/api/admin/boarding/stations/${stationUid}/screens/${uid}`, change),
    remove: (uid) => api.del(`/api/admin/boarding/stations/${stationUid}/screens/${uid}`),
    filter: (uid, bays, carriers) => api.put(`/api/admin/boarding/stations/${stationUid}/screens/${uid}/filter`, { bays, carriers }),
    pair: (uid, code) => api.post(`/api/admin/boarding/stations/${stationUid}/screens/${uid}/pair`, { code }),
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
  const [filtering, setFiltering] = useState<Screen | null>(null);
  const [pairing, setPairing] = useState<Screen | null>(null);
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
        : s.unseen && s.last_seen_at ? <span className="chip red"><Icon name="warning" size={16} />{t("scr.unseenSince", { when: `${date(s.last_seen_at, { day: "numeric", month: "short" })} ${time(s.last_seen_at)}` })}</span>
        : s.online ? <span className="chip green"><Icon name="check_circle" size={16} />{t("scr.online")}</span>
        : s.last_seen_at ? <span className="small muted">{t("scr.seen", { when: `${date(s.last_seen_at, { day: "numeric", month: "short" })} ${time(s.last_seen_at)}` })}</span>
        : <span className="small muted">{t("scr.never")}</span>;
      return (
        <div className="stack">
          {(!v.boards_on || !v.displays) && <div className="alert warn small"><Icon name="info" />{t("scr.off")}</div>}
          {v.screens.some((s) => s.unseen) && (
            <div className="alert error small" role="alert"><Icon name="warning" />{t("scr.unseenAlert", { n: v.screens.filter((s) => s.unseen).length, m: v.unseen_minutes ?? 10 })}</div>
          )}
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
                        <td><strong>{s.label}</strong>
                          {((s.bays?.length ?? 0) > 0 || (s.carriers?.length ?? 0) > 0) && (
                            <div className="small muted">{[...(s.bays ?? []).map((b) => t("scr.bayN", { code: b })), ...(s.carriers ?? []).map((c) => c.name)].join(" · ")}</div>)}</td>
                        <td>{seen(s)}</td>
                        <td className="text-nowrap">
                          <Link className="btn text small" to={`/screen/${s.uid}`} target="_blank" rel="noopener"><Icon name="open_in_new" />{t("scr.open")}</Link>
                          <button className="btn text small" onClick={() => copy(s.uid)}><Icon name="content_copy" />{t("scr.copy")}</button>
                          <button className="btn text small" disabled={busy} onClick={() => setPairing(s)}><Icon name="link" />{t("scr.pair")}</button>
                        </td>
                        <td className="num text-nowrap">
                          <button className="btn text small" disabled={busy} onClick={() => setEditing(s)}><Icon name="edit" />{t("scr.edit")}</button>
                          <button className="btn text small" disabled={busy} onClick={() => setFiltering(s)}><Icon name="filter_list" />{t("scr.filter")}</button>
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
          {filtering && (
            <FilterScreen screen={filtering} bays={v.bays ?? []} carriers={v.carriers ?? []} busy={busy} onClose={() => setFiltering(null)}
                          onSave={async (bays, carriers) => { if (await run(() => calls.filter(filtering.uid, bays, carriers), t("scr.saved"))) setFiltering(null); }} />
          )}
          {pairing && (
            <PairScreen screen={pairing} busy={busy} onClose={() => setPairing(null)}
                        onPair={async (code) => { if (await run(() => calls.pair(pairing.uid, code), t("scr.paired"))) setPairing(null); }} />
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

function FilterScreen({ screen, bays, carriers, busy, onClose, onSave }: {
  screen: Screen; bays: string[]; carriers: Carrier[]; busy: boolean; onClose: () => void; onSave: (bays: string[], carriers: string[]) => void;
}) {
  const { t } = useI18n();
  const [chosenBays, setBays] = useState<string[]>(screen.bays ?? []);
  const [chosenCarriers, setCarriers] = useState<string[]>((screen.carriers ?? []).map((c) => c.uid));
  // a carrier named on the screen that no longer calls at the station stays listed, so it can be taken off
  const all = [...carriers, ...(screen.carriers ?? []).filter((c) => !carriers.some((x) => x.uid === c.uid))];
  const flip = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  return (
    <Modal title={t("scr.filterTitle", { label: screen.label })} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
        <button className="btn" disabled={busy} onClick={() => onSave(chosenBays, chosenCarriers)}>{t("common.save")}</button></>}>
      <div className="stack">
        <p className="small muted" style={{ margin: 0 }}>{t("scr.filterHint")}</p>
        <fieldset className="stack tight" style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="small"><strong>{t("scr.filterBays")}</strong></legend>
          {bays.length === 0 ? <span className="small muted">{t("scr.noBays")}</span> : (
            <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
              {bays.map((b) => <label key={b} className="check"><input type="checkbox" checked={chosenBays.includes(b)} onChange={() => setBays(flip(chosenBays, b))} />{t("scr.bayN", { code: b })}</label>)}
            </div>)}
        </fieldset>
        <fieldset className="stack tight" style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="small"><strong>{t("scr.filterCarriers")}</strong></legend>
          {all.length === 0 ? <span className="small muted">{t("scr.noCarriers")}</span> : (
            <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
              {all.map((c) => <label key={c.uid} className="check"><input type="checkbox" checked={chosenCarriers.includes(c.uid)} onChange={() => setCarriers(flip(chosenCarriers, c.uid))} />{c.name}</label>)}
            </div>)}
        </fieldset>
      </div>
    </Modal>
  );
}

function PairScreen({ screen, busy, onClose, onPair }: { screen: Screen; busy: boolean; onClose: () => void; onPair: (code: string) => void }) {
  const { t } = useI18n();
  const [code, setCode] = useState("");
  const clean = code.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
  return (
    <Modal title={t("scr.pairTitle", { label: screen.label })} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
        <button className="btn" disabled={busy || clean.length !== 6} onClick={() => onPair(clean)}>{t("scr.pair")}</button></>}>
      <div className="stack">
        <p className="small" style={{ margin: 0 }}>{t("scr.pairHint", { url: `${window.location.origin}/screen/pair` })}</p>
        <Field label={t("scr.pairCode")}>
          <input className="input mono ltr" autoComplete="off" inputMode="text" value={clean} maxLength={6} style={{ fontSize: "1.5rem", letterSpacing: "0.2em" }}
                 onChange={(e) => setCode(e.target.value)} />
        </Field>
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
            <HubsPanel key={`${uid}-hubs`} calls={stationHubsApi(uid)} />
          </>
        );
      }}</Loaded>
    </div>
  );
}
