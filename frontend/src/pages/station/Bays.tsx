import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, Field, Icon, Loaded, useErrorText, useLoad, useToast } from "../../components/ui";

// Bays assigned by the station's administration (owner's decision, October 2026; migration 1115). The station chooses
// how it gives its bays: a permanent bay for each carrier, which it changes when it needs to, or a bay for each trip.
// A bay set on a trip comes first in either mode. The counter's trips, the boarding pass and the departure board show
// the bay in force. The same panel serves the station portal and the platform (where a station has no administration).

interface BaysView {
  mode: "CARRIER" | "TRIP";
  bays: { code: string; gate_type: string }[];
  carriers: { carrier_uid: string; carrier: string; carrier_logo?: string | null; bay: string | null; updated_at: string | null }[];
  trips: {
    trip_uid: string; trip_no: string; trip_code: string | null; carrier_uid: string; carrier: string; carrier_logo?: string | null; status: string; stop_seq: number;
    departs_at: string; dest_code: string; dest_name: string; dest_city: string | null;
    bay: string | null; trip_bay: string | null; bay_source: "TRIP" | "CARRIER" | null;
  }[];
}

export interface BaysApi {
  load: (signal: AbortSignal) => Promise<BaysView>;
  mode: (mode: "CARRIER" | "TRIP") => Promise<unknown>;
  carrier: (carrierUid: string, bay: string | null) => Promise<unknown>;
  trip: (tripUid: string, stopSeq: number, bay: string | null) => Promise<unknown>;
}

/** The station portal's calls: the station is named in each request. */
export function stationBaysApi(stationUid: string): BaysApi {
  return {
    load: (signal) => api.get<BaysView>("/api/station/bays", { station_uid: stationUid }, { signal }),
    mode: (mode) => api.put("/api/station/bays/mode", { station_uid: stationUid, mode }),
    carrier: (carrierUid, bay) => api.put("/api/station/bays/carriers", { station_uid: stationUid, carrier_uid: carrierUid, bay }),
    trip: (tripUid, stopSeq, bay) => api.put("/api/station/bays/trips", { trip_uid: tripUid, stop_seq: stopSeq, bay }),
  };
}

/** The platform's calls, where a station has no administration yet. */
export function platformBaysApi(stationUid: string): BaysApi {
  return {
    load: (signal) => api.get<BaysView>(`/api/admin/boarding/stations/${stationUid}/bays`, undefined, { signal }),
    mode: (mode) => api.put(`/api/admin/boarding/stations/${stationUid}/bays/mode`, { mode }),
    carrier: (carrierUid, bay) => api.put(`/api/admin/boarding/stations/${stationUid}/bays/carriers`, { carrier_uid: carrierUid, bay }),
    trip: (tripUid, stopSeq, bay) => api.put(`/api/admin/boarding/stations/${stationUid}/bays/trips`, { trip_uid: tripUid, stop_seq: stopSeq, bay }),
  };
}

export function BaysPanel({ calls }: { calls: BaysApi }) {
  const { t, date, time, city, station: placeName } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => calls.load(signal));   // a new station remounts the panel (its key)
  const [busy, setBusy] = useState(false);
  const run = async (call: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try { await call(); toast(done); state.reload(); } catch (e) { toast(errorText(e)); } finally { setBusy(false); }
  };
  return (
    <Loaded state={state}>{(v) => {
      const options = (value: string | null, onChange: (bay: string | null) => void, label: string) => (
        <select className="input" aria-label={label} value={value ?? ""} disabled={busy} onChange={(e) => onChange(e.target.value || null)}>
          <option value="">{t("bays.none")}</option>
          {v.bays.map((b) => <option key={b.code} value={b.code}>{b.code}</option>)}
        </select>
      );
      let lastDay = "";
      return (
        <div className="stack">
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("bays.how")}</h3>
            <div className="row" style={{ gap: 12, flexWrap: "wrap" }} role="radiogroup" aria-label={t("bays.how")}>
              {(["CARRIER", "TRIP"] as const).map((m) => (
                <label key={m} className={`choice ${v.mode === m ? "on" : ""}`}>
                  <input type="radio" name="bay-mode" checked={v.mode === m} disabled={busy}
                         onChange={() => run(() => calls.mode(m), t("bays.saved"))} />
                  <span><strong>{t(`bays.mode.${m}`)}</strong><span className="small muted" style={{ display: "block" }}>{t(`bays.modeHint.${m}`)}</span></span>
                </label>
              ))}
            </div>
            {v.bays.length === 0 && <div className="alert info small"><Icon name="info" />{t("bays.noBays")}</div>}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("bays.carriers")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t(v.mode === "CARRIER" ? "bays.carriersHint" : "bays.carriersOff")}</p>
            {v.carriers.length === 0 ? <Empty icon="directions_bus" title={t("bays.noCarriers")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("st.carrier")}</th><th>{t("bays.permanent")}</th></tr></thead>
                <tbody>{v.carriers.map((c) => (
                  <tr key={c.carrier_uid}>
                    <td><CarrierName name={c.carrier} uid={c.carrier_uid} logo={c.carrier_logo} /></td>
                    <td style={{ maxWidth: 200 }}>{options(c.bay, (bay) => run(() => calls.carrier(c.carrier_uid, bay), t("bays.saved")),
                                                         `${t("bays.permanent")} · ${c.carrier}`)}</td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
          <div className="card stack">
            <h3 style={{ margin: 0 }}>{t("bays.trips")}</h3>
            <p className="small muted" style={{ margin: 0 }}>{t("bays.tripsHint")}</p>
            {v.trips.length === 0 ? <Empty icon="event_busy" title={t("bays.noTrips")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("st.departs")}</th><th>{t("st.to")}</th><th>{t("trip.number")}</th><th>{t("st.carrier")}</th>
                  <th>{t("bays.inForce")}</th><th>{t("bays.tripBay")}</th></tr></thead>
                <tbody>{v.trips.map((x) => {
                  const dayLabel = date(x.departs_at, { weekday: "long", day: "numeric", month: "long" });
                  const header = dayLabel !== lastDay ? (lastDay = dayLabel) : null;
                  return [
                    header && <tr key={`d-${x.trip_uid}`} className="day-row"><td colSpan={6}>{header}</td></tr>,
                    <tr key={x.trip_uid}>
                      <td className="text-nowrap">{time(x.departs_at)}</td>
                      <td><strong>{x.dest_city && city(x.dest_city) !== x.dest_city ? city(x.dest_city) : placeName(x.dest_code, x.dest_name)}</strong></td>
                      <td className="mono text-nowrap">{x.trip_code ?? x.trip_no}</td>
                      <td><CarrierName name={x.carrier} uid={x.carrier_uid} logo={x.carrier_logo} /></td>
                      <td className="text-nowrap">{x.bay ? <><span className="mono">{x.bay}</span>{" "}
                        <span className="chip">{t(`bays.source.${x.bay_source}`)}</span></> : "—"}</td>
                      <td style={{ maxWidth: 180 }}>{options(x.trip_bay, (bay) => run(() => calls.trip(x.trip_uid, x.stop_seq, bay), t("bays.saved")),
                                                          `${t("bays.tripBay")} · ${x.trip_code ?? x.trip_no}`)}</td>
                    </tr>,
                  ];
                })}</tbody>
              </table></div>
            )}
          </div>
        </div>
      );
    }}</Loaded>
  );
}

interface Administered { station_uid: string; station_code: string; station_name: string; bay_mode: string }

/** The station portal's page: the stations the company administers, then their bays. */
export function StationBays() {
  const { t, station: placeName } = useI18n();
  const state = useLoad((signal) => api.get<{ administered: Administered[] }>("/api/station/overview", undefined, { signal }));
  const [chosen, setChosen] = useState<string>("");
  return (
    <div className="stack">
      <PageHead title={t("bays.title")} sub={t("bays.sub")} />
      <Loaded state={state}>{(o) => {
        if (o.administered.length === 0) return <div className="card"><Empty icon="local_parking" title={t("bays.notAdmin")} hint={t("bays.notAdminHint")} /></div>;
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
            <BaysPanel key={uid} calls={stationBaysApi(uid)} />
          </>
        );
      }}</Loaded>
    </div>
  );
}
