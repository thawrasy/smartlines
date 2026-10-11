#!/usr/bin/env node
/* erd_docx.js — ملف Word لمخطط علاقات جداول قاعدة البيانات (BankFas)، بصفحات أفقية لقراءة المخططات.
   Usage:  python3 tools/dbgen/erd_manifest.py | NODE_PATH=/opt/node22/lib/node_modules:/opt/node-tools/node_modules \
             node tools/dbgen/erd_docx.js <out.docx> <docs-dir>
   المدخل: JSON من erd_manifest.py. الصور: <docs-dir>/diagrams/erd/*.png (بدقة مضاعفة).
   نفس لغة الألوان والخطوط والاتجاه RTL في tools/md2docx، مع صفحة أفقية لكل مخطط وجداوله. */
'use strict';
const fs = require('fs');
const path = require('path');
const D = require('docx');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  AlignmentType, HeadingLevel, Header, Footer, PageNumber, ImageRun, PageOrientation, VerticalAlign,
} = D;
const JSZip = require('jszip');

const [,, outFile, docsDirArg] = process.argv;
if (!outFile || !docsDirArg) { console.error('usage: erd_docx.js <out.docx> <docs-dir>  (manifest JSON on stdin)'); process.exit(2); }
const DOCS = path.resolve(docsDirArg);
const M = JSON.parse(fs.readFileSync(0, 'utf8'));
const m = M.meta;

// ---------- الألوان والخطوط (مطابقة لـ md2docx) ----------
const FONT = 'Arial', MONO = 'Courier New';
const C = { navy: '1F3A5F', blue: '2B5C8A', gray: '5B6670', rule: 'BFC9D6', band: 'F5F8FC', head: '1F3A5F', metaKey: 'E8EEF6' };
const SZ = { body: 20, table: 16, tableCode: 15, h1: 32, h2: 26, small: 16, title: 44, sub: 26 };
// صفحة A4 أفقية: الأبعاد تُمرَّر عمودية ويُحوَّل الاتجاه بـ PageOrientation.LANDSCAPE
const PORT_W = 11906, PORT_H = 16838;
const MARGIN = { top: 1000, bottom: 1000, left: 900, right: 900 };
const CONTENT_W = PORT_H - MARGIN.left - MARGIN.right;              // 14796 DXA عرض الصفحة الأفقية المتاح
const IMG_MAX_W = Math.round(CONTENT_W / 1440 * 96);                // بكسل بـ96 dpi
const IMG_MAX_H = 540;                                              // يترك مجالًا للعنوان والشرح على الصفحة نفسها
const BD = { style: BorderStyle.SINGLE, size: 4, color: C.rule };

// ---------- عدد الجداول بصيغته العربية الصحيحة ----------
function pl(n) {
  if (n === 1) return 'جدول واحد';
  if (n === 2) return 'جدولان';
  if (n <= 10) return `${n} جداول`;
  return `${n} جدولًا`;
}

// ---------- عناصر مساعدة ----------
function run(text, o = {}) {
  return new TextRun({ text, font: o.mono ? MONO : FONT, size: o.size || SZ.body, bold: !!o.bold, italics: !!o.italic,
    color: o.color, rightToLeft: !o.mono });
}
function para(children, o = {}) {
  return new Paragraph({ children, bidirectional: true, alignment: o.align, pageBreakBefore: !!o.pageBreak,
    keepNext: !!o.keepNext, spacing: o.spacing || { before: 0, after: 110, line: 300 } });
}
function text(t, o = {}) { return para([run(t, o)], o); }
function h1(t, pageBreak = true) { return new Paragraph({ heading: HeadingLevel.HEADING_1, bidirectional: true, pageBreakBefore: pageBreak,
  children: [new TextRun({ text: t, font: FONT, size: SZ.h1, bold: true, color: C.navy, rightToLeft: true })] }); }
function h2(t, pageBreak = false) { return new Paragraph({ heading: HeadingLevel.HEADING_2, bidirectional: true, pageBreakBefore: pageBreak,
  children: [new TextRun({ text: t, font: FONT, size: SZ.h2, bold: true, color: C.blue, rightToLeft: true })] }); }

function cell(value, width, o = {}) {
  const fill = o.head ? C.head : o.shade;
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    shading: fill ? { type: ShadingType.CLEAR, fill, color: 'auto' } : undefined,
    margins: { top: 45, bottom: 45, left: 80, right: 80 },
    verticalAlign: VerticalAlign.CENTER,
    borders: { top: BD, bottom: BD, left: BD, right: BD },
    children: [new Paragraph({ bidirectional: true, spacing: { before: 0, after: 0, line: 252 },
      children: [run(String(value ?? ''), { mono: !!o.mono, size: o.mono ? SZ.tableCode : SZ.table, bold: o.head || o.bold,
        color: o.head ? 'FFFFFF' : undefined })] })],
  });
}

// جدول بعناوين مكرّرة في كل صفحة؛ الأعمدة المُمرَّرة كنسب من عرض الصفحة تُحوَّل إلى DXA بمجموع دقيق
function table(headers, rows, weights, monoCols = []) {
  const total = weights.reduce((a, b) => a + b, 0);
  const widths = weights.map(w => Math.floor(CONTENT_W * w / total));
  widths[widths.length - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);
  const head = new TableRow({ tableHeader: true, cantSplit: true,
    children: headers.map((h, i) => cell(h, widths[i], { head: true })) });
  const body = rows.map((r, ri) => new TableRow({ cantSplit: true,
    children: r.map((v, i) => cell(v, widths[i], { mono: monoCols.includes(i), shade: ri % 2 ? C.band : undefined })) }));
  return new Table({ rows: [head, ...body], width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: widths, visuallyRightToLeft: true });
}

// جدول مفاتيح/بيانات وصفي (خلية المفتاح في عمود ملوّن)
function keyValue(rows) {
  const widths = [3000, CONTENT_W - 3000];
  return new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: widths, visuallyRightToLeft: true,
    rows: rows.map(([k, v]) => new TableRow({ children: [cell(k, widths[0], { bold: true, shade: C.metaKey }), cell(v, widths[1])] })) });
}

// صورة PNG بدقة مضاعفة (تُقرأ في Word وLibreOffice والمتصفحات كلها)، مقاسة لتملأ الصفحة الأفقية مع الحفاظ على النسبة
function diagram(img, caption) {
  const png = fs.readFileSync(path.join(DOCS, img.image));
  const scale = Math.min(IMG_MAX_W / img.w, IMG_MAX_H / img.h, 1.25);
  const width = Math.round(img.w * scale), height = Math.round(img.h * scale);
  return [
    new Paragraph({ alignment: AlignmentType.CENTER, keepNext: true, bidirectional: true, spacing: { before: 60, after: 60 },
      children: [new ImageRun({ type: 'png', data: png, transformation: { width, height },
        altText: { name: img.image, title: caption, description: caption } })] }),
    new Paragraph({ alignment: AlignmentType.CENTER, bidirectional: true, spacing: { before: 0, after: 160 },
      children: [run(caption, { size: SZ.small, color: C.gray, italic: true })] }),
  ];
}

function membersTable(members) {
  return table(['الجدول', 'المخطط', 'الغرض', 'PK', 'FK', 'UK'],
    members.map(x => [x.fq, x.schema, x.purpose, x.pk, x.fk, x.uq]), [3300, 1000, 6496, 2500, 700, 800], [0]);
}
function relationsTable(rels) {
  if (!rels.length) return text('لا توجد مفاتيح أجنبية عملية لجداول هذه المجموعة.', { size: SZ.small, color: C.gray, italic: true });
  return table(['الجدول الابن', 'العمود', 'الجدول الأب', 'الإلزام', 'الحذف', 'نطاق الربط', 'النوع', 'الرسم'],
    rels.map(r => [r.child, r.column, r.parent, r.required ? 'إلزامي' : 'اختياري', r.cascade ? 'حذف متسلسل' : 'يمنع الحذف',
      r.via.length ? r.via.join(', ') : '—', r.kind, r.drawn ? 'مرسوم' : 'لا']),
    [3300, 2700, 2600, 1000, 1200, 2000, 900, 800], [0, 1, 2]);
}

// ---------- المحتوى ----------
const body = [];

// الغلاف وبيانات الوثيقة
body.push(new Paragraph({ bidirectional: true, alignment: AlignmentType.RIGHT, spacing: { before: 600, after: 120 },
  children: [new TextRun({ text: m.title, font: FONT, size: SZ.title, bold: true, color: C.navy, rightToLeft: true })] }));
body.push(new Paragraph({ bidirectional: true, alignment: AlignmentType.RIGHT, spacing: { before: 0, after: 360 },
  children: [new TextRun({ text: m.subtitle, font: FONT, size: SZ.sub, color: C.gray, rightToLeft: true })] }));
body.push(keyValue([
  ['الوثيقة', 'مخطط علاقات الجداول (ERD) لكل وحدة وللنواة، مع جداول العلاقات الكاملة'],
  ['الإصدار', m.version],
  ['التاريخ', m.date],
  ['الجداول', `${m.tables} جدولًا في ${m.schemas} مخططًا (schema)`],
  ['المفاتيح الأجنبية', `${m.fk_total} مفتاحًا في DDL = ${m.fk_owner} مفتاح ملكية للمشترك (TenantId → plat.Tenant، تُولَّد آليًا) + ${m.fk_model} علاقة، منها ${m.fk_declared} مكتوبة في النموذج و${m.fk_generated} مولّدة آليًا من علامتي rev وsrc`],
  ['القيود الفريدة', `${m.unique_total} قيدًا في DDL (قيود UQ والفهارس الفريدة)`],
  ['مجموعات الرسم', `${m.groups} مجموعةً رسم: ${m.core_groups} للنواة و${m.module_groups} للوحدات م0 إلى م7/م8، بحد ${m.max_tables} جداول لكل رسم`],
  ['المصدر', m.source],
]));
body.push(h1('قراءة الرسم', true));
body.push(text('ترسم الرسوم بتدوين Crow\'s Foot. كل خط يربط جدول الأب بجدول الابن، واسمه أعمدة الربط بينهما.', { spacing: { before: 0, after: 140, line: 300 } }));
body.push(table(['الرمز', 'الطرف', 'المعنى'], [
  ['||', 'طرف الأب، إلزامي', 'كل صف ابن يجب أن يشير إلى أب واحد، فالعمود الإلزامي لا يقبل NULL.'],
  ['|o', 'طرف الأب، اختياري', 'الابن قد لا يشير إلى أب، والعمود يقبل NULL.'],
  ['}o', 'طرف الابن', 'الأب الواحد يمكن أن يملك صفرًا أو أكثر من الأبناء.'],
  ['PK', 'مفتاح أساسي', 'كما في DDL؛ يسبقه TenantId في المفاتيح المركّبة.'],
  ['FK', 'مفتاح أجنبي عملي', 'يشير إلى جدول آخر. عمود الملكية TenantId لا يُعدّ هنا (انظر الملاحظات).'],
  ['UK', 'عدد القيود الفريدة', 'عدد قيود UQ والفهارس الفريدة في DDL، ومنها المصفّى بشرط؛ لا يُرسم في الشكل.'],
  ['الحذف', 'حذف متسلسل / يمنع الحذف', 'حذف متسلسل: يُحذف الابن مع أبيه. يمنع الحذف: لا يُحذف الأب ما دام له أبناء.'],
  ['الرسم', 'مرسوم / لا', 'الرسم يعرض العلاقات بين جداول الرسم نفسه، ومنها العلاقة الذاتية (جدول يشير إلى نفسه). العلاقة إلى جدول في رسم آخر، وعمود الإثبات، تُذكران في جدول العلاقات ولا تُرسمان.'],
  ['نطاق الربط', 'أعمدة إضافية', 'الأعمدة التي تضاف إلى العمود نفسه ليكوّن المفتاح المركّب، مثل FacilityId وLimitId.'],
  ['النوع', 'عمل / إثبات', 'عمل: علاقة وظيفية بين بيانات العمل. إثبات: تتبع المصدر أو التحقق أو التعارض أو سلسلة المراجعة.'],
], [1200, 2800, 10796], [0]));
body.push(text('ملاحظات الرسم والجداول:', { bold: true, keepNext: true, spacing: { before: 200, after: 80 } }));
body.push(text(`• كل جدول مملوك للمشترك يحمل عمود TenantId يشير إلى plat.Tenant، وهي ${m.fk_owner} علاقة ملكية، لا تُرسم ولا تُعرض في جداول العلاقات. plat.Tenant هو جذر المشترك: يحمل TenantId مفتاحًا أساسيًا لا مفتاح ملكية، فلا يُعدّ في العمود.`));
body.push(text(`• أعمدة الإثبات والتتبع (${M.meta.provenance.join('، ')}) تُعلَّم «إثبات»، وهي ${m.fk_prov} مفتاحًا أجنبيًا، ولا تُرسم.`));
body.push(text('• كل جدول يظهر في رسم واحد بالضبط في الملحق أ؛ وقد يظهر أيضًا في رسوم النواة.'));
body.push(text('• الإحالات المختصرة في وصف الجداول (مثل «10» و«13» و«§6.2») تشير إلى وثائق المواصفات في مجلد docs/، وليست جزءًا من هذا الملف.'));
body.push(text(`• الأرقام تُحسب من النموذج والـDDL المولَّد، وتُقارَن بينهما قبل كتابة هذا الملف: ${m.tables} جدولًا، و${m.fk_total} مفتاحًا أجنبيًا، و${m.unique_total} قيدًا فريدًا.`));

// §1 مخطط المخططات
body.push(h1('1. خريطة المخططات'));
body.push(text('كل مخطط (schema) صندوق، والعلاقة بين مخططين عدد المفاتيح الأجنبية التي تربط جداولهما. تُرسم الأزواج التي فيها خمسة مفاتيح فأكثر فقط؛ الباقي يظهر في جداول المجموعات.', { spacing: { before: 0, after: 120, line: 300 } }));
body.push(...diagram(M.schemaMap, 'الشكل 1: خريطة المخططات وعدد المفاتيح الأجنبية بين كل مخططين'));
body.push(h2('العلاقات بين المخططات (5 مفاتيح فأكثر)', true));
body.push(table(['المخطط الأب', 'المخطط الابن', 'عدد المفاتيح'],
  M.schemaMap.pairs.map(p => [p.parent, p.child, p.count]), [3000, 3000, 2000], [0, 1]));
body.push(h2('المخططات والجداول', true));
body.push(table(['المخطط', 'عدد الجداول', 'مفتاح الملكية TenantId'],
  M.schemaMap.schemas.map(s => [s.schema, s.tables, s.owned]), [3000, 2500, 2500], [0]));

// §2 النواة: رسم لكل أربعة جداول، كما في الوحدات
body.push(h1('2. النواة: المشترك والهوية والصلاحيات'));
body.push(text(`تُرسم جداول النواة (${pl(M.core.members.length)}) في ${M.coreGroups.length} رسوم متتالية، لكل رسم أربعة جداول على الأكثر. العلاقات بين رسوم النواة تظهر في جداول العلاقات.`, { spacing: { before: 0, after: 120, line: 300 } }));
let coreFig = 1;
M.coreGroups.forEach((g, i) => {
  coreFig += 1;
  body.push(h2(`2.${i + 1} ${g.title}`));
  body.push(text(g.sub, { size: SZ.small, color: C.gray, keepNext: true, spacing: { before: 0, after: 60 } }));
  body.push(...diagram(g, `الشكل ${coreFig}: ${g.title} (${pl(g.members.length)})`));
  body.push(h2('الجداول', false));
  body.push(membersTable(g.members));
  body.push(h2('العلاقات', false));
  body.push(relationsTable(g.relations));
});

// §3 مخططات الوحدات
body.push(h1('3. رسوم الوحدات', false));
body.push(text(`تغطي ${m.module_groups} مجموعةً رسم كل جداول النموذج، وكل جدول يظهر في مجموعة واحدة بالضبط. الجدول التالي يلخص الوحدات:`, { spacing: { before: 0, after: 120, line: 300 } }));
body.push(table(['الوحدة', 'عدد مجموعات الرسم', 'عدد الجداول'],
  M.modules.map(x => [x.label, x.groups, x.tables]), [3000, 3000, 3000], [0]));
let fig = 1 + M.coreGroups.length;
M.groups.forEach((g, i) => {
  fig += 1;
  body.push(h2(`3.${i + 1} ${g.title}`));
  body.push(text(g.sub, { size: SZ.small, color: C.gray, keepNext: true, spacing: { before: 0, after: 60 } }));
  body.push(...diagram(g, `الشكل ${fig}: ${g.title} (${pl(g.members.length)})`));
  body.push(h2('الجداول', false));
  body.push(membersTable(g.members));
  body.push(h2('العلاقات', false));
  body.push(relationsTable(g.relations));
});

// الملحق: فهرس الجداول
body.push(h1('الملحق أ. فهرس الجداول'));
body.push(text(`${pl(M.index.length)} مرتبة بالمخطط ثم الاسم. عمود «المجموعة» يحدد مجموعة الرسم التي ترسم الجدول.`, { spacing: { before: 0, after: 120, line: 300 } }));
body.push(table(['الجدول', 'المخطط', 'المجموعة', 'الغرض'],
  M.index.map(i => [i.fq, i.schema, i.group, i.purpose]), [3000, 1200, 4800, 5796], [0]));

// ---------- المستند ----------
const doc = new Document({
  creator: 'Claude', title: m.title, description: 'مخطط علاقات جداول قاعدة البيانات — BankFas',
  styles: {
    default: { document: { run: { font: FONT, size: SZ.body, rightToLeft: true, language: { value: 'ar-SA', bidirectional: 'ar-SA' } },
      paragraph: { bidirectional: true } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.h1, bold: true, color: C.navy },
        paragraph: { spacing: { before: 300, after: 140 }, outlineLevel: 0, keepNext: true, bidirectional: true,
          border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: C.navy, space: 3 } } } },
      { id: 'Heading2', name: 'heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.h2, bold: true, color: C.blue },
        paragraph: { spacing: { before: 220, after: 100 }, outlineLevel: 1, keepNext: true, bidirectional: true } },
    ],
  },
  sections: [{
    properties: { page: { size: { width: PORT_W, height: PORT_H, orientation: PageOrientation.LANDSCAPE },
      margin: { top: MARGIN.top, bottom: MARGIN.bottom, left: MARGIN.left, right: MARGIN.right, header: 500, footer: 500 } } },
    headers: { default: new Header({ children: [new Paragraph({ bidirectional: true, spacing: { after: 0 },
      border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: C.rule, space: 4 } },
      children: [new TextRun({ text: 'مخطط علاقات جداول قاعدة البيانات · BankFas · ' + m.version, font: FONT, size: SZ.small, color: C.gray, rightToLeft: true })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, bidirectional: true, children: [
      new TextRun({ text: 'صفحة ', font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ text: ' من ', font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ children: [PageNumber.TOTAL_PAGES], font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
    ] })] }) },
    children: body,
  }],
});

// ترتيب عناصر pBdr كما يطلبه المخطط (top,left,bottom,right) و<w:bidi/> في القسم (نفس معالجة md2docx)
async function postProcess(buf) {
  const zip = await JSZip.loadAsync(buf);
  const p = 'word/document.xml';
  let xml = await zip.file(p).async('string');
  xml = xml.replace(/<w:pBdr>([\s\S]*?)<\/w:pBdr>/g, (mm, inner) => {
    const parts = inner.match(/<w:(top|left|bottom|right|between|bar)\b[^>]*\/>/g) || [];
    const rank = t => ['top', 'left', 'bottom', 'right', 'between', 'bar'].indexOf(t.match(/<w:(\w+)/)[1]);
    return '<w:pBdr>' + parts.sort((a, b) => rank(a) - rank(b)).join('') + '</w:pBdr>';
  });
  xml = xml.replace(/<w:sectPr\b[^>]*>[\s\S]*?<\/w:sectPr>/g, s => s.includes('<w:bidi/>') ? s : s.replace('<w:docGrid', '<w:bidi/><w:docGrid'));
  zip.file(p, xml);
  return zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
}

Packer.toBuffer(doc).then(postProcess).then(buf => {
  fs.writeFileSync(outFile, buf);
  console.log('wrote', outFile, buf.length, 'bytes; figures:', fig, '; groups:', M.groups.length, '; index rows:', M.index.length);
});
