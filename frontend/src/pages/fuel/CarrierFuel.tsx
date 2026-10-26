import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, Field, Icon, Loaded, Modal, Stat, useErrorText, useLoad, useToast } from "../../components/ui";
import { AnomaliesList, FUELS, FillsTable, type Fill } from "./Fuel";

// Fuel for a company with vehicles (owner's note of 25 October 2026; migration 1180): it opens an account with each
// fuel company it uses and pays that company in advance (the money is the fuel company's; the platform keeps the
// account), gives each vehicle a card with a budget per day, week or month, blocks a lost card at once, follows every
// fill with the meter's photo and decides what the checks found. The driver shows a short-lived code at the pump.

interface FuelCompany { uid: string; name: string }
interface Account { uid: string; currency: string; balance: number; low_balance: number | null; status: string; fuel_company_uid: string; fuel_company: string }
interface Card { uid: string; card_no: string; status: string; blocked_reason: string | null; fuel_types: string[]; budget_period: string | null;
  budget_amount: number | null; budget_litres: number | null; vehicle_uid: string | null; plate_no: string | null; account_uid: string | null;
  fuel_company: string | null; tag_bound: boolean; used_amount: number; used_litres: number }
interface Vehicle { uid: string; plate_no: string; fuel_type: string | null; fuel_tank_l: number | null }
interface View { enabled: boolean; fuel_companies: FuelCompany[]; accounts: Account[]; cards: Card[]; vehicles: Vehicle[] }
interface Usage { vehicle_uid: string; plate_no: string; fills: number; litres: number; amount: number; currency: string; km: number | null;
  l_per_100km: number | null; anomalies: number }
interface CardForm { uid?: string; vehicle_uid: string; account_uid: string; fuel_types: string[]; budget_period: string; budget_amount: string; budget_litres: string }

/** A fuel code as a QR the attendant's camera reads, refreshed before it expires. */
export function FuelCode({ url, onClose }: { url: string; onClose: () => void }) {
  const { t } = useI18n();
  const [code, setCode] = useState<{ code: string; expires_in: number; plate_no: string } | null>(null);
  const [img, setImg] = useState("");
  const [left, setLeft] = useState(0);
  const errorText = useErrorText();
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true, timer = 0;
    const get = async () => {
      try {
        const c = await api.get<{ code: string; expires_in: number; plate_no: string }>(url);
        if (!live) return;
        setCode(c); setLeft(c.expires_in); setImg(await QRCode.toDataURL(c.code, { margin: 1, width: 280 }));
        timer = window.setTimeout(get, Math.max(c.expires_in - 10, 15) * 1000);
      } catch (e) { if (live) setError(errorText(e)); }
    };
    void get();
    return () => { live = false; window.clearTimeout(timer); };
  }, [url, errorText]);
  useEffect(() => { const i = window.setInterval(() => setLeft((s) => Math.max(s - 1, 0)), 1000); return () => window.clearInterval(i); }, []);
  return (
    <Modal title={code ? t("fuel.codeFor", { plate: code.plate_no }) : t("fuel.code")} onClose={onClose} actions={<button className="btn" onClick={onClose}>{t("common.close")}</button>}>
      {error ? <div className="alert error"><Icon name="block" /><span>{error}</span></div> : code && (
        <div className="stack" style={{ alignItems: "center", textAlign: "center" }}>
          {img && <img src={img} alt={t("fuel.code")} width={280} height={280} />}
          <div className="mono ltr small" style={{ wordBreak: "break-all" }}>{code.code}</div>
          <div className="small muted">{t("fuel.codeExpires", { s: left })}</div>
          <p className="small" style={{ margin: 0 }}>{t("fuel.codeHint")}</p>
        </div>
      )}
    </Modal>
  );
}

export function CarrierFuel() {
  const { t, money, toMinor, fromMinor } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => api.get<View>("/api/carrier/fuel", undefined, { signal }));
  const usage = useLoad((signal) => api.get<{ days: number; vehicles: Usage[] }>("/api/carrier/fuel/consumption", { days: 30 }, { signal }));
  const fills = useLoad((signal) => api.get<{ fills: Fill[] }>("/api/carrier/fuel/fills", { limit: 50 }, { signal }));
  const [tab, setTab] = useState<"cards" | "fills" | "usage" | "anomalies">("cards");
  const [opening, setOpening] = useState<{ company: string; low: string } | null>(null);
  const [form, setForm] = useState<CardForm | null>(null);
  const [blocking, setBlocking] = useState<{ card: Card; reason: string } | null>(null);
  const [showCode, setShowCode] = useState<string | null>(null);
  const run = async (call: () => Promise<unknown>, done: string) => {
    try { await call(); toast(done); state.reload(); return true; } catch (e) { toast(errorText(e)); return false; }
  };
  const saveCard = async (f: CardForm) => {
    const body = { fuel_types: f.fuel_types, budget_period: f.budget_period || null,
                   budget_amount: f.budget_period && f.budget_amount ? toMinor(f.budget_amount) : null,
                   budget_litres: f.budget_period && f.budget_litres ? Number(f.budget_litres) : null };
    return run(() => (f.uid ? api.patch(`/api/carrier/fuel/cards/${f.uid}`, body)
      : api.post("/api/carrier/fuel/cards", { ...body, vehicle_uid: f.vehicle_uid, account_uid: f.account_uid })), t("common.saved"));
  };
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="local_gas_station" /> {t("fuel.carrierTitle")}</h1>
        <button className="btn tonal" onClick={() => setOpening({ company: "", low: "" })}><Icon name="add" />{t("fuel.openWith")}</button></div>
      <p className="small muted" style={{ margin: 0 }}>{t("fuel.carrierHint")}</p>
      <Loaded state={state}>{(v) => (
        <>
          {!v.enabled && <div className="alert info"><Icon name="info" /><span>{t("fuel.off")}</span></div>}
          <div className="grid cols-3">
            {v.accounts.map((a) => (
              <Stat key={a.uid} icon="account_balance_wallet" label={a.fuel_company} value={money(a.balance, true, a.currency)}
                tone={a.low_balance != null && a.balance < a.low_balance ? "red" : undefined} />))}
          </div>
          {v.accounts.length === 0 && <Empty icon="account_balance_wallet" title={t("fuel.noAccountYet")} hint={t("fuel.noAccountYetHint")} />}
          <div className="row" role="tablist" style={{ gap: 4 }}>
            {(["cards", "fills", "usage", "anomalies"] as const).map((k) => (
              <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "text"}`} onClick={() => setTab(k)}>{t(`fuel.tab.${k}`)}</button>))}
          </div>
          {tab === "cards" && (
            <div className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h3 style={{ margin: 0 }}>{t("fuel.cards")}</h3>
                <button className="btn tonal small" disabled={v.accounts.length === 0}
                  onClick={() => setForm({ vehicle_uid: "", account_uid: v.accounts[0]?.uid ?? "", fuel_types: ["DIESEL"], budget_period: "DAY", budget_amount: "", budget_litres: "" })}>
                  <Icon name="add" />{t("fuel.newCard")}</button>
              </div>
              {v.cards.length === 0 ? <Empty icon="local_gas_station" title={t("fuel.noCards")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("fuel.vehicle")}</th><th>{t("fuel.card")}</th><th>{t("fuel.budget")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                  <tbody>{v.cards.map((c) => (
                    <tr key={c.uid}>
                      <td><span className="mono ltr">{c.plate_no ?? "—"}</span><div className="small muted">{c.fuel_company}</div></td>
                      <td className="small"><span className="mono">{c.card_no}</span><div className="muted">{c.fuel_types.map((f) => t(`fuel.type.${f}`)).join(t("common.listSep"))}
                        {c.tag_bound && <> · <Icon name="nfc" size={14} /> {t("fuel.tag")}</>}</div></td>
                      <td className="small">{c.budget_period ? <>{[c.budget_amount != null ? `${money(c.used_amount)} / ${money(c.budget_amount)}` : null,
                        c.budget_litres != null ? `${c.used_litres} / ${c.budget_litres} L` : null].filter(Boolean).join(" · ")}<div className="muted">{t(`fuel.period.${c.budget_period}`)}</div></> : t("fuel.noBudget")}</td>
                      <td><span className={`chip ${c.status === "ACTIVE" ? "green" : "red"}`}>{t(`fuel.cardStatus.${c.status}`)}</span>{c.blocked_reason && <div className="small muted">{c.blocked_reason}</div>}</td>
                      <td><div className="row nowrap" style={{ gap: 4 }}>
                        {c.status === "ACTIVE" && <button className="btn text small" onClick={() => setShowCode(c.uid)}><Icon name="qr_code_2" />{t("fuel.code")}</button>}
                        <button className="btn text small" onClick={() => setForm({ uid: c.uid, vehicle_uid: c.vehicle_uid ?? "", account_uid: c.account_uid ?? "", fuel_types: c.fuel_types,
                          budget_period: c.budget_period ?? "", budget_amount: c.budget_amount != null ? String(fromMinor(c.budget_amount)) : "", budget_litres: c.budget_litres != null ? String(c.budget_litres) : "" })}>{t("fuel.budget")}</button>
                        {c.status === "ACTIVE" ? <button className="btn text small" onClick={() => setBlocking({ card: c, reason: "" })}><Icon name="block" />{t("fuel.block")}</button>
                          : <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/cards/${c.uid}/unblock`), t("common.saved"))}>{t("fuel.unblock")}</button>}
                        {c.tag_bound && <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/cards/${c.uid}/unbind`), t("fuel.unbound"))}><Icon name="link_off" />{t("fuel.unbind")}</button>}
                      </div></td>
                    </tr>))}</tbody>
                </table></div>
              )}
            </div>
          )}
          {tab === "fills" && <div className="card"><Loaded state={fills}>{(f) => <FillsTable fills={f.fills} photoBase="/api/carrier/fuel/fills" />}</Loaded></div>}
          {tab === "usage" && (
            <div className="card"><Loaded state={usage}>{(u) => u.vehicles.length === 0 ? <Empty icon="speed" title={t("fuel.noFills")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("fuel.vehicle")}</th><th>{t("fuel.fills")}</th><th>{t("fuel.litres")}</th><th>{t("fuel.amount")}</th><th>km</th><th>{t("fuel.per100")}</th><th>{t("fuel.anomalies")}</th></tr></thead>
                <tbody>{u.vehicles.map((x) => (
                  <tr key={x.vehicle_uid}><td className="mono ltr">{x.plate_no}</td><td>{x.fills}</td><td>{x.litres}</td><td>{money(x.amount, true, x.currency)}</td>
                    <td>{x.km ?? "—"}</td><td>{x.l_per_100km ?? "—"}</td><td>{x.anomalies}</td></tr>))}</tbody>
              </table></div>
            )}</Loaded><p className="small muted">{t("fuel.usageHint")}</p></div>
          )}
          {tab === "anomalies" && <AnomaliesList anomalyApi="/api/carrier/fuel/anomalies" />}

          {opening && (
            <Modal title={t("fuel.openWith")} onClose={() => setOpening(null)}
              actions={<><button className="btn text" onClick={() => setOpening(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={!opening.company} onClick={async () => {
                  if (await run(() => api.post("/api/carrier/fuel/accounts", { fuel_company_uid: opening.company, low_balance: opening.low ? toMinor(opening.low) : null }), t("fuel.accountOpened"))) setOpening(null); }}>{t("common.create")}</button></>}>
              <Field label={t("fuel.fuelCompany")} required>
                <select className="input" value={opening.company} onChange={(e) => setOpening({ ...opening, company: e.target.value })}>
                  <option value="">{t("fuel.pickCompany")}</option>
                  {v.fuel_companies.map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
                </select>
              </Field>
              <Field label={t("fuel.lowBalance")} optional hint={t("fuel.lowBalanceHint")}>
                <input className="input ltr" inputMode="decimal" value={opening.low} onChange={(e) => setOpening({ ...opening, low: e.target.value })} />
              </Field>
              <p className="small muted">{t("fuel.prepaidHint")}</p>
            </Modal>
          )}
          {form && (
            <Modal title={form.uid ? t("fuel.budget") : t("fuel.newCard")} onClose={() => setForm(null)}
              actions={<><button className="btn text" onClick={() => setForm(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={(!form.uid && (!form.vehicle_uid || !form.account_uid)) || form.fuel_types.length === 0
                  || (!!form.budget_period && !form.budget_amount && !form.budget_litres)}
                  onClick={async () => { if (await saveCard(form)) setForm(null); }}>{t("common.save")}</button></>}>
              <div className="grid cols-2">
                {!form.uid && <>
                  <Field label={t("fuel.vehicle")} required>
                    <select className="input" value={form.vehicle_uid} onChange={(e) => setForm({ ...form, vehicle_uid: e.target.value })}>
                      <option value="">{t("fuel.pickVehicle")}</option>
                      {v.vehicles.filter((x) => !v.cards.some((c) => c.vehicle_uid === x.uid && c.status === "ACTIVE")).map((x) => <option key={x.uid} value={x.uid}>{x.plate_no}</option>)}
                    </select>
                  </Field>
                  <Field label={t("fuel.account")} required>
                    <select className="input" value={form.account_uid} onChange={(e) => setForm({ ...form, account_uid: e.target.value })}>
                      {v.accounts.map((a) => <option key={a.uid} value={a.uid}>{a.fuel_company}</option>)}
                    </select>
                  </Field>
                </>}
                <Field label={t("fuel.fuelTypes")} required>
                  <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>{FUELS.map((f) => (
                    <label key={f} className="row nowrap small" style={{ gap: 4 }}><input type="checkbox" checked={form.fuel_types.includes(f)}
                      onChange={(e) => setForm({ ...form, fuel_types: e.target.checked ? [...form.fuel_types, f] : form.fuel_types.filter((x) => x !== f) })} />{t(`fuel.type.${f}`)}</label>))}</div>
                </Field>
                <Field label={t("fuel.periodLabel")} optional>
                  <select className="input" value={form.budget_period} onChange={(e) => setForm({ ...form, budget_period: e.target.value })}>
                    <option value="">{t("fuel.noBudget")}</option>
                    {["DAY", "WEEK", "MONTH"].map((p) => <option key={p} value={p}>{t(`fuel.period.${p}`)}</option>)}
                  </select>
                </Field>
                {form.budget_period && <>
                  <Field label={t("fuel.budgetAmount")} optional><input className="input ltr" inputMode="decimal" value={form.budget_amount} onChange={(e) => setForm({ ...form, budget_amount: e.target.value })} /></Field>
                  <Field label={t("fuel.budgetLitres")} optional><input className="input ltr" inputMode="decimal" value={form.budget_litres} onChange={(e) => setForm({ ...form, budget_litres: e.target.value })} /></Field>
                </>}
              </div>
              <p className="small muted">{t("fuel.budgetHint")}</p>
            </Modal>
          )}
          {blocking && (
            <Modal title={t("fuel.blockTitle", { plate: blocking.card.plate_no ?? blocking.card.card_no })} onClose={() => setBlocking(null)}
              actions={<><button className="btn text" onClick={() => setBlocking(null)}>{t("common.cancel")}</button>
                <button className="btn danger" disabled={blocking.reason.trim().length < 3} onClick={async () => {
                  if (await run(() => api.post(`/api/carrier/fuel/cards/${blocking.card.uid}/block`, { reason: blocking.reason }), t("fuel.blocked"))) setBlocking(null); }}>{t("fuel.block")}</button></>}>
              <Field label={t("fuel.reasonLabel")} required><input className="input" maxLength={200} value={blocking.reason} onChange={(e) => setBlocking({ ...blocking, reason: e.target.value })} /></Field>
              <p className="small muted">{t("fuel.blockHint")}</p>
            </Modal>
          )}
          {showCode && <FuelCode url={`/api/carrier/fuel/cards/${showCode}/code`} onClose={() => setShowCode(null)} />}
        </>
      )}</Loaded>
    </div>
  );
}

export function DriverFuel() {
  const { t } = useI18n();
  const state = useLoad((signal) => api.get<{ cards: { uid: string; card_no: string; plate_no: string; fuel_types: string[] }[] }>("/api/driver/fuel", undefined, { signal }));
  const [show, setShow] = useState<string | null>(null);
  return (
    <div className="app-body stack">
      <h2 style={{ margin: 0 }}><Icon name="local_gas_station" /> {t("fuel.driverTitle")}</h2>
      <p className="small muted" style={{ margin: 0 }}>{t("fuel.driverHint")}</p>
      <Loaded state={state}>{(v) => v.cards.length === 0 ? <Empty icon="local_gas_station" title={t("fuel.noCards")} /> : (
        <div className="stack">{v.cards.map((c) => (
          <button key={c.uid} className="card row" style={{ justifyContent: "space-between", textAlign: "start" }} onClick={() => setShow(c.uid)}>
            <span><b className="mono ltr">{c.plate_no}</b><div className="small muted">{c.card_no}</div></span><Icon name="qr_code_2" />
          </button>))}</div>
      )}</Loaded>
      {show && <FuelCode url={`/api/driver/fuel/${show}/code`} onClose={() => setShow(null)} />}
    </div>
  );
}

interface AdminCompany { uid: string; name: string; company_no: string | null; approval_status: string; accounts: number; fills_24h: number;
  stations: { uid: string; code: string; name: string; status: string; pumps: number | null; station: string | null }[] }

export function AdminFuel() {
  const { t } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => api.get<{ enabled: boolean; open_anomalies: number; companies: AdminCompany[] }>("/api/admin/fuel", undefined, { signal }));
  const [adding, setAdding] = useState<{ legal_name: string; license_no: string; owner_name: string; owner_email: string; owner_password: string } | null>(null);
  const [door, setDoor] = useState<{ company_no: string; username: string } | null>(null);
  const [station, setStation] = useState<{ company: AdminCompany; name: string; code: string; pumps: string } | null>(null);
  const run = async (call: () => Promise<unknown>, done: string) => {
    try { await call(); toast(done); state.reload(); return true; } catch (e) { toast(errorText(e)); return false; }
  };
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="local_gas_station" /> {t("fuel.adminTitle")}</h1>
        <button className="btn tonal" onClick={() => setAdding({ legal_name: "", license_no: "", owner_name: "", owner_email: "", owner_password: "" })}><Icon name="add_business" />{t("fuel.addCompany")}</button></div>
      <Loaded state={state}>{(v) => (
        <>
          {!v.enabled && <div className="alert info"><Icon name="info" /><span>{t("fuel.offAdmin")}</span></div>}
          {v.companies.length === 0 ? <Empty icon="local_gas_station" title={t("fuel.noCompanies")} /> : v.companies.map((c) => (
            <div key={c.uid} className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h3 style={{ margin: 0 }}>{c.name} <span className="small muted mono">{c.company_no}</span></h3>
                <button className="btn tonal small" onClick={() => setStation({ company: c, name: "", code: "", pumps: "" })}><Icon name="add" />{t("fuel.addStation")}</button>
              </div>
              <div className="small muted">{t("fuel.companyLine", { accounts: c.accounts, fills: c.fills_24h })}</div>
              {c.stations.length > 0 && (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("fuel.station")}</th><th>{t("fuel.pumps")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                  <tbody>{c.stations.map((s) => (
                    <tr key={s.uid}><td>{s.name}<div className="small muted mono">{s.code}{s.station ? ` · ${s.station}` : ""}</div></td><td>{s.pumps ?? "—"}</td>
                      <td><span className={`chip ${s.status === "ACTIVE" ? "green" : "outline"}`}>{t(`fuel.stationStatus.${s.status}`)}</span></td>
                      <td>{s.status === "ACTIVE"
                        ? <button className="btn text small" onClick={() => void run(() => api.post(`/api/admin/fuel/stations/${s.uid}/status`, { status: "SUSPENDED" }), t("common.saved"))}>{t("fuel.suspend")}</button>
                        : s.status === "SUSPENDED" && <button className="btn text small" onClick={() => void run(() => api.post(`/api/admin/fuel/stations/${s.uid}/status`, { status: "ACTIVE" }), t("common.saved"))}>{t("fuel.activate")}</button>}</td></tr>))}</tbody>
                </table></div>
              )}
            </div>
          ))}
          <h3 style={{ margin: 0 }}>{t("fuel.anomalies")} ({v.open_anomalies})</h3>
          <AnomaliesList anomalyApi="/api/admin/fuel/anomalies" />
        </>
      )}</Loaded>
      {adding && (
        <Modal title={t("fuel.addCompany")} onClose={() => setAdding(null)}
          actions={<><button className="btn text" onClick={() => setAdding(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!adding.legal_name || !adding.owner_name || !adding.owner_email || adding.owner_password.length < 12} onClick={async () => {
              try { const r = await api.post<{ uid: string; door: { company_no: string; username: string } }>("/api/admin/fuel/companies", { ...adding, license_no: adding.license_no || null });
                    setAdding(null); setDoor(r.door); state.reload(); } catch (e) { toast(errorText(e)); } }}>{t("common.create")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.legalName")} required><input className="input" maxLength={200} value={adding.legal_name} onChange={(e) => setAdding({ ...adding, legal_name: e.target.value })} /></Field>
            <Field label={t("fuel.licence")} optional><input className="input" maxLength={60} value={adding.license_no} onChange={(e) => setAdding({ ...adding, license_no: e.target.value })} /></Field>
            <Field label={t("fuel.ownerName")} required><input className="input" maxLength={120} value={adding.owner_name} onChange={(e) => setAdding({ ...adding, owner_name: e.target.value })} /></Field>
            <Field label={t("fuel.ownerEmail")} required><input className="input ltr" type="email" value={adding.owner_email} onChange={(e) => setAdding({ ...adding, owner_email: e.target.value })} /></Field>
            <Field label={t("fuel.ownerPassword")} required hint={t("fuel.ownerPasswordHint")}><input className="input ltr" type="password" value={adding.owner_password} onChange={(e) => setAdding({ ...adding, owner_password: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
      {door && (
        <Modal title={t("fuel.doorTitle")} onClose={() => setDoor(null)} actions={<button className="btn" onClick={() => setDoor(null)}>{t("common.close")}</button>}>
          <p style={{ marginTop: 0 }}>{t("fuel.doorHint")}</p>
          <p className="mono ltr">{t("fuel.companyNo")}: {door.company_no} · {t("fuel.username")}: {door.username}</p>
        </Modal>
      )}
      {station && (
        <Modal title={t("fuel.addStationTo", { name: station.company.name })} onClose={() => setStation(null)}
          actions={<><button className="btn text" onClick={() => setStation(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!station.name || !/^[A-Z0-9-]{3,30}$/.test(station.code)} onClick={async () => {
              if (await run(() => api.post(`/api/admin/fuel/companies/${station.company.uid}/stations`, { name: station.name, code: station.code, pumps: station.pumps ? Number(station.pumps) : null }), t("common.saved"))) setStation(null); }}>{t("common.create")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.stationName")} required><input className="input" maxLength={200} value={station.name} onChange={(e) => setStation({ ...station, name: e.target.value })} /></Field>
            <Field label={t("fuel.stationCode")} required hint={t("fuel.stationCodeHint")}><input className="input mono ltr" maxLength={30} value={station.code} onChange={(e) => setStation({ ...station, code: e.target.value.toUpperCase() })} /></Field>
            <Field label={t("fuel.pumps")} optional><input className="input ltr" inputMode="numeric" value={station.pumps} onChange={(e) => setStation({ ...station, pumps: e.target.value.replace(/\D/g, "") })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
