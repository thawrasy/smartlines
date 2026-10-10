#!/usr/bin/env python3
"""check_grants.py — تحقق ثابت (بلا SQL Server) من قواعد الصلاحيات والتشفير في db/.

القواعد (وثيقة 20-database-design.md §3، §6، §9):
  R1  tp_app بلا كتابة (INSERT/UPDATE/DELETE) على أي جدول عالمي (بلا RLS)
  R2  tp_app بلا أي منح على الجداول noapp
  R3  tp_platform بلا أي منح مباشر على جداول المشتركين (المملوكة للمشترك)
  R4  لا REFERENCES لأي دور تطبيقي
  R5  لا منح على مستوى المخطط لـ tp_app أو tp_platform (استثناء: مخطط rls للقراءة)
  R6  tp_auth يملك SELECT على sec.AppUser وplat.Tenant فقط
  R7  عدد أعمدة sens=restricted = عدد عبارات DENY لـ tp_readonly
  R8  كل جدول فيه عمود *Enc يملك مفتاح بيانات (EncKeyId | MfaKeyId | MfaKeyRef)،
      وكل عمود *Hash مرتبط بمفتاح فهرسة (HashKeyId | MfaKeyRef)
  R9  لا UPDATE لأي دور على جدول للإضافة فقط (append) خارج aud
  R10 ترتيب النشر: كل ملف في deploy.sql موجود، ومنح مخطط rls يأتي بعد إنشائه (010)
Exit code 0 = كل القواعد محققة؛ غير ذلك = مخالفات مطبوعة.
"""
import glob, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
MODEL = os.path.join(ROOT, 'db', 'model')
GEN = os.path.join(ROOT, 'db', 'generated', 'tsql')
STATIC = os.path.join(ROOT, 'db', 'static')
APP, PLAT, RO, AUTH = '[tp_app]', '[tp_platform]', '[tp_readonly]', '[tp_auth]'

def read(p):
    return open(p, encoding='utf-8').read()

def model_tables():
    """يستعمل محلّل المولّد نفسه، فلا تختلف قراءة التحقق عن قراءة البناء."""
    sys.path.insert(0, os.path.join(ROOT, 'tools', 'dbgen'))
    import dbgen
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(MODEL, '*.model'))), False)
    if errs:
        raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    return tables

def grants_from(text):
    """yields (verbs, object, principal) for GRANT/DENY statements; object is 'schema.table' or 'SCHEMA::x'"""
    out = []
    for m in re.finditer(r'(GRANT|DENY)\s+([^;]+?)\s+ON\s+(?:(SCHEMA)::)?\[?(\w+)\]?(?:\.\[?(\w+)\]?)?\s+TO\s+([^;\n]+)', text, flags=re.I):
        verbs = [v.strip().upper() for v in m.group(2).split(',')]
        obj = f'SCHEMA::{m.group(4)}' if m.group(3) else f'{m.group(4)}.{m.group(5)}'
        principals = [p.strip().strip('[]') for p in m.group(6).split(',')]
        out.append((m.group(1).upper(), verbs, obj, principals))
    return out

def main():
    errs = []
    tables = model_tables()
    gen_grants = grants_from(read(os.path.join(GEN, '007_table_grants.sql')) + read(os.path.join(GEN, '005_delete_grants.sql')))
    static_text = ''.join(read(p) for p in glob.glob(os.path.join(STATIC, '*.sql')))
    static_grants = grants_from(static_text)
    all_grants = gen_grants + static_grants

    def kind(obj):
        t = tables.get(obj)
        if t is None: return None
        return {'global': t.is_global and not t.is_mixed, 'mixed': t.is_mixed,
                'noapp': 'noapp' in t.flags, 'append': 'append' in t.flags}

    # R1, R2, R3, R9
    for action, verbs, obj, principals in gen_grants + static_grants:
        if action != 'GRANT' or obj.startswith('SCHEMA::'): continue
        k = kind(obj)
        if k is None: continue
        if '[tp_app]' in ''.join(f'[{p}]' for p in principals) or 'tp_app' in principals:
            if k['global'] and any(v in ('INSERT', 'UPDATE', 'DELETE') for v in verbs):
                errs.append(f'R1: tp_app يكتب على جدول عالمي {obj} {verbs}')
            if k['noapp']:
                errs.append(f'R2: منح لـ tp_app على جدول noapp {obj}')
        if 'tp_platform' in principals and not (k['global'] or k['mixed'] or k['noapp']):
            errs.append(f'R3: منح مباشر لـ tp_platform على جدول مشترك {obj}')
    for action, verbs, obj, principals in all_grants:
        if action == 'GRANT' and 'REFERENCES' in verbs and any(p in ('tp_app', 'tp_platform', 'tp_readonly') for p in principals):
            errs.append(f'R4: REFERENCES لدور تطبيقي على {obj}')
        # استثناء موثَّق: مخطط rls (دوال السياسات) قراءة فقط لـ tp_app
        if action == 'GRANT' and obj.startswith('SCHEMA::') and obj != 'SCHEMA::rls' and any(p in ('tp_app', 'tp_platform') for p in principals):
            errs.append(f'R5: منح على مستوى المخطط {obj} لـ {principals}')
    for action, verbs, obj, principals in static_grants:
        if action == 'GRANT' and 'tp_auth' in principals and obj not in ('sec.AppUser', 'plat.Tenant'):
            errs.append(f'R6: tp_auth يملك منحًا على {obj}')
        if action == 'GRANT' and obj.startswith('SCHEMA::') and 'tp_auth' in principals:
            errs.append(f'R6: tp_auth منح مخطط {obj}')
    for action, verbs, obj, principals in gen_grants:
        if action == 'GRANT' and 'UPDATE' in verbs and 'aud' not in obj and kind(obj) and kind(obj)['append']:
            errs.append(f'R9: UPDATE على جدول للإضافة فقط {obj}')

    # R7: كل عمود sens=restricted (كما يحسبه المولّد) يقابله DENY لـ tp_readonly
    sens_model = sum(1 for t in tables.values() for c in t.cols if c.sens == 'restricted')
    deny_ro = len(re.findall(r'DENY SELECT ON \[\w+\]\.\[\w+\]\(\[\w+\]\) TO \[tp_readonly\]', read(os.path.join(GEN, '006_sensitive_columns.sql'))))
    if sens_model != deny_ro:
        errs.append(f'R7: sens=restricted={sens_model} لكن DENY لـ tp_readonly={deny_ro}')

    # R8
    for name, t in tables.items():
        cols = [c.name for c in t.cols]
        if any(c.endswith('Enc') for c in cols):
            if not any(k in cols for k in ('EncKeyId', 'MfaKeyId', 'MfaKeyRef')):
                errs.append(f'R8: {t.fq} فيه عمود *Enc بلا مفتاح بيانات')
        if any(c in cols for c in ('NumberHash', 'AccountNoHash', 'IbanHash', 'BeneficiaryAccountIbanHash')):
            if not any(k in cols for k in ('HashKeyId', 'MfaKeyRef')):
                errs.append(f'R8: {t.fq} فيه بصمة فهرسة بلا مفتاح HMAC')

    # R10: ملفات النشر موجودة، ومنح rls بعد إنشاء المخطط في 010
    deploy = read(os.path.join(ROOT, 'db', 'deploy.sql'))
    for ref in re.findall(r'^:r\s+(\S+)', deploy, flags=re.M):
        if not os.path.exists(os.path.join(ROOT, 'db', ref.replace('\\', '/'))):
            errs.append(f'R10: ملف النشر غير موجود {ref}')
    rls_src = read(os.path.join(STATIC, '010_rls.sql'))
    if 'GRANT SELECT ON SCHEMA::[rls]' in rls_src and rls_src.find('CREATE SCHEMA [rls]') > rls_src.find('GRANT SELECT ON SCHEMA::[rls]'):
        errs.append('R10: منح rls قبل إنشاء المخطط في 010')
    if 'SCHEMA::[rls]' in read(os.path.join(STATIC, '020_roles_and_grants.sql')):
        errs.append('R10: منح rls في 020 قبل إنشاء المخطط')

    if errs:
        print('check_grants: FAILED')
        for e in errs: print('  -', e)
        return 1
    print(f'check_grants: OK  (tables={len(tables)}, generated grants={len(gen_grants)}, static grants={len(static_grants)}, restricted columns={sens_model})')
    return 0

if __name__ == '__main__':
    sys.exit(main())
