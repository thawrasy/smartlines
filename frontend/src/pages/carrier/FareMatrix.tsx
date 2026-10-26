import { useEffect, useState } from "react";
import { api } from "../../api";
import { fromMinor, toMinor, useI18n } from "../../i18n";
import { ErrorBox, Loaded, Modal, useLoad, useToast } from "../../components/ui";

// A price for every station pair of a route (owner's request N10, migration 1164): any boarding station to any later
// one. Trips made from the route take the matrix; the fare ladder from the origin follows its first row. While the
// state's price bands are on, a price outside the band of the carrier's class is refused.

interface Stop { seq: number; station_code: string; station_name: string; fare_from_origin: number; dist_from_origin_km: number | null }
interface Cell { from_seq: number; to_seq: number; price: number; set: boolean; km: number | null; band: "below" | "above" | null }
interface Matrix { code: string; stops: Stop[]; cells: Cell[]; band: { min_per_km: number | null; max_per_km: number | null; currency: string } | null }

export function FareMatrix({ uid, onClose }: { uid: string; onClose: () => void }) {
  const { t, station, money, num } = useI18n();
  const toast = useToast();
  const state = useLoad((signal) => api.get<Matrix>(`/api/carrier/routes/${uid}/fares`, undefined, { signal }));
  const [prices, setPrices] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [dearer, setDearer] = useState<string[]>([]);
  useEffect(() => {
    if (state.data) setPrices(Object.fromEntries(state.data.cells.map((c) => [`${c.from_seq}-${c.to_seq}`, String(fromMinor(c.price))])));
  }, [state.data]);
  const save = async () => {
    setBusy(true); setError(null);
    try {
      const cells = Object.entries(prices).map(([k, v]) => { const [a, b] = k.split("-").map(Number); return { from_seq: a, to_seq: b, price: toMinor(v) }; });
      const r = await api.put<{ pairs: number; dearer_inside_longer: string[] }>(`/api/carrier/routes/${uid}/fares`, { cells });
      setDearer(r.dearer_inside_longer); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("fares.matrix")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.close")}</button>
             <button className="btn" disabled={busy || !state.data} onClick={save}>{t("common.save")}</button></>}>
      <Loaded state={state}>{(m) => {
        const cell = (a: number, b: number) => m.cells.find((c) => c.from_seq === a && c.to_seq === b);
        return (
          <div className="stack">
            <p className="small muted" style={{ margin: 0 }}>{t("fares.matrixHint")}</p>
            {m.band && <p className="small" style={{ margin: 0 }}>{t("fares.bandNow", { min: m.band.min_per_km == null ? "—" : money(m.band.min_per_km), max: m.band.max_per_km == null ? "—" : money(m.band.max_per_km) })}</p>}
            <ErrorBox error={error} />
            {dearer.length > 0 && <p className="small" role="status" style={{ margin: 0 }}>{t("fares.dearer", { pairs: dearer.join(", ") })}</p>}
            <div className="table-wrap" tabIndex={0}>
              <table className="table">
                <thead><tr><th>{t("fares.fromTo")}</th>{m.stops.slice(1).map((s) => <th key={s.seq}>{station(s.station_code, s.station_name)}</th>)}</tr></thead>
                <tbody>{m.stops.slice(0, -1).map((a) => (
                  <tr key={a.seq}><th scope="row">{station(a.station_code, a.station_name)}</th>
                    {m.stops.slice(1).map((b) => {
                      if (b.seq <= a.seq) return <td key={b.seq} />;
                      const c = cell(a.seq, b.seq);
                      const k = `${a.seq}-${b.seq}`;
                      return (
                        <td key={b.seq}>
                          <input className="input mono" inputMode="decimal" aria-label={`${a.station_code} - ${b.station_code}`} style={{ minWidth: 90 }}
                                 value={prices[k] ?? ""} onChange={(e) => setPrices({ ...prices, [k]: e.target.value })} />
                          <div className="small muted">{c?.km != null ? `${num(c.km)} ${t("fares.km")}` : ""}{c && !c.set ? ` · ${t("fares.fromLadder")}` : ""}</div>
                          {c?.band && <div className="small" style={{ color: "var(--error)" }}>{t(`fares.band_${c.band}`)}</div>}
                        </td>
                      );
                    })}
                  </tr>
                ))}</tbody>
              </table>
            </div>
          </div>
        );
      }}</Loaded>
    </Modal>
  );
}
