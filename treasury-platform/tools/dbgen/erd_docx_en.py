#!/usr/bin/env python3
"""erd_docx_en.py — English Word document for the database relationship diagrams.

Usage: python3 tools/dbgen/erd_docx_en.py <manifest.json> <output.docx>
Input: the manifest written by erd_build_en.py (all counts come from the model and the generated DDL).
Layout: A4 portrait for the front matter; A3 landscape for the conventions, the schema overview, every chart
and the appendices. Charts are placed at natural size (1 pt of chart = 1 pt of page) unless they are wider or
taller than the page, in which case they are scaled down; the scale used is printed under each figure.
"""
import json, os, sys
from docx import Document
from docx.enum.section import WD_ORIENT, WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Mm, Pt, RGBColor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
DOCS = os.path.join(ROOT, 'docs')
NAVY = RGBColor(0x1F, 0x3A, 0x5F)
MUTED = RGBColor(0x6B, 0x72, 0x80)
FONT = 'Arial'
HEADER_FILL = '1F3A5F'
BAND_FILL = 'E8EEF6'
A3_W, A3_H, A4_W, A4_H = 420, 297, 210, 297
MARGIN_MM = 15
USABLE_W_PT = (A3_W - 2 * MARGIN_MM) / 25.4 * 72            # about 1105 pt
USABLE_H_PT = 640.0                                         # chart height left after the figure caption


def shade(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    tc_pr.append(shd)


def repeat_header(row):
    tr_pr = row._tr.get_or_add_trPr()
    el = OxmlElement('w:tblHeader')
    el.set(qn('w:val'), 'true')
    tr_pr.append(el)


def no_split(row):
    tr_pr = row._tr.get_or_add_trPr()
    el = OxmlElement('w:cantSplit')
    el.set(qn('w:val'), 'true')
    tr_pr.append(el)


def cell_text(cell, text, size=8, bold=False, color=None, align=None):
    cell.text = ''
    p = cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.space_before = Pt(0)
    if align:
        p.alignment = align
    run = p.add_run(str(text))
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.name = FONT
    if color is not None:
        run.font.color.rgb = color


def table(doc, headers, rows, widths_mm, size=8, zebra=False):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.LEFT
    t.autofit = False
    hdr = t.rows[0]
    repeat_header(hdr)
    for i, h in enumerate(headers):
        c = hdr.cells[i]
        cell_text(c, h, size=size, bold=True, color=RGBColor(0xFF, 0xFF, 0xFF))
        shade(c, HEADER_FILL)
    for n, r in enumerate(rows):
        row = t.add_row()
        no_split(row)
        for i, v in enumerate(r):
            cell_text(row.cells[i], v, size=size)
            if zebra and n % 2 == 1:
                shade(row.cells[i], BAND_FILL)
    for i, w in enumerate(widths_mm):
        t.columns[i].width = Mm(w)
    for row in t.rows:
        for i, w in enumerate(widths_mm):
            row.cells[i].width = Mm(w)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def para(doc, text, size=9.5, bold=False, italic=False, color=None, after=4, align=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(after)
    if align:
        p.alignment = align
    run = p.add_run(text)
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.italic = italic
    run.font.name = FONT
    if color is not None:
        run.font.color.rgb = color
    return p


def heading(doc, text, level):
    h = doc.add_heading(text, level=level)
    for r in h.runs:
        r.font.name = FONT
        r.font.color.rgb = NAVY
    return h


def add_field(paragraph, instr):
    run = paragraph.add_run()
    b = OxmlElement('w:fldChar'); b.set(qn('w:fldCharType'), 'begin')
    it = OxmlElement('w:instrText'); it.set(qn('xml:space'), 'preserve'); it.text = instr
    s = OxmlElement('w:fldChar'); s.set(qn('w:fldCharType'), 'separate')
    t = OxmlElement('w:t'); t.text = '1'
    e = OxmlElement('w:fldChar'); e.set(qn('w:fldCharType'), 'end')
    for el in (b, it, s, t, e):
        run._r.append(el)
    run.font.size = Pt(8)


def set_orientation(section, landscape):
    if landscape:
        section.orientation = WD_ORIENT.LANDSCAPE
        section.page_width, section.page_height = Mm(A3_W), Mm(A3_H)
    else:
        section.orientation = WD_ORIENT.PORTRAIT
        section.page_width, section.page_height = Mm(A4_W), Mm(A4_H)
    for side in ('left_margin', 'right_margin', 'top_margin', 'bottom_margin'):
        setattr(section, side, Mm(MARGIN_MM))


def picture(doc, path, w_pt, h_pt, caption):
    scale = min(1.0, USABLE_W_PT / w_pt, USABLE_H_PT / h_pt)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.keep_with_next = True
    p.add_run().add_picture(path, width=Pt(w_pt * scale))
    para(doc, f'{caption}  ·  printed at {scale * 100:.0f}% of natural size'
         + (f' (smallest text {8 * scale:.1f} pt)' if scale < 1 else ''),
         size=8, italic=True, color=MUTED, after=6, align=WD_ALIGN_PARAGRAPH.CENTER)
    return scale


def build(manifest, out_path):
    m = manifest
    meta = m['meta']
    doc = Document()
    st = doc.styles['Normal']
    st.font.name = FONT
    st.font.size = Pt(9.5)
    for name, size in (('Heading 1', 16), ('Heading 2', 12.5), ('Heading 3', 10.5)):
        s = doc.styles[name]
        s.font.name = FONT
        s.font.size = Pt(size)
        s.font.color.rgb = NAVY

    # ---------------- front matter (A4 portrait) ----------------
    front = doc.sections[0]
    set_orientation(front, landscape=False)
    hdr = front.header.paragraphs[0]
    hdr.text = 'BankFas · Database relationship diagrams · v0.5 draft · English'
    hdr.runs[0].font.size = Pt(8)
    hdr.runs[0].font.color.rgb = MUTED
    ftr = front.footer.paragraphs[0]
    ftr.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    ftr.add_run('Page ').font.size = Pt(8)
    add_field(ftr, 'PAGE')

    para(doc, 'BankFas treasury platform', size=11, color=MUTED, after=2)
    para(doc, 'Database Relationship Diagrams', size=24, bold=True, color=NAVY, after=2)
    para(doc, 'Entity relationship diagrams for the SQL Server 2025 database · '
              f'{meta["tables"]} tables · {meta["schemas"]} schemas · {meta["fk_total"]} foreign keys',
         size=10.5, color=MUTED, after=14)

    heading(doc, 'Document control', 2)
    table(doc, ['Item', 'Value'], [
        ['Document', 'Database relationship diagrams (ERD), English edition'],
        ['Version and status', 'v0.5 · draft for specialist review'],
        ['Date', meta['date']],
        ['Product', 'BankFas multi-tenant treasury platform'],
        ['Database platform', 'Microsoft SQL Server 2025 (T-SQL DDL generated from the model)'],
        ['Scope', f'All {meta["tables"]} tables in {meta["schemas"]} schemas; {meta["fk_total"]} foreign keys; '
                  f'{meta["unique_total"]} unique constraints'],
        ['Source of truth', 'db/model/*.model (purposes, flags, columns); db/generated/tsql (keys, nullability, counts)'],
        ['Generated by', 'tools/dbgen/erd_build_en.py and erd_layout.py; this document is built by erd_docx_en.py'],
    ], widths_mm=[42, 120], size=8.5)

    heading(doc, 'Revision history', 2)
    table(doc, ['Version', 'Date', 'Change'], [
        ['v0.3', meta['date'], 'Arabic edition with Mermaid and Graphviz diagrams. Superseded by v0.4.'],
        ['v0.5', meta['date'], 'Open items and decisions added from two specialist reviews (section 4). Lender-share rule drafted as a trigger '
                               '(db/static/050). Foreign-key index guard added. Diagrams unchanged in content.'],
        ['v0.4', meta['date'], 'English re-issue. Diagrams redrawn to SQL Server database-diagram conventions: '
                               'table boxes with KEY, COLUMN, TYPE and NULL columns; orthogonal connectors anchored on '
                               'the exact key row; crow\'s-foot notation; grey boxes for tables outside the chart.'],
    ], widths_mm=[22, 26, 114], size=8.5)

    heading(doc, 'Contents', 2)
    for line in ['1  Conventions and legend',
                 '2  Schema overview',
                 '3  Diagrams by module (M0 to M8)',
                 '4  Open items and decisions',
                 'Appendix A  Table index',
                 'Appendix B  Reconciliation with the DDL']:
        para(doc, line, size=10, after=2)
    para(doc, '', after=4)
    para(doc, 'How to read this document. Every diagram is followed by its table list (purpose, primary key, '
              'unique constraints and foreign keys) and its relation list (child column, parent column, required or '
              'optional, cascade). Tables that have a parent in another diagram appear as grey boxes with only the '
              'referenced key, so every connector drawn has both ends on the page.', size=9, after=4)

    # ---------------- body (A3 landscape) ----------------
    body = doc.add_section(WD_SECTION.NEW_PAGE)
    set_orientation(body, landscape=True)

    heading(doc, '1  Conventions and legend', 1)
    para(doc, 'The diagrams follow Microsoft SQL Server database-diagram conventions. Each table is a box whose '
              'header holds the schema-qualified name. Under the header, one row per shown column carries its key '
              'role, column name, data type and nullability, exactly as created by the generated T-SQL.', after=6)
    lg = m['legend']
    picture(doc, os.path.join(DOCS, lg['png']), lg['w_pt'], lg['h_pt'], 'Figure 1  Legend: a sample of the symbols used in every diagram')
    table(doc, ['Symbol or text', 'Meaning'], [
        ['Navy header', 'A table owned by the tenant model; its rows are tenant-scoped.'],
        ['Grey header', 'A reference table whose parent or child lies outside this diagram. Only the referenced key is shown.'],
        ['PK', 'Primary key column. Composite keys show every non-tenant key column with PK.'],
        ['FK', 'Foreign-key column that takes part in a drawn relation.'],
        ['UQ', 'Column referenced by a foreign key from another table but not part of the primary key (alternate key).'],
        ['TYPE', 'SQL Server data type as generated. varchar(n) and decimal(p,s) show their length or precision.'],
        ['NULL', '"not null" = the column must have a value; "null" = the column may be empty.'],
        ['TenantId', 'Every composite key starts with TenantId. TenantId columns are omitted from the diagrams to keep '
                     'them readable; the relation lists include them where they are part of a foreign key. '
                     'TenantId → plat.Tenant (tenant ownership) is not drawn.'],
        ['+ N more columns', 'Non-key columns of the table that are not drawn. They are described in the data dictionary.'],
        ['Line with one bar (||)', 'Parent end of a mandatory foreign key: each child row has exactly one parent.'],
        ['Line with bar and circle (|o)', 'Parent end of an optional foreign key: each child row has zero or one parent.'],
        ['Crow\'s foot with circle (o<)', 'Child end of every foreign key: a parent row has zero or many child rows.'],
        ['Traceability link', 'A provenance or audit foreign key (for example CreatedBy or SourceDocumentId). It is listed in '
                              'the relation lists but not drawn, to keep the diagrams to business relations.'],
    ], widths_mm=[62, 200], size=8.5)

    heading(doc, '2  Schema overview', 1)
    para(doc, f'The {meta["tables"]} tables are grouped in {meta["schemas"]} schemas. "Owned" counts the tables that '
              'carry a TenantId foreign key to plat.Tenant (tenant-owned data); the other tables are global.', after=6)
    table(doc, ['Schema', 'Description', 'Tables', 'Tenant-owned'],
          [[s['schema'], s['text'], s['tables'], s['owned']] for s in m['schemas']],
          widths_mm=[24, 170, 24, 30], size=8.5, zebra=True)
    heading(doc, 'Foreign keys between schemas', 2)
    para(doc, 'Number of model foreign keys from a table in the child schema to a table in the parent schema. '
              'Foreign keys inside a schema are not counted.', after=6)
    table(doc, ['Child schema (holds the FK)', 'Parent schema (referenced)', 'Foreign keys'],
          [[p['child'], p['parent'], p['count']] for p in m['pairs']],
          widths_mm=[80, 80, 40], size=8.5, zebra=True)

    heading(doc, '3  Diagrams by module', 1)
    para(doc, f'{len(m["charts"])} diagrams cover {meta["tables"]} tables. Each table is a member of exactly one diagram, '
              'and is shown in navy there. Where a group had more tables than fit one A3 page, it is split into parts '
              'with the same title; a table repeated in a later part is marked as continued.', after=4)
    table(doc, ['Module', 'Diagrams', 'Tables'],
          [[md['label'], md['charts'], md['tables']] for md in m['modules']],
          widths_mm=[120, 40, 40], size=8.5)

    fig = 1
    current_module = None
    for ch in m['charts']:
        fig += 1
        if ch['module'] != current_module:
            current_module = ch['module']
            heading(doc, current_module, 2)
        title = ch['title'] + (f' (part {ch["part"]} of {ch["parts"]})' if ch['parts'] > 1 else '')
        heading(doc, title, 3)
        para(doc, ch['subtitle'], size=9, italic=True, color=MUTED, after=4)
        n_members = len(ch['members'])
        picture(doc, os.path.join(DOCS, ch['png']), ch['w_pt'], ch['h_pt'],
                f'Figure {fig}  {title}  ·  {n_members} table{"s" if n_members != 1 else ""} '
                f'with {len(ch["refs"])} referenced table{"s" if len(ch["refs"]) != 1 else ""} outside the diagram')
        table(doc, ['Table', 'Purpose', 'Primary key', 'UQ', 'FK', 'Note'],
              [[mm['fq'], mm['purpose'], mm['pk'], mm['uq'], mm['fk'],
                'continued from an earlier part' if mm['continued'] else ''] for mm in ch['members']],
              widths_mm=[52, 118, 52, 14, 14, 12], size=7.8, zebra=True)
        if ch['relations']:
            table(doc, ['Child table', 'Child column(s)', 'Parent table', 'Parent column(s)', 'Required', 'Cascade', 'Kind', 'Drawn'],
                  [[r['child'], r['columns'], r['parent'], r['parent_columns'],
                    'yes' if r['required'] else 'no', 'delete' if r['cascade'] else '',
                    r['kind'], 'yes' if r['drawn'] else 'no'] for r in ch['relations']],
                  widths_mm=[48, 52, 48, 52, 18, 18, 22, 14], size=7.8, zebra=True)

    heading(doc, '4  Open items and decisions', 1)
    para(doc, 'Items raised by the two specialist reviews of 12 October 2026, with the state of the model and the next step. '
              'A status marked "drafted" or "verified" names the file that implements or checks it. Nothing in this section '
              'has been executed on SQL Server 2025 yet.', after=6)
    from erd_open_items import ITEMS
    table(doc, ['ID', 'Source', 'Finding', 'Status in the model', 'Next step'],
          [[i['id'], i['sources'], i['finding'], i['status'], i['next']] for i in ITEMS],
          widths_mm=[14, 40, 75, 85, 48], size=7.6, zebra=True)

    heading(doc, 'Appendix A  Table index', 1)
    para(doc, f'All {meta["tables"]} tables in alphabetical order, with the diagram in which each table is a member.', after=6)
    table(doc, ['Table', 'Purpose', 'Diagram'],
          [[r['fq'], r['purpose'], r['chart']] for r in m['index']],
          widths_mm=[62, 180, 30], size=7.6, zebra=True)

    heading(doc, 'Appendix B  Reconciliation with the DDL', 1)
    para(doc, 'Every count below is taken from the model and the generated T-SQL, and the build stops if any count '
              'disagrees with the DDL.', after=6)
    table(doc, ['Quantity', 'Count', 'How it is obtained'], [
        ['Tables', meta['tables'], 'CREATE TABLE statements in 001_tables.sql'],
        ['Schemas', meta['schemas'], 'Distinct schema prefixes of the tables'],
        ['Foreign keys (total)', meta['fk_total'], 'ALTER TABLE … FOREIGN KEY statements in 002_foreign_keys.sql'],
        ['  tenant ownership (TenantId → plat.Tenant)', meta['fk_owner'], 'not drawn; one per tenant-owned table'],
        ['  model foreign keys', meta['fk_model'], 'from the model; equals total minus ownership'],
        ['    drawn in diagrams', meta['fk_drawn'], 'each appears once in a diagram, as a connector and a relation row'],
        ['    traceability (listed, not drawn)', meta['fk_traceability'], 'provenance and audit links'],
        ['Unique constraints', meta['unique_total'], 'UQ_ constraints and unique filtered indexes'],
        ['Indexes', meta['indexes'], 'CREATE INDEX statements in 003_indexes.sql'],
        ['Diagrams', meta['charts'], 'including the legend'],
    ], widths_mm=[88, 26, 148], size=8.5, zebra=True)

    zoom = doc.settings.element.find(qn('w:zoom'))
    if zoom is not None:
        zoom.set(qn('w:percent'), '100')          # the default template omits this required attribute
    doc.save(out_path)
    return out_path


if __name__ == '__main__':
    with open(sys.argv[1], encoding='utf-8') as fh:
        manifest = json.load(fh)
    print(build(manifest, sys.argv[2]))
