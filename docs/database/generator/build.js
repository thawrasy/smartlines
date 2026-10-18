// Builds the database design document from ../build/model.json and the rendered ERDs, in the study's styling
// (Arial, headings in #2E74B5, table headers in #1F3A5F with white text, alternating #F2F6FA rows, #B7C3D0 borders).
// Usage: node build.js   (after render.py and trace.py)  ->  ../Masslak_Database_Design_and_ERD_v<VERSION>.docx
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer, AlignmentType,
  HeadingLevel, WidthType, BorderStyle, ShadingType, PageOrientation, PageNumber, PageBreak, LevelFormat, VerticalAlign,
} = require("docx");

const HERE = __dirname;
const model = JSON.parse(fs.readFileSync(path.join(HERE, "..", "build", "model.json"), "utf8"));
const PNG = path.join(HERE, "..", "erd", "png");
// numbers of the verification run that built this document (verification.py), never typed by hand (audit T3-17)
const V = JSON.parse(fs.readFileSync(path.join(HERE, "..", "build", "verification.json"), "utf8"));
const lastFile = V.last_schema_file.split("_")[0];
const VERSION = "3.20";
const DATE = "18 October 2026";
const FONT = "Arial";
const C = { navy: "1F3A5F", blue: "2E74B5", blue2: "1F4D78", grid: "B7C3D0", alt: "F2F6FA", grey: "595959" };

const T = {};
for (const t of model.tables) T[`${t.schema}.${t.name}`] = t;
const tableCount = model.tables.length;
const colCount = model.tables.reduce((n, t) => n + t.columns.length, 0);
const fkCount = model.tables.reduce((n, t) => n + (t.fks || []).length, 0);
const rlsCount = model.tables.filter((t) => t.rls).length;
// project phase of each table (file 1041) and the phases a module spans, in roadmap order
const PH = model.table_phase || {};
const phaseOrder = (model.phases || []).map((p) => p.code);
const spread = (tabs) => phaseOrder.map((c) => [c, tabs.filter((t) => PH[t] === c).length]).filter(([, n]) => n)
  .map(([c, n]) => `${c}: ${n}`).join(", ");
const schemas = [...new Set(model.tables.map((t) => t.schema))];
const allFks = model.tables.flatMap((t) => (t.fks || []).map((f) => ({ ...f, table: `${t.schema}.${t.name}` })));
const ACTOR = /(_by|_by_user_id)$|^(actor_id|reviewer_id|proposer_id|approver_id|second_approver|by_user_id|scorer_user_id)$/;
const indexClass = (f) => f.indexed ? "indexed" : (f.ref.startsWith("ref.") && f.ref !== "ref.file_object") ? "lookup"
  : (f.ref === "iam.app_user" && ACTOR.test(f.cols[0])) ? "actor" : "missing";
const idxCount = (k) => allFks.filter((f) => indexClass(f) === k).length;
const cascadeCount = allFks.filter((f) => f.on_delete === "c").length;
const noFk = model.tables.flatMap((t) => t.columns.filter((c) => /^(Polymorphic|External|No FK):/.test(c.comment || ""))
  .map((c) => ({ table: `${t.schema}.${t.name}`, col: c.name, kind: c.comment.split(":")[0], why: c.comment.slice(c.comment.indexOf(":") + 1).trim() })));

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
  children: [run(`Complete relational model of the Analysis and Design Study v3.0: ${tableCount} tables, ${fkCount} relationships`, { color: "7F7F7F" })] }));
front.push(table(["Item", "Details"], [
  ["Version", `${VERSION} (the database after schema file ${lastFile}; a dead delivery names its destination and owner, the chapters of earlier versions are marked as historical records, after the independent reviewer's eighth round; its figures and verification come from the commit of the fourth delivery to the independent reviewer, the commit CI built the evidence pack from; replaces version 3.19)`],
  ["Date", DATE],
  ["Basis", "Analysis and Design Study v3.0 (English), the Use Case and Data Flow Diagrams v1.0, the Database Architecture Review v1.0, the Strategic Database Review and its relationship audit register, the Third-Party Technical Audit, the Technical Audit of design document 3.7, its re-audit of 3.8 and follow-up of 3.9, the architecture review of 3.9, the expert review and code review of October 2026, and the three reviews of release 1.47.0 with the owner's five decisions, the use case review of October 2026 and the owner's decisions that followed it, and the owner's requests of October 2026 up to truck transport (study 3.8), and the systems review of study 3.8 of October 2026, and the four evaluation reports of October 2026 (TEM, GP, GIMI, MANU) with the owner's decisions on them, and the independent review of the first three deliveries (18 October 2026)"],
  ["Scope", `${schemas.length} schemas, ${tableCount} tables, ${colCount} columns, ${fkCount} foreign keys; all phases 1 to 15`],
  ["Application", "Python 3.12 with FastAPI, asyncpg and Pydantic (backend/app); the website in React 19 with TypeScript and Vite (frontend); the apps in React Native with Expo (mobile); all in the same repository as this schema"],
  ["Engine", `PostgreSQL ${V.postgres} with row-level security on every table; PostGIS ${V.postgis} in schema gis; ${V.schema_files} schema files, db/schema/000 to ${lastFile}`],
  ["Status", `Built and verified at commit ${V.source_commit} (migration ${V.migration}, schema SHA-256 ${V.schema_sha256.slice(0, 16)}): fresh build and upgrade identical, ${V.db_checks} database checks and ${V.api_tests} API tests passing, every foreign key indexed or exempt by rule`],
  ["Website", "masslak.com"],
], [2800, 6946]));

const toc = [H(HeadingLevel.HEADING_1, "Contents", { pageBreak: true })];
const tocLines = ["Changes in version 3.20", "Changes in version 3.19", "Changes in version 3.18", "Changes in version 3.17", "Changes in version 3.16", "Changes in version 3.15", "Changes in version 3.14", "Changes in version 3.13", "Changes in version 3.12", "Changes in version 3.11", "Changes in version 3.10", "Changes in version 3.9", "Changes in version 3.8", "Changes in version 3.7", "Changes in version 3.6", "Changes in version 3.5", "Changes in version 3.4", "Changes in version 3.3", "Changes in version 3.2", "Changes in version 3.1", "Changes in version 3.0", "1. Introduction", "2. Database architecture", "3. Design rules", "4. Security model in the database",
  "5. Data stores of the data flow diagrams", "6. Entity-relationship diagrams by module",
  ...model.groups.map((g, i) => `      6.${i + 1} ${g[0]} ${g[1]}`), `      6.${model.groups.length + 1} Focus diagrams: rules that span modules`,
  "7. Table definitions", "8. Traceability to the study", "9. Verification",
  "Appendix A: Feature flags", "Appendix B: Generalizations and naming decisions", "Appendix C: References without a foreign key"];
for (const l of tocLines) toc.push(P(l, { after: 40, size: 20 }));

// ------------------------------ changes in 3.9 ------------------------------
const changes39 = [H(HeadingLevel.HEADING_2, "c. The remaining items of the audit (file 1047)"),
  P("The remaining items of the third-party technical audit (schema file 1047_audit_operations.sql, migration 1.29.0; the application "
    + "tools and runbooks are listed in docs/database/THIRD_PARTY_AUDIT.md and docs/operations/RUNBOOKS.md)."),
  bullet("Every schema change is logged in audit.ddl_event (append-only); a grant, policy, function, trigger or row-level security change made "
    + "outside a migration raises security.ddl_change through the outbox. The audit logs are exported as chained, checksummed batches for "
    + "storage with object lock.", "Schema changes (R-09)"),
  bullet("Every JSONB column is registered with its kind and version (sys.json_contract); rule and shape columns are checked on every write "
    + "against their contract, and price and terms snapshots are frozen once written.", "JSONB (R-08)"),
  bullet("gov.v_lifecycle_matrix gives every dataset its retention, erasure method, copies and backup expiry; delivered events, webhook "
    + "deliveries and old notifications are purged when their retention ends, unless a legal hold stops it.", "Lifecycle (R-11)"),
  bullet("sys.v_policy_matrix lists every policy by actor scope and command; no private table accepts writes unconditionally.", "Permissions (R-05)"),
  bullet("A write sweep tried to hand a row of each company to another company in every table with a company column. It found three paths "
    + "(file owner, typed document reference, session company), now closed: typed reference columns are rebuilt on every update, a file "
    + "belongs to a company its writer acts for, and a session acts only for a company its user belongs to.", "Isolation (R-01)"),
  bullet("Data keys can be stored wrapped and opened by a key service at start-up (envelope encryption).", "Keys (R-10)"),
];

// ------------------------------ changes in 3.8 ------------------------------
const changes38 = [H(HeadingLevel.HEADING_2, "b. Hardening after the third-party technical audit (file 1046)"),
  P("A third-party technical audit reviewed version 3.6 and recommended hardening within the current design. Each finding was checked "
    + "against the built database (docs/database/THIRD_PARTY_AUDIT.md); the owner approved the database fixes, carried by schema file "
    + "1046_audit_hardening.sql (migration 1.28.0)."),
  bullet("Passengers' and family members' phone numbers are encrypted; a person's contact lives only on their account; reporting and audit "
    + "roles lose the contact columns and the change log masks them. This corrects the earlier statement that phone numbers were hashed.", "Contact data (R-04)"),
  bullet("A company sits on a company or entity party; a person only for an individual owner-driver.", "Company party (R-06)"),
  bullet("Every (type, id) reference is registered with its targets, owner and reason (sys.polymorphic_reference); a weekly sweep records "
    + "references to missing rows and raises an alert through the outbox.", "Orphans (R-03)"),
  bullet("Every table of a switched phase is closed in the database by a restrictive policy tied to its phase's switches, not only by the "
    + "application. The gate exposed two phase-map corrections: tracking positions and alerts belong to release 1B, the PostGIS reference "
    + "table to 1A.", "Phase gate (R-14)"),
  bullet("School transport comes before the last phase; electronic reporting of violations waits for the government's e-government "
    + "infrastructure and moves to Phase 5.", "Owner decisions"),
  P("Schema-level two-way dependencies (21, frozen by test H-07) differ from phase-level dependencies, of which there are none backwards: "
    + "the earlier wording is clarified accordingly. db/tools/audit_pack.sh builds the evidence pack for the second phase of the audit."),
];

// ------------------------------ changes in 3.20 (the independent reviewer's eighth round) ------------------------------
const changes3_20 = [H(HeadingLevel.HEADING_1, "Changes in version 3.20", { pageBreak: true }),
  P(`Version 3.20 describes the database after schema file ${lastFile}. The independent reviewer's eighth round (90.5 of 100) read `
    + "two figures of the chapter on version 3.3 (445 tables under row-level security, 188 database checks) as the present database. "
    + "They are that version's figures; the chapter did not say so. Each chapter on an earlier version now opens with a line that marks "
    + "it as a historical record, and db/tools/check_delivery.py refuses a delivery in which a figure that differs from the evidence "
    + "pack stands outside such a chapter without naming the schema file, commit or version it was measured at."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1138 and 1139"),
  table(["Object", "What it does"], [
    ["sys.dead_delivery_metrics()", "One series per partner endpoint with a delivery that gave up in the last 7 days, labelled with the endpoint, its host (never the URL path or query, which can hold a token), the API client and company that own it and the event types; and dead outbox events per event type. Executable by the application and read-only roles, not by PUBLIC."],
    ["Alert WebhookEndpointDead", "Names the client and company to tell; RUNBOOKS.md section 33 says who tells the partner, who retries and who approves a retry of a money or authority event."],
  ], [3200, 6546], { boldFirst: true }),
  P("The database checks \"Dead deliveries (1138)\" prove the series, the host without its path, the event type count, the 7-day "
    + "window and that PUBLIC cannot execute the function (critical control C-16)."),
  P("Schema file 1139 corrects the policy of rpt.report_schedule. The scheduler reads due schedules in the SYSTEM context, which "
    + "counts as the platform, and the policy of file 1034 let the platform see only platform schedules: a company's scheduled report "
    + "was never sent. The test written to measure the scheduler's coverage (round 8, T-07) found it. The SYSTEM context now sees every "
    + "schedule; platform staff still see only the platform's and a company member only their own (checks \"Report schedules (1139)\")."),
  H(HeadingLevel.HEADING_2, "b. Row-level security at 200,530 trips"),
  P("The seat and ticket policies reach their trip through an EXISTS on ops.trip. Measured with python -m loadtest.rls_plans on a scratch "
    + "copy with 200,530 trips and 8.9 million seat rows, through the API's login in a carrier's context: every query that names its "
    + "trips reads ops.trip by its key (Index Scan), the seat map of a trip executes in 1.2 ms; at 530 trips the planner scans the "
    + "visible trips instead. The visibility function kept in reserve is not needed (docs/operations/PERFORMANCE_BASELINE.md, "
    + "evidence/rls_plans_2026-10-18.json); the measurement is repeated on staging with production volume (gate G3)."),
  H(HeadingLevel.HEADING_2, "c. Counts"),
  table(["Measure", "Version 3.19", "Version 3.20"], [
    ["Schema files", "150 (000 to 1137)", `${V.schema_files} (000 to ${lastFile})`],
    ["Tables", "560", String(tableCount)],
    ["Database checks", "962", String(V.db_checks)],
    ["API tests", "773", String(V.api_tests)],
    ["Commit", "6857d7a", V.source_commit.slice(0, 7)],
  ], [3200, 3273, 3273], { boldFirst: true }),
];

// a chapter on an earlier version keeps that version's figures: it says so before anything else (independent review, round 8)
const historical = (chapter, version) => [chapter[0],
  P(`Historical record: this chapter keeps what changed in version ${version} and the figures of that version. They are not the `
    + "current database: the current figures are on the title page and in chapter 9 (verification)."), ...chapter.slice(1)];

// ------------------------------ changes in 3.19 (the independent reviewer's detailed reply) ------------------------------
const changes3_19 = [H(HeadingLevel.HEADING_1, "Changes in version 3.19", { pageBreak: true }),
  P("Version 3.19 described the database after schema file 1137. The independent reviewer asked for a wider prompt-injection "
    + "set for the AI assistant (40 checks or more). Widening it to tool arguments, units, tool names, chained tools and the policy "
    + "itself found four gaps in file 1134, closed by file 1137. No table was added, so the diagrams are unchanged."),
  H(HeadingLevel.HEADING_2, "a. Schema file 1137"),
  table(["Gap in 1134", "What 1137 does"], [
    ["A limit written as text (\"max_amount\": \"100\") was not a number, so it was silently not applied", "Check constraint crm.ai_policy.ai_policy_limits_ck: max_amount a number above zero, max_calls_per_conversation a whole number of zero or more, currency an ISO code of three capital letters"],
    ["An amount of zero or less passed the amount limit", "crm.ai_tool_refusal refuses it with AMOUNT_LIMIT"],
    ["An amount in another currency than the policy's passed it", "When the policy names a currency, an amount in another one, or with none, is refused with AMOUNT_LIMIT"],
    ["A closed conversation could be opened again by clearing ended_at", "Trigger b_ai_conversation_ended on crm.ai_conversation: a conversation once ended stays ended (AI_CONVERSATION_ENDED)"],
    ["A request with no conversation, or one that does not exist, failed on a constraint", "crm.ai_authorize_tool refuses it first with AI_CONVERSATION_UNKNOWN, before anything is recorded"],
  ], [4200, 5546], { boldFirst: true }),
  P("The database checks \"AI tools (1137)\" add 38 cases to the 13 of file 1134, 51 in all; each assumes a model that obeys the "
    + "injected instruction and expects the database to refuse it (critical control C-06)."),
  H(HeadingLevel.HEADING_2, "b. Counts"),
  table(["Measure", "Version 3.18", "Version 3.19"], [
    ["Schema files", "149 (000 to 1136)", "150 (000 to 1137)"],
    ["Tables", "560", "560"],
    ["Database checks", "924", "962"],
    ["API tests", "773", "773"],
    ["Commit", "921369d", "6857d7a"],
  ], [3200, 3273, 3273], { boldFirst: true }),
];

// ------------------------------ changes in 3.18 (the independent review of the first delivery) ------------------------------
const changes3_18 = [H(HeadingLevel.HEADING_1, "Changes in version 3.18", { pageBreak: true }),
  P("Version 3.18 describes the same database as version 3.17 (schema file 1136); no schema file was added. The independent "
    + "reviewer of the first delivery (commit e6dbeb8) found the evidence pack's verification file left by an earlier build (commit "
    + "840b3dc, schema file 1132) beside documents of commit e6dbeb8. The pack now makes that file from its own database and logs, and "
    + "db/tools/check_delivery.py refuses a delivery whose documents do not name the pack's commit and figures "
    + "(docs/operations/INDEPENDENT_REVIEW.md)."),
  P("The figures of version 3.18 and its verification came from commit 921369d, the commit of the second "
    + "delivery: 924 database checks and 773 API tests passing, 149 schema files. Between 3.17 and "
    + "3.18 only the evidence tools, a CI step and documents changed; the database and the server code are the same."),
];

// ------------------------------ changes in 3.17 (the four evaluation reports of October 2026) ------------------------------
const changes3_17 = [H(HeadingLevel.HEADING_1, "Changes in version 3.17", { pageBreak: true }),
  P(`Version 3.17 describes the database after schema file 1136. Since version 3.16 (schema file 1132), four schema files were `
    + "added, 1133 to 1136: two after the systems review of study 3.8 and two the owner approved after the four evaluation reports of "
    + "October 2026 (TEM, GP, GIMI and MANU). The four relationship rules of chapter 3.2 hold; no table was added, so the diagrams are "
    + "unchanged. The figures and the verification of chapter 9 came from commit e6dbeb8b00e1, the commit delivered to the "
    + "independent reviewer with the evidence pack (docs/operations/INDEPENDENT_REVIEW.md)."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1133 to 1136"),
  table(["Schema file", "What it adds"], [
    ["1133_outbox_review_point.sql", "The outbox is partitioned by day since file 1053, so its row estimate is now summed over its partitions (the metric of file 1051 had read zero since); the partitioning point becomes a review point of 8 million rows (setting capacity.outbox_review_rows, alert OutboxReviewDue). No table changes."],
    ["1134_ai_tool_guard.sql", "The AI assistant's tools are authorised by the database whatever the model asks: crm.ai_authorize_tool records each request and allows it only with the assistant switched on, the tool enabled, the traveller's confirmation where required, an open conversation and the tool's limits; a refusal is kept with its reason (new column crm.ai_tool_call.refusal); a row written as allowed by another path is checked the same way by a trigger."],
    ["1135_definer_execute.sql", "No SECURITY DEFINER function is executable by PUBLIC (report MANU): each callable one is granted to the roles that use its schema, then EXECUTE is revoked from PUBLIC; trigger functions need no grant. A later schema file that forgets the revoke fails the database check \"Definer functions (1135)\"."],
    ["1136_step_up.sql", "Step-up authentication (report GP): iam.user_session.mfa_at records when the session last passed its second factor; the setting auth.mfa.step_up_minutes (10 by default, 5 to 60) is how recent it must be before money leaves the platform, access widens, data is exported or API keys are issued (POST /api/auth/mfa/step-up confirms it)."],
  ], [3000, 6746], { boldFirst: true }),
  H(HeadingLevel.HEADING_2, "b. Counts"),
  table(["Measure", "Version 3.16", "Version 3.17"], [
    ["Schema files", "145 (000 to 1132)", "149 (000 to 1136)"],
    ["Tables", "560", "560"],
    ["Columns", "5,920", "5,922"],
    ["Foreign keys", "1,667", "1,667"],
    ["Database checks", "904", "924"],
    ["API tests passed", "758", "773"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.16 (the systems review of study 3.8) ------------------------------
const changes3_16 = [H(HeadingLevel.HEADING_1, "Changes in version 3.16", { pageBreak: true }),
  P(`Version 3.16 describes the same database as version 3.15 (schema file 1132); no schema file was added. It corrects the `
    + "document after the systems review of study 3.8 (October 2026)."),
  bullet(`The table of chapter 2.1 listed 23 of the ${schemas.length} schemas: sch (school transport, 11 tables), rpt (reports, 4) and gis `
    + `(PostGIS reference, 1) were missing, so its rows summed to 544 tables against the ${tableCount} the document states. It now lists `
    + "every schema of the built database with a total row, and the generator stops if a schema has no description.", "1. Schema table"),
  bullet("The cover names the application layer that uses this database: Python 3.12 with FastAPI in the same repository, the website in "
    + "React and the apps in React Native. The study (version 3.9, section 2.9) describes it.", "2. Application layer"),
  bullet("The figures of this document (schemas, tables, columns, foreign keys, checks and tests) are read from the built database and the "
    + "test run (generator/verification.py); none is typed by hand. The readiness register 2.1 quotes them from here.", "3. One source for the figures"),
];

// ------------------------------ changes in 3.15 (the owner's requests of October 2026, up to truck transport) ------------------------------
const changes3_15 = [H(HeadingLevel.HEADING_1, "Changes in version 3.15", { pageBreak: true }),
  P(`Version 3.15 describes the database after schema file 1132. Since version 3.14 (schema file 1112), 20 schema files were added, `
    + "1113 to 1132, each for a request or a decision of the owner in October 2026: the station screens and bays, logos, regular trips, "
    + "company know-your-customer files, trip numbers, journeys, charter, the administrative geography, connections across carriers and "
    + "truck transport of goods and containers. They carry no migration version of their own yet; the next release records them. The four "
    + "relationship rules of chapter 3.2 hold for every new table and column; every new table has row-level security, a project phase "
    + "and a lifecycle, and is in exactly one diagram."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1113 to 1132"),
  table(["Schema file", "What it adds"], [
    ["1113_station_screens_review.sql", "Fixes from the design review of the station screens: the boarding pass and printed ticket carry a fixed signed code, the counter's trip list names the destination and check-in state. No table changes."],
    ["1114_trip_numbers.sql", "The short trip number passengers read (carrier designator and service number, repeated daily) beside the trip reference staff use. No new table."],
    ["1115_station_bays_logos_board.sql", "A company's logo to a specification, set by the platform (iam.company_logo, diagram E01); a carrier's permanent bay at a station, set by its administration (net.station_carrier_bay, diagram E44); the board turns a cancelled trip red."],
    ["1116_carrier_logo_everywhere.sql", "The carrier's logo beside its name wherever it is shown. No table changes."],
    ["1117_trip_schedules.sql", "Regular trips the carrier defines (every day, on days of the week or of the month) under one number: requests with the approval stages in force (ops.schedule_request), each stage's decision (ops.schedule_approval) and the authority staff who decide (sec.authority_member). Diagram E46."],
    ["1118_company_kyc.sql", "The know-your-customer file of each company: the form in versions (iam.kyc_form), the file in versions with its risk and next review (iam.company_kyc), and each review stage's decision (iam.kyc_decision), with encrypted values. Diagram E45."],
    ["1119_trip_rotations.sql", "Four-digit number blocks as a setting, odd outbound and even return, and a regular trip that continues its vehicle's previous leg. No new table."],
    ["1120_station_screens.sql", "Separate departures and arrivals screens, the kinds the platform allows and the screens the station's administration registers (net.station_screen). Diagram E44."],
    ["1121_journeys.sql", "One way, round trip and several places booked together as one journey, direct or with stops, and tourism groups booked by agencies. New columns on sales.booking; no new table."],
    ["1122_seat_limits.sql", "The seats one booking may take as a platform setting (4 by default), raised for a family head. No new table."],
    ["1123_charter.sql", "Carriers hire out a vehicle or a whole scheduled trip, to tourism companies and by special request to travellers: offers (sales.charter_offer), requests priced, paid into escrow and held (sales.charter_request) and the seats taken off sale (sales.charter_seat). Diagram E47."],
    ["1124_admin_geography.sql", "Syria's administrative geography from the United Nations P-code file: each load (ref.geo_source), governorates, districts and sub-districts (ref.admin_area), communities and neighbourhoods with their positions (ref.place). Diagram E48."],
    ["1125_geography_in_use.sql", "Stations record their place by search; a field-survey place proposed by the platform is reviewed by another person; area boundaries. No new table."],
    ["1126_charter_passengers.sql", "The requester names the travellers of blocked seats, who appear on the trip's manifest. No new table."],
    ["1127_place_name_corrections.sql", "Words of the published names the platform writes otherwise (ref.name_correction). Diagram E48."],
    ["1128_charter_deposit_vehicles.sql", "A charter paid as a deposit then the balance, and the vehicles named one by one (sales.charter_vehicle). Diagram E47."],
    ["1129_station_screen_pairing.sql", "A display pairs with a station screen by a short code it shows and a secret only it holds (net.screen_pairing); an alert for a screen no longer seen. Diagram E44."],
    ["1130_connections.sql", "Connections across carriers where no trip runs direct: the platform's change times, each carrier's policy for a missed trip (ops.carrier_connection_policy), the risks accepted on a connection's bookings, and a booking changed to another trip (sales.booking_change). Diagram E46."],
    ["1131_freight_transport.sql", "Truck transport of goods and containers inside Syria, to and from the port, in transit and across borders: shipping lines, bills of lading with house bills and containers (ISO 6346 check digit, declared count, customs release), consignments by route kind with seller, buyer, papers and goods, the truck owners' rates, truck movements with the trailer's length checked, transport invoices per bill, container or consignment, and consignment notes and TCNs issued as frozen snapshots with a hash and a verification code. Diagram E49."],
    ["1132_connection_holds.sql", "A connection's booking missed by all its travellers stays open after its trip is completed, its escrow held, until the carrier's change window ends (sales.connection_hold); released by the worker or ended by a change. Diagram E46."],
  ], [3000, 6746], { boldFirst: true }),
  H(HeadingLevel.HEADING_2, "b. The owner's requests and decisions in the database"),
  bullet("Stations register their screens, bays and displays themselves; carriers keep a permanent bay or take one per trip (files 1115, 1120, 1129).", "1. Station screens"),
  bullet("A regular trip passes the approval stages in force when it was asked, including a government authority where one is named (file 1117).", "2. Regular trips"),
  bullet("Every company on the platform has a versioned KYC file, reviewed in stages and reviewed again by its risk (file 1118).", "3. Know your customer"),
  bullet("Charter is paid into escrow, by deposit and balance, and the carrier is paid when the hire is done (files 1123, 1128).", "4. Charter"),
  bullet("A connection's missed trip stays changeable until the carrier's change window ends, its money held meanwhile (files 1130, 1132).", "5. Connections"),
  bullet("Truck transport keeps its rules in the database: valid container numbers, the bill's count, one active movement per truck and trailer, documents complete before issue and frozen after, a container never invoiced twice (file 1131). Opened by the freight switch.", "6. Truck transport"),
  H(HeadingLevel.HEADING_2, "c. Diagrams and counts"),
  P("The 38 tables added since version 3.14 are placed in five new diagrams and three existing ones: E45 company know-your-customer file, "
    + "E46 regular trips, connections and changed bookings, E47 charter, E48 administrative geography and E49 truck transport; the logo in "
    + "E01 and the station's bays, screens and pairing in E44. The earlier freight tables of phase 8 (requests, bids, contracts) stay in E33."),
  table(["Measure", "Version 3.14", "Version 3.15"], [
    ["Schema files", "125 (000 to 1112)", "145 (000 to 1132)"],
    ["Tables", "522", "560"],
    ["Columns", "5,392", "5,920"],
    ["Foreign keys", "1,514", "1,667"],
    ["Module diagrams", "44", "49"],
    ["Data stores", "D1 to D23", "D1 to D23"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.14 (the use case review, the owner's decisions, boarding stations at work) ------------------------------
const changes3_14 = [H(HeadingLevel.HEADING_1, "Changes in version 3.14", { pageBreak: true }),
  P("Version 3.14 describes the database after schema file 1112. Since version 3.13 (schema file 1099), 13 schema files were added, "
    + "1100 to 1112: the six gaps found when the use cases were checked against the code (tracking alerts, SOS and incidents, a "
    + "carrier's trip cancellation, loyalty points, e-invoices; the sixth, the bulk import tool, needs no schema change), the owner's "
    + "decisions that followed (a cancellation penalty only where regulators impose one, partner redemption under agreements, taxes "
    + "and signing keys on e-invoices, the counter photo kept off), and boarding stations at work: the counter check-in, sales at the "
    + "station counter and the departure board. They carry no migration version of their own yet; the next release records them. The "
    + "four relationship rules of chapter 3.2 hold for every new table and column; every new table has row-level security, a project "
    + "phase and a lifecycle, and is in exactly one diagram."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1100 to 1112"),
  table(["Schema file", "What it adds"], [
    ["1100_tracking_alerts.sql", "The platform opens tracking alerts: a departed trip whose vehicle stays silent past a set time gets one open "
      + "SIGNAL_LOST alert, escalated when the silence lasts; each opening and escalation tells the carrier through the outbox "
      + "(ops.raise_tracking_alerts, run every minute by the worker). Diagram E09."],
    ["1101_sos_incidents.sql", "The apps write SOS and incident reports: sec.raise_sos for the assigned driver or a passenger holding a ticket on "
      + "the trip, ops.report_incident for the driver; each checks who the caller is on the trip, and an SOS tells the carrier's owners and "
      + "the platform's security staff at once."],
    ["1102_trip_cancellation.sql", "A carrier cancels a published trip: every paid booking is cancelled and refunded in full, the platform fee "
      + "included, to whoever paid it; every line of the price allocation is reversed."],
    ["1103_loyalty_earn_redeem.sql", "Loyalty points are earned when a trip is completed and redeemed for wallet credit, each step idempotent "
      + "(pricing.earn_points_for_trip and the redemption functions); points expire after the programme's period."],
    ["1104_einvoice_issuing.sql", "E-invoices are issued for paid bookings by each seller with an active issuing unit, with credit notes for "
      + "refunds; numbers are gapless per unit, each hash chains to the previous document and is signed. Diagram E20."],
    ["1105_station_checkin.sql", "The counter check-in at a boarding station and its boarding pass with the bay (brd.station_checkin), under "
      + "the operating company's BOARDING_PASS right, the check-in window and the carrier's required references; boarding at the bay "
      + "only for a checked-in ticket. Diagram E44."],
    ["1106_cancel_penalty.sql", "A penalty on a carrier that cancels a trip, only when the platform turns it on citing the regulator's "
      + "decision (setting trip.cancel_penalty, off); each charge is recorded once per trip (ops.trip_cancel_penalty). Diagram E08."],
    ["1107_loyalty_agreements.sql", "Points redeemed at partners under agreements the platform records per partner (pricing.loyalty_agreement, "
      + "activated by another person and frozen once used); vouchers honoured by the partner, paid by the platform, and settled by "
      + "statements (pricing.loyalty_settlement and its lines) approved and paid by different people. Diagram E15."],
    ["1108_einvoice_taxes_keys.sql", "Taxes on e-invoices from the platform's tax schemes, rules and bands (exempt, zero, standard, compound, a "
      + "tax on another tax), each line's taxes written once (acct.einvoice_line_tax); the public signing keys named by key id on every "
      + "document (acct.einvoice_signing_key). Diagram E20."],
    ["1109_station_trips_horizon.sql", "The station's list of trips covers its calendar days in the station's time zone. No table changes."],
    ["1110_station_sales.sql", "Tickets sold at a station counter under the carrier's BOOKING right (brd.station_sale), the booking remaining "
      + "the carrier's and the cash owed by the operating company within its limit; station boarding tables join the first release "
      + "(phase 1B). Diagram E44."],
    ["1111_counter_photo_gate.sql", "A fifth photo view role, the station counter at check-in, off; turned on only by an approved change that "
      + "records the legal document number."],
    ["1112_station_board.sql", "The station's public departure board (brd.station_board): departures and arrivals with bays and states, "
      + "without passenger data, only where the platform switched the station's screens on. No table changes."],
  ], [3000, 6746], { boldFirst: true }),
  H(HeadingLevel.HEADING_2, "b. The owner's decisions in the database"),
  bullet("Passengers are always refunded in full; a penalty on the carrier applies only when the platform turns it on with the regulator's "
    + "decision, and is off at launch (file 1106).", "1. Cancellation penalty"),
  bullet("The platform bears the cost of redemption at the prices agreed with each partner (points = amount, and the share the platform "
    + "pays); agreements, statements and payments each need a different person (file 1107).", "2. Partner redemption"),
  bullet("Out of scope, exempt, zero, by band or by product, compound and a tax on another tax are all configured, not coded; a scheme "
    + "applies only once finance approves it (file 1108).", "3. Taxes"),
  bullet("Each document names the key that signed it, so keys can be rotated and old documents still verified (file 1108).", "4. Signing keys"),
  bullet("Station counter sales are part of the first release (file 1110); the counter photo stays off until legal and legislative "
    + "approvals allow it (file 1111).", "5. Boarding stations"),
  H(HeadingLevel.HEADING_2, "c. Diagrams and counts"),
  P("The 8 tables added since version 3.13 are placed in existing diagrams: ops.trip_cancel_penalty in E08, the three loyalty agreement "
    + "and statement tables in E15, the line taxes and signing keys in E20, and the station check-ins and sales in E44, which becomes "
    + "data store D23 with them. The schema brd, which held the border manifests, now also holds station boarding."),
  P("Foreign keys are now drawn and counted once on a partitioned table. Up to version 3.13 the generator also drew and counted the copy "
    + "PostgreSQL keeps of a foreign key on each partition of the table it references (sales.booking has three partitions), so 3.13 "
    + "showed 1,547 foreign keys, 76 of them such copies; counted the same way as now, 3.13 had 1,471. The data dictionary always "
    + "counted each foreign key once."),
  table(["Measure", "Version 3.13", "Version 3.14"], [
    ["Schema files", "112 (000 to 1099)", "125 (000 to 1112)"],
    ["Tables", "514", "522"],
    ["Columns", "5,279", "5,392"],
    ["Foreign keys", "1,471 (1,547 with the partition copies)", "1,514"],
    ["Module diagrams", "44", "44"],
    ["Data stores", "D1 to D22", "D1 to D23"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.13 (the reviews of October 2026, the boarding photo, boarding stations) ------------------------------
const changes3_13 = [H(HeadingLevel.HEADING_1, "Changes in version 3.13", { pageBreak: true }),
  P("Version 3.13 describes the database after schema file 1099. Since version 3.12 (schema file 1079, migration 1.48.0), 20 schema "
    + "files were added, 1080 to 1099: the code reviews and external reports of October 2026 on releases 1.48.0 and 1.49.0, the "
    + "closing of an account, the boarding photo and its policy, and the boarding stations with their operating companies. They carry "
    + "no migration version of their own yet; the next release records them. The four relationship rules of chapter 3.2 hold for "
    + "every new table and column; every new table has row-level security, a project phase and a lifecycle."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1080 to 1099"),
  table(["Schema file", "What it adds"], [
    ["1080_verified_context.sql", "A request context the application's login cannot forge: sys.set_context accepts only a ticket signed with "
      + "an active key (sys.context_key) and fresh by the database clock, and the settings it writes stay locked; the windows that accepted "
      + "unsigned contexts are recorded (sys.context_unsigned_window). Finding C-01. Diagram E42."],
    ["1081_definer_search_path.sql", "Functions that run as their owner search the session's temporary objects last."],
    ["1082_validate_constraints.sql", "Constraints added NOT VALID are validated afterwards (sys.validate_constraints); readiness names any that is not."],
    ["1083_default_partition_batches.sql", "A late partition upkeep moves large periods out of the default partition one period per transaction."],
    ["1084_settings_guard.sql", "The settings the database trusts are protected by the server and change only through the guarded path."],
    ["1085_account_deactivation.sql", "A closed account keeps its data: status DEACTIVATED, every session ended, sign-in refused until it is reactivated."],
    ["1086_boarding_photo.sql", "The boarding photo: at most one encrypted photo per person (iam.party_photo), taken by the person or by the head "
      + "of the family for a member. Diagram E43."],
    ["1087_photo_policy.sql", "Photo rules per market, trip scope and traveller class with their legal basis (iam.photo_rule); a photo on file "
      + "changes only by a request with evidence decided by another person (iam.photo_change_request). Diagram E43."],
    ["1088_photo_evidence_kinds.sql", "The documents accepted as evidence for a photo change, as a platform setting (iam.photo_evidence_kind)."],
    ["1089_photo_policy_approvals.sql", "Changes to the accepted documents and to the identity age rule need two people (iam.photo_policy_change, "
      + "iam.photo_approval)."],
    ["1090_photo_evidence_national.sql", "The documents accepted nationally for a photo change, from the owner's list."],
    ["1091_photo_approval_stages.sql", "The approval stages of a change are a platform setting; the identity age defaults to 18; each data item is "
      + "required or optional by setting (iam.data_requirement)."],
    ["1092_photo_rule_stages.sql", "The approval stages apply to the photo rules: proposal, approval and retirement each pass them."],
    ["1093_photo_rule_retirement_proposer.sql", "The person who proposed a photo rule, gave its final approval or asked for its retirement does not "
      + "approve the retirement."],
    ["1094_photo_feature_switch.sql", "The photo feature is a switch, off at launch, turned on only by a change that names its legal basis and passes "
      + "the stages; a photo is refused while it is off."],
    ["1095_photo_switch_settings.sql", "The stages of the switch are a setting, a third-party check is a choice, and the approval records the legal "
      + "document number when given."],
    ["1096_photo_settings.sql", "Photo settings changed in stages: who sees the photo and when (the traveller on request; the driver, the carrier's "
      + "office and the agent only while the trip is boarding, as set), the date from which a required photo is asked, re-verification and the "
      + "identity provider (none connected)."],
    ["1097_boarding_stations.sql", "Boarding stations: platform settings off or empty at launch; each station's own switch, counter system and "
      + "check-in window (net.station_boarding); counters and bays numbered by the platform; the carrier's agreement and licence references "
      + "(net.operation_reference). Diagram E44."],
    ["1098_boarding_operators.sql", "The rights of station operating companies (net.station_operator_grant): given by a carrier for its trips or by "
      + "the platform for a state-mandated operator, revoked and never changed; net.operator_may decides. Diagram E44."],
    ["1099_station_portal.sql", "The station portal: sessions of portal STATION, the company type STATION_OPERATOR, the role STATION_COUNTER with "
      + "station.counter, and the second factor wherever the carrier portal needs one."],
  ], [3000, 6746], { boldFirst: true }),
  H(HeadingLevel.HEADING_2, "b. The owner's decisions in the database"),
  bullet("The feature is off until a change naming its legal basis passes the approval stages; rules, evidence and settings change only "
    + "through the stages, and every view of a photo is logged (files 1086 to 1096).", "1. Boarding photo"),
  bullet("A closed account keeps its data; only an erasure request removes or anonymises it (file 1085).", "2. Closing an account"),
  bullet("Each station is separate, off until switched on, with its own counter system (the platform's or the station's own); the platform "
    + "numbers counters and bays and never reuses a number (file 1097).", "3. Boarding stations"),
  bullet("An operating company signs in to its own portal and acts only with the rights a carrier or the platform gave it (files 1098, 1099).",
    "4. Operating companies"),
  H(HeadingLevel.HEADING_2, "c. Diagrams"),
  P("Every table is in exactly one module diagram, which the generator checks. The 12 tables added since version 3.12 are placed in E42 "
    + "(context keys) and in two new diagrams: E43 boarding photo and its policy (data stores D21 and D22) and E44 boarding stations and "
    + "operating companies (data stores D18 to D20)."),
  table(["Measure", "Version 3.12", "Version 3.13"], [
    ["Schema files", "92 (000 to 1079)", "112 (000 to 1099)"],
    ["Tables", "502", "514"],
    ["Columns", "5,158", "5,279"],
    ["Foreign keys", "1,516", "1,547"],
    ["Module diagrams", "42", "44 (new: E43 and E44)"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.12 (release 1.48.0) ------------------------------
const changes3_12 = [H(HeadingLevel.HEADING_1, "Changes in version 3.12", { pageBreak: true }),
  P("Version 3.12 describes the database of release 1.48.0. Since version 3.11 (schema file 1053, migration 1.35.0), 26 schema "
    + "files were added, 1054 to 1079 (migrations 1.36.0 to 1.48.0): launch completeness, the payment options the platform switches, "
    + "the expert review of October 2026 (stages B to D), the code review and external reports of October 2026, and the three reviews "
    + "of release 1.47.0 with the owner's five decisions (docs/operations/REVIEW_1_47_RESPONSE.md). The four relationship rules of "
    + "chapter 3.2 hold for every new table and column; every new table has row-level security, a project phase and a lifecycle."),
  H(HeadingLevel.HEADING_2, "a. Schema files 1054 to 1079"),
  table(["Schema file", "Migration", "What it adds"], [
    ["1054_launch_completeness.sql", "1.36.0", "Complaints and claims with service levels and four-eyes approval, trip rating rules, guardians' answers, "
      + "trips generated from templates, and the remaining launch tables given their endpoints."],
    ["1055_ai_phase_gate.sql", "1.36.1", "The contact centre and AI assistant phase stays closed in the database until its threat model and data "
      + "protection impact assessment are approved (launch gate 9)."],
    ["1056_payment_options.sql", "1.37.0", "Ways of paying switched by the platform (fin.payment_method): cash at the counter within a credit limit "
      + "per company (fin.cash_credit_limit), pay later with a pay-by time, cards, instalments and financing providers. Diagram E41."],
    ["1057_review_stage_b.sql", "1.38.0", "Ageing of the cash carriers owe, finance metrics, and freshness limits for reports read from the replica."],
    ["1058_release_manifest.sql", "1.39.0", "The release each database is at: version, commit and hash of the applied schema files (sys.release_manifest); "
      + "an upgrade refuses a record changed by hand. Diagram E42."],
    ["1059_app_delete_grants.sql", "1.39.1", "The application role deletes only from the tables listed with their reason (sys.app_delete_grant). Diagram E42."],
    ["1060_monitoring_detail.sql", "1.39.2", "Lock waits per table, partitions created ahead and rows left in default partitions, for the monitoring."],
    ["1061_markets.sql", "1.40.0", "Markets with their time zone, currency and language (ref.market); platform wallets per currency; days and money "
      + "read in the market of the data. Diagram E03."],
    ["1062_warehouse_publication.sql", "1.41.0", "A publication of facts and dimensions without personal data for the data warehouse, with its "
      + "replication role and slot metrics."],
    ["1063_telemetry.sql", "1.42.0", "One set of trust rules for vehicle positions, graded in batches on the primary when the history lives in the "
      + "separate telemetry database."],
    ["1064_partitioned_bookings.sql", "1.43.0", "Bookings partitioned by ranges of id, their keys unique over all partitions (sales.booking_key); the "
      + "generic conversion sys.partition_by_id. Diagram E11."],
    ["1065_failover.sql", "1.44.0", "Standby figures for automatic failover and the table the failover drill writes to (sys.failover_probe). Diagram E42."],
    ["1066_position_without_vehicle.sql", "1.45.0", "A position without a vehicle is graded again (a regression of 1063 found by the launch gate 4 rehearsal)."],
    ["1067_cargo_capacity.sql", "1.46.0", "Cargo stays within the capacity of the vehicle that carries it: used weight counted from what is loaded, "
      + "overloads refused."],
    ["1068_shared_rate_limits.sql", "1.47.0", "Request limits shared by every API process: sign-in buckets per address and per account identifier, in an "
      + "unlogged table reached only through sec.rate_take (sec.rate_bucket). Diagram E25."],
    ["1069_audit_archive_lag.sql", "1.47.0", "How far the signed audit archive lags behind each audit log, for the metrics and the alert AuditArchiveBehind."],
    ["1070_partition_upkeep_late.sql", "1.47.0", "Partition upkeep that survives running late: the rows of a missing period move out of the default "
      + "partition instead of aborting the upkeep."],
    ["1071_late_provider_payment.sql", "1.47.0", "A provider's confirmation that arrives after the platform stopped waiting is credited to the payer's "
      + "wallet, flagged captured_late."],
    ["1072_trip_rating_privacy.sql", "1.47.0", "Trip ratings readable only by the rater, the rated carrier and the platform."],
    ["1073_signed_notice_dedup.sql", "1.48.0", "A provider's event id is unique among signed notices only; unsigned notices are kept and counted per provider."],
    ["1074_money_boundaries.sql", "1.48.0", "Payments recorded before the provider is called (stages CREATED and PROVIDER_UNKNOWN); refunds held and sent "
      + "once under a fixed reference; fee rules per way of paying, currency, customer and period (fin.fee_rule); the payer of a withdrawal is "
      + "not its approver; the approval matrix of money decisions (fin.approval_policy, approval_level, approval_level_member, approval_request, "
      + "approval_decision). Diagram E41."],
    ["1075_sign_in_and_operations.sql", "1.48.0", "Two-step sign-in by several methods under the platform's policy (sys.setting auth.mfa); message codes "
      + "kept only as keyed hashes for minutes with five tries (iam.mfa_challenge); a boarding names a stop its ticket covers; offline scans "
      + "bounded by the driver's pack download (ops.offline_pack_download); every late partition period created; positions waiting on the "
      + "primary for the telemetry database (ops.position_backlog). Diagrams E02, E08, E09."],
    ["1076_backups_and_durability.sql", "1.48.0", "Each nightly backup's local and off-site copy recorded (sys.backup_run); the age of both and whether "
      + "commits wait for a standby, for the monitoring (zero data loss as a setting); the security console's connections capped. Diagram E42."],
    ["1077_statement_statistics.sql", "1.48.0", "Statement statistics read only through functions that mask literals and never carry bind values."],
    ["1078_manifests_and_parcels.sql", "1.48.0", "Manifests sealed once issued, with signed hashes of a canonical form; parcels booked on a trip's hold with "
      + "carrier tariffs (ship.parcel_tariff) and agreed-price offers (ship.parcel_offer); a guaranteed shipment needs a leg holding capacity. "
      + "Diagram E29."],
    ["1079_lifecycle_coverage.sql", "1.48.0", "Every table has a lifecycle: a dataset of its own or membership of one (gov.dataset_member); "
      + "gov.lifecycle_gaps() must be empty. Diagram E26."],
  ], [2300, 1100, 6346], { boldFirst: true }),
  H(HeadingLevel.HEADING_2, "b. The owner's decisions in the database"),
  bullet("A setting turns zero data loss on or off; when on, every commit waits for a standby, and the database reports whether it does "
    + "for the alerts (file 1076; deploy/durability.sh).", "1. Data loss"),
  bullet("The policy in sys.setting auth.mfa chooses the methods open (authenticator app, text message, WhatsApp; one or more) and the "
    + "portals that must use one, drivers included; codes sent by message live in iam.mfa_challenge as keyed hashes (file 1075).", "2. Second factor"),
  bullet("Parcels are booked on a trip's hold under its lock before the wallet is charged; carriers publish tariffs by weight, volume, "
    + "both, a fixed price or agreement; one database function makes every price (file 1078).", "3. Parcels"),
  bullet("fin.fee_rule sets the provider's fee per way of paying, currency, customer and period, as a percentage, a fixed amount or none; "
    + "the customer pays it by default and sees it before paying (file 1074).", "4. Payment fees"),
  bullet("The approval matrix gives each kind of money decision 0 to 5 levels decided by the holders of a permission or by named people; "
    + "the database refuses a requester deciding, one person deciding two levels, or levels out of order (file 1074).", "5. Approvals"),
  H(HeadingLevel.HEADING_2, "c. Diagrams"),
  P("Every table is in exactly one module diagram, which the generator checks. The 21 tables added since version 3.11 are placed in "
    + "E02 (message codes), E03 (markets), E08 (offline pack downloads), E09 (positions waiting for the telemetry database), E11 "
    + "(booking keys), E25 (shared rate limits), E26 (dataset members) and E29 (parcel tariffs and offers), and in two new diagrams: "
    + "E41 ways of paying, fees and approvals (data store D8) and E42 release, backups and failover records."),
  table(["Measure", "Version 3.11", "Version 3.12"], [
    ["Schema files", "66 (000 to 1053)", "92 (000 to 1079)"],
    ["Tables", "481", "502"],
    ["Columns", "4,954", "5,158"],
    ["Foreign keys", "1,403", "1,516"],
    ["Module diagrams", "40", "42 (new: E41 and E42)"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.11 (ten million operations a day) ------------------------------
const changes3_11 = [H(HeadingLevel.HEADING_1, "Changes in version 3.11", { pageBreak: true }),
  P("The owner set the planning figure at ten million operations a day for the full platform. The load, the data volumes, "
    + "the server sizes and the growth stages are recalculated in docs/operations/CAPACITY_MODEL.md. This version changes the "
    + "database where that volume would otherwise meet a limit (schema files 1052_scale_ten_million.sql and 1053_outbox_partitions.sql, "
    + "migrations 1.34.0 and 1.35.0). Each change was measured, and a populated database at 1.33.0 was upgraded in 5.6 seconds "
    + "with every wallet reconciled before and after."),
  H(HeadingLevel.HEADING_2, "a. Money: no shared hot row"),
  bullet("A wallet that many transactions credit at once (carrier, agency, the platform's fee, tax, escrow and clearing wallets) "
    + "has balance_mode DEFERRED: a posting appends its entry and touches no wallet row; fin.roll_up_balances folds finished "
    + "entries into the stored balance every few seconds; the balance that counts is fin.wallet_balance(id). A debit that "
    + "must stay covered queues only with the other debits of that wallet and checks that balance; holds use fin.adjust_hold. "
    + "Passenger and family wallets stay IMMEDIATE.", "Shared wallets"),
  bullet("Measured with db/tools/wallet_contention_bench.py on one carrier wallet and one clearing wallet: 865 postings a "
    + "second at most before, falling to 688 at 32 clients; 2,654 after, steady at 32 clients, with clean reconciliation.", "Measured"),
  bullet("fin.ledger_entry sits in monthly partitions. fin.close_ledger_days totals every wallet per finished UTC day "
    + "(fin.ledger_day_total, with a running total); nothing is posted into a closed day (LEDGER_DAY_CLOSED); "
    + "fin.reconcile_wallets reads the last running total plus the open days, and fin.verify_ledger_day re-reads a past day. "
    + "fin.wallet_balance_at gives the balance at any moment for statements.", "Ledger"),
  H(HeadingLevel.HEADING_2, "b. Events, positions, audit and connections"),
  bullet("sys.outbox_event sits in daily partitions dropped whole after the retention (sys.drop_outbox_days); a delivery "
    + "keeps the day of its event (outbox_created_at) with its reference; the duplicate pending-queue index is gone; the "
    + "worker claims events in batches, each in its own savepoint.", "Outbox"),
  bullet("ops.vehicle_position keeps the latest accepted position of each vehicle, written once per insert statement of "
    + "positions; apps send positions in batches of up to 120.", "Positions"),
  bullet("A wallet change made only by a posting is not copied to the change log (the entry is the record); updates now keep "
    + "the row key in the log. Audit months older than audit.online_months (13) are dropped once audit.archive_checkpoint shows "
    + "the signed archive covers them.", "Audit"),
  bullet("sys.partition_option holds the storage settings applied to every new partition. PgBouncer in transaction mode "
    + "stands between the API instances and the primary; the full API suite passes through it.", "Storage and pooling"),
];

// ------------------------------ changes in 3.10 (owner decisions and architecture review of 3.9) ------------------------------
const changes3_10 = [H(HeadingLevel.HEADING_1, "Changes in version 3.10", { pageBreak: true }),
  P("Two reviews of version 3.9 led to this version. The auditors' follow-up kept general launch behind nine operational gates, "
    + "and the owner decided the targets and who tests (schema file 1050_owner_decisions.sql, migration 1.32.0). A second firm's "
    + "architecture review raised five risks. Each was checked against the built database; the response keeps what the measurements "
    + "support and declines what would weaken integrity (schema file 1051_architecture_review.sql, migration 1.33.0; "
    + "docs/database/ARCHITECTURE_REVIEW_RESPONSE.md)."),
  H(HeadingLevel.HEADING_2, "a. Owner decisions (file 1050)"),
  bullet("RPO 60 seconds, RTO 30 minutes and the service level objectives are approved and stored as settings (recovery.rpo_seconds, "
    + "recovery.rto_minutes, slo.objectives); the restore drill and monitoring compare their measurements with them.", "Targets"),
  bullet("External auditors and penetration testers get the read-only role EXTERNAL_AUDITOR only through sec.external_access_grant: "
    + "granted by a second person for a named engagement, at most 30 days, never extended, revocable at once, announced through the "
    + "outbox. A trigger on iam.user_role refuses the role without a live grant.", "Reviewer access"),
  bullet("Staging and the penetration test are run by external firms. The staging kit (deploy/staging, docs/operations/STAGING.md), "
    + "the launch gate register (docs/operations/LAUNCH_GATES.md) and the test scope (docs/security/PENETRATION_TEST_SCOPE.md) "
    + "are what they receive.", "Operations"),
  H(HeadingLevel.HEADING_2, "b. Architecture review (file 1051 and the stack)"),
  bullet("The positions table described itself as partitioned monthly, and that comment reached the reviewers through this document. "
    + "The table has used daily partitions, dropped whole after 7 days, since file 1048. The comment is corrected, and a check now "
    + "keeps comments on partitioned tables in step with their partitions.", "Positions"),
  bullet("Reports and scheduled exports read a streaming replica (service db-replica). In production the API and the worker refuse to "
    + "start without one, or when the address given is a primary. Bookings and payments keep their single-transaction guarantee "
    + "with the ledger.", "Reports"),
  bullet("The 21 two-way schema pairs and 20 table cycles are listed with their reasons (db/schema_dependencies.json, "
    + "docs/database/SCHEMA_DEPENDENCIES.md). CI fails on a new pair or a new cycle without a recorded reason.", "Module dependencies"),
  bullet("sys.capacity_metrics() reports table growth, the outbox purge backlog and partitioning point "
    + "(capacity.outbox_partition_rows), and the time spent in each trigger when track_functions is on. Staging turns it on, and "
    + "the load test reports milliseconds per row for the costliest triggers, against a budget of 1 ms (STANDARDS.md).", "Capacity and cost"),
];

// ------------------------------ changes in 3.9 (re-audit of design 3.8) ------------------------------
const changes3_9 = [H(HeadingLevel.HEADING_1, "Changes in version 3.9", { pageBreak: true }),
  P("The auditors re-read version 3.8 without access to the build: 10 findings closed on paper, 6 partly addressed, 4 open or "
    + "deferred, and no general launch before recovery (T3-01) and egress (T3-02) are proven. Schema file 1049_recheck_operations.sql "
    + "(migration 1.31.0), the application and the operations tooling close what the repository can close, and the raw evidence of "
    + "this build is packed for the auditors to re-run (db/tools/evidence_pack.sh; docs/database/DESIGN_AUDIT_T3_RECHECK.md)."),
  H(HeadingLevel.HEADING_2, "a. Outbound connections (T3-02)"),
  P("Version 3.8 described only the transport rule of government endpoints; the controls on partner webhooks existed but were not "
    + "written here. Two layers now stand between the platform and any outside address:"),
  bullet("A webhook URL must be https without credentials; a literal private, loopback, link-local, metadata or reserved address "
    + "(IPv4, IPv6 and IPv4-mapped IPv6) is refused at registration. At every delivery the name is resolved again, every address "
    + "checked, and the connection made to the checked address with the name kept for TLS, so a name that rebinds to an internal "
    + "address is refused. No redirect is followed, the certificate is verified, personal fields are removed unless enabled, and "
    + "each request is signed (HMAC-SHA256 with a timestamp).", "Application"),
  bullet("Every outbound connection (webhooks, payment providers, SMS, SMTP) goes through the egress proxy, and production refuses "
    + "to start without it; the API and worker containers have no route out. The proxy tunnels only ports 443, 465 and 587, "
    + "refuses private, loopback, link-local, metadata and reserved addresses after its own DNS lookup, and allows only "
    + "allowlisted names: the fixed providers, and the partner endpoints the worker writes every minute.", "Egress proxy"),
  P("Tests: 10 application cases (http, credentials, metadata, private, IPv6, IPv4-mapped, rebinding at delivery, redirects), the "
    + "proxy tunnel and its refusals (also against a real Squid), a self-test where every forbidden target answers 403, and a CI "
    + "step proving the containers cannot reach the internet directly."),
  H(HeadingLevel.HEADING_2, "b. Database and application (file 1049)"),
  bullet("sys.ops_metrics() and the job log sys.job_run feed /api/metrics: outbox age, deliveries, partitions, scans, jobs, WAL "
    + "archiving, connections, locks, long transactions, deadlocks, vacuum, wraparound, replica lag, payments and review queues, "
    + "with request counts and latency per route. 24 alert rules proven by promtool unit tests, a dashboard, and SLOs proposed for "
    + "approval (docs/operations/SLO.md).", "Monitoring (T3-16)"),
  bullet("A scheduled report with personal or money columns needs the owner's recorded consent, goes only to named accounts, and "
    + "arrives as a per-recipient link valid 72 hours (rpt.report_delivery keeps only the token hash); every download is counted "
    + "and logged.", "Sensitive reports (T3-05)"),
  bullet("Positions record the registered device of the mobile session; a revoked device or a failed attestation rejects them, and "
    + "attestation (Play Integrity, App Attest) becomes required by configuration (tracking.device_attestation). Violations on "
    + "low-trust evidence are reviewed by a person with violation.review.", "Positions (T3-11)"),
  bullet("Resending a money or authority event to a partner waits for a second person's approval (sys.delivery_retry_request); "
    + "fin.reconcile_payments() checks payments, refunds, provider notices and the ledger every day and alerts on any mismatch.", "Events and money (T3-12)"),
  H(HeadingLevel.HEADING_2, "c. Measured evidence (development environment)"),
  table(["Run", "Result", "Evidence file"], [
    ["Restore drill (T3-01)", "PASS: point-in-time restore exact; server lost without warning: 3.2 s of writes lost, usable in 4.9 s; "
      + "wallets, ledger, orphans, audit seals, schema hash and counts all checked", "restore_drill_2026-10-07.json"],
    ["Migration rehearsal of 1048 (T3-08)", "200,000 rows per table under traffic: 5.2 s, 87 MB WAL, longest exclusive lock 1.98 s, "
      + "traffic p99 3 ms, 0 errors; cause and live-database plan in MIGRATION_PLANS.md", "migration_rehearsal_1048_2026-10-07.json"],
    ["End-to-end load (T3-09)", "booking, payment, refund, tracking and reports at 10 to 50 users: 0 errors, 0 deadlocks; 3,582 "
      + "bookings and refunds reconciled with 0 mismatches", "load_test_full_mix_2026-10-07.json"],
  ], [2400, 5146, 2200], { boldFirst: true }),
  P("These runs prove the mechanisms; the capacity, recovery-time and migration figures for production come from the same tools on "
    + "staging with production-size data, which remains a launch gate together with the monitoring deployment, the audit archive "
    + "account, the ClamAV service and an external penetration test. docs/operations/RELEASE_MAP.md, generated from this database, "
    + "states what each release brings into service: launch scope 1A and 1B, with 92 tables closed until their switch opens."),
];

// ------------------------------ changes in 3.8 (technical audit of design 3.7) ------------------------------
const changes3_8 = [H(HeadingLevel.HEADING_1, "Changes in version 3.8", { pageBreak: true }),
  P("A technical audit reviewed design document 3.7 on paper (findings T3-01 to T3-20). Each finding was checked against the built "
    + "database and the code (docs/database/DESIGN_AUDIT_T3.md). Schema file 1048_design_audit_t3.sql (migration 1.30.0) and the application "
    + "changes close every finding the repository can close; the rest are operational conditions of the launch, listed in the response."),
  bullet("An official signature, a ledger transaction, a family spend and a legal hold now name a real row of a registered kind the moment "
    + "they are written (sys.tg_business_reference); the weekly sweep stays as a net. Signatures are written once and only revoked. The "
    + "registry test now also finds pairs named like doc_type and doc_ref_id, which had escaped it.", "References with legal or financial weight (T3-04)"),
  bullet("Break-glass access has a mandatory expiry (240 minutes at most), an approver other than its user or a declared emergency, an "
    + "incident reference and scope; it alerts when opened, expires without any job (sec.break_glass_active), is closed and flagged for review "
    + "by the upkeep, and cannot be widened, rewritten or deleted. Application roles still hold no superuser or BYPASSRLS.", "Break-glass (T3-03)"),
  bullet("Positions sit in daily partitions dropped whole after the retention, which now has one source: 7 days in the lifecycle matrix (the "
    + "separate setting is gone). Each position carries the device's event id and sequence, device and server times, provider and a mock flag; "
    + "a resent position is dropped, and a trust grade (HIGH, LOW, REJECTED) flags late, out-of-order, inaccurate, network-only, impossible-speed "
    + "and mock positions. A violation built on low-trust positions is confirmed or reported only after a person's review.", "Positions (T3-10, T3-11)"),
  bullet("A regulatory requirement changes only through sys.requirement_change: proposed by a platform user with its measured impact (how "
    + "many vehicles, drivers or companies would fall short), decided by a second one, and applied with its date. A direct change is refused.", "Requirement changes (T3-14)"),
  bullet("Every uploaded file starts in quarantine (scan_status PENDING); the scanner (built-in checks plus ClamAV in production) sets CLEAN, "
    + "REJECTED or QUARANTINED. Only a clean file is downloaded, signed or approved; a verdict is final.", "File quarantine (T3-15)"),
  bullet("Nobody reviews their own access; every sensitive read names a user, an API client or a named service, and a request id.", "Access reviews (T3-19)"),
  bullet("Government endpoints accept only encrypted transports; a city must name its IANA time zone (no Damascus default); every outbox "
    + "event carries a schema version, a correlation id and its sequence within the aggregate (docs/integration/EVENTS.md).", "Endpoints, time zones, events (T3-02, T3-18, T3-12)"),
  bullet("Scheduled reports go only to members of the owner's company (or platform accounts and the platform's own domains), checked again "
    + "at every run; migrations run with lock and statement timeouts; the audit archive's manifests are signed (Ed25519) and verified "
    + "against the tip the custodian records outside the platform; the numbers in this document come from the verification run (section 9).", "Application and operations (T3-05, T3-08, T3-13, T3-17)"),
];

// ------------------------------ changes in 3.7 ------------------------------
const changes37 = [H(HeadingLevel.HEADING_1, "Changes in version 3.7", { pageBreak: true }),
  H(HeadingLevel.HEADING_2, "a. Regulated routes, school transport and PostGIS (files 1043 to 1045)"),
  P("Two requests followed the regulators' review, with the owner's decisions on each open question (schema files "
    + "1043_route_compliance.sql, 1044_school_transport.sql and 1045_postgis.sql, migrations 1.25.0 to 1.27.0; details in "
    + "docs/database/ROUTE_COMPLIANCE_AND_SCHOOL.md)."),
  bullet("Every licence, tracking source and reporting duty a regulator may impose is registered in sys.compliance_requirement with a level "
    + "switched by configuration: OFF, OPTIONAL (collected, never blocking) or REQUIRED (enforced from a date). A new government rule needs "
    + "no release. Licence records now cover any person (school bus attendants) and the school transport, route permit, criminal record, "
    + "first aid and tracking device licences.", "Requirements"),
  bullet("Trips are tracked from the driver's phone first; contracted tracking devices come later, chosen per vehicle (fleet.tracking_device). "
    + "Shuttle vehicles are bound to the approved line of their permit (fleet.line_permit_vehicle), within its validity and vehicle limit; "
    + "every trip carries its route obligation (approved line, transit corridor, private contract or none).", "Shuttle lines"),
  bullet("A deviation warns the driver, then sounds a continuous alarm; the violation keeps its evidence (frozen once reviewed, kept 730 "
    + "days). It is reported to the authorities only when a regulator requires it and only while the vehicle was in service (a running "
    + "trip or passengers on board); the database refuses any other report. Regulator diversions count as part of the route.", "Violations"),
  bullet("School transport is a phase of its own (SCH, schema sch, 11 tables): five kinds of operator under a school transport licence, pupils "
    + "linked to their guardians while minors, four contract kinds, routes with bus, driver and attendant, daily runs and attendance. The "
    + "database refuses to hand a pupil under 12 to anyone but an authorised receiver, and to close a run with a child on board or before "
    + "the empty-bus check.", "School transport"),
  bullet("PostGIS (schema gis) adds generated geography columns with spatial indexes to lines, diversions, corridors, school routes and "
    + "stations; a route binds only with a valid line shape; ops.route_distance_m measures the distance from the binding route.", "PostGIS"),
  P("Route adherence events move to Phase 2 with the shuttle; tracking positions and alerts, which the driver app and the regulator dashboard "
    + "use from the launch, belong to release 1B (part b). "
    + "The binding table lives in schema fleet so that no new two-way dependency between schemas appears (test H-07)."),
];

// ------------------------------ changes in 3.6 ------------------------------
const changes36 = [H(HeadingLevel.HEADING_1, "Changes in version 3.6", { pageBreak: true }),
  P("The owner decided two changes to the phase map (schema file 1042_rollout_decisions.sql, migration 1.24.0):"),
  bullet("The contact center and the AI assistant move to a later phase of their own (CS, 14 tables). Until then support runs on cases: "
    + "complaints arrive by WhatsApp and email during working hours, and a support agent handles them in the system (crm.case, release 1A).", "Support"),
  bullet("The shuttle is a phase of its own, not part of the launch, opened city by city in stages. sys.city_rollout records the stage and "
    + "status of each city; a shuttle line or zone is activated only in a city opened for the shuttle (CITY_NOT_OPEN otherwise).", "Shuttle"),
];

// ------------------------------ changes in 3.5 ------------------------------
const changes35 = [H(HeadingLevel.HEADING_1, "Changes in version 3.5", { pageBreak: true }),
  P("The model is divided by the project phases of the study roadmap (22, appendix D), with Phase 1 split into releases 1A and 1B as "
    + "the architecture review decided. Schema file 1041_project_phases.sql (migration 1.23.0) records the phase of every table in "
    + "sys.table_phase; the database stays one database built from one chain of files. The tests check that every table has a phase and "
    + "that no table of an earlier phase requires a row of a later one; references that point forward are optional readiness columns "
    + "(study decision 88), listed by sys.v_phase_forward_reference. Each module heading in chapter 6 and each table in chapter 7 now "
    + "names its phase."),
  table(["Phase", "Scope", "Study", "Tables"], (model.phases || []).map((p) => [p.name, p.scope, p.study,
    `${Object.values(PH).filter((c) => c === p.code).length}`]), [2300, 5046, 1300, 1100], { boldFirst: true, size: 16 }),
];

// ------------------------------ changes in 3.4 ------------------------------
const changes34 = [H(HeadingLevel.HEADING_1, "Changes in version 3.4", { pageBreak: true }),
  P("A strategic review of the study and of version 3.3 approved the architecture and the model as the baseline and asked that the "
    + "critical controls be proven, not only designed. Its audit register classified all 1,304 relationships of version 3.3 and flagged "
    + "136 for review. Each flagged relationship was checked against the built database; the disposition of every one is in "
    + "docs/database/INTEGRITY_AUDIT.md. Schema file 1040_integrity_audit.sql (migration 1.22.0) adds what the check found missing; "
    + "its three composite keys bring the relationships to " + fkCount + ". No table was added or removed."),
  table(["Finding", "What the database now does", "Evidence"], [
    ["C-03, F-001, F-002 Cross-entity integrity", "A ticket travels on the trip of its booking and belongs to a passenger of that booking; a sold seat belongs to "
      + "the trip of its ticket: validated composite foreign keys. A scan of another trip's ticket is recorded only as WRONG_TRIP; a manifest lists "
      + "only tickets of its own trip; a cargo leg rides a trip of its carrier; a payment draws only on the payer's own wallet; a ticket sells only "
      + "its carrier's fare brands", "one test per rule"],
    ["F-003, F-004 Tenant references", "27 more references are guarded inside one company, 9 vehicle references by ownership or lease. Vehicles follow ownership or an active lease (fleet.vehicle_usable_by): a "
      + "same-company key, as proposed, would refuse every leased vehicle. Crew profiles are keyed by party. References to service partners stay "
      + "open by design: a partner is a company of its own", "tests: leased vehicle accepted, other company's vehicle refused, COPY checked"],
    ["F-003 Guard quality", "Every tenant guard is a row trigger, BEFORE INSERT OR UPDATE, enabled and not deferrable; bulk loading fires it",
      "test: trigger shape sweep"],
    ["H-02, F-006 Company wallet", "One COMPANY wallet per company and currency (wallet_company_currency_uq); cash and expense wallets stay per owner", "test"],
    ["C-01 Seat hold", "ops.seat_lock is an audit trail only; the hold is the LOCKED row of ops.seat_segment, taken in a fixed seat and segment order",
      "tests: 36 overlapping requests, multi-seat holds in opposite orders"],
    ["C-04 Pooling", "The request context is transaction-local (set_config with is_local); a reused connection carries nothing to the next request",
      "API test on one shared physical connection"],
    ["H-01 References without a key", "14 of the 25 polymorphic pairs are backed by real foreign keys (1039); their comments now say so. The other "
      + "references are integration mappings, event metadata and append-only logs (appendix C)", "appendix C"],
    ["H-07, M-02 Governance", "sys.v_schema_dependency and sys.v_jsonb_inventory; a new two-way schema dependency or a JSONB field in a policy, key or "
      + "index fails the build (docs/database/STANDARDS.md)", "tests: dependency baseline, JSONB rule"],
    ["FK-0414 Jurisdictions", "Tax jurisdictions form a tree without loops", "test"],
  ], [2200, 5146, 2400], { boldFirst: true }),
  gap(),
  table(["Measure", "Version 3.3", "Version 3.4"], [
    ["Tables", "445", "445"],
    ["References guarded inside one company", "79", "106, and 9 vehicle references by ownership or lease"],
    ["Database checks", "188", "209"],
    ["API tests", "171", "175"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.3 ------------------------------
const changes33 = [H(HeadingLevel.HEADING_1, "Changes in version 3.3", { pageBreak: true }),
  P("An independent review of the study and of this design (Database Architecture Review v1.0) found no need to redesign and asked for "
    + "targeted hardening. Schema file 1039_review_hardening.sql (migration 1.21.0) closes every finding the database can close; "
    + "docs/database/REVIEW_RESPONSE.md maps each finding to its fix and to the test that proves it. The study moves to v2.9 (sections 16.27 and 16.28)."),
  table(["Finding", "What the database now does", "Evidence"], [
    ["3.1 Proof of the build", "The SQL, the tests and the generators are in the repository; sys.v_security_inventory lists every table with its class, "
      + "owner path, RLS state, owner and privileges", "db/schema, db/tests, this document regenerated from the built database"],
    ["3.2 RLS coverage", `Row-level security on all 445 tables (83 more than in 3.2), each with a data class in sys.table_class; reporting has no access `
      + "to restricted tables; row security forced on credentials, factors and biometrics; sign-in in its own AUTH scope", "tests: classification, sweep, bypass"],
    ["3.3 Polymorphic references", "Decision records (documents, verifications, screening, risk, authority orders, fraud cases, licences, allocations, "
      + "manifest responses, invoices) carry one real foreign key per type, set by a trigger; at most one is set", "test: a document of a missing vehicle"],
    ["3.4 Ownership", "Every private table has a documented owner path; 80 references are checked to stay inside one company (TENANT_MISMATCH)",
      "tests: owner path, cross-company route"],
    ["3.5 Ledger", "Reversals mirror the original (deferred check), one reversal per transaction with a reason, posting batches with control totals, "
      + "provider events post once, balances move only through entries, daily reconciliation", "tests: mirror, reason, replay, direct write, reconciliation"],
    ["3.6 Ledger location", "Decision: the ledger stays in schema fin of the same database, written in the booking's local transaction (study 16.28)", "study v2.9"],
    ["3.7 Tracking", "sys.run_maintenance creates partitions ahead, drops positions past their retention unless a legal hold applies, and runs daily",
      "test: partitions ahead; worker --maintenance"],
    ["3.8 Seats", "PostgreSQL is the only seat record; a sold segment must match its ticket; a passenger only takes free seats or frees their own hold; "
      + "expired holds are released", "tests: mismatch, passenger cannot sell or free; 20 concurrent holds, one winner"],
    ["3.9 Reference data", "ref.seed_version records the version and hash of reference sets; sys.v_check_inventory sorts every CHECK into lifecycle or business list", "views"],
    ["3.10 Phases", "A restrictive policy closes the tables of a module whose switch is off (sys.module_gate)", "test: feature flag safety"],
    ["3.11 Authorisation", "Scopes by role, station and authority; sec.authorize records every restricted read with purpose, reason and policy version", "tests: document access"],
    ["3.12 Keys", "Key versions and envelope fields; one active key per purpose; no new data under a non-active key; the API refuses to start without keys",
      "tests: decrypt-only key, two active keys, production start"],
    ["3.14 Business rules", "Ownership up to 100%, lap infants, infant date of birth, stop order, pair fares on existing stops, capacity, licence and permit "
      + "at publication, permit activation, manifest chain, delivery scope, four-eyes authority requests", "one test per rule"],
    ["3.15 Retention", "gov.retention_policy, gov.legal_hold, erasure by pseudonymisation (gov.erase_party) with gov.erasure_log", "tests: hold refuses, pseudonymised"],
  ], [1900, 5346, 2500], { boldFirst: true }),
  gap(),
  table(["Measure", "Version 3.2", "Version 3.3"], [
    ["Tables", "432", "445"],
    ["Tables with row-level security", "349", `${rlsCount}`],
    ["Database checks", "141", "188"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.2 ------------------------------
const changes32 = [H(HeadingLevel.HEADING_1, "Changes in version 3.2", { pageBreak: true }),
  P("Version 3.2 follows the Analysis and Design Study v2.8: passenger categories and family accounts (4.19, 4.20), manifests issued by "
    + "the carrier for domestic and international trips and routed to the linked authorities (11.10), and the isolation of data between "
    + "companies, carriers and shippers (16.26). The four relationship rules of chapter 3.2 hold for every new table and column."),
  table(["Schema file", "Migration", "What it adds"], [
    ["1038_passengers_families_manifests.sql", "1.21.0", "Age bands per carrier with platform defaults that may not overlap (exclusion constraint), child and infant "
      + "fare rules, family offers; families with members (encrypted document numbers), link requests from members' own devices, travel rules "
      + "per member and an append-only spending log; a FAMILY wallet type; family and funding columns on bookings, passengers and subscriptions, "
      + "the fare category and the carrying adult of lap infants. Diagram E39."],
    ["1038_passengers_families_manifests.sql", "1.21.0", "Manifests of domestic trips (border point optional, scope, issuer, SHA-256 of the content, superseded version), persons with "
      + "the fare category and seat label, documents required only on international manifests; four-eyes routing rules to authorities and one delivery "
      + "per manifest version and authority. Diagram E34."],
    ["1038_passengers_families_manifests.sql", "1.21.0", "Row-level security added or tightened on containers, freight requests, rate cards and tables, hubs, routing rules, linehaul "
      + "schedules, rental fleet and rates, award seat rules and staff sessions; a market view of open loads without the shipper's identity. "
      + "An automated sweep checks that no company sees another company's rows."],
  ], [2300, 1100, 6346], { boldFirst: true }),
  gap(),
  table(["Measure", "Version 3.1", "Version 3.2"], [
    ["Schemas", "24", "24"],
    ["Module diagrams", "38", "39 (new: E39 passenger categories and family accounts)"],
    ["Focus diagrams", "3", "3"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.1 ------------------------------
const changes31 = [H(HeadingLevel.HEADING_1, "Changes in version 3.1", { pageBreak: true }),
  P("Version 3.1 adds the database support of three platform services built on the relational design of version 3.0: the reports centre, "
    + "the payment integration of the wallet, and the public integration API for carriers, sales channels, banks, e-wallets and authorities. "
    + "The four relationship rules of chapter 3.2 hold for every new table and column, and the automated checks still pass."),
  table(["Schema file", "Migration", "What it adds"], [
    ["1034_reports.sql", "1.17.0", "Schema rpt: report definitions (private or shared within a company), the append-only log of report runs and exports "
      + "with the file's SHA-256, and scheduled e-mail delivery; permissions report.custom and report.schedule. Diagram E38."],
    ["1035_payments.sql", "1.18.0", "Provider adapters (hosted card page, partner e-wallet, bank transfer, agency cash, sandbox) with limits and purposes; "
      + "payment stages, expiry and failure codes; refunds to the source (fin.payment_refund); imported bank statements and their lines "
      + "(fin.bank_statement_import, fin.bank_statement_line) matched to transfer references; a bank clearing wallet. Diagram E16."],
    ["1036_integration.sql", "1.19.0", "API clients act for their company through an acting staff account and may be linked to a payment provider or an "
      + "authority; daily usage per client (iam.api_usage_daily); row-level security on keys, webhook endpoints and deliveries; partner "
      + "wallet credits on fin.payment with a unique (client, reference) pair; the API_PARTNER adapter. Diagrams E02 and F03."],
  ], [2300, 1100, 6346], { boldFirst: true }),
  gap(),
  table(["Measure", "Version 3.0", "Version 3.1"], [
    ["Schemas", "23", "24"],
    ["Tables", "415", "422"],
    ["Module diagrams", "37", "38"],
    ["Focus diagrams", "2", "3 (new: F03 wallet top-up and partner integration)"],
    ["Diagram coverage", "checked by hand", "checked by the generator: it stops when a table is in no diagram or in two"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ changes in 3.0 ------------------------------
const changes = [H(HeadingLevel.HEADING_1, "Changes in version 3.0", { pageBreak: true }),
  P("Version 3.0 redesigns the relationships of the database from the start against the Analysis and Design Study v2.7. Every foreign key of "
    + "the built schema was audited against four rules (chapter 3.2) and the gaps were closed in schema file 1033_relational_integrity.sql. "
    + "The rules are now checked by the automated tests, so a later schema change cannot break them unnoticed."),
  table(["Change", "Before (2.0)", "Now (3.0)"], [
    ["Study basis", "v2.6", "v2.7: passport required on international trips, approved document exceptions (11.9.1)"],
    ["Tables without a primary key", "1 (acct.gl_period)", "0"],
    ["Foreign keys", "1,123", "1126, of which 57 are compositions (cascade)"],
    ["Reference columns without a foreign key", "64, undocumented", `0 undocumented; ${noFk.length} justified exceptions (appendix C)`],
    ["Foreign keys with a supporting index", "246", `${idxCount("indexed")}; the other ${idxCount("lookup") + idxCount("actor")} point at fixed lookup lists or record an actor; ${idxCount("missing")} missing`],
    ["Polymorphic references", "partly indexed", "every (type, id) pair indexed and documented"],
    ["Travel documents (11.9)", "entry rule with documents only", "validity period, legal basis, note, four-eyes approval, document type and exception on the ticket"],
    ["Diagrams", "37 module diagrams", "37 module diagrams with compositions in the module colour, plus 2 focus diagrams across modules"],
  ], [2700, 2400, 4646], { boldFirst: true }),
];

// ------------------------------ 1. introduction ------------------------------
const intro = [H(HeadingLevel.HEADING_1, "1. Introduction", { pageBreak: true }),
  H(HeadingLevel.HEADING_2, "1.1 Purpose"),
  P("This document is the database design of the Masslak platform. It redevelops the data model so that every entity and relationship "
    + "of the Analysis and Design Study v3.0 has a table, keys and constraints in the database, and it draws the relationships of each module "
    + "as an entity-relationship diagram in the colours of the study."),
  H(HeadingLevel.HEADING_2, "1.2 Sources and scope"),
  bullet("the Analysis and Design Study v3.0 (English), including appendix D (additional phases 13 to 15), the travel document rules of 11.9.1, passenger categories and family accounts (4.19, 4.20), carrier-issued manifests (11.10) and data isolation (16.26);", "Study"),
  bullet("the Use Case and Data Flow Diagrams v1.0, whose data stores D1 to D17 are mapped to tables in chapter 5;", "Diagrams"),
  bullet("the PostgreSQL schema in db/schema, built and tested; every diagram and table definition here is generated from the built database, "
    + "so the document cannot drift from the schema.", "Database"),
  P("The model covers the core of Phase 1 and every later phase: shuttle and approved lines, shipping, international trips and the border manifest, "
    + "government integration, tracking and stations, trucks and transit, intermediary platforms, rail, taxi, car rental, and the additional phases "
    + "13 to 15. Modules of later phases are built now and stay disabled behind feature flags until their phase starts (study v3.0, decision D-6)."),
  H(HeadingLevel.HEADING_2, "1.3 Notation"),
  P("Each diagram shows one module. A box is a table: the coloured band and header follow the module's colour family from the study's figure 4.1; "
    + "rows list the primary key (PK), the foreign keys (FK), unique keys (UQ) and the main attributes, with required columns in bold. The number "
    + "of remaining columns is given at the bottom of the box; every column is listed in chapter 7. Dashed grey boxes are tables of other modules. "
    + "Heavy lines in the module colour are compositions: the child rows are part of the parent and are deleted with it."),
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
  sch: ["School transport: operators, schools, contracts, routes, runs, pupils, guardians and attendance", "SCH"], rpt: ["Report definitions, runs, schedules and deliveries", "1B"],
  gis: ["PostGIS spatial reference systems", "1A"],
};
const order = ["iam", "ref", "sys", "net", "fleet", "ops", "sales", "pricing", "fin", "acct", "bill", "crm", "gov", "sec", "audit", "ptn", "ship",
  "frt", "brd", "ctr", "sch", "rail", "taxi", "rent", "rpt", "gis"];
{
  const missing = schemas.filter((s) => !order.includes(s) || !schemaInfo[s]);
  if (missing.length) throw new Error(`schemas without a row in table 2.1: ${missing.join(", ")}`);
}
const perSchema = (s) => model.tables.filter((t) => t.schema === s);
const arch = [H(HeadingLevel.HEADING_1, "2. Database architecture", { pageBreak: true }),
  P(`The database has ${schemas.length} schemas, one per module, each with its own privileges. The overview groups them into the seven families of the `
    + "study's figure 4.1, with the same colours."),
  image(path.join(PNG, "E00_overview.png"), 640, 440),
  H(HeadingLevel.HEADING_2, "2.1 Schemas"),
  table(["Schema", "Contents", "Tables", "Foreign keys", "Phase"],
    [...order.map((s) => [s, schemaInfo[s][0], String(perSchema(s).length), String(perSchema(s).reduce((n, t) => n + (t.fks || []).length, 0)), schemaInfo[s][1]]),
      ["Total", `${order.length} schemas`, String(tableCount), fkCount.toLocaleString("en-US"), ""]],
    [1100, 4846, 1100, 1300, 1400], { boldFirst: true }),
  gap(),
  H(HeadingLevel.HEADING_2, "2.2 Relationships between modules"),
  P("By phase, data depends only backwards: a later-phase module references parties, companies, stations, trips, vehicles and wallets, while "
    + "no table of an earlier phase requires a row of a later one (references forward are optional readiness columns, tested). By schema, "
    + "21 pairs of schemas reference each other both ways (for example ops and sales, fin and ship); the set is frozen by test H-07 and any new "
    + "pair fails the build. The table counts the foreign keys from each module to the others."),
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
    ["Personal data", "identity, document and visa numbers encrypted (bytea) with a blind index and the key reference; passengers' and family members' phone numbers encrypted with the last four digits for display; a person's contact only on their account, hidden from reporting and audit roles and masked in the change log; card numbers never stored (last four digits only), NFC card identifiers hashed"],
  ], [2400, 7346], { boldFirst: true }),
  gap(),
  H(HeadingLevel.HEADING_2, "3.2 Relationship rules"),
  P("Four rules govern every relationship. They are checked by db/tests on every build, together with the security rules of chapter 4."),
  table(["Rule", "Statement", "How it is checked"], [
    ["R1 Keys", "Every table has a primary key: a bigint identity, a shared key with its parent (extensions) or a composite key (association and child tables).",
      "test: every table has a primary key"],
    ["R2 Declared references", "Every column that names another row is a foreign key. The only exceptions carry a column comment that starts with "
      + "Polymorphic (a type and id pair naming rows of several tables), External (an identifier issued outside the platform) or No FK "
      + "(append-only logs and partitioned telemetry kept after the referenced row is gone). They are listed in appendix C.",
      "test: every reference column is a foreign key or says why not"],
    ["R3 Indexed references", "Every foreign key is the leading column of an index, so joins from the parent and deletes of the parent never scan the "
      + "child. Exempt by rule: references to fixed lookup lists (ref.currency, ref.country, ...) and actor columns (created_by, approved_by, ...).",
      "test: every foreign key has a supporting index"],
    ["R4 Delete behaviour", "CASCADE only from a parent to the rows that are part of it (route stops, invoice lines, manifest persons, seat segments). "
      + "Everything else is NO ACTION or RESTRICT; rows that carry money or legal effect are never deleted, they change status.",
      "review of every cascade (chapter 6 lists the delete rule of each relationship)"],
  ], [1700, 5546, 2500], { boldFirst: true }),
  gap(),
  bullet("A required relationship has a NOT NULL foreign key; an optional one is nullable; one to one is a unique foreign key or a shared primary key (iam.company, fleet.truck_unit, brd.border_point).", "Cardinality"),
  bullet("Many to many relationships are association tables with a composite key: role_permission, call_agent_skill, leg_container, rental_booking_addon.", "Many to many"),
  bullet("Extensions share the parent's primary key: a company is a party, a truck unit is a vehicle, a border point is a station, a rental car is a vehicle.", "Extensions"),
  bullet("Alternative parents are nullable foreign keys with a CHECK such as num_nonnulls(trip_id, load_id, route_id) = 1.", "Exclusive arcs"),
  bullet("A foreign key may point at a unique business key instead of the identity when that key is what other systems carry: signing keys are referenced by key_ref.", "Business keys"),
  bullet("New foreign keys on existing tables are added NOT VALID and validated in the same file; rows written before the rule are reported, never silently rewritten.", "Upgrades"),
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
  P(`Row-level security is enabled on ${rlsCount} of the ${tableCount} tables. The application connects as a role that does not own the tables and `
    + "cannot bypass row security, so the policies always apply; without a request context no private row is visible. Every table carries a data "
    + "class in sys.table_class (public catalog, platform confidential, company private, personal, restricted security, append-only audit, system) "
    + "and a documented owner path, and sys.v_security_inventory shows the whole picture in one query (version 3.3)."),
  P("Sign-in runs in a narrow AUTH scope that opens accounts, second factors and sessions only. Reporting has no access to restricted tables, "
    + "and row security is forced on credentials, factors and biometrics. Tables of a module whose switch is off are closed by a restrictive "
    + "policy for everyone but the platform. Validation triggers run as the owner with a fixed search path, so a rule sees the rows it checks "
    + "even when the caller's policies hide them. Reads of restricted values pass sec.authorize, which records purpose, reason and decision."),
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
    + "partners, contracted transport, rail, taxi, car rental, reports, payment integration and the integration API) are listed with their diagrams in chapter 6."),
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
  children.push(P([run(`Study: ${secs}  ·  Family: ${FAMILY_NAME[fam]}  ·  ${tabs.length} tables  ·  Phases: ${spread(tabs)}`, { size: 18, color: C.grey })], { after: 60 }));
  children.push(P(desc, { after: 100 }));
  children.push(land ? image(file, 960, 520) : image(file, 640, 760));
  const rels = [];
  for (const full of tabs) for (const f of T[full].fks || []) {
    rels.push([`${full}.${f.cols.join(", ")}`, f.ref, f.unique ? "one to one" : "many to one", f.required ? "required" : "optional",
      ON_DELETE[f.on_delete], indexClass(f)]);
  }
  children.push(H(HeadingLevel.HEADING_3, `Relationships of ${gid} (${rels.length})`));
  const ws = land ? [4700, 3300, 2000, 1700, 1600, 1538] : [3100, 2300, 1250, 1050, 1000, 1046];
  children.push(table(["Child (foreign key)", "Parent", "Cardinality", "Child side", "On delete", "Index"], rels, ws, { size: 16 }));
  erdSections.push(section(land ? LANDSCAPE : PORTRAIT, children));
});

(model.focus || []).forEach((g, i) => {
  const [gid, title, secs, , desc, tabs] = g;
  const file = path.join(PNG, `${gid}.png`);
  const { w, h } = pngSize(file);
  const land = w / h > 1.05;
  const children = [];
  if (i === 0) {
    children.push(H(HeadingLevel.HEADING_2, `6.${model.groups.length + 1} Focus diagrams: rules that span modules`));
    children.push(P("A focus diagram follows one business rule across modules. Each table keeps the colour of its own module, and only the "
      + "links among the tables shown are drawn, including who approves when that is part of the rule."));
  }
  children.push(H(HeadingLevel.HEADING_3, `${gid} ${title}`));
  children.push(P([run(`Study: ${secs}  ·  ${tabs.length} tables`, { size: 18, color: C.grey })], { after: 60 }));
  children.push(P(desc, { after: 100 }));
  children.push(land ? image(file, 960, 520) : image(file, 640, 760));
  if (gid === "F01") {
    children.push(table(["Step", "Tables and keys", "Rule (study 11.9.1)"], [
      ["1. Segment countries", "sales.ticket (trip_id, from_seq, to_seq) -> ops.trip_stop (trip_id, seq) -> net.station.country_code -> ref.country",
        "international when the last stop, or a stop on the way, is in another country than the first"],
      ["2. Rule lookup", "sales.entry_rule (country_code, country_role, nationality, valid, status = ACTIVE), index entry_rule_lookup",
        "the passenger's nationality first, then any nationality, then the platform default travel.international_default in sys.setting"],
      ["3. Several borders", "one entry_rule per destination and transit country", "only documents accepted at every border remain; none in common means passport"],
      ["4. Exceptions", "doc_required other than PASSPORT needs legal_basis (constraint entry_rule_exception_basis); approved_by <> created_by",
        "drafted by one officer, approved by another; approving a version retires the previous one"],
      ["5. Record on the ticket", "sales.ticket_doc (ticket_id PK and FK, entry_rule_id, doc_type, exception, dest_country, verified_by)",
        "every international ticket keeps the document type used and the rule that allowed it"],
      ["6. Passenger", "sales.passenger (id_type, nationality, passport_country, passport_expiry)",
        "the passport must stay valid passport_min_days after departure (default 180)"],
    ], land ? [2600, 6738, 5500] : [1700, 4346, 3700], { size: 16, boldFirst: true }));
  }
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
    defs.push(P([run(`Phase ${PH[full] || "?"}`, { size: 18, color: C.grey })], { after: 40 }));
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
    ["Automated tests (db/tests/run.sh)", `${V.db_checks} checks passing: isolation of shipments, bids, partners, manifests; exclusion and uniqueness rules; `
      + "append-only tables; four-eyes approvals; feature flags off; the relationship rules R1 to R3; and the acceptance matrix of the architecture review "
      + "(classification, isolation sweep, RLS bypass, typed references, tenant checks, ledger, seats, business rules, scopes, keys, erasure, tracking) "
      + "and of the integrity audit (sale chain, manifests, cargo legs, wallets, leased vehicles, COPY, guard shape, schema dependencies, JSONB), "
      + "the third-party audit (orphans, contact data, phase gate, change log, JSON contracts, lifecycle, policy matrix) and the technical audit "
      + "of design 3.7 and its re-audit (references, break-glass, positions, devices, requirement changes, quarantine, access reviews, "
      + "envelope, metrics, job log, payment reconciliation, resend approvals)"],
    ["Relationship audit", `${fkCount} foreign keys: ${idxCount("indexed")} indexed, ${idxCount("lookup")} to lookup lists, ${idxCount("actor")} actor columns, ${idxCount("missing")} missing an index; ${noFk.length} documented references without a foreign key`],
    ["Application", `${V.api_tests} API tests passing, among them 20 concurrent holds on one seat (one winner), 36 overlapping-segment requests, multi-seat `
      + "holds in opposite orders without deadlock, concurrent wallet bookings that reconcile, a pooled connection that carries no company "
      + "into the next request, sign-in in the AUTH scope, file quarantine, report recipients and links, position evidence and devices, "
      + "two-person requirement changes and resends, metrics, and the egress proxy and webhook address checks"],
    ["Evidence of this build", `commit ${V.source_commit}; migration ${V.migration}; last schema file ${V.last_schema_file}; schema SHA-256 `
      + `${V.schema_sha256}; PostgreSQL ${V.postgres}, PostGIS ${V.postgis}; collected ${V.generated_at} by generator/verification.py from the `
      + "console output of the same run. A database check is one PASS line of db/tests/run_tests.sql; an API test is one pytest test"],
    ["Coverage", "every table has row-level security, a data class and an owner path (checked by the tests)"],
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

const appC = [H(HeadingLevel.HEADING_1, "Appendix C: References without a foreign key", { pageBreak: true }),
  P(`Rule R2 allows a reference column without a foreign key only when its comment says why. These are the ${noFk.length} such columns, read from the database.`),
  table(["Table", "Column", "Kind", "Reason"], noFk.map((r) => [r.table, r.col, r.kind, r.why]), [2700, 1800, 1300, 3946], { size: 16 }),
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
    section(PORTRAIT, [...front, ...toc, ...changes3_20, ...historical(changes3_19, "3.19"), ...historical(changes3_18, "3.18"), ...historical(changes3_17, "3.17"), ...historical(changes3_16, "3.16"), ...historical(changes3_15, "3.15"), ...historical(changes3_14, "3.14"), ...historical(changes3_13, "3.13"), ...historical(changes3_12, "3.12"), ...historical(changes3_11, "3.11"), ...historical(changes3_10, "3.10"), ...historical(changes3_9, "3.9"), ...historical(changes3_8, "3.8"), ...historical(changes37, "3.7"), ...changes38, ...changes39, ...historical(changes36, "3.6"), ...historical(changes35, "3.5"), ...historical(changes34, "3.4"), ...historical(changes33, "3.3"), ...historical(changes32, "3.2"), ...historical(changes31, "3.1"), ...historical(changes, "3.0"), ...intro, ...arch, ...rules, ...security, ...stores]),
    ...erdSections,
    section(PORTRAIT, [...defs, ...trace, ...verify, ...flags, ...gens, ...appC]),
  ],
});
const out = path.join(HERE, "..", `Masslak_Database_Design_and_ERD_v${VERSION}.docx`);
Packer.toBuffer(doc).then((b) => { fs.writeFileSync(out, b); console.log("written", out, (b.length / 1e6).toFixed(1), "MB"); });
