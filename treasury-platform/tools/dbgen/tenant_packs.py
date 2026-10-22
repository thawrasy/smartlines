#!/usr/bin/env python3
"""tenant_packs.py — checks the tenant seed packs of db/seed/packs/<PackKey>/v<N>/ (DOC-B05 sections 5.1 and 6, FR-PLT-008)
against the model, the way the application's generic seeder (app/src/BankFas.Data/Seeding/TenantPacks.cs) reads them.

  python3 tools/dbgen/tenant_packs.py            check every pack; exit 1 on an error

A pack of the generic convention has a manifest with a Tables list, a DependsOn list and References of the form
{"<file.csv>": {"<CsvColumn>": {"Column": "<FkColumn>", "Table": "<schema.Table>", "Key": "<KeyColumn>"}}}. For it:
  - every listed file exists, every CSV file of the folder is listed, and each names a table of db/model;
  - the header holds columns of the table (never TenantId, the identity key, RowVersion, PublicId, the audit columns or a
    computed column) or declared reference columns; a reference names a foreign key column of the table to its target,
    and every required column without a default is given;
  - values fit their column: 1/0 booleans, integers, enum and set members, JSON, lengths, ASCII for ascii() columns;
  - references resolve: to a row of an earlier table of the pack (or an earlier row of the same table), of a pack named
    in DependsOn (sec.Role is the pack CORE.ROLES), or of a global ref.* table seeded by db/seed/101_iso_reference.sql;
    a composite key (via=) copies the referenced row's values;
  - every row of a table with a SeedKey has one, unique in the table and prefixed with the PackKey; rows of a table
    without one are unique; the unique keys of the model hold within the pack;
  - catalogue codes match the check of the model (BR-CAT-001), a locked row is system and active, a system row has
    NameEn (BR-CAT-003), and the CHECK constraints of the S1 tables hold (limit kinds, obligation families, Shariah
    pairs, base-rate scope, list scope, numbering patterns of db/static/039, descending lead days).
The other packs (CORE.ROLES, NTF.BASE, FIN.PROVISION) keep their own conventions and checkers, core_roles_pack.py and
ntf_pack.py, even where their manifest has References the seeder reads (NTF.BASE v2); they are parsed: their files must exist, their SeedKeys be unique, and columns outside the model are noted.
"""
import csv, glob, json, os, re, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen  # noqa: E402  (the model parser)

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
PACKS = os.path.join(ROOT, 'db', 'seed', 'packs')
ISO = os.path.join(ROOT, 'db', 'seed', '101_iso_reference.sql')
FORBIDDEN = {'TenantId', 'RowVersion', 'PublicId', 'CreatedAt', 'CreatedBy', 'UpdatedAt', 'UpdatedBy'}
CODE_CHECK = "Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'"
ROLE_PACK = {'sec.Role': 'CORE.ROLES'}


def load_model():
    tables = dbgen.parse_files(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))))
    dbgen.expand(tables)
    return tables


def load_iso():
    text = open(ISO, encoding='utf-8').read()
    country = text.split('MERGE ref.Country', 1)[1].split('MERGE ref.Currency', 1)[0]
    currency = text.split('MERGE ref.Currency', 1)[1]
    return {'ref.Country': {'Iso2': set(re.findall(r"\(\s*'([A-Z]{2})',\s*'[A-Z]{3}'", country)),
                            'Iso3': set(re.findall(r"\(\s*'[A-Z]{2}',\s*'([A-Z]{3})'", country))},
            'ref.Currency': {'Code': set(re.findall(r"\(\s*'([A-Z]{3})',\s*'[0-9]{3}'", currency))}}


def read_csv(path):
    raw = open(path, 'rb').read()
    errs = []
    if raw.startswith(b'\xef\xbb\xbf'):
        errs.append('%s: UTF-8 with a BOM' % path)
    rows = list(csv.reader(raw.decode('utf-8-sig').splitlines(True) if raw else []))
    return rows, errs


OWN_CONVENTION = {'CORE.ROLES', 'NTF.BASE', 'FIN.PROVISION'}   # their SeedKeys and references follow their own checkers


def is_new_convention(man):
    refs = man.get('References', {})
    return (man.get('PackKey') not in OWN_CONVENTION and 'DependsOn' in man and isinstance(man.get('Tables'), list) and isinstance(refs, dict)
            and all(isinstance(v, dict) and all(isinstance(x, dict) for x in v.values()) for v in refs.values()))


class Checker:
    def __init__(self):
        self.model = load_model()
        self.iso = load_iso()
        self.errors, self.notes, self.counts = [], [], []
        self.packs = {}          # PackKey -> {'dir', 'man', 'tables': {table: (header, rows)}}

    def err(self, msg):
        self.errors.append(msg)

    # ------------------------------------------------------------------ loading
    def load(self):
        for man_path in sorted(glob.glob(os.path.join(PACKS, '*', 'v*', 'manifest.json'))):
            d = os.path.dirname(man_path)
            rel = os.path.relpath(d, ROOT)
            try:
                man = json.load(open(man_path, encoding='utf-8'))
            except ValueError as e:
                self.err('%s: manifest.json is not JSON (%s)' % (rel, e))
                continue
            key = man.get('PackKey')
            if key != os.path.basename(os.path.dirname(d)):
                self.err('%s: PackKey %s is not the folder name' % (rel, key))
            if man.get('SeedVersion') != int(os.path.basename(d)[1:]):
                self.err('%s: SeedVersion %s is not the folder version' % (rel, man.get('SeedVersion')))
            pack = {'dir': d, 'rel': rel, 'man': man, 'tables': {}, 'new': is_new_convention(man)}
            self.packs[key] = pack
            if not isinstance(man.get('Tables'), list):
                self.notes.append('%s: no Tables list; parsed only' % rel)
                continue
            for f in man['Tables']:
                p = os.path.join(d, f)
                if not os.path.exists(p):
                    self.err('%s: listed file %s does not exist' % (rel, f))
                    continue
                rows, e = read_csv(p)
                self.errors += e
                if not rows:
                    self.err('%s/%s: no header' % (rel, f))
                    continue
                pack['tables'][f[:-4] if f.endswith('.csv') else f] = (rows[0], rows[1:])
            for f in sorted(os.listdir(d)):
                if f.endswith('.csv') and f not in man['Tables']:
                    self.err('%s: %s is not listed in the manifest' % (rel, f))

    # ------------------------------------------------------------------ value checks
    def check_value(self, where, col, v):
        if v == '':
            return
        if col.type == 'fk':
            return
        if col.is_bool and v not in ('0', '1'):
            self.err('%s: %s = %r is not 1 or 0' % (where, col.name, v))
        elif col.type in ('int', 'bigint', 'smallint', 'tinyint') and not re.fullmatch(r'-?[0-9]+', v):
            self.err('%s: %s = %r is not an integer' % (where, col.name, v))
        elif col.enum and v not in col.enum:
            self.err('%s: %s = %r is not one of %s' % (where, col.name, v, ','.join(col.enum)))
        elif col.isset:
            parts = v.split(',')
            if any(p not in col.setvals for p in parts) or len(set(parts)) != len(parts):
                self.err('%s: %s = %r is not a set of %s' % (where, col.name, v, ','.join(col.setvals)))
        elif col.is_json:
            try:
                json.loads(v)
            except ValueError:
                self.err('%s: %s is not JSON' % (where, col.name))
        elif col.type == 'dec':
            if not re.fullmatch(r'-?[0-9]+(\.[0-9]+)?', v):
                self.err('%s: %s = %r is not a number' % (where, col.name, v))
        m = re.match(r'^(N?VARCHAR|CHAR)\((\d+)\)$', col.sqltype or '')
        if m and len(v) > int(m.group(2)):
            self.err('%s: %s is longer than %s characters' % (where, col.name, m.group(2)))
        if col.type in ('ascii', 'char') and not all(ord(ch) < 128 for ch in v):
            self.err('%s: %s = %r is not ASCII' % (where, col.name, v))

    # ------------------------------------------------------------------ reference lookup
    def key_values(self, pack, table, key, upto_table=None, upto_row=None):
        """The values of a key column available to a reference: (values, reason when unavailable)."""
        if table in self.iso:
            if key not in self.iso[table]:
                return None, '%s.%s is not a key seeded by 101_iso_reference.sql' % (table, key)
            return self.iso[table][key], None
        owners = []
        if table in pack['tables']:
            order = list(pack['tables'])
            if upto_table is not None and order.index(table) > order.index(upto_table):
                return None, '%s comes after %s in the pack' % (table, upto_table)
            owners.append(pack['key'])
        for dep in pack['man'].get('DependsOn', []):
            if dep in self.packs and table in self.packs[dep]['tables']:
                owners.append(dep)
        if not owners:
            need = ROLE_PACK.get(table)
            return None, ('%s is in no pack of DependsOn%s' % (table, ' (it is in %s)' % need if need else ''))
        vals = set()
        for o in owners:
            header, rows = self.packs[o]['tables'][table]
            if key not in header:
                return None, '%s of pack %s has no column %s' % (table, o, key)
            i = header.index(key)
            lim = upto_row if (o == pack['key'] and table == upto_table) else None
            vals |= {r[i] for r in (rows if lim is None else rows[:lim]) if i < len(r) and r[i]}
        return vals, None

    def parent_row(self, pack, table, key, value):
        for o in [pack['key']] + list(pack['man'].get('DependsOn', [])):
            if o in self.packs and table in self.packs[o]['tables']:
                header, rows = self.packs[o]['tables'][table]
                if key in header:
                    i = header.index(key)
                    for r in rows:
                        if i < len(r) and r[i] == value:
                            return dict(zip(header, r))
        return None

    # ------------------------------------------------------------------ the generic convention
    def check_pack(self, key, pack):
        pack['key'] = key
        man, rel = pack['man'], pack['rel']
        for k in ('PackKey', 'SeedVersion', 'Slice', 'Status', 'Tables', 'DependsOn', 'References', 'Sources'):
            if k not in man:
                self.err('%s: manifest has no %s' % (rel, k))
        for dep in man.get('DependsOn', []):
            if dep not in self.packs:
                self.err('%s: DependsOn %s, which is not a pack' % (rel, dep))
        for f in man.get('References', {}):
            if f not in man['Tables']:
                self.err('%s: References name %s, which is not in Tables' % (rel, f))
        for table, (header, rows) in pack['tables'].items():
            self.check_table(pack, table, header, rows)

    def check_table(self, pack, table, header, rows):
        where0 = '%s/%s.csv' % (pack['rel'], table)
        self.counts.append((pack['key'], table, len(rows)))
        t = self.model.get(table)
        if t is None:
            self.err('%s: %s is not a table of db/model' % (where0, table))
            return
        if t.is_global and not t.is_mixed:
            self.err('%s: %s is a global table, not a tenant table' % (where0, table))
        refs = pack['man'].get('References', {}).get(table + '.csv', {})
        if len(set(header)) != len(header):
            self.err('%s: duplicate header columns' % where0)
        target = {}
        for h in header:
            if h in refs:
                r = refs[h]
                c = t.colmap.get(r.get('Column'))
                if c is None:
                    self.err('%s: reference %s names %s, not a column of %s' % (where0, h, r.get('Column'), table))
                    continue
                if c.fk != r.get('Table'):
                    self.err('%s: reference %s: %s.%s refers to %s, not %s' % (where0, h, table, c.name, c.fk, r.get('Table')))
                tt = self.model.get(r.get('Table'))
                if tt is None or (r.get('Key') not in tt.colmap):
                    self.err('%s: reference %s: %s has no column %s' % (where0, h, r.get('Table'), r.get('Key')))
                if h in t.colmap:
                    self.err('%s: reference column %s is also a column of %s' % (where0, h, table))
                target[h] = c.name
                continue
            c = t.colmap.get(h)
            if c is None:
                self.err('%s: column %s is not in %s and is not a declared reference' % (where0, h, table))
            elif h in FORBIDDEN or (t.has_surrogate and h == t.idname) or c.calc:
                self.err('%s: column %s is generated by the database' % (where0, h))
            elif c.type == 'fk':
                self.err('%s: column %s is a foreign key given as an id; give a reference column' % (where0, h))
            else:
                target[h] = h
        for r in refs:
            if r not in header:
                self.err('%s: declared reference %s is not a column of the file' % (where0, r))
        given = set(target.values())
        for c in t.cols:
            if c.req and c.default is None and not c.calc and c.name not in given and c.name not in FORBIDDEN and not c.auto:
                self.err('%s: required column %s is not given' % (where0, c.name))
        # rows
        has_seed = 'SeedKey' in t.colmap
        seen_seed, seen_rows = {}, set()
        uniques = [u for u in t.uniques if u[2] is None or u[2] == 'SeedKey IS NOT NULL']
        seen_uq = [dict() for _ in uniques]
        inv = {v: k for k, v in target.items()}
        for n, row in enumerate(rows, 1):
            where = '%s row %d' % (where0, n + 1)
            if len(row) != len(header):
                self.err('%s: %d fields for %d columns' % (where, len(row), len(header)))
                continue
            rec = dict(zip(header, row))
            for h, v in rec.items():
                if h in refs:
                    if v == '':
                        if t.colmap[target[h]].req if h in target else False:
                            self.err('%s: reference %s is required' % (where, h))
                        continue
                    r = refs[h]
                    vals, why = self.key_values(pack, r['Table'], r.get('Key', 'SeedKey'), table, n - 1)
                    if vals is None:
                        self.err('%s: reference %s cannot resolve: %s' % (where, h, why))
                    elif v not in vals:
                        self.err('%s: %s = %s is not a %s.%s%s' % (where, h, v, r['Table'], r.get('Key'),
                                                                     '' if r['Table'] in self.iso else ' of the pack or its dependencies (earlier rows)'))
                    else:
                        self.check_via(where, pack, t, target[h], r, v, rec, inv)
                elif h in t.colmap:
                    c = t.colmap[h]
                    if c.req and v == '' and c.default is None:
                        self.err('%s: %s is required' % (where, h))
                    self.check_value(where, c, v)
            if has_seed:
                sk = rec.get('SeedKey', '')
                if not sk:
                    self.err('%s: no SeedKey' % where)
                elif sk in seen_seed:
                    self.err('%s: SeedKey %s repeats row %d' % (where, sk, seen_seed[sk]))
                else:
                    seen_seed[sk] = n + 1
                    if not sk.startswith(pack['key'] + '.'):
                        self.err('%s: SeedKey %s does not start with %s.' % (where, sk, pack['key']))
            else:
                k = tuple(row)
                if k in seen_rows:
                    self.err('%s: the row repeats an earlier row' % where)
                seen_rows.add(k)
            for i, u in enumerate(uniques):
                cols = u[0]
                if all(c in inv for c in cols):
                    k = tuple(rec[inv[c]] for c in cols)
                    if u[2] and k[cols.index('SeedKey')] == '':
                        continue
                    if k in seen_uq[i]:
                        self.err('%s: unique (%s) repeats row %d' % (where, ','.join(cols), seen_uq[i][k]))
                    seen_uq[i][k] = n + 1
            self.check_rules(where, t, rec)

    def check_via(self, where, pack, t, col_name, r, value, rec, inv):
        """A composite key copies the referenced row's values (via=A>B)."""
        c = t.colmap[col_name]
        if not c.via:
            return
        parent = self.parent_row(pack, r['Table'], r.get('Key', 'SeedKey'), value)
        if parent is None:
            return
        for mine, theirs in zip(c.via, c.via_t):
            if mine not in inv:
                continue
            if theirs in parent:
                expect = parent[theirs]
            elif r['Table'] == 'cat.BaseRate' and theirs == 'ScopeKey':
                expect = '0' if not parent.get('InstitutionSeedKey') else None
            else:
                continue
            if expect is not None and rec[inv[mine]] != expect:
                self.err('%s: %s = %s, but the referenced %s has %s = %s' % (where, mine, rec[inv[mine]], r['Table'], theirs, expect))

    def check_rules(self, where, t, rec):
        """The CHECK constraints of the model that a pack can break, written out for the catalogue and S1 tables."""
        g = rec.get
        checks = ' | '.join(e for e, _ in t.checks)
        if 'Code' in rec and CODE_CHECK in checks:
            code = g('Code')
            if not re.fullmatch(r'[A-Z][A-Z0-9_]*', code):
                self.err('%s: code %s does not match the catalogue code check (BR-CAT-001)' % (where, code))
            elif not re.fullmatch(r'[A-Z][A-Z0-9_]{1,39}', code):
                self.notes.append('%s: code %s is outside the 2..40 length of BR-CAT-001 (the application rule; the database accepts it)' % (where, code))
        if 'IsLocked' in t.colmap and 'IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)' in checks:
            locked, system, active = g('IsLocked', '0') or '0', g('IsSystem', '0') or '0', g('IsActive', '1') or '1'
            if locked == '1' and not (system == '1' and active == '1'):
                self.err('%s: a locked row is system and active (BR-CAT-003)' % where)
            if system == '1' and not g('NameEn'):
                self.err('%s: a system row has NameEn (BR-CAT-001)' % where)
        n = t.fq
        if n == 'cat.LimitType':
            if (g('Kind') == 'MAIN') == bool(g('ParentLimitTypeSeedKey')):
                self.err('%s: a MAIN limit type has no parent and a SUB one has one' % where)
            if g('ParentLimitTypeSeedKey') and g('ParentLimitTypeSeedKey') == g('SeedKey'):
                self.err('%s: a limit type is not its own parent' % where)
        elif n == 'cat.ObligationType':
            if g('Family') == 'COVENANT' and not g('MeasureKind'):
                self.err('%s: a covenant has a MeasureKind' % where)
            if g('MeasureKind') == 'NONE' and g('IsQualitative') != '1':
                self.err('%s: MeasureKind NONE is qualitative' % where)
        elif n == 'cat.ProductFinancingType':
            pc, fi = g('ProductCompliance'), g('FinancingIsIslamic')
            if not (pc == 'NEUTRAL' or (pc == 'ISLAMIC' and fi == '1') or (pc == 'CONVENTIONAL' and fi == '0')):
                self.err('%s: a %s product with a financing type IsIslamic=%s (DR-30)' % (where, pc, fi))
        elif n == 'cat.BaseRate':
            if (g('Kind') == 'MARKET') == bool(g('InstitutionSeedKey') or g('InstitutionCode')):
                self.err('%s: a MARKET rate has no institution and a BANK_INTERNAL one has one' % where)
            if g('StaleAfterDays') and int(g('StaleAfterDays')) <= 0:
                self.err('%s: StaleAfterDays > 0' % where)
        elif n == 'cat.LookupList':
            if not ((g('Scope') == 'SYSTEM' and g('IsSystem') == '1') or (g('Scope') == 'TENANT' and g('IsSystem') != '1')):
                self.err('%s: a SYSTEM list is a system row and a TENANT list is not (DR-03)' % where)
        elif n == 'cat.CollateralTypeAttribute':
            if g('DataType') == 'LIST' and not g('ListOptions'):
                self.err('%s: a LIST attribute has its options' % where)
        elif n == 'cat.DocumentType':
            for c in ('MaxSizeMb', 'RetentionYears', 'MaxAgeDays'):
                if g(c) and int(g(c)) <= 0:
                    self.err('%s: %s > 0' % (where, c))
        elif n == 'cfg.NumberSequenceDefinition':
            self.check_pattern(where, rec)
        elif n == 'cfg.ExpiryAlertRule':
            try:
                lead = json.loads(g('LeadDays'))
                if not (isinstance(lead, list) and lead and all(isinstance(x, int) and x > 0 for x in lead) and lead == sorted(lead, reverse=True)
                        and len(set(lead)) == len(lead)):
                    self.err('%s: LeadDays is a descending list of positive days' % where)
            except ValueError:
                pass
            if g('ReminderAfterExpiryDays') and int(g('ReminderAfterExpiryDays')) <= 0:
                self.err('%s: ReminderAfterExpiryDays > 0' % where)
        elif n == 'cat.LookupItem' and g('Attributes') and g('LookupListSeedKey', '').endswith('.ID_NUMBER_FORMAT'):
            a = json.loads(g('Attributes'))
            if set(a) != {'docKind', 'countryIso2', 'regex', 'mode'} or a.get('mode') not in ('WARN', 'BLOCK') \
                    or a.get('countryIso2') not in self.iso['ref.Country']['Iso2'] \
                    or a.get('docKind') not in self.model['pty.IdentityDocument'].colmap['DocKind'].enum:
                self.err('%s: the attributes of an ID_NUMBER_FORMAT item are docKind, countryIso2, regex and mode WARN or BLOCK' % where)
            else:
                try:
                    re.compile(a['regex'])
                except re.error:
                    self.err('%s: the regex does not compile' % where)

    def check_pattern(self, where, rec):
        """db/static/039_numbering.sql: one {seq} or {seq:0..0} tag (1 to 18 zeros), only {erp} (COMPANY), {yy} and {yyyy}."""
        p, scope = rec.get('Pattern', ''), rec.get('ScopeLevel', 'TENANT')
        rest = p.replace('{erp}', '').replace('{yyyy}', '').replace('{yy}', '')
        tags = re.findall(r'\{seq(?::(0+))?\}', rest)
        rest = re.sub(r'\{seq(?::0{1,18})?\}', '', rest)
        if len(tags) != 1 or '{' in rest or '}' in rest or (tags[0] and len(tags[0]) > 18):
            self.err('%s: pattern %s is not valid (039: one {seq} tag; {erp}, {yy}, {yyyy})' % (where, p))
        if '{erp}' in p and scope != 'COMPANY':
            self.err('%s: {erp} needs the COMPANY scope' % where)
        if rec.get('PeriodBasis') == 'FISCAL_YEAR' and scope != 'COMPANY':
            self.err('%s: a FISCAL_YEAR period needs the COMPANY scope' % where)
        key = rec.get('SequenceKey', '')
        if (key == 'PROFORMA' or key.startswith('req:')) and rec.get('GapPolicy') != 'GAP_FREE':
            self.err('%s: request and proforma numbers are gap-free (Q-PLT-08)' % where)
        if rec.get('MinWidth') and not 1 <= int(rec['MinWidth']) <= 18:
            self.err('%s: MinWidth between 1 and 18' % where)

    # ------------------------------------------------------------------ the other packs
    def check_legacy(self, key, pack):
        legacy_refs = set(pack['man'].get('References', {}) or {})
        for table, (header, rows) in pack['tables'].items():
            self.counts.append((key, table, len(rows)))
            t = self.model.get(table)
            if t is None:
                self.err('%s: %s is not a table of db/model' % (pack['rel'], table))
                continue
            extra = [h for h in header if h not in t.colmap and h not in legacy_refs]
            if extra:
                self.notes.append('%s/%s.csv: columns outside the model (own convention): %s' % (pack['rel'], table, ', '.join(extra)))
            if 'SeedKey' in header:
                i = header.index('SeedKey')
                keys = [r[i] for r in rows if i < len(r)]
                for k in sorted({k for k in keys if keys.count(k) > 1}):
                    self.err('%s/%s.csv: SeedKey %s repeats' % (pack['rel'], table, k))

    def run(self):
        self.load()
        for key, pack in self.packs.items():
            if not isinstance(pack['man'].get('Tables'), list):
                continue
            if pack['new']:
                self.check_pack(key, pack)
            else:
                self.notes.append('%s: own convention (checked by its own tool); files, SeedKeys and columns parsed' % pack['rel'])
                self.check_legacy(key, pack)
        last = None
        for key, table, n in self.counts:
            if key != last:
                print('%s%s' % (key, '' if self.packs[key]['new'] else '  (own convention)'))
                last = key
            print('  %-34s %4d' % (table, n))
        for n in self.notes:
            print('note: ' + n)
        for e in self.errors:
            print('ERROR: ' + e)
        print('%d packs, %d tables, %d rows: %s' % (len(self.packs), len(self.counts), sum(n for _, _, n in self.counts),
                                                  'OK' if not self.errors else '%d errors' % len(self.errors)))
        return 1 if self.errors else 0


if __name__ == '__main__':
    sys.exit(Checker().run())
