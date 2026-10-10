#!/usr/bin/env node
/* md2docx — converts one Arabic (RTL) Markdown design document to a Word .docx.
   Usage:  NODE_PATH=$(npm root -g) node tools/md2docx/md2docx.js <in.md> <out.docx> [--header "short header text"]
   Pipeline: pandoc (gfm -> JSON AST) -> docx-js (RTL paragraphs/tables/lists) -> post-process (<w:bidi/> on the section).
   Supported Markdown: headings, paragraphs, bold/italic/inline code, pipe tables, bullet/ordered/nested lists,
   block quotes, fenced code blocks, horizontal rules (dropped), links (rendered as plain text). */
'use strict';
const fs = require('fs');
const { execFileSync } = require('child_process');
const D = require('docx');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  AlignmentType, HeadingLevel, LevelFormat, Header, Footer, PageNumber, InternalHyperlink, Bookmark,
  PageBreak, VerticalAlign,
} = D;

const [,, inFile, outFile, ...rest] = process.argv;
if (!inFile || !outFile) { console.error('usage: md2docx.js in.md out.docx [--header text]'); process.exit(2); }
const hi = rest.indexOf('--header');
const HEADER_TEXT = hi >= 0 ? rest[hi + 1] : '';

// ---------- look & feel ----------
const FONT = 'Arial', MONO = 'Courier New', EMOJI_FONT = 'Segoe UI Emoji';
const C = { navy: '1F3A5F', blue: '2B5C8A', gray: '5B6670', rule: 'BFC9D6', band: 'F5F8FC', head: '1F3A5F', metaKey: 'E8EEF6',
            code: 'F1F3F5', codeText: '1F2937', quote: 'FFF8E1', quoteLine: 'E8C766' };
const SZ = { body: 21, table: 18, code: 17, inlineCode: 18, tableCode: 16, h1: 32, h2: 26, h3: 23, title: 48, small: 17 };
const PAGE = { w: 11906, h: 16838, mT: 1134, mB: 1134, mL: 1021, mR: 1021 };
const CONTENT_W = PAGE.w - PAGE.mL - PAGE.mR;
const LRM = '‎';
const EMOJI_RE = /([⚠✅✔❌\u{1F7E1}\u{1F534}\u{1F7E2}]️?)/u;

// ---------- pandoc AST ----------
const ast = JSON.parse(execFileSync('pandoc', ['-f', 'gfm', '-t', 'json', inFile], { maxBuffer: 1 << 28 }).toString('utf8'));

// ---------- inline handling ----------
function segs(inls, st = {}) {
  const out = [];
  for (const x of inls) {
    switch (x.t) {
      case 'Str': out.push({ t: x.c, ...st }); break;
      case 'Space': case 'SoftBreak': out.push({ t: ' ', ...st }); break;
      case 'LineBreak': out.push({ br: true }); break;
      case 'Strong': out.push(...segs(x.c, { ...st, b: true })); break;
      case 'Emph': out.push(...segs(x.c, { ...st, i: true })); break;
      case 'Strikeout': case 'Underline': case 'Superscript': case 'Subscript': case 'SmallCaps':
        out.push(...segs(x.c, st)); break;
      case 'Code': out.push({ t: x.c[1], ...st, code: true }); break;
      case 'Link': out.push(...segs(x.c[1], st)); break;         // relative .md links are useless in Word: keep the text
      case 'Image': out.push(...segs(x.c[1], st)); break;
      case 'Span': out.push(...segs(x.c[1], st)); break;
      case 'Quoted': out.push({ t: '"', ...st }, ...segs(x.c[1], st), { t: '"', ...st }); break;
      case 'Note': break;
      default: break;
    }
  }
  // merge neighbours with identical style
  const merged = [];
  for (const s of out) {
    const p = merged[merged.length - 1];
    if (p && !s.br && !p.br && !!p.b === !!s.b && !!p.i === !!s.i && !!p.code === !!s.code) p.t += s.t; else merged.push({ ...s });
  }
  return merged;
}
const plain = (inls) => segs(inls).map(s => s.t || '').join('');

function runsFrom(inls, o = {}) {
  const size = o.size || SZ.body, codeSize = o.codeSize || SZ.inlineCode, color = o.color, boldAll = !!o.bold;
  const rtl = o.rtl !== false;
  const runs = [];
  for (const s of segs(inls, o.st || {})) {
    if (s.br) { runs.push(new TextRun({ break: 1 })); continue; }
    if (s.code) {
      runs.push(new TextRun({ text: LRM + s.t + LRM, font: MONO, size: codeSize, bold: s.b || boldAll, color: o.codeColor || C.codeText,
        shading: o.noCodeShade ? undefined : { type: ShadingType.CLEAR, fill: C.code, color: 'auto' }, rightToLeft: rtl }));
      continue;
    }
    for (const part of s.t.split(EMOJI_RE)) {
      if (!part) continue;
      if (EMOJI_RE.test(part)) runs.push(new TextRun({ text: part, font: EMOJI_FONT, size, rightToLeft: rtl }));
      else runs.push(new TextRun({ text: part, font: FONT, size, bold: s.b || boldAll, italics: s.i, color, rightToLeft: rtl }));
    }
  }
  return runs;
}

// ---------- numbering ----------
const numberingConfigs = [{
  reference: 'bul',
  levels: [0, 1, 2, 3].map(l => ({ level: l, format: LevelFormat.BULLET, text: ['•', '–', '·', '·'][l], alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 454 * (l + 1) + 120, hanging: 284 } } } })),
}];
let orderedCount = 0;
function newOrderedRef() {
  const ref = 'ord' + (++orderedCount);
  numberingConfigs.push({ reference: ref, levels: [0, 1, 2].map(l => ({ level: l, format: LevelFormat.DECIMAL, text: `%${l + 1}.`, alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 454 * (l + 1) + 120, hanging: 340 } } } })) });
  return ref;
}

// ---------- blocks ----------
const body = [];
const headings = [];          // for the contents list
let secNo = 0;

function bodyPara(inls, extra = {}) {
  return new Paragraph({ children: runsFrom(inls, extra.run || {}), bidirectional: true, spacing: { before: 0, after: 110, line: 312 }, ...extra.p });
}

function listBlock(block, level, ordRef, out) {
  const isOrdered = block.t === 'OrderedList';
  const items = isOrdered ? block.c[1] : block.c;
  const ref = isOrdered ? (ordRef || newOrderedRef()) : 'bul';
  for (const item of items) {
    let first = true;
    for (const b of item) {
      if (b.t === 'Plain' || b.t === 'Para') {
        out.push(new Paragraph({ children: runsFrom(b.c), bidirectional: true, numbering: first ? { reference: ref, level: Math.min(level, 3) } : undefined,
          spacing: { before: 0, after: 70, line: 300 },
          indent: first ? undefined : { left: 454 * (level + 1) + 120 } }));
        first = false;
      } else if (b.t === 'BulletList' || b.t === 'OrderedList') {
        listBlock(b, level + 1, null, out);
      } else { blockToDocx(b, out); }
    }
  }
}

// weight = longest unbreakable token (so code identifiers never split) blended with total text length
function colWeights(rows, ncols) {
  const longest = new Array(ncols).fill(0), total = new Array(ncols).fill(0);
  for (const r of rows) r.forEach((cell, i) => {
    const text = cell.map(b => (b.t === 'Plain' || b.t === 'Para') ? plain(b.c) : '- '.repeat(12)).join(' ');
    total[i] = Math.max(total[i], Math.min(text.length, 200));
    for (const tok of text.split(/\s+/)) longest[i] = Math.max(longest[i], Math.min(tok.length, 60));
  });
  return longest.map((l, i) => Math.max(l * 3.0, Math.pow(Math.max(total[i], 8), 0.6) * 2.2));
}

function tableBlock(block, out) {
  const [, , colspecs, thead, tbodies] = block.c;
  const ncols = colspecs.length;
  const headRows = thead[1].map(r => r[1].map(c => c[4]));
  const bodyRows = [];
  for (const tb of tbodies) { for (const r of tb[3]) bodyRows.push(r[1].map(c => c[4])); }
  const weights = colWeights([...headRows, ...bodyRows], ncols);
  const sum = weights.reduce((a, b) => a + b, 0), MIN = 1000;
  let widths = weights.map(x => Math.max(MIN, Math.round(CONTENT_W * x / sum)));
  const over = widths.reduce((a, b) => a + b, 0) - CONTENT_W;
  if (over !== 0) { const k = widths.indexOf(Math.max(...widths)); widths[k] -= over; }
  const hdrTexts = headRows[0] ? headRows[0].map(c => c.map(b => plain(b.c || [])).join('')) : [];
  const isMeta = ncols === 2 && hdrTexts[0] === 'البند';
  const thin = { style: BorderStyle.SINGLE, size: 4, color: C.rule };
  const borders = { top: thin, bottom: thin, left: thin, right: thin };

  const mkCell = (blocks, ci, kind, ri) => {
    const paras = [];
    const header = kind === 'head';
    const keyCol = isMeta && ci === 0 && !header;
    for (const b of blocks.length ? blocks : [{ t: 'Plain', c: [] }]) {
      if (b.t === 'Plain' || b.t === 'Para') {
        paras.push(new Paragraph({
          children: runsFrom(b.c, { size: SZ.table, codeSize: SZ.tableCode, bold: header || keyCol, color: header ? 'FFFFFF' : undefined,
            codeColor: header ? 'FFFFFF' : undefined, noCodeShade: header }),
          bidirectional: true, spacing: { before: 30, after: 30, line: 264 }, keepNext: false,
        }));
      } else if (b.t === 'BulletList' || b.t === 'OrderedList') { listBlock(b, 0, null, paras); }
    }
    return new TableCell({
      children: paras, width: { size: widths[ci], type: WidthType.DXA }, borders, verticalAlign: header ? VerticalAlign.CENTER : VerticalAlign.TOP,
      margins: { top: 50, bottom: 50, left: 90, right: 90 },
      shading: header ? { type: ShadingType.CLEAR, fill: C.head, color: 'auto' }
        : keyCol ? { type: ShadingType.CLEAR, fill: C.metaKey, color: 'auto' }
        : (ri % 2 === 1 ? { type: ShadingType.CLEAR, fill: C.band, color: 'auto' } : undefined),
    });
  };
  const rows = [];
  headRows.forEach(r => rows.push(new TableRow({ tableHeader: true, cantSplit: true, children: r.map((c, i) => mkCell(c, i, 'head', 0)) })));
  bodyRows.forEach((r, ri) => rows.push(new TableRow({ cantSplit: true, children: r.map((c, i) => mkCell(c, i, 'body', ri)) })));
  out.push(new Table({ rows, columnWidths: widths, width: { size: CONTENT_W, type: WidthType.DXA }, visuallyRightToLeft: true }));
  out.push(new Paragraph({ children: [], spacing: { before: 0, after: 120 }, bidirectional: true }));
}

function codeBlock(text, out) {
  const line = { style: BorderStyle.SINGLE, size: 4, color: C.rule, space: 4 };
  const lines = text.replace(/\n$/, '').split('\n');
  lines.forEach((ln, i) => out.push(new Paragraph({
    children: [new TextRun({ text: ln === '' ? ' ' : ln, font: MONO, size: SZ.code, color: C.codeText, rightToLeft: false })],
    alignment: AlignmentType.LEFT, bidirectional: false,
    shading: { type: ShadingType.CLEAR, fill: C.code, color: 'auto' },
    border: { top: line, left: line, bottom: line, right: line },
    spacing: { before: 0, after: i === lines.length - 1 ? 140 : 0, line: 260 }, indent: { left: 120, right: 120 }, keepLines: true, keepNext: i < lines.length - 1,
  })));
}

function blockToDocx(b, out) {
  switch (b.t) {
    case 'Header': {
      const lvl = b.c[0], inls = b.c[2];
      if (lvl === 1) {
        out.push(new Paragraph({ style: 'Title', children: runsFrom(inls, { size: SZ.title, bold: true, color: C.navy, noCodeShade: true, codeSize: 40 }), bidirectional: true }));
      } else {
        const id = `_sec${++secNo}`;
        headings.push({ id, lvl, text: plain(inls) });
        const size = lvl === 2 ? SZ.h1 : lvl === 3 ? SZ.h2 : SZ.h3;
        out.push(new Paragraph({
          heading: lvl === 2 ? HeadingLevel.HEADING_1 : lvl === 3 ? HeadingLevel.HEADING_2 : HeadingLevel.HEADING_3,
          children: [new Bookmark({ id, children: runsFrom(inls, { size, bold: true, color: lvl === 2 ? C.navy : C.blue, noCodeShade: true, codeSize: size - 4 }) })],
          bidirectional: true,
        }));
      }
      break;
    }
    case 'Para': case 'Plain': out.push(bodyPara(b.c)); break;
    case 'BulletList': case 'OrderedList': listBlock(b, 0, null, out); out.push(new Paragraph({ children: [], spacing: { before: 0, after: 60 }, bidirectional: true })); break;
    case 'BlockQuote': {
      const line = { style: BorderStyle.SINGLE, size: 6, color: C.quoteLine, space: 6 };
      for (const q of b.c) if (q.t === 'Para' || q.t === 'Plain') out.push(new Paragraph({
        children: runsFrom(q.c, { size: 20 }), bidirectional: true,
        shading: { type: ShadingType.CLEAR, fill: C.quote, color: 'auto' }, border: { top: line, left: line, bottom: line, right: line },
        spacing: { before: 60, after: 160, line: 300 }, indent: { left: 140, right: 140 },
      }));
      break;
    }
    case 'CodeBlock': codeBlock(b.c[1], out); break;
    case 'Table': tableBlock(b, out); break;
    case 'HorizontalRule': break;
    default: console.error('unsupported block', b.t);
  }
}

for (const b of ast.blocks) blockToDocx(b, body);

// ---------- contents list (internal links, no page numbers: avoids Word's "update fields" prompt) ----------
const toc = [];
const tocTitleIdx = body.findIndex(p => p && p.options && p.options.style === 'Title');
toc.push(new Paragraph({ children: [new TextRun({ text: 'المحتويات', font: FONT, size: SZ.h1, bold: true, color: C.navy, rightToLeft: true })],
  bidirectional: true, spacing: { before: 280, after: 100 }, border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: C.navy, space: 4 } } }));
for (const h of headings) {
  if (h.lvl > 3) continue;
  const sub = h.lvl === 3;
  toc.push(new Paragraph({
    bidirectional: true, spacing: { before: 0, after: sub ? 30 : 50 }, indent: { left: sub ? 560 : 0 },
    children: [new InternalHyperlink({ anchor: h.id, children: [new TextRun({ text: h.text.replace(/`/g, ''), font: FONT, size: sub ? 18 : 20, bold: !sub,
      color: sub ? C.gray : C.navy, rightToLeft: true })] })],
  }));
}
toc.push(new Paragraph({ children: [new PageBreak()] }));
// insert contents after the first table that follows the title (the metadata table), else right after the title
let insertAt = tocTitleIdx + 1;
for (let i = tocTitleIdx + 1; i < body.length; i++) { if (body[i] instanceof Table) { insertAt = i + 2; break; } if (body[i] && body[i].options && body[i].options.heading) break; }
body.splice(insertAt, 0, ...toc);

// ---------- document ----------
const hdrBorder = { bottom: { style: BorderStyle.SINGLE, size: 4, color: C.rule, space: 4 } };
const doc = new Document({
  creator: 'Claude', title: plain(ast.blocks.find(b => b.t === 'Header').c[2]), description: 'BankFas database design document',
  styles: {
    default: { document: { run: { font: FONT, size: SZ.body, rightToLeft: true, language: { value: 'ar-SA', bidirectional: 'ar-SA' } }, paragraph: { bidirectional: true } } },
    paragraphStyles: [
      { id: 'Title', name: 'Title', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.title, bold: true, color: C.navy },
        paragraph: { spacing: { before: 0, after: 160 }, bidirectional: true } },
      { id: 'Heading1', name: 'heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.h1, bold: true, color: C.navy },
        paragraph: { spacing: { before: 380, after: 140 }, outlineLevel: 0, keepNext: true, bidirectional: true,
          border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: C.navy, space: 3 } } } },
      { id: 'Heading2', name: 'heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.h2, bold: true, color: C.blue },
        paragraph: { spacing: { before: 260, after: 100 }, outlineLevel: 1, keepNext: true, bidirectional: true } },
      { id: 'Heading3', name: 'heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: SZ.h3, bold: true, color: C.blue },
        paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 2, keepNext: true, bidirectional: true } },
    ],
  },
  numbering: { config: numberingConfigs },
  sections: [{
    properties: { page: { size: { width: PAGE.w, height: PAGE.h }, margin: { top: PAGE.mT, bottom: PAGE.mB, left: PAGE.mL, right: PAGE.mR, header: 500, footer: 500 } } },
    headers: { default: new Header({ children: [new Paragraph({ bidirectional: true, border: hdrBorder, spacing: { after: 0 },
      children: [new TextRun({ text: HEADER_TEXT, font: FONT, size: SZ.small, color: C.gray, rightToLeft: true })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, bidirectional: true, children: [
      new TextRun({ text: 'صفحة ', font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ text: ' من ', font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
      new TextRun({ children: [PageNumber.TOTAL_PAGES], font: FONT, size: SZ.small, color: C.gray, rightToLeft: true }),
    ] })] }) },
    children: body,
  }],
});

// docx-js writes w:id="1" for every bookmark; Word needs unique ids. Renumber start/end pairs (bookmarks never nest here).
async function renumberBookmarks(buf) {
  const JSZip = require('jszip');
  const zip = await JSZip.loadAsync(buf);
  const path = 'word/document.xml';
  let xml = await zip.file(path).async('string');
  let next = 0; const open = [];
  xml = xml.replace(/<w:bookmarkStart w:name="([^"]+)" w:id="\d+"\/>|<w:bookmarkEnd w:id="\d+"\/>/g, (m, name) => {
    if (name !== undefined) { const id = ++next; open.push(id); return `<w:bookmarkStart w:name="${name}" w:id="${id}"/>`; }
    return `<w:bookmarkEnd w:id="${open.pop()}"/>`;
  });
  // docx-js emits paragraph borders as top,bottom,left,right; the schema wants top,left,bottom,right
  xml = xml.replace(/<w:pBdr>([\s\S]*?)<\/w:pBdr>/g, (m, inner) => {
    const parts = inner.match(/<w:(top|left|bottom|right|between|bar)\b[^>]*\/>/g) || [];
    const rank = t => ['top', 'left', 'bottom', 'right', 'between', 'bar'].indexOf(t.match(/<w:(\w+)/)[1]);
    return '<w:pBdr>' + parts.sort((a, b) => rank(a) - rank(b)).join('') + '</w:pBdr>';
  });
  // right-to-left section layout: <w:bidi/> sits after w:pgNumType/w:cols/w:titlePg/w:textDirection and before w:docGrid
  xml = xml.replace(/<w:sectPr\b[^>]*>[\s\S]*?<\/w:sectPr>/g, sect => sect.includes('<w:bidi/>') ? sect : sect.replace('<w:docGrid', '<w:bidi/><w:docGrid'));
  zip.file(path, xml);
  return zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
}
Packer.toBuffer(doc).then(renumberBookmarks).then(buf => { fs.writeFileSync(outFile, buf); console.log('wrote', outFile, buf.length, 'bytes; headings:', headings.length); });
