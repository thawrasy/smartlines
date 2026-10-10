#!/usr/bin/env python3
"""
dbgen - compact model language -> SQL Server DDL (deliverable) + PostgreSQL DDL (structural validation only)
         + data dictionary + ERD.  See README.md for the model language.

Usage:
  python3 dbgen.py check  model/*.model [--allow-missing-refs]
  python3 dbgen.py build  model/*.model --out generated [--docs docs-out-dir]
"""
import re, sys, os, argparse, collections, json

RESERVED_SCHEMA_DESC = {}
MAXID = 128

class ModelError(Exception): pass

# ----------------------------------------------------------------------------- IR
class Col:
    def __init__(self, name):
        self.name = name; self.type = None; self.sqltype = None; self.pgtype = None
        self.req = False; self.default = None; self.fk = None; self.via = []
        self.cascade = False; self.noidx = False; self.enum = None; self.sens = None
        self.comment = ''; self.calc = None; self.auto = False; self.is_json = False
        self.src_line = None; self.isset = False; self.is_bool = False; self.baretype = None

class Table:
    def __init__(self, schema, name):
        self.schema = schema; self.name = name
        self.flags = set(); self.cols = []; self.colmap = {}
        self.uniques = []   # (name, [cols], where)
        self.indexes = []   # (name, [cols], include, where)
        self.checks = []    # (name, expr)
        self.pk_cols = None # explicit natural pk
        self.comment = ''; self.module = ''; self.file = ''; self.line = 0
        self.idtype = 'bigint'
        self.required_scopes = set()  # tuples of via columns needing unique (Tenant,via..,Id)
    @property
    def fq(self): return f'{self.schema}.{self.name}'
    @property
    def is_global(self): return 'global' in self.flags
    @property
    def is_mixed(self): return 'mixed' in self.flags
    @property
    def tenant_scoped(self): return not self.is_global
    @property
    def has_surrogate(self): return self.pk_cols is None
    @property
    def idname(self): return f'{self.name}Id'

# ----------------------------------------------------------------------------- parsing
TYPE_RE = re.compile(r'^(int|bigint|smallint|tinyint|bool|date|ts|time|guid|text|json|money|rate|blob)$', re.I)

def parse_type(tok, col, where):
    t = tok
    m = re.match(r'^enum\{([^}]*)\}$', t)
    if m:
        vals = [v.strip() for v in m.group(1).split(',') if v.strip()]
        if not vals: raise ModelError(f'{where}: empty enum')
        col.enum = vals; n = max(len(v) for v in vals)
        col.sqltype = f'VARCHAR({max(n,10) if n<=10 else n+0})'; col.pgtype = f'varchar({max(n,10) if n<=10 else n})'
        col.type = 'enum'; return
    m = re.match(r'^set\{([^}]*)\}$', t)
    if m:
        vals = [v.strip() for v in m.group(1).split(',') if v.strip()]
        n = max(sum(len(v) for v in vals) + len(vals), 40)
        col.isset = True; col.type = 'set'
        col.sqltype = f'VARCHAR({n})'; col.pgtype = f'varchar({n})'; return
    m = re.match(r'^(str|ascii|char)\((\d+)\)$', t)
    if m:
        k, n = m.group(1), int(m.group(2)); col.type = k
        if k == 'str': col.sqltype = f'NVARCHAR({n})'; col.pgtype = f'varchar({n})'
        elif k == 'ascii': col.sqltype = f'VARCHAR({n})'; col.pgtype = f'varchar({n})'
        else: col.sqltype = f'CHAR({n})'; col.pgtype = f'char({n})'
        return
    m = re.match(r'^dec\((\d+),(\d+)\)$', t)
    if m:
        col.type = 'dec'; col.sqltype = f'DECIMAL({m.group(1)},{m.group(2)})'; col.pgtype = f'numeric({m.group(1)},{m.group(2)})'; return
    m = re.match(r'^bin\((\d+)\)$', t)
    if m:
        col.type = 'bin'; col.sqltype = f'VARBINARY({m.group(1)})'; col.pgtype = 'bytea'; return
    simple = {
        'int': ('INT','integer'), 'bigint': ('BIGINT','bigint'), 'smallint': ('SMALLINT','smallint'), 'tinyint': ('TINYINT','smallint'),
        'bool': ('BIT','smallint'), 'date': ('DATE','date'), 'ts': ('DATETIME2(3)','timestamp(3)'), 'time': ('TIME(0)','time(0)'),
        'guid': ('UNIQUEIDENTIFIER','uuid'), 'text': ('NVARCHAR(MAX)','text'), 'json': ('NVARCHAR(MAX)','text'),
        'money': ('DECIMAL(19,4)','numeric(19,4)'), 'rate': ('DECIMAL(9,6)','numeric(9,6)'), 'blob': ('VARBINARY(MAX)','bytea'),
    }
    tl = t.lower()
    if tl in simple:
        col.type = tl; col.sqltype, col.pgtype = simple[tl]
        if tl == 'json': col.is_json = True
        if tl == 'bool': col.is_bool = True
        return
    raise ModelError(f'{where}: unknown type "{tok}"')

def split_comment(line):
    m = re.search(r'\s#\s', line + ' ')
    if m and ' # ' in line:
        i = line.index(' # ')
        return line[:i].rstrip(), line[i+3:].strip()
    return line.rstrip(), ''

def parse_files(paths):
    tables = collections.OrderedDict(); cur = None; module = ''
    for path in paths:
        for ln, raw in enumerate(open(path, encoding='utf-8'), 1):
            where = f'{os.path.basename(path)}:{ln}'
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'): continue
            body, comment = split_comment(line)
            toks = body.split()
            head = toks[0]
            if not raw.startswith((' ', '\t')):
                if head == 'module':
                    module = toks[1]; cur = None; continue
                if head == 'table':
                    if len(toks) < 2 or '.' not in toks[1]: raise ModelError(f'{where}: table needs schema.Name')
                    sch, nm = toks[1].split('.', 1)
                    fq = f'{sch}.{nm}'
                    if fq in tables: raise ModelError(f'{where}: duplicate table {fq} (first at {tables[fq].file}:{tables[fq].line})')
                    t = Table(sch, nm); t.comment = comment; t.module = module; t.file = os.path.basename(path); t.line = ln
                    for f in toks[2:]:
                        if f.startswith('pk='): t.pk_cols = [c for c in f[3:].split(',') if c]
                        else: t.flags.add(f)
                    if 'int' in t.flags: t.idtype = 'int'
                    tables[fq] = t; cur = t; continue
                raise ModelError(f'{where}: unexpected top-level line "{head}"')
            if cur is None: raise ModelError(f'{where}: indented line outside a table')
            t = cur
            if head in ('unique', 'index'):
                rest = body.strip()[len(head):].strip()
                where_expr = None; include = []
                m = re.search(r'\bwhere\b', rest, re.I)
                if m: where_expr = rest[m.end():].strip(); rest = rest[:m.start()].strip()
                m = re.search(r'\binclude\b', rest, re.I)
                if m: include = [c.strip() for c in rest[m.end():].split(',') if c.strip()]; rest = rest[:m.start()].strip()
                cols = [c.strip() for c in rest.split(',') if c.strip()]
                if not cols: raise ModelError(f'{where}: {head} needs columns')
                (t.uniques if head == 'unique' else t.indexes).append([cols, include, where_expr, where])
                continue
            if head == 'check':
                t.checks.append((body.strip()[5:].strip(), where)); continue
            if head == 'sens':
                for c in body.split()[1:]:
                    for cc in c.split(','):
                        if cc: t.__dict__.setdefault('_sens_pending', []).append((cc, where))
                continue
            if head == 'calc':
                # calc Name type =expr...   (expression is the remainder after '=')
                m = re.match(r'^\s*calc\s+(\w+)\s+(\S+)\s*=\s*(.+)$', body)
                if not m: raise ModelError(f'{where}: bad calc line')
                col = Col(m.group(1)); parse_type(m.group(2), col, where); col.calc = m.group(3).strip(); col.comment = comment; col.src_line = where
                add_col(t, col, where); continue
            # column line
            col = Col(head); col.comment = comment; col.src_line = where
            if len(toks) < 2: raise ModelError(f'{where}: column "{head}" has no type')
            ty = toks[1]
            if ty.startswith('->'):
                col.fk = ty[2:]
                if '.' not in col.fk: raise ModelError(f'{where}: FK target must be schema.Table')
                col.type = 'fk'
            else:
                parse_type(ty, col, where)
            for tk in toks[2:]:
                if tk == 'req': col.req = True
                elif tk == 'opt': col.req = False
                elif tk == 'cascade': col.cascade = True
                elif tk == 'noidx': col.noidx = True
                elif tk.startswith('via='): col.via = [v for v in tk[4:].split(',') if v]
                elif tk.startswith('sens='): col.sens = tk[5:]
                elif tk.startswith('='):
                    col.default = tk[1:]
                else: raise ModelError(f'{where}: unknown token "{tk}" on column {head}')
            add_col(t, col, where)
    return tables

def add_col(t, col, where):
    if col.name in t.colmap: raise ModelError(f'{where}: duplicate column {t.fq}.{col.name}')
    if len(col.name) > 100: raise ModelError(f'{where}: column name too long')
    t.cols.append(col); t.colmap[col.name] = col

# ----------------------------------------------------------------------------- macros
def mkcol(name, ty, where, req=False, default=None, fk=None, comment='', **kw):
    c = Col(name); c.req = req; c.default = default; c.comment = comment; c.src_line = where; c.auto = True
    if fk: c.fk = fk; c.type = 'fk'
    else: parse_type(ty, c, where)
    for k, v in kw.items(): setattr(c, k, v)
    return c

def expand(tables):
    for t in tables.values():
        w = f'{t.file}:{t.line}'
        f = t.flags
        pre = []
        if 'catalog' in f:
            pre += [mkcol('Code','ascii(80)',w,True,comment='رمز الكتالوج'), mkcol('NameAr','str(200)',w,True), mkcol('NameEn','str(200)',w),
                    mkcol('Description','str(500)',w), mkcol('IsActive','bool',w,True,'1'), mkcol('IsSystem','bool',w,True,'0'),
                    mkcol('IsLocked','bool',w,True,'0'), mkcol('SortOrder','int',w,True,'0'), mkcol('SeedKey','ascii(80)',w), mkcol('ExternalCode','ascii(80)',w)]
            t.uniques.append([['Code'], [], None, w]); t.uniques.append([['SeedKey'], [], 'SeedKey IS NOT NULL', w])
        for c in reversed(pre):
            if c.name not in t.colmap: t.cols.insert(0, c); t.colmap[c.name] = c
        extra = []
        if 'rev' in f:
            extra += [mkcol('FromRevision','int',w,True,'1'), mkcol('ToRevision','int',w), mkcol('SupersedesId',None,w,fk=t.fq)]
        if 'src' in f:
            extra += [mkcol('SourceDocumentId',None,w,fk='doc.Document'), mkcol('SourcePage','ascii(40)',w), mkcol('ReadFromScan','bool',w,True,'0'),
                      mkcol('OriginalText','str(2000)',w), mkcol('NoSourceReason','str(300)',w), mkcol('Confidence','enum{CONFIRMED_AGAINST_ORIGINAL,READ_FROM_SCAN_UNVERIFIED,ENTERED_NO_DOCUMENT}',w,True,'ENTERED_NO_DOCUMENT'),
                      mkcol('VerifiedBy',None,w,fk='sec.AppUser'), mkcol('VerifiedOn','ts',w), mkcol('ConflictId',None,w,fk='fac.ValueConflict')]
        for c in extra:
            if c.name not in t.colmap: t.cols.append(c); t.colmap[c.name] = c
        # public id
        if 'public' in f and 'PublicId' not in t.colmap:
            c = mkcol('PublicId','guid',w,True,'NEWSEQUENTIALID()'); t.cols.append(c); t.colmap['PublicId'] = c
        if 'noaudit' not in f:
            for c in [mkcol('CreatedAt','ts',w,True,'SYSUTCDATETIME()'), mkcol('CreatedBy','bigint',w)]:
                if c.name not in t.colmap: t.cols.append(c); t.colmap[c.name] = c
            if 'append' not in f:
                for c in [mkcol('UpdatedAt','ts',w), mkcol('UpdatedBy','bigint',w)]:
                    if c.name not in t.colmap: t.cols.append(c); t.colmap[c.name] = c
        if 'append' not in f and 'norv' not in f and 'noaudit' not in f and 'global' not in f and 'junction' not in f:
            pass
        # sens pending
        for cc, where in getattr(t, '_sens_pending', []):
            if cc not in t.colmap: raise ModelError(f'{where}: sens column {cc} not found in {t.fq}')
            t.colmap[cc].sens = t.colmap[cc].sens or 'restricted'

# ----------------------------------------------------------------------------- resolution & validation
def resolve(tables, allow_missing=False):
    errs = []; missing = collections.OrderedDict()
    for t in tables.values():
        # tenant column
        if t.tenant_scoped and 'TenantId' in t.colmap:
            errs.append(f'{t.fq}: do not declare TenantId (added automatically)')
        # pk type
        if t.pk_cols:
            for c in t.pk_cols:
                if c not in t.colmap: errs.append(f'{t.fq}: pk column {c} not defined')
    for t in tables.values():
        for c in t.cols:
            if not c.fk: continue
            tgt = tables.get(c.fk)
            if tgt is None:
                missing.setdefault(c.fk, []).append(f'{t.fq}.{c.name}')
                continue
            if tgt.pk_cols is not None and len(tgt.pk_cols) != 1:
                errs.append(f'{c.src_line}: {t.fq}.{c.name} -> {tgt.fq}: target has composite pk')
                continue
            if t.is_global and tgt.tenant_scoped and not tgt.is_mixed:
                errs.append(f'{c.src_line}: global table {t.fq}.{c.name} cannot reference tenant table {tgt.fq}')
            if t.is_mixed and tgt.tenant_scoped and not tgt.is_mixed:
                errs.append(f'{c.src_line}: mixed-scope table {t.fq}.{c.name} cannot reference tenant table {tgt.fq}')
            if c.via:
                for v in c.via:
                    if v not in t.colmap: errs.append(f'{c.src_line}: via column {v} missing on {t.fq}')
                    if v not in tgt.colmap: errs.append(f'{c.src_line}: via column {v} missing on target {tgt.fq}')
                tgt.required_scopes.add(tuple(c.via))
    if missing and not allow_missing:
        for k, v in missing.items(): errs.append(f'unresolved FK target {k} referenced by {", ".join(v[:6])}{" ..." if len(v)>6 else ""}')
    return errs, missing

def pk_sqltype(t):
    if t.pk_cols: return t.colmap[t.pk_cols[0]].sqltype, t.colmap[t.pk_cols[0]].pgtype
    return ('INT', 'integer') if t.idtype == 'int' else ('BIGINT', 'bigint')

def fk_pkcol(t):
    return t.pk_cols[0] if t.pk_cols else t.idname

def validate_semantics(tables):
    errs = []
    for t in tables.values():
        names = set(t.colmap) | ({t.idname} if t.has_surrogate else set()) | ({'TenantId'} if t.tenant_scoped else set())
        if t.has_surrogate and t.idname in t.colmap: errs.append(f'{t.fq}: column {t.idname} is generated')
        for c in t.cols:
            if c.enum and c.default is not None and c.default.strip("'") not in c.enum:
                errs.append(f'{c.src_line}: default {c.default} not in enum of {t.fq}.{c.name}')
        for cols, inc, wh, where in t.uniques + t.indexes:
            for cc in cols + inc:
                if cc not in names: errs.append(f'{where}: column {cc} not in {t.fq}')
        for expr, where in t.checks:
            for ident in re.findall(r'\b[A-Za-z_]\w*\b', re.sub(r"'[^']*'", '', expr)):
                if ident.upper() in ('AND','OR','NOT','IS','NULL','IN','LIKE','BETWEEN','CASE','WHEN','THEN','ELSE','END','LEN','DATALENGTH','ABS','LOWER','UPPER','LTRIM','RTRIM','DATEADD','DAY','MONTH','YEAR'): continue
                if ident not in names: errs.append(f'{where}: check refers to unknown identifier {ident} in {t.fq}')
        if t.has_surrogate and not t.tenant_scoped and t.is_mixed: errs.append(f'{t.fq}: mixed tables are tenant-scoped')
    return errs

def check_names(tables):
    errs = []; per_schema = collections.defaultdict(set)
    def reg(schema, name, where):
        if len(name) > MAXID: errs.append(f'{where}: identifier too long ({len(name)}): {name}')
        key = name.lower()
        if key in per_schema[schema]: errs.append(f'{where}: duplicate constraint/index name in schema {schema}: {name}')
        per_schema[schema].add(key)
    return errs, reg, per_schema

# ----------------------------------------------------------------------------- emitters
def q_ms(n): return f'[{n}]'
import hashlib
def q_pg(n):
    if len(n) > 60: n = n[:50] + '_' + hashlib.md5(n.encode()).hexdigest()[:8]
    return f'"{n}"'

def coltype_sql(c, dialect):
    return c.sqltype if dialect == 'ms' else c.pgtype

def lit_default(c, dialect):
    d = c.default
    if d is None: return None
    if d.startswith("'") or re.match(r'^-?\d+(\.\d+)?$', d) or d.endswith(')'):
        v = d
    elif c.enum or c.type in ('str','ascii','char','set'):
        v = "'" + d + "'"
    else:
        v = d
    if dialect == 'pg':
        v = v.replace('SYSUTCDATETIME()', "(now() at time zone 'utc')").replace('NEWSEQUENTIALID()', 'gen_random_uuid()').replace('NEWID()', 'gen_random_uuid()')
    return v

class Emitter:
    def __init__(self, tables):
        self.tables = tables
        self.errs = []
        # name registries
        self.names = collections.defaultdict(set)
    def reg(self, schema, name, where):
        if len(name) > MAXID: self.errs.append(f'{where}: identifier too long ({len(name)}): {name}')
        k = name.lower()
        if k in self.names[schema]: self.errs.append(f'{where}: duplicate constraint name in schema {schema}: {name}')
        self.names[schema].add(k)
        return name

    def scope_uq_name(self, t, via):
        return f'UQ_{t.name}_Scope_{"_".join(via)}'

    def plan(self):
        """compute constraint/index plan shared by both dialects"""
        P = {}
        for t in self.tables.values():
            p = {'pk': None, 'uqs': [], 'idx': [], 'fks': [], 'checks': []}
            idc = fk_pkcol(t)
            tenant = t.tenant_scoped
            # primary key
            if t.pk_cols:
                pkc = (['TenantId'] if tenant else []) + t.pk_cols
            else:
                pkc = [t.idname]
            p['pk'] = (self.reg(t.schema, f'PK_{t.name}', t.fq), pkc)
            # unique (Tenant, Id) target
            if tenant and t.has_surrogate:
                p['uqs'].append((self.reg(t.schema, f'UQ_{t.name}_Tenant', t.fq), ['TenantId', t.idname], None))
            for via in sorted(t.required_scopes):
                nm = self.reg(t.schema, self.scope_uq_name(t, via), t.fq)
                cols = (['TenantId'] if tenant else []) + list(via) + [idc]
                p['uqs'].append((nm, cols, None))
            if 'public' in t.flags:
                p['uqs'].append((self.reg(t.schema, f'UQ_{t.name}_PublicId', t.fq), ['PublicId'], None))
            for cols, inc, wh, where in t.uniques:
                if cols == ['PublicId'] and 'public' in t.flags: continue
                full = (['TenantId'] if tenant else []) + cols
                nm = self.reg(t.schema, f'UQ_{t.name}_' + '_'.join(cols), where)
                p['uqs'].append((nm, full, wh))
            for cols, inc, wh, where in t.indexes:
                full = (['TenantId'] if tenant else []) + cols
                nm = self.reg(t.schema, f'IX_{t.name}_' + '_'.join(cols), where)
                p['idx'].append((nm, full, inc, wh))
            # FKs
            if tenant and 'plat.Tenant' in self.tables:
                tt = self.tables['plat.Tenant']
                p['fks'].append((self.reg(t.schema, f'FK_{t.name}_Tenant', t.fq), ['TenantId'], tt, ['TenantId'], Col('TenantId')))
            for c in t.cols:
                if not c.fk: continue
                tgt = self.tables.get(c.fk)
                if tgt is None: continue
                tpk = fk_pkcol(tgt)
                simple = (not t.tenant_scoped) or (not tgt.tenant_scoped) or tgt.is_mixed
                if simple:
                    cols, rcols = [c.name], [tpk]
                else:
                    cols = ['TenantId'] + c.via + [c.name]
                    rcols = ['TenantId'] + c.via + [tpk]
                nm = self.reg(t.schema, f'FK_{t.name}_{c.name}', c.src_line or t.fq)
                p['fks'].append((nm, cols, tgt, rcols, c))
                if not c.noidx:
                    # auto index unless leading columns of PK/unique/index already cover
                    lead = ((['TenantId'] if t.tenant_scoped and not simple else []) + ([] if simple else c.via) + [c.name])
                    if t.tenant_scoped and simple: lead = ['TenantId', c.name]
                    p['idx'].append(('AUTO', lead, [], None, c))
            for i, (expr, where) in enumerate(t.checks, 1):
                p['checks'].append((self.reg(t.schema, f'CK_{t.name}_{i}', where), expr))
            for c in t.cols:
                if c.enum:
                    p['checks'].append((self.reg(t.schema, f'CK_{t.name}_{c.name}', c.src_line or t.fq), None, c))
            P[t.fq] = p
        # resolve AUTO idx names, dedupe vs existing leading prefixes
        for t in self.tables.values():
            p = P[t.fq]; existing = [p['pk'][1]] + [u[1] for u in p['uqs']] + [i[1] for i in p['idx'] if i[0] != 'AUTO']
            out = []; seen = set()
            for ix in p['idx']:
                if ix[0] == 'AUTO':
                    lead = ix[1]; c = ix[4]
                    if any(e[:len(lead)] == lead for e in existing): continue
                    key = tuple(lead)
                    if key in seen: continue
                    seen.add(key)
                    nm = self.reg(t.schema, f'IX_{t.name}_{c.name}', c.src_line or t.fq)
                    out.append((nm, lead, [], None))
                else: out.append(ix[:4])
            p['idx'] = out
        return P

    # ---------------- T-SQL
    def col_ms(self, t, c):
        if c.calc:
            return f'    {q_ms(c.name)} AS ({c.calc}) PERSISTED'
        s = f'    {q_ms(c.name)} {c.sqltype}'
        if c.name == 'RowVersion': s = f'    {q_ms(c.name)} ROWVERSION'
        s += ' NOT NULL' if c.req else ' NULL'
        d = lit_default(c, 'ms')
        if d is not None:
            self.reg(t.schema, f'DF_{t.name}_{c.name}', c.src_line or t.fq)
            s += f' CONSTRAINT {q_ms("DF_"+t.name+"_"+c.name)} DEFAULT {d}'
        return s

    def emit_ms(self, P, order):
        out_tables = collections.OrderedDict(); out_fk = []; out_idx = []
        for t in order:
            p = P[t.fq]; lines = []
            tenant = t.tenant_scoped
            if tenant:
                nullable = t.is_mixed
                lines.append(f'    [TenantId] INT {"NULL" if nullable else "NOT NULL"}')
            if t.has_surrogate:
                lines.append(f'    {q_ms(t.idname)} {"INT" if t.idtype=="int" else "BIGINT"} IDENTITY(1,1) NOT NULL')
            for c in t.cols:
                if c.fk:
                    tgt = self.tables[c.fk]; ty = pk_sqltype(tgt)[0]
                    s = f'    {q_ms(c.name)} {ty}' + (' NOT NULL' if c.req else ' NULL')
                    d = lit_default(c, 'ms')
                    if d is not None: s += f' CONSTRAINT {q_ms("DF_"+t.name+"_"+c.name)} DEFAULT {d}'
                    lines.append(s)
                else:
                    lines.append(self.col_ms(t, c))
            if t.is_mixed is False and tenant:
                pass
            # rowversion
            if t.tenant_scoped and 'norv' not in t.flags and 'append' not in t.flags and 'noaudit' not in t.flags and 'junction' not in t.flags and 'RowVersion' not in t.colmap:
                lines.append('    [RowVersion] ROWVERSION NOT NULL')
            cons = []
            pk = p['pk']
            cons.append(f'    CONSTRAINT {q_ms(pk[0])} PRIMARY KEY CLUSTERED ({", ".join(q_ms(c) for c in pk[1])})')
            for nm, cols, wh in p['uqs']:
                if wh:
                    out_idx.append(f'CREATE UNIQUE NONCLUSTERED INDEX {q_ms(nm)} ON {q_ms(t.schema)}.{q_ms(t.name)} ({", ".join(q_ms(c) for c in cols)}) WHERE {wh};')
                else:
                    cons.append(f'    CONSTRAINT {q_ms(nm)} UNIQUE ({", ".join(q_ms(c) for c in cols)})')
            for ck in p['checks']:
                if ck[1] is None:
                    c = ck[2]; vals = ', '.join("'"+v+"'" for v in c.enum)
                    cons.append(f'    CONSTRAINT {q_ms(ck[0])} CHECK ({q_ms(c.name)} IS NULL OR {q_ms(c.name)} IN ({vals}))')
                else:
                    cons.append(f'    CONSTRAINT {q_ms(ck[0])} CHECK ({ck[1]})')
            for c in t.cols:
                if c.is_json:
                    nm = self.reg(t.schema, f'CK_{t.name}_{c.name}_json', c.src_line or t.fq)
                    cons.append(f'    CONSTRAINT {q_ms(nm)} CHECK ({q_ms(c.name)} IS NULL OR ISJSON({q_ms(c.name)}) = 1)')
            body = ',\n'.join(lines + cons)
            desc = f'-- {t.comment}\n' if t.comment else ''
            out_tables[t.fq] = f'{desc}CREATE TABLE {q_ms(t.schema)}.{q_ms(t.name)} (\n{body}\n);'
            for nm, cols, tgt, rcols, c in p['fks']:
                od = ' ON DELETE CASCADE' if c.cascade else ''
                out_fk.append(f'ALTER TABLE {q_ms(t.schema)}.{q_ms(t.name)} ADD CONSTRAINT {q_ms(nm)} FOREIGN KEY ({", ".join(q_ms(x) for x in cols)}) REFERENCES {q_ms(tgt.schema)}.{q_ms(tgt.name)} ({", ".join(q_ms(x) for x in rcols)}){od};')
            for nm, cols, inc, wh in p['idx']:
                incl = f' INCLUDE ({", ".join(q_ms(x) for x in inc)})' if inc else ''
                whr = f' WHERE {wh}' if wh else ''
                out_idx.append(f'CREATE NONCLUSTERED INDEX {q_ms(nm)} ON {q_ms(t.schema)}.{q_ms(t.name)} ({", ".join(q_ms(x) for x in cols)}){incl}{whr};')
        return out_tables, out_fk, out_idx

    # ---------------- PostgreSQL (validation only)
    def emit_pg(self, P, order):
        out_tables = collections.OrderedDict(); out_fk = []; out_idx = []
        for t in order:
            p = P[t.fq]; lines = []
            tenant = t.tenant_scoped
            if tenant: lines.append(f'  "TenantId" integer {"NULL" if t.is_mixed else "NOT NULL"}')
            if t.has_surrogate:
                lines.append(f'  {q_pg(t.idname)} {"integer" if t.idtype=="int" else "bigint"} GENERATED BY DEFAULT AS IDENTITY NOT NULL')
            for c in t.cols:
                if c.fk:
                    tgt = self.tables[c.fk]; ty = pk_sqltype(tgt)[1]
                    s = f'  {q_pg(c.name)} {ty}' + (' NOT NULL' if c.req else ' NULL')
                    d = lit_default(c, 'pg')
                    if d is not None: s += f' DEFAULT {d}'
                    lines.append(s)
                elif c.calc:
                    lines.append(f'  {q_pg(c.name)} {c.pgtype} GENERATED ALWAYS AS ({pg_expr(c.calc)}) STORED')
                else:
                    s = f'  {q_pg(c.name)} {c.pgtype}' + (' NOT NULL' if c.req else ' NULL')
                    d = lit_default(c, 'pg')
                    if d is not None: s += f' DEFAULT {d}'
                    lines.append(s)
                    if c.is_bool: lines.append(f'  CHECK ({q_pg(c.name)} IS NULL OR {q_pg(c.name)} IN (0,1))')
            cons = [f'  PRIMARY KEY ({", ".join(q_pg(c) for c in p["pk"][1])})']
            for nm, cols, wh in p['uqs']:
                if wh: out_idx.append(f'CREATE UNIQUE INDEX {q_pg(nm)} ON {q_pg(t.schema)}.{q_pg(t.name)} ({", ".join(q_pg(c) for c in cols)}) WHERE {pg_expr(wh)};')
                else: cons.append(f'  CONSTRAINT {q_pg(nm)} UNIQUE ({", ".join(q_pg(c) for c in cols)})')
            for ck in p['checks']:
                if ck[1] is None:
                    c = ck[2]; vals = ', '.join("'"+v+"'" for v in c.enum)
                    cons.append(f'  CONSTRAINT {q_pg(ck[0])} CHECK ({q_pg(c.name)} IS NULL OR {q_pg(c.name)} IN ({vals}))')
                else:
                    cons.append(f'  CONSTRAINT {q_pg(ck[0])} CHECK ({pg_expr(ck[1])})')
            out_tables[t.fq] = f'CREATE TABLE {q_pg(t.schema)}.{q_pg(t.name)} (\n' + ',\n'.join(lines + cons) + '\n);'
            for nm, cols, tgt, rcols, c in p['fks']:
                od = ' ON DELETE CASCADE' if c.cascade else ''
                out_fk.append(f'ALTER TABLE {q_pg(t.schema)}.{q_pg(t.name)} ADD CONSTRAINT {q_pg(nm)} FOREIGN KEY ({", ".join(q_pg(x) for x in cols)}) REFERENCES {q_pg(tgt.schema)}.{q_pg(tgt.name)} ({", ".join(q_pg(x) for x in rcols)}){od};')
            for nm, cols, inc, wh in p['idx']:
                whr = f' WHERE {pg_expr(wh)}' if wh else ''
                out_idx.append(f'CREATE INDEX {q_pg(nm)} ON {q_pg(t.schema)}.{q_pg(t.name)} ({", ".join(q_pg(x) for x in cols)}){whr};')
        return out_tables, out_fk, out_idx

def pg_expr(e):
    """quote bare identifiers (PascalCase column names) for PostgreSQL"""
    funcs = {'LEN': 'length', 'DATALENGTH': 'octet_length', 'ABS': 'abs', 'LOWER': 'lower', 'UPPER': 'upper', 'LTRIM': 'ltrim', 'RTRIM': 'rtrim'}
    kw = {'AND','OR','NOT','IS','NULL','IN','LIKE','BETWEEN','CASE','WHEN','THEN','ELSE','END','TRUE','FALSE'}
    def sub(m):
        w = m.group(0)
        if w.upper() in funcs and re.match(r'\s*\(', e[m.end():m.end()+3]): return funcs[w.upper()]
        if w.upper() in kw: return w
        if re.match(r'^\d', w): return w
        return f'"{w}"'
    return re.sub(r"('[^']*')|\b[A-Za-z_]\w*\b", lambda m: m.group(1) if m.group(1) else sub(m), e)

# ----------------------------------------------------------------------------- ordering & docs
def order_tables(tables):
    return list(tables.values())

def emit_dictionary(tables, P, title='قاموس البيانات'):
    by_mod = collections.OrderedDict()
    for t in tables.values(): by_mod.setdefault(t.module or t.schema, []).append(t)
    out = [f'# {title}', '', '> مُولَّد آليًا من نموذج البيانات بـ `tools/dbgen` — لا يُعدَّل يدويًا. الأعمدة المشتركة التي تضيفها اصطلاحات التوليد (TenantId، المعرّف، التدقيق) تظهر في كل جدول.', '']
    total = len(tables)
    out += [f'**عدد الجداول: {total}**', '']
    out += ['| الوحدة | عدد الجداول |', '|---|---|'] + [f'| {m} | {len(v)} |' for m, v in by_mod.items()] + ['']
    for m, ts in by_mod.items():
        out += [f'## {m}', '']
        for t in ts:
            p = P[t.fq]; tags = []
            tags.append('عالمي' if t.is_global else ('مختلط النطاق' if t.is_mixed else 'مملوك للمشترك'))
            if 'rev' in t.flags: tags.append('مراجَع')
            if 'src' in t.flags: tags.append('بمصدر')
            if 'catalog' in t.flags: tags.append('كتالوج')
            out += [f'### `{t.fq}`' + (f' — {t.comment}' if t.comment else ''), '', f'*{" · ".join(tags)}*', '', '| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |', '|---|---|---|---|---|---|']
            if t.tenant_scoped: out.append(f'| TenantId | INT | {"نعم" if t.is_mixed else "لا"} | | plat.Tenant | عزل المشترك |')
            if t.has_surrogate: out.append(f'| **{t.idname}** | {"INT" if t.idtype=="int" else "BIGINT"} IDENTITY | لا | | | مفتاح أساسي |')
            for c in t.cols:
                ty = c.sqltype if not c.fk else pk_sqltype(tables[c.fk])[0] if c.fk in tables else '?'
                ref = ''
                if c.fk: ref = c.fk + (f' (via {",".join(c.via)})' if c.via else '')
                note = c.comment
                if c.enum: note = (note + ' ' if note else '') + 'enum: ' + ', '.join(c.enum)
                if c.sens: note = (note + ' ' if note else '') + f'🔒 {c.sens}'
                if c.calc: note = (note + ' ' if note else '') + f'محسوب: `{c.calc}`'
                out.append(f'| {c.name} | {ty} | {"لا" if c.req and not c.calc else "نعم"} | {c.default or ""} | {ref} | {note.replace("|","/")} |')
            keys = [f'PK({", ".join(p["pk"][1])})'] + [f'UQ({", ".join(u[1])}){" WHERE "+u[2] if u[2] else ""}' for u in p['uqs'] if not u[0].startswith('UQ_'+t.name+'_Scope') and not u[0].endswith('_Tenant')]
            if keys: out += ['', '**المفاتيح:** ' + ' · '.join(keys)]
            if t.checks: out += ['', '**قيود:** ' + ' · '.join(f'`{e}`' for e, _ in t.checks)]
            out.append('')
    return '\n'.join(out)

def emit_erd(tables):
    by_schema = collections.OrderedDict()
    for t in tables.values(): by_schema.setdefault(t.schema, []).append(t)
    out = ['# مخططات العلاقات (ERD) حسب المخطط', '', '> مُولَّد آليًا. تظهر العلاقات بين الجداول (مفتاح أجنبي ← جدول مرجعي) داخل المخطط، وتُختصَر العلاقات العابرة للمخططات في جدول.', '']
    for sch, ts in by_schema.items():
        names = {t.fq for t in ts}
        rels = []
        cross = []
        for t in ts:
            for c in t.cols:
                if not c.fk: continue
                if c.fk in names:
                    if c.fk == t.fq: continue
                    rels.append(f'  {c.fk.split(".")[1]} ||--o{{ {t.name} : "{c.name}"')
                else: cross.append((t.name, c.name, c.fk))
        out += [f'## مخطط `{sch}` ({len(ts)} جدولًا)', '']
        if len(ts) <= 45:
            out += ['```mermaid', 'erDiagram'] + sorted(set(rels)) + ['```', '']   # الجداول بلا علاقات داخل المخطط تُذكر في الجدول أدناه (لا كيانات وهمية)
        else:
            out += [f'(المخطط كبير؛ العلاقات الداخلية: {len(set(rels))})', '']
        if cross:
            out += ['| الجدول | العمود | يشير إلى |', '|---|---|---|'] + [f'| {a} | {b} | {c} |' for a, b, c in sorted(set(cross))] + ['']
    return '\n'.join(out)

# ----------------------------------------------------------------------------- CLI
def load(paths, allow_missing):
    tables = parse_files(paths)
    expand(tables)
    errs, missing = resolve(tables, allow_missing)
    errs += validate_semantics(tables)
    return tables, errs, missing

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['check', 'build'])
    ap.add_argument('models', nargs='+')
    ap.add_argument('--allow-missing-refs', action='store_true')
    ap.add_argument('--out'); ap.add_argument('--docs')
    a = ap.parse_args()
    try:
        tables, errs, missing = load(a.models, a.allow_missing_refs)
    except ModelError as e:
        print('MODEL ERROR:', e); sys.exit(2)
    em = Emitter(tables)
    # global tables referenced before... order by declaration
    if not errs or a.allow_missing_refs:
        usable = {k: v for k, v in tables.items()}
        # drop FKs to missing targets for emission in lenient mode
        if missing:
            for t in tables.values():
                for c in t.cols:
                    if c.fk and c.fk not in tables: c.fk = None; c.type = 'bigint'; c.sqltype = 'BIGINT'; c.pgtype = 'bigint'; c.comment += ' [FK مؤجل: هدف غير معرَّف]'
        P = em.plan()
        errs += em.errs
    print(f'tables: {len(tables)}  columns: {sum(len(t.cols) for t in tables.values())}')
    if missing:
        print(f'unresolved FK targets ({len(missing)}):')
        for k, v in missing.items(): print(f'  {k}  <- {", ".join(v[:4])}{" ..." if len(v)>4 else ""}')
    if errs:
        print(f'ERRORS ({len(errs)}):')
        for e in errs[:200]: print('  -', e)
        if not a.allow_missing_refs or any(not e.startswith('unresolved') for e in errs): sys.exit(1)
    if a.cmd == 'check':
        print('OK'); return
    order = order_tables(tables)
    ms_t, ms_fk, ms_idx = em.emit_ms(P, order)
    # RESET emitter names for pg run (names registered once already; reuse plan P)
    em2 = Emitter(tables); em2.names = em.names
    pg_t, pg_fk, pg_idx = em2.emit_pg(P, order)
    out = a.out; os.makedirs(os.path.join(out, 'tsql'), exist_ok=True); os.makedirs(os.path.join(out, 'pg'), exist_ok=True)
    schemas = sorted({t.schema for t in tables.values()})
    hdr = '/* مُولَّد آليًا من نموذج البيانات (tools/dbgen) — لا يُعدَّل يدويًا؛ عدِّل النموذج وأعد التوليد. */\nSET NOCOUNT ON;\nSET XACT_ABORT ON;\nSET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- مطلوبة للفهارس المصفّاة والأعمدة المحسوبة المخزَّنة (sqlcmd يفترض QUOTED_IDENTIFIER OFF)\nGO\n'
    w = lambda p, s: open(os.path.join(out, p), 'w', encoding='utf-8').write(s)
    w('tsql/000_schemas.sql', hdr + 'GO\n'.join(f"IF SCHEMA_ID(N'{s}') IS NULL EXEC(N'CREATE SCHEMA [{s}] AUTHORIZATION dbo;');\n" for s in schemas) + 'GO\n')
    by_schema = collections.OrderedDict()
    for fq, ddl in ms_t.items(): by_schema.setdefault(tables[fq].schema, []).append(ddl)
    w('tsql/001_tables.sql', hdr + '\n'.join(f'-- ===== schema {s} =====\n' + '\nGO\n'.join(v) + '\nGO\n' for s, v in by_schema.items()))
    w('tsql/002_foreign_keys.sql', hdr + '\n'.join(ms_fk) + '\nGO\n')
    w('tsql/003_indexes.sql', hdr + '\n'.join(ms_idx) + '\nGO\n')
    w('pg/000_all.sql', 'CREATE EXTENSION IF NOT EXISTS pgcrypto;\n' + ''.join(f'CREATE SCHEMA IF NOT EXISTS "{s}";\n' for s in schemas) + '\n'.join(pg_t.values()) + '\n' + '\n'.join(pg_fk) + '\n' + '\n'.join(pg_idx) + '\n')
    rls_rows = [(t.schema, t.name, 1 if t.is_mixed else 0) for t in tables.values() if t.tenant_scoped]
    deletable = [(t.schema, t.name) for t in tables.values() if 'deletable' in t.flags]
    w('tsql/004_rls_tables.sql', hdr + "/* قائمة الجداول الخاضعة لعزل الصفوف (يولّدها النموذج)؛ يستهلكها 004_rls.sql */\nIF OBJECT_ID(N'tempdb..#rls_tables') IS NOT NULL DROP TABLE #rls_tables;\nCREATE TABLE #rls_tables (SchemaName sysname NOT NULL, TableName sysname NOT NULL, IsMixed bit NOT NULL);\n" + ''.join(f"INSERT #rls_tables VALUES (N'{a_}', N'{b_}', {c_});\n" for a_, b_, c_ in rls_rows) + 'GO\n')
    append_only = [(t.schema, t.name) for t in tables.values() if 'append' in t.flags and t.schema != 'aud']   # aud.* يكفيه منح SELECT, INSERT على المخطط
    w('tsql/005_delete_grants.sql', hdr + "/* (1) الجداول المسموح للتطبيق بالحذف الفعلي منها (علامة deletable في النموذج)؛ بقية الجداول بلا صلاحية حذف أصلًا.\n   (2) جداول الإضافة فقط (append) خارج aud: DENY UPDATE على التطبيق والمنصة فيصير «للإضافة فقط» مفروضًا بالصلاحيات لا بالعُرف. */\n" + ''.join(f"GRANT DELETE ON [{a_}].[{b_}] TO [tp_app];\n" for a_, b_ in deletable) + ''.join(f"DENY UPDATE ON [{a_}].[{b_}] TO [tp_app], [tp_platform];\n" for a_, b_ in append_only) + 'GO\n')
    # صلاحيات الجداول (007): منح صريح لكل جدول، لا منح على مستوى المخطط. القواعد:
    #  - مملوك للمشترك: tp_app = SELECT, INSERT, UPDATE؛ tp_platform بلا وصول مباشر (عمليات المنصة عبر إجراءات مُراجَعة)
    #  - مختلط: tp_app = SELECT, INSERT, UPDATE (RLS يقصر الكتابة على صفوف المشترك)؛ tp_platform = SELECT, INSERT, UPDATE
    #  - عالمي: tp_app = SELECT فقط؛ tp_platform = SELECT, INSERT, UPDATE (إدارة الكتالوجات العالمية)
    #  - للإضافة فقط (append): بلا UPDATE لأي دور (وتُفرض أيضًا بـ DENY في 005)
    #  - noapp: بلا منح لتطبيق المشترك أبدًا (يُقرأ عبر عرض مُحدَّد إن لزم)
    grant_lines = []
    for t in tables.values():
        obj = f'[{t.schema}].[{t.name}]'
        if 'noapp' in t.flags: app = None
        elif t.is_global and not t.is_mixed: app = 'SELECT'
        elif 'append' in t.flags: app = 'SELECT, INSERT'
        else: app = 'SELECT, INSERT, UPDATE'
        plat = None
        if t.is_global or t.is_mixed:
            plat = 'SELECT, INSERT' if 'append' in t.flags else 'SELECT, INSERT, UPDATE'
        grant_lines.append(f'-- {t.fq}' + ('  (noapp: بلا منح لتطبيق المشترك)' if app is None else ''))
        if app: grant_lines.append(f'GRANT {app} ON {obj} TO [tp_app];')
        if plat: grant_lines.append(f'GRANT {plat} ON {obj} TO [tp_platform];')
    w('tsql/007_table_grants.sql', hdr + "/* صلاحيات الجداول الصريحة (يولّدها النموذج). القواعد في tools/dbgen/dbgen.py عند الحلقة grant_lines. */\n" + '\n'.join(grant_lines) + '\nGO\n')
    sens_rows = [(t.schema, t.name, c.name, c.sens) for t in tables.values() for c in t.cols if c.sens == 'restricted']
    w('tsql/006_sensitive_columns.sql', hdr + "/* حجب الأعمدة الحساسة (sens في النموذج) عن دور القراءة/التقارير tp_readonly؛ تقرؤها طبقة التطبيق عبر tp_app فقط */\n" + ''.join(f"DENY SELECT ON [{a_}].[{b_}]([{c_}]) TO [tp_readonly]; -- {d_}\n" for a_, b_, c_, d_ in sens_rows) + 'GO\n')
    if a.docs:
        os.makedirs(a.docs, exist_ok=True)
        open(os.path.join(a.docs, '21-data-dictionary.md'), 'w', encoding='utf-8').write(emit_dictionary(tables, P))
        open(os.path.join(a.docs, '22-erd-by-schema.md'), 'w', encoding='utf-8').write(emit_erd(tables))
    fkcount = len(ms_fk); ixcount = len(ms_idx)
    print(f'built: {len(tables)} tables, {fkcount} foreign keys, {ixcount} indexes -> {out}')

if __name__ == '__main__':
    main()
