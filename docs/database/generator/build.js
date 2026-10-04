// Builds the database design document from ../build/model.json and the rendered ERDs, in the study's styling
// (Arial, headings in #2E74B5, table headers in #1F3A5F with white text, alternating #F2F6FA rows, #B7C3D0 borders).
// Usage: node build.js   (after render.py and trace.py)  ->  ../Masslak_Database_Design_and_ERD_v2.0.docx
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer, AlignmentType,
  HeadingLevel, WidthType, BorderStyle, ShadingType, PageOrientation, PageNumber, PageBreak, LevelFormat, VerticalAlign,
} = require("docx");

const HERE = __dirname;
const model = JSON.parse(fs.readFileSync(path.join(HERE, "..", "build", "model.json"), "utf8"));
const PNG = path.join(HERE, "..", "erd", "png");
const VERSION = "2.0";
const DATE = "4 October 2026";
const FONT = "Arial";
const C = { navy: "1F3A5F", blue: "2E74B5", blue2: "1F4D78", grid: "B7C3D0", alt: "F2F6FA", grey: "595959" };

const T = {};
for (const t of model.tables) T[`${t.schema}.${t.name}`] = t;
const tableCount = model.tables.length;
const colCount = model.tables.reduce((n, t) => n + t.columns.length, 0);
const fkCount = model.tables.reduce((n, t) => n + (t.fks || []).length, 0);
const rlsCount = model.tables.filter((t) => t.rls).length;
const schemas = [...new Set(model.tables.map((t) => t.schema))];

// ------------------------------ building blocks ------------------------------
const run = (text, o = {}) => new TextRun({ text, font: FONT, size: o.size || 22, bold: o.bold, italics: o.italics, color: o.color });
const P = (text, o = {}) => new Paragraph({ spacing: { after: o.after ?? 120, line: 300 }, alignment: o.align, keepNext: o.keepNext,
  children: Array.isArray(text) ? text : [run(text, o)] });
const H = (level, text, o = {}) => new Paragraph({ heading: level, pageBreakBefore: o.pageBreak, keepNext: true,
  children: [new TextRun({ text, font: FONT })] });
const bullet = (text, label) => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 80, line: 290 },
  children: label ? [run(label + ": ", { bold: true }), run(text)] : [run(text)] });
const border = { style: BorderStyle.SINGLE, size: 4, color: C.grid };
const borders = { top: border, bottom: border, left: border, right: border };

function cell(text, width, o = {}) {
  const runs = (Array.isArray(text) ? text : [text]).map((t) => typeof t === "string"
    ? run(t, { size: o.size || 18, bold: o.header || o.bold, color: o.header ? "FFFFFF" : o.color, italics: o.italics }) : t);
  return new TableCell({
    width: { size: width, type: WidthType.DXA }, borders, verticalAlign: VerticalAlign.CENTER,
    shading: { fill: o.header ? C.navy : (o.fill || "FFFFFF"), type: ShadingType.CLEAR, color: "auto" },
    margins: { top: 60, bottom: 60, left: 90, right: 90 },
    children: [new Paragraph({ spacing: { after: 30, line: 260 }, children: runs })],
  });
}
function table(head, rows, widths, o = {}) {
  const total = widths.reduce((a, b) => a + b, 0);
  return new Table({
    width: { size: total, type: WidthType.DXA }, columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, cantSplit: true, children: head.map((h, i) => cell(h, widths[i], { header: true, size: o.size })) }),
      ...rows.map((r, k) => new TableRow({ cantSplit: true,
        children: r.map((v, i) => cell(v, widths[i], { fill: k % 2 ? C.alt : "FFFFFF", size: o.size, bold: o.boldFirst && i === 0 })) })),
    ],
  });
}
const gap = () => new Paragraph({ spacing: { after: 80 }, children: [] });

function pngSize(file) {
  const b = fs.readFileSync(file);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}
function image(file, maxW, maxH) {
  const { w, h } = pngSize(file);
  const s = Math.min(maxW / w, maxH / h);
  return new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 120 },
    children: [new ImageRun({ type: "png", data: fs.readFileSync(file), transformation: { width: Math.round(w * s), height: Math.round(h * s) } })] });
}

const PORTRAIT = { size: { width: 11906, height: 16838 }, margin: { top: 1200, right: 1080, bottom: 1100, left: 1080, header: 708, footer: 708 } };
const LANDSCAPE = { size: { width: 11906, height: 16838, orientation: PageOrientation.LANDSCAPE },
  margin: { top: 1000, right: 1000, bottom: 1000, left: 1000, header: 600, footer: 600 } };
const PW = 9746, LW = 14838;               // usable widths in DXA
const header = new Header({ children: [new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: C.grid, space: 4 } },
  children: [run(`Masslak | Database Design and ERD | Version ${VERSION}`, { size: 16, color: C.grey })] })] });
const footer = new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
  children: [run("Page ", { size: 18, color: C.grey }), new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 18, color: C.grey })] })] });
const section = (props, children) => ({ properties: { page: props }, headers: { default: header }, footers: { default: footer }, children });

const ON_DELETE = { a: "no action", r: "restrict", c: "cascade", n: "set null", d: "set default" };
const FAMILY_NAME = { core: "Core", asset: "Assets and network", trip: "Trips and operations", money: "Money", booking: "Booking",
  security: "Security", service: "Service" };

// ------------------------------ front matter ------------------------------
const front = [];
front.push(new Paragraph({ spacing: { before: 2400, after: 200 }, alignment: AlignmentType.CENTER,
  children: [new TextRun({ text: "Masslak", font: FONT, size: 72, bold: true, color: C.navy })] }));
front.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 },
  children: [new TextRun({ text: "Travel Booking Platform for Bus, Rail and Freight Transport", font: FONT, size: 32, bold: true, color: C.navy })] }));
front.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 },
  children: [new TextRun({ text: "Database Design and Entity-Relationship Diagrams", font: FONT, size: 30, bold: true, color: C.blue })] }));
front.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 1200 },
  children: [run(`Complete relational model of the Analysis and Design Study v2.6: ${tableCount} tables, ${fkCount} relationships`, { color: "7F7F7F" })] }));
front.push(table(["Item", "Details"], [
  ["Version", `${VERSION} (complete model of study v2.6, replacing the Phase 1 data model 1.0)`],
  ["Date", DATE],
  ["Basis", "Analysis and Design Study v2.6 (English) and the Use Case and Data Flow Diagrams v1.0"],
  ["Scope", `${schemas.length} schemas, ${tableCount} tables, ${colCount} columns, ${fkCount} foreign keys; all phases 1 to 15`],
  ["Engine", "PostgreSQL 16 with row-level security; schema files db/schema/000 to 1029"],
  ["Status", "Built and verified: fresh build and upgrade identical, 111 automated checks passing"],
  ["Website", "masslak.com"],
], [2800, 6946]));

const toc = [H(HeadingLevel.HEADING_1, "Contents", { pageBreak: true })];
const tocLines = ["1. Introduction", "2. Database architecture", "3. Design rules", "4. Security model in the database",
  "5. Data stores of the data flow diagrams", "6. Entity-relationship diagrams by module",
  ...model.groups.map((g, i) => `      6.${i + 1} ${g[0]} ${g[1]}`), "7. Table definitions", "8. Traceability to the study", "9. Verification",
  "Appendix A: Feature flags", "Appendix B: Generalizations and naming decisions"];
for (const l of tocLines) toc.push(P(l, { after: 40, size: 20 }));

// ------------------------------ 1. introduction ------------------------------
const intro = [H(HeadingLevel.HEADING_1, "1. Introduction", { pageBreak: true }),
  H(HeadingLevel.HEADING_2, "1.1 Purpose"),
  P("This document is the database design of the Masslak platform. It redevelops the data model so that every entity and relationship "
    + "of the Analysis and Design Study v2.6 has a table, keys and constraints in the database, and it draws the relationships of each module "
    + "as an entity-relationship diagram in the colours of the study."),
  H(HeadingLevel.HEADING_2, "1.2 Sources and scope"),
  bullet("the Analysis and Design Study v2.6 (English), including appendix D (additional phases 13 to 15);", "Study"),
  bullet("the Use Case and Data Flow Diagrams v1.0, whose data stores D1 to D17 are mapped to tables in chapter 5;", "Diagrams"),
  bullet("the PostgreSQL schema in db/schema, built and tested; every diagram and table definition here is generated from the built database, "
    + "so the document cannot drift from the schema.", "Database"),
  P("The model covers the core of Phase 1 and every later phase: shuttle and approved lines, shipping, international trips and the border manifest, "
    + "government integration, tracking and stations, trucks and transit, intermediary platforms, rail, taxi, car rental, and the additional phases "
    + "13 to 15. Modules of later phases are built now and stay disabled behind feature flags until their phase starts (study 2.8, decision D-6)."),
  H(HeadingLevel.HEADING_2, "1.3 Notation"),
  P("Each diagram shows one module. A box is a table: the coloured band and header follow the module's colour family from the study's figure 4.1; "
    + "rows list the primary key (PK), the foreign keys (FK), unique keys (UQ) and the main attributes, with required columns in bold. The number "
    + "of remaining columns is given at the bottom of the box; every column is listed in chapter 7. Dashed grey boxes are tables of other modules."),
  image(path.join(PNG, "legend.png"), 620, 260),
  P("Lines use crow's foot notation: the crow's foot with a circle at the child means zero or many; two bars at the parent mean exactly one "
    + "(the foreign key is required); a bar and a circle mean zero or one (the foreign key is optional). A bar and a circle at the child mean the "
    + "foreign key is also unique (one to one). Links that record who performed an action (created_by, approved_by...) and links to currencies, "
    + "countries, files and encryption keys are not drawn, for readability; they are listed in chapter 7."),
];

// ------------------------------ 2. architecture ------------------------------
const famOf = { iam: "core", ref: "core", sys: "core", net: "asset", fleet: "asset", ship: "asset", ops: "trip", ctr: "trip", rail: "trip",
  taxi: "trip", rent: "trip", frt: "trip", sales: "booking", pricing: "money", fin: "money", acct: "money", bill: "money", crm: "service",
  ptn: "service", sec: "security", brd: "security", gov: "security", audit: "security" };
const schemaInfo = {
  iam: ["Identity, parties, users, roles, devices and API access", "1"], ref: ["Reference data, locales, files and extensible lists", "1"],
  sys: ["Settings, feature flags, outbox and webhooks", "1"], net: ["Stations, routes, carrier codes, lines, corridors and geofences", "1, 2, 7"],
  fleet: ["Vehicles, seats, crews, licences, trucks and trailers", "1, 8"], ops: ["Trips, inventory, tracking, incidents, shuttle rides", "1, 2, 7"],
  sales: ["Bookings, tickets, channels, subscriptions and travel documents", "1, 2, 4, 9"], pricing: ["Fares, taxes, commissions, campaigns and loyalty", "1"],
  fin: ["Wallets, ledger, payments, allocation, settlement and float", "1"], acct: ["Books, e-invoicing, tax profiles and integration", "1"],
  bill: ["Carrier subscriptions, metering and platform invoices", "1"], crm: ["Cases, notifications, AI assistant and contact center", "1"],
  gov: ["Policy authority, obligations and data protection", "1"], sec: ["Security, compliance hub and government adapters", "1, 5"],
  audit: ["Append-only login, activity, data-access and change logs", "1"], ptn: ["Fuel stations, rest stops and maintenance partners", "later (14.11)"],
  ship: ["Shipments, parcels, network, delivery and partner integration", "3"], frt: ["Freight, containers and transit trucking", "8, 15"],
  brd: ["Border manifest gateway", "4, 6"], ctr: ["Contracted transport for schools, universities and staff", "14"], rail: ["Rail extension", "10"],
  taxi: ["Taxis within and between cities", "11"], rent: ["Car rental platform", "12"],
};
const order = ["iam", "ref", "sys", "net", "fleet", "ops", "sales", "pricing", "fin", "acct", "bill", "crm", "gov", "sec", "audit", "ptn", "ship",
  "frt", "brd", "ctr", "rail", "taxi", "rent"];
const perSchema = (s) => model.tables.filter((t) => t.schema === s);
const arch = [H(HeadingLevel.HEADING_1, "2. Database architecture", { pageBreak: true }),
  P(`The database has ${schemas.length} schemas, one per module, each with its own privileges. The overview groups them into the seven families of the `
    + "study's figure 4.1, with the same colours."),
  image(path.join(PNG, "E00_overview.png"), 640, 440),
  H(HeadingLevel.HEADING_2, "2.1 Schemas"),
  table(["Schema", "Contents", "Tables", "Foreign keys", "Phase"],
    order.map((s) => [s, schemaInfo[s][0], String(perSchema(s).length), String(perSchema(s).reduce((n, t) => n + (t.fks || []).length, 0)), schemaInfo[s][1]]),
    [1100, 4846, 1100, 1300, 1400], { boldFirst: true }),
  gap(),
  H(HeadingLevel.HEADING_2, "2.2 Relationships between modules"),
  P("Modules depend on the core and never the other way round: a later-phase module references parties, companies, stations, trips, vehicles "
    + "and wallets, while no core table references a later-phase module. The table counts the foreign keys from each module to the others."),
];
{
  const cross = {};
  for (const t of model.tables) for (const f of t.fks || []) {
    const ps = f.ref.split(".")[0];
    if (ps === t.schema) continue;
    (cross[t.schema] ||= {})[ps] = (cross[t.schema][ps] || 0) + 1;
  }
  arch.push(table(["Module", "References (number of foreign keys)"],
    order.filter((s) => cross[s]).map((s) => [s, Object.entries(cross[s]).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(", ")]),
    [1300, 8446], { boldFirst: true }));
}

// ------------------------------ 3. design rules ------------------------------
const rules = [H(HeadingLevel.HEADING_1, "3. Design rules", { pageBreak: true }),
  H(HeadingLevel.HEADING_2, "3.1 Keys, types and naming"),
  table(["Rule", "Applied as"], [
    ["Names", "English, lower case with underscores; one schema per module; tables in the singular (study 29.1)"],
    ["Primary keys", "bigint identity for relationships; a public uuid (uid) for interfaces and links, so sequential numbers are never exposed"],
    ["Composite keys", "for pure association and child tables: (route_id, seq), (trip_id, seq), (contract_id, party_id)"],
    ["Amounts", "bigint in the currency's minor unit, never floating point; every amount carries its currency (char(3) foreign key)"],
    ["Time", "timestamptz in UTC; periods as tstzrange or daterange so overlaps can be prevented by the database"],
    ["Statuses", "text with a CHECK list; adding a status changes a constraint, not the table"],
    ["Extensible lists", "reference tables (ref.trip_type, ref.party_role_type, ref.vehicle_class, ref.station_subtype, ref.cargo_category) with foreign keys"],
    ["Flexible data", "jsonb only for snapshots, terms and configurable fields, never in place of columns"],
    ["Personal data", "identity, document and visa numbers encrypted (bytea) with a blind index and the key reference; card and phone numbers hashed"],
  ], [2400, 7346], { boldFirst: true }),
  gap(),
  H(HeadingLevel.HEADING_2, "3.2 Relationship rules"),
  bullet("Every relationship is a declared foreign key; the only exception is the high-volume position table ops.geo_event, which skips them for insert speed.", "Declared"),
  bullet("CASCADE only for children that cannot exist without the parent (route stops, invoice lines, manifest persons); everything else is NO ACTION, so history is never deleted by accident.", "Delete rules"),
  bullet("A required relationship has a NOT NULL foreign key; an optional one is nullable; one to one is a unique foreign key or a shared primary key (iam.company, fleet.truck_unit, brd.border_point).", "Cardinality"),
  bullet("Many to many relationships are association tables with a composite key: role_permission, call_agent_skill, leg_container, rental_booking_addon.", "Many to many"),
  bullet("Extensions share the parent's primary key: a company is a party, a truck unit is a vehicle, a border point is a station, a rental car is a vehicle.", "Extensions"),
  bullet("Alternative parents are nullable foreign keys with a CHECK such as num_nonnulls(trip_id, load_id, route_id) = 1.", "Exclusive arcs"),
  H(HeadingLevel.HEADING_2, "3.3 Integrity enforced by the database"),
  table(["Mechanism", "Examples"], [
    ["Exclusion constraints", "a vehicle, trailer, driver or lease cannot overlap in time; one active contract per partner and period; no double rental of a car"],
    ["Partial unique indexes", "one open shuttle ride per user; one active subscription per company; one active line version; one accepted bid per request"],
    ["Four-eyes checks", "approved_by <> created_by on agreements, entry rules, contracts and override policies"],
    ["Append-only tables", "ledger, tracking and crossing events, boarding, inspections, custody transfers, manifest responses: trigger plus revoked UPDATE and DELETE"],
    ["Domain triggers", "crossing points and border points must be BORDER stations; licence dates locked; e-invoices locked after submission"],
    ["Format checks", "ISO 6346 container numbers, UN numbers, station and line codes, mod-11 check digits"],
  ], [2600, 7146], { boldFirst: true }),
];

// ------------------------------ 4. security ------------------------------
const policyKinds = [
  ["Tenant", "rows of one company: visible to the platform and to that company only", "fleet.trailer, bill.usage_event, ship.load"],
  ["Parent", "a child inherits the visibility of its parent row", "ship.parcel, brd.manifest_person, rent.rental_contract"],
  ["Trip", "operational rows of a trip: the trip's company only, even though published trips are public", "ops.tracking_state, brd.manifest"],
  ["Catalog", "everyone reads, only the platform writes", "net.line, ship.service_product, sales.entry_rule"],
  ["Split", "public read, company or platform write", "net.timetable_template, rent.rental_rate"],
  ["Owner", "the passenger's own rows (party or user)", "ops.shuttle_ride, pricing.reward_voucher, ptn.partner_order"],
  ["Platform", "treasury, regulator links and contact-center data", "fin.float_account, sec.authority_alert, crm.call_qa"],
  ["Shared parties", "both sides of a relationship: carrier and client, seller and buyer, shipper and leg carriers", "ctr.service_contract, ship.capacity_booking, ship.shipment"],
];
const security = [H(HeadingLevel.HEADING_1, "4. Security model in the database", { pageBreak: true }),
  P(`Row-level security is enabled on ${rlsCount} of the ${tableCount} tables, including every table of the new modules. The application connects `
    + "as a role that does not own the tables, so the policies always apply; without a request context no private row is visible."),
  table(["Policy", "Rule", "Examples"], policyKinds, [1700, 4646, 3400], { boldFirst: true }),
  gap(),
  P("Where a policy must look into another table that is itself protected (a shipment seen by the carrier of one of its legs, a partner's staff, "
    + "a channel's members, a taxi shift), a small SECURITY DEFINER function performs the lookup so policies never call each other in a loop. "
    + "Silent authority flags in manifest responses are never visible to the carrier (study 16.12)."),
];

// ------------------------------ 5. data stores ------------------------------
const stores = [H(HeadingLevel.HEADING_1, "5. Data stores of the data flow diagrams", { pageBreak: true }),
  P("The data flow diagrams v1.0 group the platform's data into stores D1 to D17. Each store is implemented by the tables below; the diagram "
    + "column points to the ERD in chapter 6."),
  table(["Store", "Name", "Diagrams", "Tables"], model.stores.map(([id, name, groups, extra]) => {
    const tabs = [...groups.flatMap((g) => model.groups.find((x) => x[0] === g)[5]), ...extra];
    return [id, name, groups.join(", ") || "-", [...new Set(tabs)].join(", ")];
  }), [800, 1900, 1300, 5746], { size: 16, boldFirst: true }),
  gap(),
  P("The stores added by the study after v1.0 of the diagrams (approved lines, shipping network, freight, border manifest, billing, service "
    + "partners, contracted transport, rail, taxi and car rental) are listed with their diagrams in chapter 6."),
];

// ------------------------------ 6. ERD chapter ------------------------------
const erdSections = [];
model.groups.forEach((g, i) => {
  const [gid, title, secs, fam, desc, tabs] = g;
  const file = path.join(PNG, `${gid}.png`);
  const { w, h } = pngSize(file);
  const land = w / h > 1.05;
  const width = land ? LW : PW;
  const children = [];
  if (i === 0) children.push(H(HeadingLevel.HEADING_1, "6. Entity-relationship diagrams by module"));
  children.push(H(HeadingLevel.HEADING_2, `6.${i + 1} ${gid} ${title}`));
  children.push(P([run(`Study: ${secs}  ·  Family: ${FAMILY_NAME[fam]}  ·  ${tabs.length} tables`, { size: 18, color: C.grey })], { after: 60 }));
  children.push(P(desc, { after: 100 }));
  children.push(land ? image(file, 960, 520) : image(file, 640, 760));
  const rels = [];
  for (const full of tabs) for (const f of T[full].fks || []) {
    rels.push([`${full}.${f.cols.join(", ")}`, f.ref, f.unique ? "one to one" : "many to one", f.required ? "required" : "optional", ON_DELETE[f.on_delete]]);
  }
  children.push(H(HeadingLevel.HEADING_3, `Relationships of ${gid} (${rels.length})`));
  const ws = land ? [5200, 3600, 2200, 1900, 1938] : [3500, 2500, 1350, 1150, 1246];
  children.push(table(["Child (foreign key)", "Parent", "Cardinality", "Child side", "On delete"], rels, ws, { size: 16 }));
  erdSections.push(section(land ? LANDSCAPE : PORTRAIT, children));
});

// ------------------------------ 7. table definitions ------------------------------
const defs = [H(HeadingLevel.HEADING_1, "7. Table definitions"),
  P(`All ${tableCount} tables with every column, grouped by diagram. Key: PK primary key, FK foreign key (with the parent), UQ unique; `
    + "Null shows whether the column accepts empty values."),
];
model.groups.forEach((g) => {
  defs.push(H(HeadingLevel.HEADING_2, `${g[0]} ${g[1]}`));
  for (const full of g[5]) {
    const t = T[full];
    const pk = new Set(t.pk || []);
    const fkOf = {};
    for (const f of t.fks || []) if (f.cols.length === 1) fkOf[f.cols[0]] = f.ref;
    const uq = new Set((t.unique || []).filter((u) => u.length === 1).map((u) => u[0]));
    defs.push(H(HeadingLevel.HEADING_3, full));
    if (t.comment) defs.push(P(t.comment, { size: 20, after: 80 }));
    defs.push(table(["Column", "Type", "Key", "Null", "Default"], t.columns.map((c) => [
      c.name, c.type.replace("timestamp with time zone", "timestamptz"),
      [pk.has(c.name) ? "PK" : "", fkOf[c.name] ? `FK ${fkOf[c.name]}` : "", uq.has(c.name) ? "UQ" : ""].filter(Boolean).join(" "),
      c.notnull ? "no" : "yes", (c.default || "").length > 34 ? c.default.slice(0, 33) + "…" : (c.default || ""),
    ]), [2500, 1900, 2700, 650, 1996], { size: 16 }));
    const notes = [];
    const multiUq = (t.unique || []).filter((u) => u.length > 1);
    if (multiUq.length) notes.push(`Unique: ${multiUq.map((u) => "(" + u.join(", ") + ")").join("; ")}`);
    const checks = (t.checks || []).filter((c) => !/^CHECK \(\(?\w+ (IS NOT NULL|>=? 0)\)?\)$/.test(c));
    if (checks.length) notes.push(`Constraints: ${checks.slice(0, 6).map((c) => c.length > 150 ? c.slice(0, 149) + "…" : c).join("; ")}${checks.length > 6 ? `; and ${checks.length - 6} more` : ""}`);
    if ((t.indexes || []).length) notes.push(`Indexes: ${t.indexes.map((x) => x.replace(/^CREATE (UNIQUE )?INDEX (\w+) ON \S+ USING btree /, (m, u, n) => `${n}${u ? " (unique)" : ""} `)).slice(0, 4).join("; ")}`);
    notes.push(`Row-level security: ${t.rls ? (t.policies || []).join(", ") || "enabled" : "not enabled (platform tables)"}`);
    if ((t.triggers || []).length) notes.push(`Triggers: ${t.triggers.join(", ")}`);
    for (const n of notes) defs.push(P(n, { size: 16, after: 30, color: C.grey }));
    defs.push(gap());
  }
});

// ------------------------------ 8. traceability, 9. verification, appendices ------------------------------
const trace = [H(HeadingLevel.HEADING_1, "8. Traceability to the study", { pageBreak: true }),
  P(`Every entity the study defines (the entity tables of sections 4 to 16 and appendix D, the reserved entities of 4.10 and the new entities of `
    + `21.1 and 21.2) is implemented. ${model.trace.length} study rows map to the tables below; none is left without a table.`),
  table(["Study", "Entity in the study", "Database tables", "Note"], model.trace.map((r) => [
    r.section.length > 14 ? r.heading.slice(0, 26) : r.section, r.entity, r.tables.join(", "), r.note]), [1400, 2500, 3600, 2246], { size: 16 }),
];
const verify = [H(HeadingLevel.HEADING_1, "9. Verification", { pageBreak: true }),
  table(["Check", "Result"], [
    ["Fresh build (db/build.sh)", `all schema files apply in order; ${tableCount} tables, ${fkCount} foreign keys`],
    ["Upgrade (db/upgrade.sh)", "a database of the previous release upgrades to a schema identical to a fresh build (pg_dump compared)"],
    ["Idempotence", "every new file runs twice without error"],
    ["Automated tests (db/tests/run.sh)", "111 checks passing, 24 of them on the new model: isolation of shipments, bids, partners, manifests; "
      + "exclusion and uniqueness rules; append-only tables; four-eyes approvals; feature flags off"],
    ["Coverage", "every table of the new modules has row-level security, a policy and grants (checked by the tests)"],
    ["Documents", "this document, db/DATA_DICTIONARY.md and db/ERD.md are generated from the built database"],
  ], [3200, 6546], { boldFirst: true }),
];
const flags = [H(HeadingLevel.HEADING_1, "Appendix A: Feature flags", { pageBreak: true }),
  P("Modules of later phases are switched on by the platform in sys.setting (key features), without a schema change."),
  table(["Flag", "Module", "Schemas and tables"], [
    ["international, gov_integration", "International trips, government integration", "brd, sec.gov_adapter_config, sales.ticket_doc"],
    ["cargo", "Shipping (phase 3)", "ship"], ["approved_lines", "Approved lines and tariffs (4.15)", "net.line*"],
    ["shuttle_rides, shuttle_subscriptions", "Shuttle rides and passes", "ops.shuttle_ride, sales.subscription*"],
    ["carrier_billing", "Carrier subscriptions", "bill"], ["service_partners, loyalty_partners", "Partners and loyalty partners", "ptn, pricing.loyalty_partner"],
    ["freight", "Trucks and transit (phase 8)", "frt, fleet.truck_unit, fleet.trailer"], ["border_manifest", "Border manifest gateway", "brd"],
    ["intermediary_platforms", "Channels (phase 9)", "sales.channel_*"], ["accounting_ops", "Accounting operations", "acct.sales_invoice, cash boxes"],
    ["contact_center", "Contact center", "crm.call*"], ["gov_adapters", "Government adapters (phase 5)", "sec.gov_adapter_config, sec.verification_job"],
    ["transit_passengers, contract_transport", "Phases 13 and 14", "ops crossing tables, ctr"], ["rail, taxi, car_rental", "Phases 10 to 12", "rail, taxi, rent"],
  ], [3000, 3200, 3546], { boldFirst: true }),
];
const gens = [H(HeadingLevel.HEADING_1, "Appendix B: Generalizations and naming decisions"),
  table(["Study", "Database", "Reason"], [
    ["cargo_assignment, cargo_booking, shipment_event (9.4)", "ship.shipment_leg, ship.capacity_booking, ship.tracking_event", "generalized by the study itself in 9.9"],
    ["trip_position (7.8)", "ops.geo_event", "one partitioned position table for every tracked trip"],
    ["company_profile (4.2)", "iam.company", "1:1 with the party, sharing its key"],
    ["driver_profile, host_profile (4.3)", "fleet.crew_profile with fleet.license_record", "licence dates are locked records (4.18)"],
    ["price_snapshot (4.6)", "sales.booking.price_breakdown and rules_version", "the snapshot lives with the booking"],
    ["line_fare_table (7.13)", "net.line_fare", "merged with line_fare: one row model for pair, band, flat and distance fares"],
    ["approved_by[] (4.15)", "net.line_version_approval", "one row per approver instead of an array, so each approval has a key"],
    ["items of partner_order", "ptn.partner_order_item", "order lines normalized"],
    ["agent, queue, skill (7.11)", "crm.call_agent, crm.call_queue, crm.call_skill and their links", "names prefixed to stay clear in the crm schema"],
    ["name_ar, name_en", "one English name plus ref.translation", "localization belongs to the interface (database policy)"],
  ], [3200, 3400, 3146], { size: 17 }),
];

// ------------------------------ assemble ------------------------------
const doc = new Document({
  creator: "Masslak", title: `Masslak: Database Design and ERD (Version ${VERSION})`,
  styles: {
    default: { document: { run: { font: FONT, size: 22 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 32, bold: true, color: C.blue, font: FONT }, paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, color: C.blue, font: FONT }, paragraph: { spacing: { before: 200, after: 120 }, outlineLevel: 1 } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 22, bold: true, color: C.blue2, font: FONT }, paragraph: { spacing: { before: 160, after: 80 }, outlineLevel: 2 } },
    ],
  },
  numbering: { config: [{ reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] }] },
  sections: [
    section(PORTRAIT, [...front, ...toc, ...intro, ...arch, ...rules, ...security, ...stores]),
    ...erdSections,
    section(PORTRAIT, [...defs, ...trace, ...verify, ...flags, ...gens]),
  ],
});
const out = path.join(HERE, "..", `Masslak_Database_Design_and_ERD_v${VERSION}.docx`);
Packer.toBuffer(doc).then((b) => { fs.writeFileSync(out, b); console.log("written", out, (b.length / 1e6).toFixed(1), "MB"); });
