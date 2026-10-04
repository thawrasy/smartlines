// Builds "Masslak — Use Case and Data Flow Diagrams" (Word) from out/data.json and the rendered diagrams.
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, ImageRun, Table, TableRow, TableCell, WidthType, ShadingType, AlignmentType,
  HeadingLevel, PageOrientation, Header, Footer, PageNumber, BorderStyle, LevelFormat, PageBreak, TableLayoutType,
} = require("docx");

const D = JSON.parse(fs.readFileSync("out/data.json", "utf8"));
const NAVY = "1F3864", BORDER = "B7C3D0", LABEL_FILL = "EAF1FB";
const A4 = { w: 11906, h: 16838 }, MARGIN = 1134;
const PORTRAIT_W = A4.w - 2 * MARGIN, LANDSCAPE_W = A4.h - 2 * MARGIN;

// ---------------------------------------------------------------- helpers
const run = (text, o = {}) => new TextRun({ text, font: "Arial", size: o.size || 21, bold: o.bold, italics: o.italics, color: o.color });
const p = (text, o = {}) => new Paragraph({ children: Array.isArray(text) ? text : [run(text, o)], spacing: { after: o.after ?? 120, line: 290 }, alignment: o.align });
const h1 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun({ text: t, font: "Arial" })], pageBreakBefore: true });
const h2 = (t, br = false) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun({ text: t, font: "Arial" })], pageBreakBefore: br });
const h3 = (t, br = false) => new Paragraph({ heading: HeadingLevel.HEADING_3, children: [new TextRun({ text: t, font: "Arial" })], pageBreakBefore: br });
const bullet = (text) => new Paragraph({ numbering: { reference: "bullets", level: 0 }, children: [run(text)], spacing: { after: 60, line: 280 } });
const caption = (t) => new Paragraph({ children: [run(t, { size: 18, italics: true, color: "5B6B7F" })], alignment: AlignmentType.CENTER, spacing: { after: 200 } });

function pngSize(file) {
  const b = fs.readFileSync(file);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}
function image(file, maxWpx, maxHpx) {
  const { w, h } = pngSize(file);
  let width = maxWpx, height = Math.round(h * maxWpx / w);
  if (height > maxHpx) { height = maxHpx; width = Math.round(w * maxHpx / h); }
  return new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 60 },
    children: [new ImageRun({ type: "png", data: fs.readFileSync(file), transformation: { width, height },
      altText: { title: file, description: file, name: file } })] });
}

const cellBorders = { top: { style: BorderStyle.SINGLE, size: 4, color: BORDER }, bottom: { style: BorderStyle.SINGLE, size: 4, color: BORDER },
                      left: { style: BorderStyle.SINGLE, size: 4, color: BORDER }, right: { style: BorderStyle.SINGLE, size: 4, color: BORDER } };
function cell(content, width, o = {}) {
  const paras = (Array.isArray(content) ? content : [content]).map((t) => t instanceof Paragraph ? t :
    new Paragraph({ children: [run(String(t), { size: o.size || 18, bold: o.bold, color: o.header ? "FFFFFF" : undefined })],
                    spacing: { after: 30, line: 250 }, alignment: o.align }));
  return new TableCell({ children: paras, width: { size: width, type: WidthType.DXA }, borders: cellBorders,
    shading: { fill: o.fill || (o.header ? NAVY : "FFFFFF"), type: ShadingType.CLEAR, color: "auto" },
    margins: { top: 60, bottom: 60, left: 90, right: 90 } });
}
function table(headers, rows, widths, o = {}) {
  const total = widths.reduce((a, b) => a + b, 0);
  const trs = [new TableRow({ tableHeader: true, cantSplit: true, children: headers.map((h, i) => cell(h, widths[i], { header: true, bold: true, size: o.headSize || 18, align: o.align?.[i] })) })];
  for (const r of rows) trs.push(new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i], { size: o.size, align: o.align?.[i], fill: o.fills?.(i, c) })) }));
  return new Table({ width: { size: total, type: WidthType.DXA }, columnWidths: widths, rows: trs, layout: TableLayoutType.FIXED });
}
function kvTable(pairs, width) {
  const w1 = 2300, w2 = width - w1;
  return new Table({ width: { size: width, type: WidthType.DXA }, columnWidths: [w1, w2], layout: TableLayoutType.FIXED,
    rows: pairs.map(([k, v]) => new TableRow({ cantSplit: false, children: [cell(k, w1, { bold: true, fill: LABEL_FILL }), cell(v, w2)] })) });
}
const spacer = () => new Paragraph({ children: [], spacing: { after: 160 } });

// ---------------------------------------------------------------- content
const cover = [
  new Paragraph({ spacing: { before: 2400, after: 200 }, alignment: AlignmentType.CENTER, children: [run("Masslak", { size: 56, bold: true, color: NAVY })] }),
  new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 120 }, children: [run("Use Case and Data Flow Diagrams", { size: 40, bold: true })] }),
  new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 600 }, children: [run("How actors use the platform and how data moves inside it", { size: 24, color: "5B6B7F" })] }),
  kvTable([["Version", "1.0"], ["Date", "3 October 2026"], ["Source", "Analysis and Design Study v2.5 (English edition) — the only source used"],
           ["Contents", "11 use case diagrams (UML 2.5), 11 data flow diagrams (Gane & Sarson: context, two Level 1, eight Level 2), use case specifications, data store catalog, access matrix and traceability"],
           ["Status", "Ready for review"]], PORTRAIT_W),
];

const SECTIONS = ["1. Introduction and notation", "2. Actors", "3. Use case diagrams", "4. Key use case specifications",
  "5. Data flow diagrams", "6. Data store catalog", "7. Process and data store access matrix", "8. Traceability", "9. Assumptions and notes"];
const contents = [h1("Contents"), ...SECTIONS.map((s) => p(s, { after: 80 }))];

const intro = [
  h1("1. Introduction and notation"),
  h2("1.1 Purpose"),
  p("This document shows who uses the Masslak platform and for what (use case diagrams), and how data moves between the actors, the platform's processes and its data stores (data flow diagrams). It is a companion to the Analysis and Design Study and helps business, technical and authority readers share one picture of the system before and during the build."),
  h2("1.2 Source and scope"),
  p("Every actor, use case, process, flow and data store is taken from the Analysis and Design Study v2.5 (English edition), and section numbers in the tables refer to that study. The diagrams cover the full target scope: scheduled intercity travel and shuttle transport, carrier and driver operations, integrated shipping, service partners and loyalty, administration and finance, security and compliance with the authorities, distribution channels, and accounting with e-invoicing. Use cases belonging to a later phase are labelled with that phase."),
  h2("1.3 Use case notation (UML 2.5)"),
  image("out/legend-uc.png", 620, 200),
  bullet("Primary actors (people who start the use case) are on the left; secondary actors (external systems and devices) are on the right."),
  bullet("«include»: the base use case always performs the included one. «extend»: the extension adds optional behaviour to the base."),
  bullet("Each diagram has a system boundary named after the part of the platform it covers."),
  h2("1.4 Data flow notation (Gane & Sarson)"),
  image("out/legend-dfd.png", 620, 200),
  bullet("External entity: a person, organization or system outside the platform. Process: a rounded box with its number. Data store: an open box with its D number."),
  bullet("A dashed process belongs to another diagram and is shown for context. A duplicate symbol repeats an element to keep flows short."),
  bullet("Levels: the context diagram (DFD-0) shows the platform as one process; Level 1 (DFD-1A and DFD-1B) splits it into 14 processes; Level 2 details the processes with the most data movement."),
  h2("1.5 Numbering"),
  table(["Item", "Format", "Example"], [["Use case diagram", "UC-n", "UC-2 Shuttle transport"], ["Use case", "UC-n.m", "UC-2.8 Charge the next segment"],
    ["Level 1 process", "Pn", "P8 Operate shuttle rides"], ["Level 2 process", "n.m", "8.4 Charge segment at departure"],
    ["Data store", "Dn", "D10 Shuttle rides"], ["Data flow diagram", "DFD-n", "DFD-8 (Level 2 of P8)"]], [2600, 2400, PORTRAIT_W - 5000]),
];

const actors = [
  h1("2. Actors"),
  p(`The platform has ${D.actors.filter((a) => a.kind === "Primary").length} primary actors (people in a role) and ${D.actors.filter((a) => a.kind !== "Primary").length} secondary actors (external systems and devices).`),
  table(["Actor", "Type", "Description", "Study"], D.actors.map((a) => [a.name, a.kind, a.desc, a.ref]), [2300, 1500, PORTRAIT_W - 5000, 1200]),
];

const ucSections = [h1("3. Use case diagrams"),
  h2("3.1 System overview (UC-0)"),
  p("The overview groups the actors and shows which subsystem each group uses. Each subsystem is detailed in its own diagram below."),
  image("out/UC-0.png", 600, 820),
  caption("Figure UC-0. Actor groups and the platform's subsystems"),
  table(["Subsystem", "Diagram", "Main actors", "External systems"], D.uc.map((u, i) => [`${D.subsystems[i].id} ${u.title}`, u.id, u.primary.join(", "), u.secondary.join(", ") || "-"]),
        [2600, 1000, 3400, PORTRAIT_W - 7000]),
];
D.uc.forEach((u, i) => {
  ucSections.push(h2(`3.${i + 2} ${u.id} ${u.title}`, true));
  ucSections.push(p(`Boundary: ${u.boundary}. Primary actors: ${u.primary.join(", ")}.${u.secondary.length ? " Secondary actors: " + u.secondary.join(", ") + "." : ""}`));
  ucSections.push(image(`out/${u.id}.png`, 620, 760));
  ucSections.push(caption(`Figure ${u.id}. ${u.title}`));
  ucSections.push(table(["ID", "Use case", "Actors", "Description", "Study"],
    u.rows.map((r) => [r.id, r.name + (r.phase !== 1 ? ` (Phase ${r.phase})` : ""), r.actors, r.desc, r.ref]), [1000, 1900, 1700, PORTRAIT_W - 5700, 1100], { size: 17 }));
});

const specs = [h1("4. Key use case specifications"),
  p("The following use cases carry the most money, risk or regulatory weight, so they are specified step by step. The numbered steps are the main success scenario; alternative flows refer to the step they branch from.")];
D.specs.forEach((s, i) => {
  specs.push(h2(`4.${i + 1} ${s.id} ${s.name}`, i > 0));
  specs.push(kvTable([
    ["Primary actor", s.primary], ["Secondary actors", s.secondary],
    ["Preconditions", s.pre.map((x) => new Paragraph({ children: [run("• " + x, { size: 18 })], spacing: { after: 30, line: 250 } }))],
    ["Trigger", s.trigger],
    ["Main flow", s.main.map((x, k) => new Paragraph({ children: [run(`${k + 1}. ${x}`, { size: 18 })], spacing: { after: 30, line: 250 } }))],
    ["Alternative flows", s.alt.map((x) => new Paragraph({ children: [run(x, { size: 18 })], spacing: { after: 30, line: 250 } }))],
    ["Postconditions", s.post], ["Study references", s.refs]], PORTRAIT_W));
});

// ---- data flow diagrams (landscape)
const L_IMG_W = 960, L_IMG_H = 560;
const dfdSections = [h1("5. Data flow diagrams"),
  h2("5.1 DFD-0 Context diagram"),
  p("The context diagram shows the whole platform as a single process and every external entity that sends data to it or receives data from it."),
  image("out/DFD-0.png", L_IMG_W, 450), caption("Figure DFD-0. Context diagram"),
  h3("External entities and their flows", true),
  table(["External entity", "Data into the platform", "Data from the platform"],
        [...D.context.left, ...D.context.right].map((e) => [e.name, e.inp, e.out]), [3400, (LANDSCAPE_W - 3400) / 2, (LANDSCAPE_W - 3400) / 2]),
  h2("5.2 DFD-1A Level 1: passenger transport core", true),
  image("out/DFD-1A.png", L_IMG_W, L_IMG_H), caption("Figure DFD-1A. Processes P1 to P8"),
  h2("5.3 DFD-1B Level 1: logistics, compliance, partners, finance and channels", true),
  image("out/DFD-1B.png", L_IMG_W, L_IMG_H), caption("Figure DFD-1B. Processes P9 to P14"),
  h3("Level 1 processes"),
  table(["Process", "Name", "What it does", "Diagram", "Level 2", "Study"],
        D.processes.map((x) => [x.id, x.name, x.desc, x.level, x.detail || "-", x.ref]), [900, 2500, LANDSCAPE_W - 8100, 1100, 1100, 2500]),
];
D.level2.forEach((l, i) => {
  dfdSections.push(h2(`5.${i + 4} ${l.title}`, true));
  dfdSections.push(image(`out/${l.id}.png`, L_IMG_W, L_IMG_H));
  dfdSections.push(caption(`Figure ${l.id}. ${l.title.split(": ")[1]}`));
  dfdSections.push(table(["Process", "Name", "What it does"], l.rows.map((r) => [r.id, r.name, r.desc]), [1100, 3200, LANDSCAPE_W - 4300]));
  dfdSections.push(p(`Data stores used: ${l.stores.join(", ")}.`, { size: 18, after: 60 }));
});

const storeSection = [h1("6. Data store catalog"),
  p("Each data store groups related tables of the platform's database. Writers create or update its data; readers only read it."),
  table(["Store", "Name", "Main entities", "Written by", "Read by", "Protection"],
        D.stores.map((s) => [s.id, s.name, s.entities, s.writers, s.readers, s.protection]), [800, 2000, LANDSCAPE_W - 9200, 2000, 2000, 2400])];

const sids = D.store_ids;
const mW = Math.floor((LANDSCAPE_W - 2600) / sids.length);
const matrixSection = [h1("7. Process and data store access matrix"),
  p("W = the process creates or updates data in the store; R = the process reads it. The matrix is derived from the data flow diagrams."),
  table(["Process", ...sids], D.processes.map((x) => [`${x.id} ${x.name}`, ...sids.map((s) => D.matrix[x.id][s] || "")]),
        [2600, ...sids.map(() => mW)], { size: 16, headSize: 16, align: [undefined, ...sids.map(() => AlignmentType.CENTER)],
          fills: (i, c) => (i > 0 && c ? (c.includes("W") ? "D7E6F7" : "EEF2F6") : undefined) })];

const traceSection = [h1("8. Traceability"),
  p("Each use case diagram maps to the data flow processes that carry its data and to the diagrams that detail them."),
  table(["Use case diagram", "DFD processes", "Detailed in", "Main study sections"],
        D.uc.map((u) => [`${u.id} ${u.title}`, u.procs.join(", "), u.dfds.join(", "), u.refs.slice(0, 10).join(", ")]), [3000, 1900, 1700, PORTRAIT_W - 6600])];
const notes = [h1("9. Assumptions and notes"), ...D.assumptions.map(bullet)];

// ---------------------------------------------------------------- document
const header = new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [run("Masslak | Use Case and Data Flow Diagrams | Version 1.0", { size: 16, color: "5B6B7F" })] })] });
const footer = new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [new TextRun({ font: "Arial", size: 16, color: "5B6B7F", children: ["Page ", PageNumber.CURRENT] })] })] });
const portrait = { page: { size: { width: A4.w, height: A4.h }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } };
const landscape = { page: { size: { width: A4.w, height: A4.h, orientation: PageOrientation.LANDSCAPE }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } };

const doc = new Document({
  creator: "Masslak", title: "Masslak: Use Case and Data Flow Diagrams (Version 1.0)",
  styles: {
    default: { document: { run: { font: "Arial", size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 32, bold: true, color: NAVY, font: "Arial" }, paragraph: { spacing: { before: 120, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 26, bold: true, color: NAVY, font: "Arial" }, paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 1 } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 22, bold: true, color: "2E5597", font: "Arial" }, paragraph: { spacing: { before: 200, after: 100 }, outlineLevel: 2 } },
    ],
  },
  numbering: { config: [{ reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] }] },
  sections: [
    { properties: portrait, headers: { default: header }, footers: { default: footer }, children: [...cover, ...contents, ...intro, ...actors, ...ucSections, ...specs] },
    { properties: landscape, headers: { default: header }, footers: { default: footer }, children: [...dfdSections, ...storeSection, ...matrixSection] },
    { properties: portrait, headers: { default: header }, footers: { default: footer }, children: [...traceSection, ...notes] },
  ],
});
Packer.toBuffer(doc).then((buf) => { fs.writeFileSync("out/Masslak_Use_Case_and_Data_Flow_Diagrams_v1.0.docx", buf); console.log("written", buf.length); });
