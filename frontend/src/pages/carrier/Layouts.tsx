import { useEffect, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { SeatGrid, type SeatMapData } from "../../components/SeatGrid";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

export interface LayoutRow { uid: string; name: string; total_seats: number; decks: string[][]; seats_per_row: number[][]; is_template: boolean; vehicles: number }
interface Preview extends SeatMapData { total_seats: number; seats_per_row: number[][] }

// Position codes understood by the server (backend/app/modules/fleet/layout.py)
const TOOLS = ["S", "H", "_", "D", "C", "R", "X"] as const;
type Tool = (typeof TOOLS)[number];
const PATTERNS = ["2+2", "2+1", "1+2", "1+1", "3+2", "2", "3", "4"];

function Tile({ label, accessible }: { label: string; accessible?: boolean }) {
  return <div className={`seat-tile${accessible ? " accessible" : ""}`}>{label}</div>;
}

/** Read-only drawing of a saved layout. The server numbers the seats; the drawing only shows them. */
export function LayoutPreview({ uid }: { uid: string }) {
  const state = useLoad(() => api.get<Preview>(`/api/carrier/seat-layouts/${uid}`), [uid]);
  return <Loaded state={state}>{(p) => <SeatGrid data={p} renderSeat={(s) => <Tile label={s.label} accessible={s.cabin === "ACCESSIBLE"} />} />}</Loaded>;
}

function Editor({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const { t } = useI18n();
  const [name, setName] = useState("");
  const [preset, setPreset] = useState({ pattern: "2+2", rows: "11", door_row: "", wc_row: "", back_row_full: false });
  const [decks, setDecks] = useState<string[][]>([["SS_SS", "SS_SS"]]);
  const [tool, setTool] = useState<Tool>("S");
  const [preview, setPreview] = useState<Preview | null>(null);
  const [previewError, setPreviewError] = useState<unknown>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);

  // Live numbering from the server, so the editor and the tickets can never disagree
  useEffect(() => {
    const id = window.setTimeout(() => {
      api.post<Preview>("/api/carrier/seat-layouts/preview", { decks })
        .then((p) => { setPreview(p); setPreviewError(null); })
        .catch((e) => { setPreview(null); setPreviewError(e); });
    }, 250);
    return () => clearTimeout(id);
  }, [decks]);

  const applyPreset = async () => {
    setError(null);
    try {
      const p = await api.post<Preview>("/api/carrier/seat-layouts/preset", {
        pattern: preset.pattern, rows: Number(preset.rows), back_row_full: preset.back_row_full,
        door_row: preset.door_row ? Number(preset.door_row) : null, wc_row: preset.wc_row ? Number(preset.wc_row) : null,
      });
      setDecks(p.decks);
      if (!name) setName(`${preset.pattern} · ${p.total_seats}`);
    } catch (e) { setError(e); }
  };
  const setCell = (d: number, r: number, c: number) =>
    setDecks((all) => all.map((rows, i) => (i !== d ? rows : rows.map((row, j) => (j !== r ? row : row.slice(0, c) + tool + row.slice(c + 1))))));
  const addRow = (d: number) => setDecks((all) => all.map((rows, i) => (i !== d ? rows : [...rows, rows[rows.length - 1]])));
  const removeRow = (d: number) => setDecks((all) => all.map((rows, i) => (i !== d || rows.length < 2 ? rows : rows.slice(0, -1))));
  const widen = (d: number, delta: 1 | -1) => setDecks((all) => all.map((rows, i) => {
    if (i !== d) return rows;
    const w = rows[0].length + delta;
    if (w < 2 || w > 7) return rows;
    return rows.map((row) => (delta > 0 ? row + "S" : row.slice(0, -1)));
  }));
  const toggleDeck = () => setDecks((all) => (all.length === 1 ? [...all, [all[0][0].replace(/[DCRX]/g, "S")]] : [all[0]]));

  const save = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/carrier/seat-layouts", { name: name.trim(), decks }); onSaved(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };

  const shown: SeatMapData = preview ?? { decks, seats: [] };
  return (
    <Modal title={t("layout.new")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !preview || name.trim().length < 2} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <Field label={t("layout.name")}><input className="input" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} /></Field>
        <div className="card flat stack">
          <strong>{t("layout.startFrom")}</strong>
          <div className="grid cols-3">
            <Field label={t("layout.pattern")} hint={t("layout.patternHint")}>
              <select className="input" value={preset.pattern} onChange={(e) => setPreset({ ...preset, pattern: e.target.value })}>
                {PATTERNS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </Field>
            <Field label={t("layout.rows")}><input className="input ltr" type="number" min={1} max={25} value={preset.rows} onChange={(e) => setPreset({ ...preset, rows: e.target.value })} /></Field>
            <Field label={`${t("layout.doorRow")} (${t("common.optional")})`}><input className="input ltr" type="number" min={1} max={25} value={preset.door_row} onChange={(e) => setPreset({ ...preset, door_row: e.target.value })} /></Field>
            <Field label={`${t("layout.wcRow")} (${t("common.optional")})`}><input className="input ltr" type="number" min={1} max={25} value={preset.wc_row} onChange={(e) => setPreset({ ...preset, wc_row: e.target.value })} /></Field>
          </div>
          <div className="row between">
            <label className="check"><input type="checkbox" checked={preset.back_row_full} onChange={(e) => setPreset({ ...preset, back_row_full: e.target.checked })} />{t("layout.backRow")}</label>
            <button className="btn tonal" type="button" onClick={applyPreset}><Icon name="refresh" />{t("layout.apply")}</button>
          </div>
        </div>
        <div className="grid split" style={{ alignItems: "start" }}>
          <div className="stack">
            <div className="stack tight">
              <strong>{t("layout.paint")}</strong>
              <div className="row" style={{ gap: 6 }} role="radiogroup" aria-label={t("layout.paint")}>
                {TOOLS.map((k) => (
                  <button key={k} type="button" role="radio" aria-checked={tool === k} className={`chip${tool === k ? " green" : " outline"}`} onClick={() => setTool(k)}>
                    {t(`layout.cells.${k}`)}
                  </button>
                ))}
              </div>
              <p className="small muted">{t("layout.paintHint")}</p>
            </div>
            <SeatGrid data={shown} onCell={setCell} renderSeat={(s) => <Tile label={s.label} accessible={s.cabin === "ACCESSIBLE"} />} />
          </div>
          <div className="stack">
            {decks.map((rows, d) => (
              <div key={d} className="card flat stack tight">
                {decks.length > 1 && <strong>{t(d === 0 ? "layout.lowerDeck" : "layout.upperDeck")}</strong>}
                <div className="row" style={{ gap: 6 }}>
                  <button className="btn outlined small" type="button" onClick={() => addRow(d)}><Icon name="add" />{t("layout.addRow")}</button>
                  <button className="btn outlined small" type="button" onClick={() => removeRow(d)} disabled={rows.length < 2}>{t("layout.removeRow")}</button>
                </div>
                <div className="row" style={{ gap: 6 }}>
                  <button className="btn outlined small" type="button" onClick={() => widen(d, 1)} disabled={rows[0].length >= 7}>{t("layout.wider")}</button>
                  <button className="btn outlined small" type="button" onClick={() => widen(d, -1)} disabled={rows[0].length <= 2}>{t("layout.narrower")}</button>
                </div>
              </div>
            ))}
            <label className="check"><input type="checkbox" checked={decks.length === 2} onChange={toggleDeck} />{t("layout.twoDecks")}</label>
            <div className={`alert ${preview ? "info" : "error"}`}>
              <Icon name={preview ? "event_seat" : "warning"} />
              {preview ? (
                <span className="stack tight">
                  <strong>{t("layout.total", { n: preview.total_seats })}</strong>
                  <span className="small">{t("layout.perRow")}: <span className="ltr mono">{preview.seats_per_row.map((d) => d.join(" · ")).join(" | ")}</span></span>
                </span>
              ) : <ErrorBox error={previewError} />}
            </div>
            <p className="small muted">{t("layout.immutable")}</p>
          </div>
        </div>
      </div>
    </Modal>
  );
}

export function CarrierLayouts() {
  const { t } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ layouts: LayoutRow[] }>("/api/carrier/seat-layouts"));
  const [open, setOpen] = useState(false);
  const [view, setView] = useState<LayoutRow | null>(null);
  const [error, setError] = useState<unknown>(null);
  const archive = async (l: LayoutRow) => {
    if (!confirm(t("layout.archiveConfirm", { name: l.name }))) return;
    try { await api.post(`/api/carrier/seat-layouts/${l.uid}/archive`); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <PageHead title={t("layout.title")} sub={t("layout.sub")}>
        {can("vehicle.manage") && <button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("layout.new")}</button>}
      </PageHead>
      <ErrorBox error={error} />
      <Loaded state={state}>{({ layouts }) => layouts.length === 0 ? <div className="card"><Empty icon="event_seat" title={t("layout.none")} hint={t("layout.noneHint")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("layout.name")}</th><th className="num">{t("layout.seats")}</th><th>{t("layout.perRow")}</th><th className="num">{t("layout.vehicles")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{layouts.map((l) => (
            <tr key={l.uid}>
              <td style={{ fontWeight: 500 }}>{l.name}{l.is_template && <span className="chip outline" style={{ marginInlineStart: 8 }}>{t("layout.template")}</span>}</td>
              <td className="num">{l.total_seats}</td>
              <td className="ltr mono small">{l.seats_per_row.map((d) => d.join(" · ")).join(" | ")}</td>
              <td className="num">{l.vehicles}</td>
              <td><div className="row nowrap" style={{ gap: 4 }}>
                <button className="btn tonal small" onClick={() => setView(l)}>{t("common.view")}</button>
                {can("vehicle.manage") && !l.is_template && l.vehicles === 0 && <button className="btn text small" onClick={() => archive(l)}>{t("layout.archive")}</button>}
              </div></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && <Editor onClose={() => setOpen(false)} onSaved={() => { setOpen(false); toast(t("common.saved")); state.reload(); }} />}
      {view && (
        <Modal title={`${view.name} · ${t("layout.total", { n: view.total_seats })}`} onClose={() => setView(null)}
               actions={<button className="btn" onClick={() => setView(null)}>{t("common.close")}</button>}>
          <LayoutPreview uid={view.uid} />
        </Modal>
      )}
    </div>
  );
}
