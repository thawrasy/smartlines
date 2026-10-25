import { useMemo, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";
import { VehicleEditor } from "./Edits";
import type { IconName } from "../../components/icons";

// One fleet for every vehicle (owner's notes, 1173): coaches, buses, minibuses, vans, trucks, tractor heads with their
// trailers, rental cars and taxis, as the company's contract allows. Each vehicle carries its licences, its insurance
// policy with the insurer from the registry, its service plans and its workshop visits; a vehicle in the workshop takes
// no trip and no rental until it is back. The rental desk hands cars over and takes them back with the odometer.

type Use = "COACH" | "CITY_BUS" | "MINIBUS" | "VAN" | "TRUCK" | "TRACTOR" | "RENTAL_CAR" | "TAXI";
interface Options { lines: string[]; uses: Use[]; trailer_types: string[]; rental_classes: { code: string; name: string }[];
  rental_branches: { id: number; name: string }[] }
interface Unit { uid: string; fleet_use: string; plate_no: string; make: string | null; model: string | null; manufacture_year: number | null;
  colour: string | null; fuel_type: string | null; passenger_seats: number | null; odometer_km: number | null; status: string;
  next_expiry: string | null; insured_until: string | null; insurer: string | null; service_due: boolean | null; trailer_plate: string | null }
interface Trailer { uid: string; plate_no: string; trailer_type: string; payload_kg: number; axles: number; status: string;
  next_expiry: string | null; insured_until: string | null; head_plate: string | null }
interface Insurer { uid: string; name_en: string; name_ar: string }
interface Model { uid: string; name: string; name_ar?: string | null; vehicle_class: string; trims?: { uid: string; name: string; fuel: string }[] }
interface Make { uid: string; name_en: string; name_ar: string; models: Model[] }

const BUS: Use[] = ["COACH", "CITY_BUS", "MINIBUS", "VAN"];
const CLASS_OF = (u: Use) => (BUS.includes(u) ? "BUS" : u === "TRUCK" || u === "TRACTOR" ? "TRUCK" : "CAR");
const FUELS = ["PETROL", "DIESEL", "HYBRID", "PLUG_IN_HYBRID", "ELECTRIC", "RANGE_EXTENDER", "GAS"];
const USE_ICON: Record<string, IconName> = { COACH: "directions_bus", CITY_BUS: "directions_bus", MINIBUS: "airport_shuttle", VAN: "airport_shuttle",
  TRUCK: "local_shipping", TRACTOR: "local_shipping", RENTAL_CAR: "car_rental", TAXI: "local_taxi", OTHER: "directions_car" };

export function CarrierFleet() {
  const { t, date } = useI18n();
  const opts = useLoad((signal) => api.get<Options>("/api/fleet/options", undefined, { signal }));
  const units = useLoad((signal) => api.get<{ vehicles: Unit[]; trailers: Trailer[] }>("/api/fleet/units", undefined, { signal }));
  const [filter, setFilter] = useState<string>("ALL");
  const [adding, setAdding] = useState(false);
  const [addingTrailer, setAddingTrailer] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [tab, setTab] = useState<"fleet" | "rentals">("fleet");
  const [q, setQ] = useState("");
  const [limit, setLimit] = useState(50);
  const lines = opts.data?.lines ?? [];
  return (
    <div className="stack">
      <PageHead title={t("fl.title")} sub={t("fl.sub")}>
        {opts.data && opts.data.uses.length > 0 && <button className="btn" onClick={() => setAdding(true)}><Icon name="add" />{t("fl.add")}</button>}
        {lines.includes("TRUCK") && <button className="btn tonal" onClick={() => setAddingTrailer(true)}><Icon name="rv_hookup" />{t("fl.addTrailer")}</button>}
      </PageHead>
      {lines.length > 0 && <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
        <span className="small muted">{t("fl.contract")}:</span>
        {lines.map((l) => <span key={l} className="chip">{t(`fl.line.${l}`)}</span>)}
      </div>}
      {lines.includes("RENTAL") && <div className="row" role="tablist" style={{ gap: 8 }}>
        {(["fleet", "rentals"] as const).map((k) => <button key={k} role="tab" aria-selected={tab === k}
          className={`btn small ${tab === k ? "" : "tonal"}`} onClick={() => setTab(k)}>{t(`fl.tab.${k}`)}</button>)}
      </div>}
      {tab === "rentals" ? <RentalDesk /> : <Loaded state={units}>{({ vehicles, trailers }) => {
        const counts: Record<string, number> = {};
        vehicles.forEach((v) => { counts[v.fleet_use] = (counts[v.fleet_use] ?? 0) + 1; });
        const term = q.trim().toLowerCase();
        const matching = (filter === "ALL" ? vehicles : filter === "TRAILERS" ? [] : vehicles.filter((v) => v.fleet_use === filter))
          .filter((v) => !term || `${v.plate_no} ${v.make ?? ""} ${v.model ?? ""}`.toLowerCase().includes(term));
        const shown = matching.slice(0, limit);
        return (<>
          <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
            <input className="input" style={{ width: 220, maxWidth: "100%" }} aria-label={t("common.search")} placeholder={t("fl.searchPlate")}
                   value={q} onChange={(e) => { setQ(e.target.value); setLimit(50); }} />
            <button className={`btn small ${filter === "ALL" ? "" : "tonal"}`} onClick={() => { setFilter("ALL"); setLimit(50); }}>{t("fl.all")} ({vehicles.length})</button>
            {Object.keys(counts).map((u) => <button key={u} className={`btn small ${filter === u ? "" : "tonal"}`} onClick={() => { setFilter(u); setLimit(50); }}>
              <Icon name={USE_ICON[u] ?? "directions_car"} />{t(`fl.use.${u}`)} ({counts[u]})</button>)}
            {trailers.length > 0 && <button className={`btn small ${filter === "TRAILERS" ? "" : "tonal"}`} onClick={() => setFilter("TRAILERS")}>
              <Icon name="rv_hookup" />{t("fl.trailers")} ({trailers.length})</button>}
          </div>
          {filter !== "TRAILERS" && <div className="card">{shown.length === 0 ? <Empty icon="directions_car" title={t("common.noData")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("fl.plate")}</th><th>{t("fl.kind")}</th><th>{t("fl.vehicle")}</th><th>{t("fl.odometer")}</th>
                <th>{t("fl.insurance")}</th><th>{t("fl.nextExpiry")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
              <tbody>{shown.map((v) => (
                <tr key={v.uid}>
                  <td className="ltr"><b>{v.plate_no}</b>{v.trailer_plate && <div className="small muted"><Icon name="rv_hookup" /> {v.trailer_plate}</div>}</td>
                  <td className="small"><Icon name={USE_ICON[v.fleet_use] ?? "directions_car"} /> {t(`fl.use.${v.fleet_use}`)}</td>
                  <td className="small">{[v.make, v.model, v.manufacture_year].filter(Boolean).join(" ") || "—"}
                    {v.colour && <span className="muted"> · {v.colour}</span>}</td>
                  <td className="num">{v.odometer_km != null ? v.odometer_km.toLocaleString("en-US") : "—"}</td>
                  <td className="small">{v.insured_until ? <>{v.insurer ?? ""}<div className="muted">{date(v.insured_until)}</div></> : <span className="chip red">{t("fl.noInsurance")}</span>}</td>
                  <td className="small">{v.next_expiry ? date(v.next_expiry) : "—"}</td>
                  <td><Status value={v.status} />{v.service_due && <div><span className="chip red small">{t("fl.serviceDue")}</span></div>}</td>
                  <td><button className="btn text small" onClick={() => setOpen(v.uid)}><Icon name="open_in_new" />{t("fl.details")}</button></td>
                </tr>))}</tbody>
            </table></div>)}
            {matching.length > shown.length && <div className="row" style={{ justifyContent: "center", marginTop: 12 }}>
              <button className="btn tonal" onClick={() => setLimit(limit + 50)}>{t("fl.more", { shown: shown.length, total: matching.length })}</button></div>}
          </div>}
          {(filter === "ALL" || filter === "TRAILERS") && trailers.length > 0 && <TrailerTable trailers={trailers} onChanged={units.reload} />}
        </>);
      }}</Loaded>}
      {adding && opts.data && <AddVehicle options={opts.data} onClose={() => setAdding(false)} onDone={() => { setAdding(false); units.reload(); }} />}
      {addingTrailer && <AddTrailer onClose={() => setAddingTrailer(false)} onDone={() => { setAddingTrailer(false); units.reload(); }} />}
      {open && <VehicleFile uid={open} trailers={units.data?.trailers ?? []} onClose={() => { setOpen(null); units.reload(); }} />}
    </div>
  );
}

function useInsurers() {
  return useLoad((signal) => api.get<{ insurers: Insurer[] }>("/api/registry/insurers", undefined, { signal }).then((r) => r.insurers));
}

function InsuranceFields({ f, set, insurers }: { f: Record<string, string>; set: (k: string, v: string) => void; insurers: Insurer[] }) {
  const { t, locale } = useI18n();
  return (<div className="grid cols-3">
    <Field label={t("fl.insurer")}><select className="input" value={f.insurer_uid} onChange={(e) => set("insurer_uid", e.target.value)}>
      <option value="">{t("finance.choose")}</option>
      {insurers.map((i) => <option key={i.uid} value={i.uid}>{locale === "ar" ? i.name_ar : i.name_en}</option>)}</select></Field>
    <Field label={t("fl.policyNo")}><input className="input ltr" value={f.policy_no} onChange={(e) => set("policy_no", e.target.value)} /></Field>
    <Field label={t("fl.coverage")}><select className="input" value={f.coverage_type} onChange={(e) => set("coverage_type", e.target.value)}>
      <option value="THIRD_PARTY">{t("fl.cover.THIRD_PARTY")}</option><option value="COMPREHENSIVE">{t("fl.cover.COMPREHENSIVE")}</option></select></Field>
    <Field label={t("fl.issue")}><input className="input ltr" type="date" value={f.issue_date} onChange={(e) => set("issue_date", e.target.value)} /></Field>
    <Field label={t("fl.expiry")}><input className="input ltr" type="date" value={f.expiry_date} onChange={(e) => set("expiry_date", e.target.value)} /></Field>
  </div>);
}

const emptyCover = { insurer_uid: "", policy_no: "", coverage_type: "THIRD_PARTY", issue_date: "", expiry_date: "" };
const coverOk = (f: Record<string, string>) => f.insurer_uid && f.policy_no.length >= 3 && f.issue_date && f.expiry_date;
const num = (v: string) => (v.trim() ? Number(v) : null);

function AddVehicle({ options, onClose, onDone }: { options: Options; onClose: () => void; onDone: () => void }) {
  const { t, locale } = useI18n();
  const toast = useToast();
  const insurers = useInsurers();
  const catalog = useLoad((signal) => api.get<{ makes: Make[] }>("/api/vehicle-models", undefined, { signal }).then((r) => r.makes));
  const layouts = useLoad((signal) => api.get<{ layouts: { uid: string; name: string; total_seats: number }[] }>("/api/carrier/seat-layouts", undefined, { signal }).then((r) => r.layouts));
  const [use, setUse] = useState<Use | null>(options.uses.length === 1 ? options.uses[0] : null);
  const [f, setF] = useState<Record<string, string>>({ plate_no: "", plate_country: "SY", chassis_no: "", machine_no: "", make_uid: "", model_uid: "",
    trim_uid: "", manufacture_year: "", colour: "", fuel_type: "", odometer_km: "", seat_layout_uid: "", passenger_seats: "", cargo_capacity_kg: "",
    gvw_kg: "", tare_kg: "", axle_config: "", rental_class: "", home_branch_id: "", taxi_licence_no: "", taxi_licence_expiry: "" });
  const [cover, setCover] = useState<Record<string, string>>(emptyCover);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const makes = useMemo(() => use ? (catalog.data ?? []).map((k) => ({ ...k, models: k.models.filter((m) => m.vehicle_class === CLASS_OF(use)) }))
    .filter((k) => k.models.length) : [], [catalog.data, use]);
  const make = makes.find((k) => k.uid === f.make_uid);
  const model = make?.models.find((m) => m.uid === f.model_uid);
  const save = async () => {
    if (!use) return;
    setBusy(true); setError(null);
    try {
      await api.post("/api/fleet/vehicles", {
        fleet_use: use, plate_no: f.plate_no, plate_country: f.plate_country || "SY", chassis_no: f.chassis_no, machine_no: f.machine_no || null,
        model_uid: f.model_uid || null, trim_uid: f.trim_uid || null, manufacture_year: num(f.manufacture_year), colour: f.colour || null,
        fuel_type: f.fuel_type || null, odometer_km: num(f.odometer_km), seat_layout_uid: f.seat_layout_uid || null, passenger_seats: num(f.passenger_seats),
        cargo_capacity_kg: num(f.cargo_capacity_kg), gvw_kg: num(f.gvw_kg), tare_kg: num(f.tare_kg), axle_config: f.axle_config || null,
        rental_class: f.rental_class || null, home_branch_id: num(f.home_branch_id), taxi_licence_no: f.taxi_licence_no || null,
        taxi_licence_expiry: f.taxi_licence_expiry || null, insurance: cover });
      toast(t("common.saved")); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const input = (k: string, label: string, ltr = true, type = "text") => (
    <Field label={label}><input className={`input${ltr ? " ltr" : ""}`} type={type} value={f[k]} onChange={(e) => set(k, e.target.value)} /></Field>);
  return (
    <Modal title={use ? `${t("fl.add")} · ${t(`fl.use.${use}`)}` : t("fl.add")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             {use && <button className="btn" disabled={busy || f.plate_no.length < 3 || f.chassis_no.length < 5 || !coverOk(cover)} onClick={save}>{t("common.save")}</button>}</>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div><div className="small muted" style={{ marginBottom: 6 }}>{t("fl.pickKind")}</div>
          <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>{options.uses.map((u) => (
            <button key={u} type="button" className={`btn ${use === u ? "" : "outlined"}`} aria-pressed={use === u}
                    onClick={() => { setUse(u); set("make_uid", ""); set("model_uid", ""); }}>
              <Icon name={USE_ICON[u]} />{t(`fl.use.${u}`)}</button>))}</div></div>
        {use && <>
          <h4>{t("fl.identity")}</h4>
          <div className="grid cols-3">
            {input("plate_no", t("fl.plate"))}{input("plate_country", t("fl.plateCountry"))}{input("chassis_no", t("fl.chassis"))}
            {input("machine_no", t("fl.engineNo"))}
            <Field label={t("fl.make")}><select className="input" value={f.make_uid} onChange={(e) => { set("make_uid", e.target.value); set("model_uid", ""); set("trim_uid", ""); }}>
              <option value="">{t("finance.choose")}</option>{makes.map((k) => <option key={k.uid} value={k.uid}>{locale === "ar" ? k.name_ar : k.name_en}</option>)}</select></Field>
            <Field label={t("fl.model")}><select className="input" value={f.model_uid} disabled={!make} onChange={(e) => { set("model_uid", e.target.value); set("trim_uid", ""); }}>
              <option value="">{t("finance.choose")}</option>{(make?.models ?? []).map((m) => <option key={m.uid} value={m.uid}>{m.name}{m.name_ar ? ` · ${m.name_ar}` : ""}</option>)}</select></Field>
            <Field label={t("fl.trim")}><select className="input" value={f.trim_uid} disabled={!model?.trims?.length} onChange={(e) => set("trim_uid", e.target.value)}>
              <option value="">—</option>{(model?.trims ?? []).map((x) => <option key={x.uid} value={x.uid}>{x.name} · {t(`vm.fuels.${x.fuel}`)}</option>)}</select></Field>
            {input("manufacture_year", t("fl.year"))}{input("colour", t("fl.colour"), false)}
            <Field label={t("vm.fuel")}><select className="input" value={f.fuel_type} onChange={(e) => set("fuel_type", e.target.value)}>
              <option value="">—</option>{FUELS.map((x) => <option key={x} value={x}>{t(`vm.fuels.${x}`)}</option>)}</select></Field>
            {input("odometer_km", t("fl.odometer"))}
          </div>
          <h4>{t("fl.capacity")}</h4>
          <div className="grid cols-3">
            {BUS.includes(use) && <Field label={t("layout.title")}><select className="input" value={f.seat_layout_uid} onChange={(e) => set("seat_layout_uid", e.target.value)}>
              <option value="">{t("finance.choose")}</option>{(layouts.data ?? []).map((l) => <option key={l.uid} value={l.uid}>{l.name} ({l.total_seats})</option>)}</select></Field>}
            {CLASS_OF(use) === "CAR" && input("passenger_seats", t("fl.seats"))}
            {CLASS_OF(use) === "TRUCK" && <>{input("cargo_capacity_kg", t("fl.payload"))}{input("gvw_kg", t("fl.gvw"))}{input("tare_kg", t("fl.tare"))}
              {input("axle_config", t("fl.axles"))}</>}
            {use === "RENTAL_CAR" && <>
              <Field label={t("fl.rentalClass")}><select className="input" value={f.rental_class} onChange={(e) => set("rental_class", e.target.value)}>
                <option value="">{t("finance.choose")}</option>{options.rental_classes.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select></Field>
              <Field label={t("fl.branch")}><select className="input" value={f.home_branch_id} onChange={(e) => set("home_branch_id", e.target.value)}>
                <option value="">—</option>{options.rental_branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field></>}
            {use === "TAXI" && <>{input("taxi_licence_no", t("fl.taxiLicence"))}{input("taxi_licence_expiry", t("fl.expiry"), true, "date")}</>}
          </div>
          <h4>{t("fl.insurance")}</h4>
          <p className="small muted">{t("fl.insuranceHint")}</p>
          <InsuranceFields f={cover} set={(k, v) => setCover((x) => ({ ...x, [k]: v }))} insurers={insurers.data ?? []} />
        </>}
      </div>
    </Modal>
  );
}

function AddTrailer({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const insurers = useInsurers();
  const [f, setF] = useState<Record<string, string>>({ plate_no: "", plate_country: "SY", chassis_no: "", trailer_type: "CURTAIN", payload_kg: "",
    axles: "3", make: "", manufacture_year: "", licence_no: "", licence_issue: "", licence_expiry: "" });
  const [cover, setCover] = useState<Record<string, string>>(emptyCover);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/fleet/trailers", { ...f, chassis_no: f.chassis_no || null, make: f.make || null, payload_kg: Number(f.payload_kg),
        axles: Number(f.axles), manufacture_year: num(f.manufacture_year), insurance: coverOk(cover) ? cover : null });
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const input = (k: string, label: string, type = "text") => (
    <Field label={label}><input className="input ltr" type={type} value={f[k]} onChange={(e) => set(k, e.target.value)} /></Field>);
  return (
    <Modal title={t("fl.addTrailer")} onClose={onClose} wide
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || f.plate_no.length < 3 || !f.payload_kg || !f.licence_no || !f.licence_issue || !f.licence_expiry} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <p className="small muted">{t("fl.trailerHint")}</p>
        <div className="grid cols-3">
          {input("plate_no", t("fl.trailerPlate"))}{input("plate_country", t("fl.plateCountry"))}{input("chassis_no", t("fl.chassis"))}
          <Field label={t("fl.trailerType")}><select className="input" value={f.trailer_type} onChange={(e) => set("trailer_type", e.target.value)}>
            {["FLATBED", "CURTAIN", "REEFER", "TANKER", "CONTAINER_CHASSIS", "LOWBED", "TIPPER", "BOX"].map((x) => <option key={x} value={x}>{t(`fl.tt.${x}`)}</option>)}</select></Field>
          {input("payload_kg", t("fl.payload"))}{input("axles", t("fl.axleCount"))}{input("make", t("fl.make"))}{input("manufacture_year", t("fl.year"))}
        </div>
        <h4>{t("fl.trailerLicence")}</h4>
        <div className="grid cols-3">{input("licence_no", t("fl.licenceNo"))}{input("licence_issue", t("fl.issue"), "date")}{input("licence_expiry", t("fl.expiry"), "date")}</div>
        <h4>{t("fl.insurance")} ({t("common.optional")})</h4>
        <InsuranceFields f={cover} set={(k, v) => setCover((x) => ({ ...x, [k]: v }))} insurers={insurers.data ?? []} />
      </div>
    </Modal>
  );
}

function TrailerTable({ trailers, onChanged }: { trailers: Trailer[]; onChanged: () => void }) {
  const { t, date } = useI18n();
  const toast = useToast();
  const [edit, setEdit] = useState<Trailer | null>(null);
  const [f, setF] = useState({ plate_no: "", reason: "" });
  const [error, setError] = useState<unknown>(null);
  return (
    <div className="card">
      <div className="card-title"><h3><Icon name="rv_hookup" /> {t("fl.trailers")}</h3></div>
      <div className="table-wrap" tabIndex={0}><table className="table">
        <thead><tr><th>{t("fl.trailerPlate")}</th><th>{t("fl.trailerType")}</th><th>{t("fl.payload")}</th><th>{t("fl.pulledBy")}</th>
          <th>{t("fl.insurance")}</th><th>{t("fl.nextExpiry")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
        <tbody>{trailers.map((x) => (
          <tr key={x.uid}><td className="ltr"><b>{x.plate_no}</b></td><td className="small">{t(`fl.tt.${x.trailer_type}`)} · {x.axles} {t("fl.axleShort")}</td>
            <td className="num">{x.payload_kg.toLocaleString("en-US")}</td><td className="ltr small">{x.head_plate ?? "—"}</td>
            <td className="small">{x.insured_until ? date(x.insured_until) : "—"}</td><td className="small">{x.next_expiry ? date(x.next_expiry) : "—"}</td>
            <td><Status value={x.status} /></td>
            <td><button className="btn text small" onClick={() => { setError(null); setEdit(x); setF({ plate_no: x.plate_no, reason: "" }); }}><Icon name="edit" />{t("edit.edit")}</button></td></tr>))}</tbody>
      </table></div>
      {edit && <Modal title={`${t("edit.edit")} · ${edit.plate_no}`} onClose={() => setEdit(null)}
                      actions={<><button className="btn text" onClick={() => setEdit(null)}>{t("common.cancel")}</button>
                        <button className="btn" disabled={f.plate_no === edit.plate_no || f.reason.trim().length < 3} onClick={async () => {
                          try { await api.patch(`/api/fleet/trailers/${edit.uid}`, f); toast(t("common.saved")); setEdit(null); onChanged(); } catch (e) { setError(e); }
                        }}>{t("common.save")}</button></>}>
        <div className="stack"><ErrorBox error={error} />
          <Field label={`${t("fl.trailerPlate")} *`}><input className="input ltr" value={f.plate_no} onChange={(e) => setF({ ...f, plate_no: e.target.value })} /></Field>
          <Field label={t("edit.reasonRequired")} hint={t("edit.regulatedHint")}><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
        </div>
      </Modal>}
    </div>
  );
}

interface FileData {
  vehicle: Unit & { fleet_use: string; plate_country: string; chassis_no: string; vehicle_class: string };
  licences: { uid: string; license_type: string; license_no: string; issuer: string; issue_date: string; expiry_date: string; status: string }[];
  insurance: { uid: string; insurer: string; policy_no: string; coverage_type: string; issue_date: string; expiry_date: string; status: string; source: string; verified_at: string | null }[];
  service_plans: { uid: string; kind: string; every_km: number | null; every_months: number | null; last_km: number | null; last_date: string | null;
    provider: string | null; contract_no: string | null; contract_until: string | null; status: string; next_km: number | null; next_date: string | null; due: boolean }[];
  maintenance: { uid: string; kind: string; workshop: string | null; sent_at: string; odometer_out: number | null; returned_at: string | null;
    odometer_in: number | null; cost: number | null; currency: string | null }[];
  coupling: { id: number; trailer_plate: string; since: string } | null;
  history: { changed_at: string; field: string; old_value: string | null; new_value: string | null; reason: string | null }[];
}

function VehicleFile({ uid, trailers, onClose }: { uid: string; trailers: Trailer[]; onClose: () => void }) {
  const { t, date, dateTime } = useI18n();
  const toast = useToast();
  const insurers = useInsurers();
  const state = useLoad((signal) => api.get<FileData>(`/api/fleet/vehicles/${uid}`, undefined, { signal }), [uid]);
  const [tab, setTab] = useState<"info" | "insurance" | "service" | "workshop" | "trailer">("info");
  const [editing, setEditing] = useState(false);
  const [cover, setCover] = useState<Record<string, string>>(emptyCover);
  const [plan, setPlan] = useState({ kind: "OIL_CHANGE", every_km: "10000", every_months: "6", provider: "", contract_no: "", contract_until: "" });
  const [send, setSend] = useState({ kind: "PERIODIC", plan_uid: "", workshop: "", odometer_km: "", expected_back: "" });
  const [back, setBack] = useState({ odometer_km: "", cost: "" });
  const [trailer, setTrailer] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, done = t("common.saved")) => {
    setBusy(true); setError(null);
    try { await fn(); toast(done); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const v = state.data?.vehicle;
  const tractor = v && (v.fleet_use === "TRACTOR" || v.fleet_use === "TRUCK");
  const open = state.data?.maintenance.find((m) => !m.returned_at);
  const tabs = (["info", "insurance", "service", "workshop", ...(tractor ? ["trailer"] : [])] as const);
  return (
    <Modal title={v ? `${v.plate_no} · ${t(`fl.use.${v.fleet_use}`)}` : t("fl.details")} onClose={onClose} wide
           actions={<button className="btn text" onClick={onClose}>{t("common.close")}</button>}>
      <div className="stack">
        <div className="row" role="tablist" style={{ gap: 6, flexWrap: "wrap" }}>
          {tabs.map((k) => <button key={k} role="tab" aria-selected={tab === k} className={`btn small ${tab === k ? "" : "tonal"}`}
            onClick={() => setTab(k as typeof tab)}>{t(`fl.ftab.${k}`)}</button>)}
        </div>
        <ErrorBox error={error} />
        <Loaded state={state}>{(d) => (<>
          {tab === "info" && <>
            <div className="grid cols-3">
              <Fact label={t("common.status")}><Status value={d.vehicle.status} /></Fact>
              <Fact label={t("fl.vehicle")}>{[d.vehicle.make, d.vehicle.model, d.vehicle.manufacture_year].filter(Boolean).join(" ") || "—"}</Fact>
              <Fact label={t("fl.chassis")}><span className="ltr">{d.vehicle.chassis_no}</span></Fact>
              <Fact label={t("fl.odometer")}>{d.vehicle.odometer_km?.toLocaleString("en-US") ?? "—"}</Fact>
              <Fact label={t("vm.fuel")}>{d.vehicle.fuel_type ? t(`vm.fuels.${d.vehicle.fuel_type}`) : "—"}</Fact>
              <Fact label={t("fl.colour")}>{d.vehicle.colour ?? "—"}</Fact>
            </div>
            <h4>{t("fl.licences")}</h4>
            <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("fl.licenceKind")}</th><th>{t("fl.licenceNo")}</th><th>{t("fl.issuer")}</th><th>{t("fl.expiry")}</th><th>{t("common.status")}</th></tr></thead>
              <tbody>{d.licences.map((l) => <tr key={l.uid}><td>{t(`fl.lic.${l.license_type}`)}</td><td className="ltr">{l.license_no}</td><td className="small">{l.issuer}</td>
                <td className="small">{date(l.expiry_date)}</td><td><Status value={l.status} /></td></tr>)}</tbody></table></div>
            <button className="btn tonal" style={{ alignSelf: "flex-start" }} onClick={() => setEditing(true)}><Icon name="edit" />{t("edit.edit")}</button>
          </>}
          {tab === "insurance" && <>
            {d.insurance.length === 0 ? <Empty icon="shield" title={t("fl.noInsurance")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("fl.insurer")}</th><th>{t("fl.policyNo")}</th><th>{t("fl.coverage")}</th>
                <th>{t("fl.period")}</th><th>{t("fl.checked")}</th></tr></thead>
                <tbody>{d.insurance.map((p) => <tr key={p.uid}><td>{p.insurer}</td><td className="ltr">{p.policy_no}</td><td className="small">{t(`fl.cover.${p.coverage_type}`)}</td>
                  <td className="small">{date(p.issue_date)} → {date(p.expiry_date)}</td>
                  <td className="small">{p.verified_at ? dateTime(p.verified_at) : <span className="muted">{t("fl.notChecked")}</span>}</td></tr>)}</tbody></table></div>)}
            <p className="small muted">{t("fl.verifyLater")}</p>
            <h4>{t("fl.renew")}</h4>
            <InsuranceFields f={cover} set={(k, val) => setCover((x) => ({ ...x, [k]: val }))} insurers={insurers.data ?? []} />
            <button className="btn" style={{ alignSelf: "flex-start" }} disabled={busy || !coverOk(cover)}
              onClick={() => run(() => api.post(`/api/fleet/vehicles/${uid}/insurance`, cover).then(() => setCover(emptyCover)))}>{t("common.save")}</button>
          </>}
          {tab === "service" && <>
            {d.service_plans.length === 0 ? <Empty icon="build" title={t("fl.noPlans")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("fl.planKind")}</th><th>{t("fl.every")}</th><th>{t("fl.last")}</th><th>{t("fl.next")}</th><th>{t("common.status")}</th></tr></thead>
                <tbody>{d.service_plans.map((p) => <tr key={p.uid}>
                  <td>{t(`fl.plan.${p.kind}`)}{p.provider && <div className="small muted">{p.provider} · {p.contract_no}</div>}</td>
                  <td className="small">{[p.every_km ? `${p.every_km.toLocaleString("en-US")} ${t("fl.km")}` : null, p.every_months ? t("fl.months", { n: p.every_months }) : null].filter(Boolean).join(" / ") || "—"}</td>
                  <td className="small">{p.last_km?.toLocaleString("en-US") ?? "—"} · {p.last_date ? date(p.last_date) : "—"}</td>
                  <td className="small">{p.next_km?.toLocaleString("en-US") ?? ""} {p.next_date ? date(p.next_date) : ""}{p.due && <div><span className="chip red small">{t("fl.serviceDue")}</span></div>}</td>
                  <td>{p.status === "ACTIVE" ? <button className="btn text small" disabled={busy} onClick={() => run(() => api.patch(`/api/fleet/service-plans/${p.uid}`, { status: "ENDED" }))}>{t("fl.endPlan")}</button>
                    : <Status value={p.status} />}</td></tr>)}</tbody></table></div>)}
            <h4>{t("fl.addPlan")}</h4>
            <div className="grid cols-3">
              <Field label={t("fl.planKind")}><select className="input" value={plan.kind} onChange={(e) => setPlan({ ...plan, kind: e.target.value })}>
                {["OIL_CHANGE", "PERIODIC", "TYRES", "INSPECTION", "CONTRACT", "OTHER"].map((k) => <option key={k} value={k}>{t(`fl.plan.${k}`)}</option>)}</select></Field>
              <Field label={t("fl.everyKm")}><input className="input ltr" value={plan.every_km} onChange={(e) => setPlan({ ...plan, every_km: e.target.value })} /></Field>
              <Field label={t("fl.everyMonths")}><input className="input ltr" value={plan.every_months} onChange={(e) => setPlan({ ...plan, every_months: e.target.value })} /></Field>
              {plan.kind === "CONTRACT" && <>
                <Field label={t("fl.provider")}><input className="input" value={plan.provider} onChange={(e) => setPlan({ ...plan, provider: e.target.value })} /></Field>
                <Field label={t("fl.contractNo")}><input className="input ltr" value={plan.contract_no} onChange={(e) => setPlan({ ...plan, contract_no: e.target.value })} /></Field>
                <Field label={t("fl.contractUntil")}><input className="input ltr" type="date" value={plan.contract_until} onChange={(e) => setPlan({ ...plan, contract_until: e.target.value })} /></Field></>}
            </div>
            <button className="btn" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={() => run(() => api.post(`/api/fleet/vehicles/${uid}/service-plans`, {
              kind: plan.kind, every_km: num(plan.every_km), every_months: num(plan.every_months), provider: plan.provider || null,
              contract_no: plan.contract_no || null, contract_until: plan.contract_until || null }))}><Icon name="add" />{t("fl.addPlan")}</button>
          </>}
          {tab === "workshop" && <>
            {open ? <div className="card flat"><b><Icon name="build" /> {t("fl.inWorkshop", { since: dateTime(open.sent_at) })}</b>
              <p className="small muted">{t("fl.inWorkshopHint")}</p>
              <div className="grid cols-3">
                <Field label={t("fl.odometer")}><input className="input ltr" value={back.odometer_km} onChange={(e) => setBack({ ...back, odometer_km: e.target.value })} /></Field>
                <Field label={t("fl.cost")}><input className="input ltr" value={back.cost} onChange={(e) => setBack({ ...back, cost: e.target.value })} /></Field>
              </div>
              <button className="btn" disabled={busy} onClick={() => run(() => api.post(`/api/fleet/maintenance/${open.uid}/return`, {
                odometer_km: num(back.odometer_km), cost: num(back.cost) }), t("fl.returned"))}><Icon name="check_circle" />{t("fl.markBack")}</button></div>
              : <div className="card flat"><h4>{t("fl.send")}</h4><p className="small muted">{t("fl.sendHint")}</p>
                <div className="grid cols-3">
                  <Field label={t("fl.visitKind")}><select className="input" value={send.kind} onChange={(e) => setSend({ ...send, kind: e.target.value })}>
                    {["OIL_CHANGE", "PERIODIC", "TYRES", "INSPECTION", "REPAIR", "ACCIDENT", "OTHER"].map((k) => <option key={k} value={k}>{t(`fl.plan.${k}`)}</option>)}</select></Field>
                  <Field label={t("fl.forPlan")}><select className="input" value={send.plan_uid} onChange={(e) => setSend({ ...send, plan_uid: e.target.value })}>
                    <option value="">—</option>{d.service_plans.filter((p) => p.status === "ACTIVE").map((p) => <option key={p.uid} value={p.uid}>{t(`fl.plan.${p.kind}`)}</option>)}</select></Field>
                  <Field label={t("fl.workshop")}><input className="input" value={send.workshop} onChange={(e) => setSend({ ...send, workshop: e.target.value })} /></Field>
                  <Field label={t("fl.odometer")}><input className="input ltr" value={send.odometer_km} onChange={(e) => setSend({ ...send, odometer_km: e.target.value })} /></Field>
                  <Field label={t("fl.expectedBack")}><input className="input ltr" type="date" value={send.expected_back} onChange={(e) => setSend({ ...send, expected_back: e.target.value })} /></Field>
                </div>
                <button className="btn" disabled={busy} onClick={() => run(() => api.post(`/api/fleet/vehicles/${uid}/maintenance`, {
                  kind: send.kind, plan_uid: send.plan_uid || null, workshop: send.workshop || null, odometer_km: num(send.odometer_km),
                  expected_back: send.expected_back || null }), t("fl.sent"))}><Icon name="build" />{t("fl.sendNow")}</button></div>}
            <h4>{t("fl.visits")}</h4>
            {d.maintenance.length === 0 ? <Empty icon="history" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table"><thead><tr><th>{t("fl.visitKind")}</th><th>{t("fl.workshop")}</th><th>{t("fl.sentAt")}</th><th>{t("fl.backAt")}</th><th>{t("fl.odometer")}</th><th>{t("fl.cost")}</th></tr></thead>
                <tbody>{d.maintenance.map((m) => <tr key={m.uid}><td>{t(`fl.plan.${m.kind}`)}</td><td className="small">{m.workshop ?? "—"}</td><td className="small">{dateTime(m.sent_at)}</td>
                  <td className="small">{m.returned_at ? dateTime(m.returned_at) : <span className="chip red small">{t("fl.inside")}</span>}</td>
                  <td className="num small">{m.odometer_out ?? "—"} → {m.odometer_in ?? "—"}</td><td className="num small">{m.cost?.toLocaleString("en-US") ?? "—"}</td></tr>)}</tbody></table></div>)}
          </>}
          {tab === "trailer" && <>
            {d.coupling ? <div className="card flat"><b><Icon name="rv_hookup" /> {t("fl.pulling", { plate: d.coupling.trailer_plate })}</b>
              <div className="small muted">{t("fl.since")} {dateTime(d.coupling.since)}</div>
              <button className="btn tonal" disabled={busy} onClick={() => run(() => api.post(`/api/fleet/couplings/${d.coupling!.id}/end`))}>{t("fl.uncouple")}</button></div>
              : <div className="card flat"><p className="small muted">{t("fl.coupleHint")}</p>
                <Field label={t("fl.trailer")}><select className="input" value={trailer} onChange={(e) => setTrailer(e.target.value)}>
                  <option value="">{t("finance.choose")}</option>{trailers.filter((x) => !x.head_plate && x.status === "ACTIVE").map((x) => <option key={x.uid} value={x.uid}>{x.plate_no} · {t(`fl.tt.${x.trailer_type}`)}</option>)}</select></Field>
                <button className="btn" disabled={busy || !trailer} onClick={() => run(() => api.post("/api/fleet/couplings", { tractor_uid: uid, trailer_uid: trailer }))}><Icon name="link" />{t("fl.couple")}</button></div>}
          </>}
        </>)}</Loaded>
      </div>
      {editing && <VehicleEditor uid={uid} onClose={() => { setEditing(false); state.reload(); }} />}
    </Modal>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return <div><div className="small muted">{label}</div><div>{children}</div></div>;
}

interface Rental { uid: string; rental_class: string; starts_at: string; ends_at: string; quoted_total: number; currency: string; status: string;
  with_driver: boolean; renter: string | null; plate_no: string | null; driver: string | null; unlimited_km: boolean | null;
  km_included_per_day: number | null; extra_km_price: number | null; contract_no: string | null; final_amount: number | null;
  km_out: number | null; km_in: number | null; driven: number | null; allowed: number | null; extra: number | null; extra_charge: number | null }

function RentalDesk() {
  const { t, dateTime, money } = useI18n();
  const toast = useToast();
  const list = useLoad((signal) => api.get<{ rentals: Rental[] }>("/api/fleet/rentals", undefined, { signal }).then((r) => r.rentals));
  const cars = useLoad((signal) => api.get<{ vehicles: Unit[] }>("/api/fleet/units", undefined, { signal }).then((r) => r.vehicles.filter((v) => v.fleet_use === "RENTAL_CAR")));
  const crew = useLoad((signal) => api.get<{ crew: { uid: string; full_name: string; crew_type: string; status: string }[] }>("/api/carrier/crew", undefined, { signal })
    .then((r) => r.crew.filter((c) => c.crew_type === "DRIVER")));
  const [act, setAct] = useState<{ r: Rental; step: "confirm" | "pickup" | "return" } | null>(null);
  const [f, setF] = useState({ vehicle_uid: "", driver_uid: "", odometer_km: "", fuel_level_pct: "100" });
  const [error, setError] = useState<unknown>(null);
  const go = async () => {
    if (!act) return;
    setError(null);
    try {
      const path = `/api/fleet/rentals/${act.r.uid}/${act.step}`;
      const out = act.step === "confirm"
        ? await api.post(path, { vehicle_uid: f.vehicle_uid, driver_uid: f.driver_uid || null })
        : await api.post<{ extra_km?: number; extra_charge?: number }>(path, { odometer_km: Number(f.odometer_km), fuel_level_pct: Number(f.fuel_level_pct) });
      const o = out as { extra_km?: number; extra_charge?: number };
      toast(act.step === "return" && o.extra_km ? t("fl.extraCharged", { km: o.extra_km, amount: money(o.extra_charge ?? 0, true, act.r.currency) }) : t("common.saved"));
      setAct(null); list.reload(); cars.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="card">
      <div className="card-title"><h3><Icon name="car_rental" /> {t("fl.desk")}</h3></div>
      <p className="small muted">{t("fl.deskHint")}</p>
      <Loaded state={list}>{(rows) => rows.length === 0 ? <Empty icon="car_rental" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("fl.renter")}</th><th>{t("fl.period")}</th><th>{t("fl.car")}</th><th>{t("fl.kmRule")}</th><th>{t("fl.distance")}</th><th>{t("fl.amount")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.uid}>
              <td>{r.renter ?? "—"}{r.with_driver && <div className="small"><Icon name="person" /> {r.driver ?? t("fl.withDriver")}</div>}</td>
              <td className="small">{dateTime(r.starts_at)}<div className="muted">{dateTime(r.ends_at)}</div></td>
              <td className="ltr small">{r.plate_no ?? "—"}<div className="muted">{r.rental_class}</div></td>
              <td className="small">{r.unlimited_km ? t("fl.unlimited") : r.km_included_per_day ? t("fl.perDay", { km: r.km_included_per_day, price: money(r.extra_km_price ?? 0, true, r.currency) }) : "—"}</td>
              <td className="small">{r.km_out != null ? `${r.km_out.toLocaleString("en-US")} → ${r.km_in?.toLocaleString("en-US") ?? "…"}` : "—"}
                {r.extra ? <div className="chip red small">+{r.extra} {t("fl.km")}</div> : null}</td>
              <td className="num">{money(r.final_amount ?? r.quoted_total, true, r.currency)}</td>
              <td><Status value={r.status} /></td>
              <td>{(r.status === "PENDING" || r.status === "CONFIRMED") && !r.contract_no &&
                    <button className="btn text small" onClick={() => { setError(null); setF({ ...f, vehicle_uid: "", driver_uid: "" }); setAct({ r, step: "confirm" }); }}>{t("fl.assign")}</button>}
                  {r.status === "CONFIRMED" && r.plate_no && <button className="btn tonal small" onClick={() => { setError(null); setF({ ...f, odometer_km: "" }); setAct({ r, step: "pickup" }); }}>{t("fl.handOver")}</button>}
                  {r.status === "PICKED_UP" && <button className="btn tonal small" onClick={() => { setError(null); setF({ ...f, odometer_km: "" }); setAct({ r, step: "return" }); }}>{t("fl.takeBack")}</button>}</td>
            </tr>))}</tbody>
        </table></div>)}</Loaded>
      {act && <Modal title={t(`fl.step.${act.step}`)} onClose={() => setAct(null)}
                     actions={<><button className="btn text" onClick={() => setAct(null)}>{t("common.cancel")}</button>
                       <button className="btn" disabled={act.step === "confirm" ? !f.vehicle_uid || (act.r.with_driver && !f.driver_uid) : !f.odometer_km} onClick={go}>{t("common.confirm")}</button></>}>
        <div className="stack"><ErrorBox error={error} />
          {act.step === "confirm" ? <>
            <Field label={t("fl.car")}><select className="input" value={f.vehicle_uid} onChange={(e) => setF({ ...f, vehicle_uid: e.target.value })}>
              <option value="">{t("finance.choose")}</option>{(cars.data ?? []).map((c) => <option key={c.uid} value={c.uid} disabled={c.status !== "ACTIVE"}>
                {c.plate_no} · {[c.make, c.model].filter(Boolean).join(" ")}{c.status !== "ACTIVE" ? ` (${t(`status.${c.status}`)})` : ""}</option>)}</select></Field>
            {act.r.with_driver && <Field label={t("fl.driver")}><select className="input" value={f.driver_uid} onChange={(e) => setF({ ...f, driver_uid: e.target.value })}>
              <option value="">{t("finance.choose")}</option>{(crew.data ?? []).map((c) => <option key={c.uid} value={c.uid}>{c.full_name}</option>)}</select></Field>}
          </> : <div className="grid cols-2">
            <Field label={t("fl.odometer")}><input className="input ltr" inputMode="numeric" value={f.odometer_km} onChange={(e) => setF({ ...f, odometer_km: e.target.value })} /></Field>
            <Field label={t("fl.fuelLevel")}><input className="input ltr" inputMode="numeric" value={f.fuel_level_pct} onChange={(e) => setF({ ...f, fuel_level_pct: e.target.value })} /></Field>
          </div>}
        </div>
      </Modal>}
    </div>
  );
}
