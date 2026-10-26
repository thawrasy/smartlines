import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, Field, Icon, Loaded, Modal, Stat, useErrorText, useLoad, useToast } from "../../components/ui";
import { AnomaliesList, FUELS, FillsTable, readTag, type Fill } from "./Fuel";

// Fuel for a company with vehicles (owner's note of 25 October 2026; migration 1180): it opens an account with each
// fuel company it uses and pays that company in advance (the money is the fuel company's; the platform keeps the
// account), gives each vehicle a card with a budget per day, week or month, blocks a lost card at once, follows every
// fill with the meter's photo and decides what the checks found. The driver shows a short-lived code at the pump.
// It subscribes its vehicles to the service by the week, month, quarter or year and pays the platform in advance; it
// binds each NFC tag the platform issued to a vehicle before sticking it on, pauses a card, gives its allowance an end
// date, and questions a fill whose photos do not match (1181).

interface FuelCompany { uid: string; name: string }
interface Account { uid: string; currency: string; balance: number; low_balance: number | null; status: string; fuel_company_uid: string; fuel_company: string }
interface Card { uid: string; card_no: string; status: string; blocked_reason: string | null; paused_reason: string | null; valid_until: string | null;
  fuel_types: string[]; budget_period: string | null; budget_amount: number | null; budget_litres: number | null; vehicle_uid: string | null;
  plate_no: string | null; account_uid: string | null; fuel_company: string | null; tag_bound: boolean; tag_label: string | null;
  covered_until: string | null; used_amount: number; used_litres: number }
interface Subscription { uid: string; period: string; vehicles: number; price_per_vehicle: number | null; amount: number | null; currency: string;
  commission_pct: number | null; starts_on: string; ends_on: string; status: string; paid_reference: string | null; plates: string[] }
interface IssuedTag { uid: string; label: string; kind: string; status: string; bound: boolean }
interface Vehicle { uid: string; plate_no: string; fuel_type: string | null; fuel_tank_l: number | null }
interface View { enabled: boolean; fuel_companies: FuelCompany[]; accounts: Account[]; cards: Card[]; vehicles: Vehicle[];
  subscriptions: Subscription[]; tags: IssuedTag[]; plan: { required: boolean; prices: Record<string, number | null> } }
interface Usage { vehicle_uid: string; plate_no: string; fills: number; litres: number; amount: number; currency: string; km: number | null;
  l_per_100km: number | null; anomalies: number }
interface CardForm { uid?: string; vehicle_uid: string; account_uid: string; fuel_types: string[]; budget_period: string; budget_amount: string;
  budget_litres: string; valid_until: string }
const PERIODS = ["DAY", "WEEK", "MONTH", "QUARTER", "YEAR"];
const SUB_PERIODS = ["WEEK", "MONTH", "QUARTER", "YEAR"];

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
  const { t, money, toMinor, fromMinor, date } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => api.get<View>("/api/carrier/fuel", undefined, { signal }));
  const [binding, setBinding] = useState<{ card: Card; serial: string; reading: boolean } | null>(null);
  const [pausing, setPausing] = useState<{ card: Card; reason: string } | null>(null);
  const [subscribing, setSubscribing] = useState<{ period: string; starts_on: string; vehicles: string[] } | null>(null);
  const [querying, setQuerying] = useState<{ fill: Fill; note: string } | null>(null);
  const usage = useLoad((signal) => api.get<{ days: number; vehicles: Usage[] }>("/api/carrier/fuel/consumption", { days: 30 }, { signal }));
  const fills = useLoad((signal) => api.get<{ fills: Fill[] }>("/api/carrier/fuel/fills", { limit: 50 }, { signal }));
  const [tab, setTab] = useState<"cards" | "subscription" | "fills" | "usage" | "anomalies">("cards");
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
                   budget_litres: f.budget_period && f.budget_litres ? Number(f.budget_litres) : null, valid_until: f.valid_until || null };
    return run(() => (f.uid ? api.patch(`/api/carrier/fuel/cards/${f.uid}`, body)
      : api.post("/api/carrier/fuel/cards", { ...body, vehicle_uid: f.vehicle_uid, account_uid: f.account_uid })), t("common.saved"));
  };
  return (
    <div className="page stack">
      <div className="page-head"><h1><Icon name="local_gas_station" /> {t("fuel.carrierTitle")}</h1>
        <button className="btn tonal" onClick={() => setOpening({ company: "", low: "" })}><Icon name="add" />{t("fuel.openWith")}</button></div>
      <div className="alert info"><Icon name="local_gas_station" /><span><b>{t("fuel.pitch")}</b> {t("fuel.pitchLine")}</span></div>
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
            {(["cards", "subscription", "fills", "usage", "anomalies"] as const).map((k) => (
              <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "text"}`} onClick={() => setTab(k)}>{t(`fuel.tab.${k}`)}</button>))}
          </div>
          {tab === "cards" && (
            <div className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h3 style={{ margin: 0 }}>{t("fuel.cards")}</h3>
                <button className="btn tonal small" disabled={v.accounts.length === 0}
                  onClick={() => setForm({ vehicle_uid: "", account_uid: v.accounts[0]?.uid ?? "", fuel_types: ["DIESEL"], budget_period: "DAY", budget_amount: "", budget_litres: "", valid_until: "" })}>
                  <Icon name="add" />{t("fuel.newCard")}</button>
              </div>
              {v.cards.length === 0 ? <Empty icon="local_gas_station" title={t("fuel.noCards")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("fuel.vehicle")}</th><th>{t("fuel.card")}</th><th>{t("fuel.budget")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                  <tbody>{v.cards.map((c) => (
                    <tr key={c.uid}>
                      <td><span className="mono ltr">{c.plate_no ?? "—"}</span><div className="small muted">{c.fuel_company}</div>
                        <div className={`small ${c.covered_until ? "muted" : "red-text"}`}>{c.covered_until ? t("fuel.coveredUntil", { date: date(c.covered_until) }) : v.plan.required ? t("fuel.notCovered") : ""}</div></td>
                      <td className="small"><span className="mono">{c.card_no}</span><div className="muted">{c.fuel_types.map((f) => t(`fuel.type.${f}`)).join(t("common.listSep"))}
                        {c.tag_bound && <> · <Icon name="nfc" size={14} /> {c.tag_label ?? t("fuel.tag")}</>}</div></td>
                      <td className="small">{c.budget_period ? <>{[c.budget_amount != null ? `${money(c.used_amount)} / ${money(c.budget_amount)}` : null,
                        c.budget_litres != null ? `${c.used_litres} / ${c.budget_litres} L` : null].filter(Boolean).join(" · ")}<div className="muted">{t(`fuel.period.${c.budget_period}`)}</div></> : t("fuel.noBudget")}
                        {c.valid_until && <div className="muted">{t("fuel.validUntilShort", { date: date(c.valid_until) })}</div>}</td>
                      <td><span className={`chip ${c.status === "ACTIVE" ? "green" : c.status === "PAUSED" ? "wheat" : "red"}`}>{t(`fuel.cardStatus.${c.status}`)}</span>
                        {(c.blocked_reason || c.paused_reason) && <div className="small muted">{c.blocked_reason ?? c.paused_reason}</div>}</td>
                      <td><div className="row nowrap" style={{ gap: 4 }}>
                        {c.status === "ACTIVE" && <button className="btn text small" onClick={() => setShowCode(c.uid)}><Icon name="qr_code_2" />{t("fuel.code")}</button>}
                        <button className="btn text small" onClick={() => setForm({ uid: c.uid, vehicle_uid: c.vehicle_uid ?? "", account_uid: c.account_uid ?? "", fuel_types: c.fuel_types,
                          budget_period: c.budget_period ?? "", budget_amount: c.budget_amount != null ? String(fromMinor(c.budget_amount)) : "",
                          budget_litres: c.budget_litres != null ? String(c.budget_litres) : "", valid_until: c.valid_until ?? "" })}>{t("fuel.budget")}</button>
                        {c.status === "ACTIVE" && <button className="btn text small" onClick={() => setPausing({ card: c, reason: "" })}><Icon name="pause_circle" />{t("fuel.pause")}</button>}
                        {c.status === "PAUSED" && <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/cards/${c.uid}/resume`), t("common.saved"))}><Icon name="play_circle" />{t("fuel.resume")}</button>}
                        {c.status === "ACTIVE" || c.status === "PAUSED" ? <button className="btn text small" onClick={() => setBlocking({ card: c, reason: "" })}><Icon name="block" />{t("fuel.block")}</button>
                          : <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/cards/${c.uid}/unblock`), t("common.saved"))}>{t("fuel.unblock")}</button>}
                        {!c.tag_bound && c.status !== "BLOCKED" && <button className="btn text small" onClick={() => setBinding({ card: c, serial: "", reading: false })}><Icon name="nfc" />{t("fuel.bindTag")}</button>}
                        {c.tag_bound && <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/cards/${c.uid}/tag-lost`), t("fuel.tagLostDone"))}><Icon name="link_off" />{t("fuel.tagLost")}</button>}
                      </div></td>
                    </tr>))}</tbody>
                </table></div>
              )}
            </div>
          )}
          {tab === "subscription" && (
            <div className="card stack">
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h3 style={{ margin: 0 }}>{t("fuel.subscriptions")}</h3>
                <button className="btn tonal small" disabled={v.vehicles.length === 0} onClick={() => setSubscribing({ period: "MONTH", starts_on: new Date().toISOString().slice(0, 10), vehicles: [] })}>
                  <Icon name="add" />{t("fuel.subscribe")}</button>
              </div>
              <p className="small muted" style={{ margin: 0 }}>{t("fuel.subscriptionHint")}</p>
              {v.subscriptions.length === 0 ? <Empty icon="event_repeat" title={t("fuel.noSubscriptions")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("fuel.periodLabel")}</th><th>{t("fuel.vehicles")}</th><th>{t("fuel.amount")}</th><th>{t("fuel.dates")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
                  <tbody>{v.subscriptions.map((x) => (
                    <tr key={x.uid}>
                      <td>{t(`fuel.period.${x.period}`)}</td>
                      <td className="small">{x.vehicles}<div className="muted mono ltr">{x.plates.slice(0, 6).join(" · ")}{x.plates.length > 6 ? " …" : ""}</div></td>
                      <td className="small">{x.amount != null ? money(x.amount, true, x.currency) : t("fuel.priceByPlatform")}{x.commission_pct != null && <div className="muted">{t("fuel.commissionLine", { pct: x.commission_pct })}</div>}</td>
                      <td className="small">{date(x.starts_on)} → {date(x.ends_on)}</td>
                      <td><span className={`chip ${x.status === "ACTIVE" ? "green" : x.status === "REQUESTED" ? "wheat" : "outline"}`}>{t(`fuel.subStatus.${x.status}`)}</span>
                        {x.status === "REQUESTED" && <div className="small muted">{t("fuel.awaitingPayment")}</div>}</td>
                      <td>{x.status === "REQUESTED" && <button className="btn text small" onClick={() => void run(() => api.post(`/api/carrier/fuel/subscriptions/${x.uid}/cancel`), t("common.saved"))}>{t("common.cancel")}</button>}</td>
                    </tr>))}</tbody>
                </table></div>
              )}
            </div>
          )}
          {tab === "fills" && <div className="card"><Loaded state={fills}>{(f) => <FillsTable fills={f.fills} photoBase="/api/carrier/fuel/fills" onQuery={(x) => setQuerying({ fill: x, note: "" })} />}</Loaded></div>}
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
                      {v.vehicles.filter((x) => !v.cards.some((c) => c.vehicle_uid === x.uid && (c.status === "ACTIVE" || c.status === "PAUSED"))).map((x) => <option key={x.uid} value={x.uid}>{x.plate_no}</option>)}
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
                    {PERIODS.map((p) => <option key={p} value={p}>{t(`fuel.period.${p}`)}</option>)}
                  </select>
                </Field>
                {form.budget_period && <>
                  <Field label={t("fuel.budgetAmount")} optional><input className="input ltr" inputMode="decimal" value={form.budget_amount} onChange={(e) => setForm({ ...form, budget_amount: e.target.value })} /></Field>
                  <Field label={t("fuel.budgetLitres")} optional><input className="input ltr" inputMode="decimal" value={form.budget_litres} onChange={(e) => setForm({ ...form, budget_litres: e.target.value })} /></Field>
                </>}
                <Field label={t("fuel.validUntil")} optional hint={t("fuel.validUntilHint")}><input className="input ltr" type="date" value={form.valid_until} onChange={(e) => setForm({ ...form, valid_until: e.target.value })} /></Field>
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
          {binding && (
            <Modal title={t("fuel.bindTitle", { plate: binding.card.plate_no ?? binding.card.card_no })} onClose={() => setBinding(null)}
              actions={<><button className="btn text" onClick={() => setBinding(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={binding.serial.replace(/[^0-9a-f]/gi, "").length < 8} onClick={async () => {
                  if (await run(() => api.post(`/api/carrier/fuel/cards/${binding.card.uid}/tag`, { tag: binding.serial }), t("fuel.tagBound"))) setBinding(null); }}>{t("fuel.bindTag")}</button></>}>
              <p className="small" style={{ marginTop: 0 }}>{t("fuel.bindTagHint")}</p>
              <button className="btn tonal" disabled={binding.reading} onClick={async () => {
                setBinding({ ...binding, reading: true });
                try {
                  const read = await readTag(new AbortController().signal);
                  if (await run(() => api.post(`/api/carrier/fuel/cards/${binding.card.uid}/tag`, read), t("fuel.tagBound"))) setBinding(null);
                  else setBinding((b) => (b ? { ...b, reading: false } : b));
                } catch (e) { toast((e as Error).message === "NFC" ? t("fuel.noNfc") : errorText(e)); setBinding((b) => (b ? { ...b, reading: false } : b)); }
              }}><Icon name="nfc" />{binding.reading ? t("fuel.tapCard") : t("fuel.readWithPhone")}</button>
              <Field label={t("fuel.tagSerial")} optional hint={t("fuel.tagSerialHint")}>
                <input className="input mono ltr" maxLength={40} value={binding.serial} onChange={(e) => setBinding({ ...binding, serial: e.target.value })} />
              </Field>
              <p className="small muted">{t("fuel.issuedTags", { n: v.tags.filter((x) => x.status === "ISSUED" && !x.bound).length })}</p>
            </Modal>
          )}
          {pausing && (
            <Modal title={t("fuel.pauseTitle", { plate: pausing.card.plate_no ?? pausing.card.card_no })} onClose={() => setPausing(null)}
              actions={<><button className="btn text" onClick={() => setPausing(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={pausing.reason.trim().length < 3} onClick={async () => {
                  if (await run(() => api.post(`/api/carrier/fuel/cards/${pausing.card.uid}/pause`, { reason: pausing.reason }), t("common.saved"))) setPausing(null); }}>{t("fuel.pause")}</button></>}>
              <Field label={t("fuel.reasonLabel")} required><input className="input" maxLength={200} value={pausing.reason} onChange={(e) => setPausing({ ...pausing, reason: e.target.value })} /></Field>
              <p className="small muted">{t("fuel.pauseHint")}</p>
            </Modal>
          )}
          {subscribing && (
            <Modal title={t("fuel.subscribe")} onClose={() => setSubscribing(null)} wide
              actions={<><button className="btn text" onClick={() => setSubscribing(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={subscribing.vehicles.length === 0 || !subscribing.starts_on} onClick={async () => {
                  if (await run(() => api.post("/api/carrier/fuel/subscriptions", { period: subscribing.period, starts_on: subscribing.starts_on, vehicle_uids: subscribing.vehicles }), t("fuel.subscriptionRequested"))) setSubscribing(null); }}>{t("fuel.subscribe")}</button></>}>
              <div className="grid cols-2">
                <Field label={t("fuel.periodLabel")} required>
                  <select className="input" value={subscribing.period} onChange={(e) => setSubscribing({ ...subscribing, period: e.target.value })}>
                    {SUB_PERIODS.map((p) => <option key={p} value={p}>{t(`fuel.period.${p}`)}{v.plan.prices[p] != null ? ` · ${money(v.plan.prices[p] as number)} / ${t("fuel.perVehicle")}` : ""}</option>)}
                  </select>
                </Field>
                <Field label={t("fuel.startsOn")} required><input className="input ltr" type="date" value={subscribing.starts_on} onChange={(e) => setSubscribing({ ...subscribing, starts_on: e.target.value })} /></Field>
              </div>
              <Field label={t("fuel.vehicles")} required>
                <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                  <button type="button" className="btn text small" onClick={() => setSubscribing({ ...subscribing, vehicles: v.vehicles.map((x) => x.uid) })}>{t("fuel.allVehicles")}</button>
                  {v.vehicles.map((x) => (
                    <label key={x.uid} className="row nowrap small" style={{ gap: 4 }}><input type="checkbox" checked={subscribing.vehicles.includes(x.uid)}
                      onChange={(e) => setSubscribing({ ...subscribing, vehicles: e.target.checked ? [...subscribing.vehicles, x.uid] : subscribing.vehicles.filter((y) => y !== x.uid) })} />
                      <span className="mono ltr">{x.plate_no}</span></label>))}
                </div>
              </Field>
              {v.plan.prices[subscribing.period] != null && (
                <p className="small"><b>{t("fuel.subscriptionTotal", { amount: money((v.plan.prices[subscribing.period] as number) * subscribing.vehicles.length) })}</b></p>)}
              <p className="small muted">{t("fuel.subscribeHint")}</p>
            </Modal>
          )}
          {querying && (
            <Modal title={t("fuel.queryTitle", { plate: querying.fill.plate_no ?? "" })} onClose={() => setQuerying(null)}
              actions={<><button className="btn text" onClick={() => setQuerying(null)}>{t("common.cancel")}</button>
                <button className="btn" disabled={querying.note.trim().length < 3} onClick={async () => {
                  if (await run(() => api.post(`/api/carrier/fuel/fills/${querying.fill.uid}/query`, { note: querying.note }), t("fuel.queried"))) { setQuerying(null); fills.reload(); } }}>{t("fuel.query")}</button></>}>
              <Field label={t("fuel.queryNote")} required><textarea className="input" rows={3} maxLength={300} value={querying.note} onChange={(e) => setQuerying({ ...querying, note: e.target.value })} /></Field>
              <p className="small muted">{t("fuel.queryHint")}</p>
            </Modal>
          )}
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

interface AdminTag { uid: string; label: string; kind: string; batch: string | null; status: string; issued_to: string | null; bound: boolean; last_seen_at: string | null }
interface AdminSub { uid: string; company: string; period: string; vehicles: number; price_per_vehicle: number | null; amount: number | null; currency: string;
  commission_pct: number | null; starts_on: string; ends_on: string; status: string; paid_reference: string | null }
interface CommissionRow { company_uid: string; company: string; side: string; currency: string; fills: number; amount: number }

/** The platform's side of the fuel service (1181): the NFC tags it registers and issues, the subscriptions it is paid for in
 *  advance, the commission agreed with each fuel company, and the commissions due each month. */
const FLEETS = ["CARRIER", "INDIVIDUAL_OPERATOR", "FOREIGN_CARRIER", "SCHOOL", "PARTNER"];

function AdminFuelService() {
  const { t, money, date, toMinor } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const [tab, setTab] = useState<"subs" | "tags" | "commissions">("subs");
  const subs = useLoad((signal) => api.get<{ subscriptions: AdminSub[] }>("/api/admin/fuel/subscriptions", undefined, { signal }));
  const tags = useLoad((signal) => api.get<{ tags: AdminTag[] }>("/api/admin/fuel/tags", undefined, { signal }));
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7));
  const commissions = useLoad((signal) => api.get<{ rows: CommissionRow[] }>("/api/admin/fuel/commissions", { month }, { signal }), [month]);
  const [confirming, setConfirming] = useState<{ sub: AdminSub; price: string; pct: string; reference: string } | null>(null);
  const [registering, setRegistering] = useState<{ kind: string; batch: string; lines: string } | null>(null);
  const [issuing, setIssuing] = useState<{ company: string; labels: string } | null>(null);
  const fleets = useLoad((signal) => (issuing ? api.get<{ companies: { uid: string; legal_name: string; company_type: string }[] }>("/api/admin/companies", undefined, { signal })
    : Promise.resolve(null)), [issuing != null]);
  const run = async (call: () => Promise<unknown>, done: string, reload: () => void) => {
    try { await call(); toast(done); reload(); return true; } catch (e) { toast(errorText(e)); return false; }
  };
  const parsed = (registering?.lines ?? "").split(/\n/).map((l) => l.trim().split(/[\s,;]+/)).filter((x) => x.length >= 2 && x[0])
    .map(([serial, label]) => ({ serial, label: label.toUpperCase() }));
  return (
    <div className="card stack">
      <h3 style={{ margin: 0 }}>{t("fuel.service")}</h3>
      <div className="row" role="tablist" style={{ gap: 4 }}>
        {(["subs", "tags", "commissions"] as const).map((k) => (
          <button key={k} role="tab" aria-selected={tab === k} className={`btn ${tab === k ? "" : "text"}`} onClick={() => setTab(k)}>{t(`fuel.adminTab.${k}`)}</button>))}
      </div>
      {tab === "subs" && <Loaded state={subs}>{(v) => v.subscriptions.length === 0 ? <Empty icon="event_repeat" title={t("fuel.noSubscriptions")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("fuel.holder")}</th><th>{t("fuel.periodLabel")}</th><th>{t("fuel.amount")}</th><th>{t("fuel.dates")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{v.subscriptions.map((x) => (
            <tr key={x.uid}><td>{x.company}<div className="small muted">{t("fuel.vehiclesN", { n: x.vehicles })}</div></td><td>{t(`fuel.period.${x.period}`)}</td>
              <td className="small">{x.amount != null ? money(x.amount, true, x.currency) : t("fuel.priceByPlatform")}{x.commission_pct != null && <div className="muted">{t("fuel.commissionLine", { pct: x.commission_pct })}</div>}</td>
              <td className="small">{date(x.starts_on)} → {date(x.ends_on)}{x.paid_reference && <div className="muted">{x.paid_reference}</div>}</td>
              <td><span className={`chip ${x.status === "ACTIVE" ? "green" : x.status === "REQUESTED" ? "wheat" : "outline"}`}>{t(`fuel.subStatus.${x.status}`)}</span></td>
              <td>{x.status === "REQUESTED" && <div className="row nowrap" style={{ gap: 4 }}>
                <button className="btn text small" onClick={() => setConfirming({ sub: x, price: "", pct: x.commission_pct != null ? String(x.commission_pct) : "", reference: "" })}>{t("fuel.recordPayment")}</button>
                <button className="btn text small" onClick={() => void run(() => api.post(`/api/admin/fuel/subscriptions/${x.uid}/cancel`), t("common.saved"), subs.reload)}>{t("common.cancel")}</button></div>}</td></tr>))}</tbody>
        </table></div>
      )}</Loaded>}
      {tab === "tags" && (
        <>
          <div className="row" style={{ gap: 8 }}>
            <button className="btn tonal small" onClick={() => setRegistering({ kind: "SECURE", batch: "", lines: "" })}><Icon name="add" />{t("fuel.registerTags")}</button>
            <button className="btn tonal small" onClick={() => setIssuing({ company: "", labels: "" })}><Icon name="local_shipping" />{t("fuel.issueTags")}</button>
          </div>
          <p className="small muted" style={{ margin: 0 }}>{t("fuel.tagsHint")}</p>
          <Loaded state={tags}>{(v) => v.tags.length === 0 ? <Empty icon="nfc" title={t("fuel.noTags")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("fuel.tag")}</th><th>{t("fuel.tagKind")}</th><th>{t("fuel.issuedTo")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
              <tbody>{v.tags.map((x) => (
                <tr key={x.uid}><td className="mono">{x.label}<div className="small muted">{x.batch}</div></td><td>{t(`fuel.tagKindName.${x.kind}`)}</td>
                  <td className="small">{x.issued_to ?? "—"}{x.bound && <div className="muted">{t("fuel.tagOnVehicle")}</div>}</td>
                  <td><span className={`chip ${x.status === "ISSUED" ? "green" : x.status === "STOCK" ? "outline" : "red"}`}>{t(`fuel.tagStatus.${x.status}`)}</span></td>
                  <td>{(x.status === "STOCK" || x.status === "ISSUED") && <button className="btn text small" onClick={() => void run(() => api.post(`/api/admin/fuel/tags/${x.uid}/status`, { status: "RETIRED" }), t("common.saved"), tags.reload)}>{t("fuel.retireTag")}</button>}</td></tr>))}</tbody>
            </table></div>
          )}</Loaded>
        </>
      )}
      {tab === "commissions" && (
        <>
          <Field label={t("fuel.month")}><input className="input ltr" type="month" value={month} onChange={(e) => setMonth(e.target.value)} style={{ maxWidth: 200 }} /></Field>
          <Loaded state={commissions}>{(v) => v.rows.length === 0 ? <Empty icon="receipt_long" title={t("fuel.noCommissions")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("fuel.holder")}</th><th>{t("fuel.side")}</th><th>{t("fuel.fills")}</th><th>{t("fuel.amount")}</th></tr></thead>
              <tbody>{v.rows.map((x) => (
                <tr key={`${x.company_uid}-${x.side}-${x.currency}`}><td>{x.company}</td><td>{t(`fuel.sideName.${x.side}`)}</td><td>{x.fills}</td><td>{money(x.amount, true, x.currency)}</td></tr>))}</tbody>
            </table></div>
          )}</Loaded>
          <p className="small muted" style={{ margin: 0 }}>{t("fuel.commissionsHint")}</p>
        </>
      )}
      {confirming && (
        <Modal title={t("fuel.recordPaymentTitle", { name: confirming.sub.company })} onClose={() => setConfirming(null)}
          actions={<><button className="btn text" onClick={() => setConfirming(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!confirming.reference.trim() || (confirming.sub.price_per_vehicle == null && !confirming.price) || confirming.pct === ""} onClick={async () => {
              if (await run(() => api.post(`/api/admin/fuel/subscriptions/${confirming.sub.uid}/confirm`, {
                price_per_vehicle: confirming.price ? toMinor(confirming.price, confirming.sub.currency) : null, commission_pct: Number(confirming.pct), reference: confirming.reference }),
                t("fuel.paymentRecorded"), subs.reload)) setConfirming(null); }}>{t("common.save")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.pricePerVehicle")} required={confirming.sub.price_per_vehicle == null} optional={confirming.sub.price_per_vehicle != null}
              hint={confirming.sub.price_per_vehicle != null ? money(confirming.sub.price_per_vehicle, true, confirming.sub.currency) : undefined}>
              <input className="input ltr" inputMode="decimal" value={confirming.price} onChange={(e) => setConfirming({ ...confirming, price: e.target.value })} /></Field>
            <Field label={t("fuel.commissionPct")} required><input className="input ltr" inputMode="decimal" value={confirming.pct} onChange={(e) => setConfirming({ ...confirming, pct: e.target.value })} /></Field>
            <Field label={t("fuel.paymentReference")} required><input className="input" maxLength={80} value={confirming.reference} onChange={(e) => setConfirming({ ...confirming, reference: e.target.value })} /></Field>
          </div>
          <p className="small muted">{t("fuel.recordPaymentHint")}</p>
        </Modal>
      )}
      {registering && (
        <Modal title={t("fuel.registerTags")} onClose={() => setRegistering(null)} wide
          actions={<><button className="btn text" onClick={() => setRegistering(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={parsed.length === 0} onClick={async () => {
              if (await run(() => api.post("/api/admin/fuel/tags", { kind: registering.kind, batch: registering.batch || null, tags: parsed }), t("fuel.tagsRegistered"), tags.reload)) setRegistering(null); }}>{t("fuel.registerN", { n: parsed.length })}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.tagKind")} required>
              <select className="input" value={registering.kind} onChange={(e) => setRegistering({ ...registering, kind: e.target.value })}>
                {["SECURE", "PLAIN"].map((k) => <option key={k} value={k}>{t(`fuel.tagKindName.${k}`)}</option>)}</select></Field>
            <Field label={t("fuel.batch")} optional><input className="input" maxLength={60} value={registering.batch} onChange={(e) => setRegistering({ ...registering, batch: e.target.value })} /></Field>
          </div>
          <Field label={t("fuel.tagLines")} required hint={t("fuel.tagLinesHint")}>
            <textarea className="input mono ltr" rows={8} value={registering.lines} onChange={(e) => setRegistering({ ...registering, lines: e.target.value })} /></Field>
        </Modal>
      )}
      {issuing && (
        <Modal title={t("fuel.issueTags")} onClose={() => setIssuing(null)}
          actions={<><button className="btn text" onClick={() => setIssuing(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!issuing.company || !issuing.labels.trim()} onClick={async () => {
              const labels = issuing.labels.split(/[\s,;]+/).map((x) => x.trim().toUpperCase()).filter(Boolean);
              if (await run(() => api.post("/api/admin/fuel/tags/issue", { company_uid: issuing.company, labels }), t("fuel.tagsIssued"), tags.reload)) setIssuing(null); }}>{t("fuel.issueTags")}</button></>}>
          <Field label={t("fuel.carrierCompany")} required>
            <select className="input" value={issuing.company} onChange={(e) => setIssuing({ ...issuing, company: e.target.value })}>
              <option value="">{t("fuel.pickCompany")}</option>
              {(fleets.data?.companies ?? []).filter((c) => FLEETS.includes(c.company_type)).map((c) => <option key={c.uid} value={c.uid}>{c.legal_name}</option>)}
            </select></Field>
          <Field label={t("fuel.tagLabels")} required><textarea className="input mono ltr" rows={4} value={issuing.labels} onChange={(e) => setIssuing({ ...issuing, labels: e.target.value })} /></Field>
        </Modal>
      )}
    </div>
  );
}

export function AdminFuel() {
  const { t } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const state = useLoad((signal) => api.get<{ enabled: boolean; open_anomalies: number; companies: AdminCompany[] }>("/api/admin/fuel", undefined, { signal }));
  const [adding, setAdding] = useState<{ legal_name: string; license_no: string; owner_name: string; owner_email: string; owner_password: string } | null>(null);
  const [door, setDoor] = useState<{ company_no: string; username: string } | null>(null);
  const [station, setStation] = useState<{ company: AdminCompany; name: string; code: string; pumps: string } | null>(null);
  const [terms, setTerms] = useState<{ company: AdminCompany; pct: string; from: string } | null>(null);
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
                <div className="row" style={{ gap: 4 }}>
                  <button className="btn tonal small" onClick={() => setTerms({ company: c, pct: "", from: new Date().toISOString().slice(0, 10) })}><Icon name="percent" />{t("fuel.terms")}</button>
                  <button className="btn tonal small" onClick={() => setStation({ company: c, name: "", code: "", pumps: "" })}><Icon name="add" />{t("fuel.addStation")}</button>
                </div>
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
          <AdminFuelService />
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
      {terms && (
        <Modal title={t("fuel.termsTitle", { name: terms.company.name })} onClose={() => setTerms(null)}
          actions={<><button className="btn text" onClick={() => setTerms(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={terms.pct === "" || !terms.from} onClick={async () => {
              if (await run(() => api.post(`/api/admin/fuel/companies/${terms.company.uid}/terms`, { commission_pct: Number(terms.pct), valid_from: terms.from }), t("common.saved"))) setTerms(null); }}>{t("common.save")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("fuel.commissionPct")} required><input className="input ltr" inputMode="decimal" value={terms.pct} onChange={(e) => setTerms({ ...terms, pct: e.target.value })} /></Field>
            <Field label={t("fuel.validFrom")} required><input className="input ltr" type="date" value={terms.from} onChange={(e) => setTerms({ ...terms, from: e.target.value })} /></Field>
          </div>
          <p className="small muted">{t("fuel.termsHint")}</p>
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
