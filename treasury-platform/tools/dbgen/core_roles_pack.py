#!/usr/bin/env python3
"""core_roles_pack.py — the tenant pack CORE.ROLES: the eight system roles and their default permissions
(FR-PLT-008, FR-PLT-018, DOC-B05 section 5.1, DQ-B05-12, owner decision 35; ADR 0035).

Usage: python3 tools/dbgen/core_roles_pack.py [--out ROOT]
Writes, under ROOT (default: the repository):
  db/seed/packs/CORE.ROLES/v1/manifest.json, sec.Role.csv, sec.RolePermission.csv   the pack, for the application's
                                                                                   tenant seeder
  db/static/057_core_roles.sql                                                     sec.usp_SeedCoreRoles, which
                                                                                   applies the same pack in the database
Sources, read every run, so the pack cannot drift from the documents:
  - the role matrices of specs 11 to 14 (section 2: one column per role, one row per action and permission code);
  - DOC-F07 section 3 (the M0 and M1 codes and their default roles) and DOC-F09 section 3.2 (the proposed codes).
Reading a cell (✔ full · ◐ restricted · R read · M masked · — none):
  ✔ and ◐ give the permission; ◐ is marked Restricted, the restriction (scope, audience, ownership) being the
  application's. R gives a code that views (a code with a "view" segment), never a code that manages: "R" in a
  manage row says the role reads through another code. M gives a view code that is not sensitive: a masked view,
  never a reveal. Cells with two codes ("a · b", values "x/y") are read pairwise; "a + b" takes one value for both.
  One value for several codes is accepted only when it means the same for each (✔, R, M, —); a single ◐ over
  several codes is refused, since it does not say which code it restricts: the matrix gives one value per code.
Roles: TA, TM, FO, TE, FA, RQ, AU, RK. FA and RK hold ntf.prefs (spec 13, owner decision 36). RQ takes the PR column of spec 14 (purchasing is a requester, spec 10
section 2 note c). Not seeded here: PO (the platform operator, not a tenant role), RQM (the requester's manager,
resolved by the assignment rule, spec 13), SL (the sales roles seeded with the S4 templates, spec 14).
Checks that stop the build: every code is in the permission catalogue (gen_permission_seed.py); a locked code goes
to TM and FO only (BR-PLT-019); no role holds fin.credit.endorse with fin.credit.assess or fin.credit.approve (ADR
0029); every role has a permission.
"""
import csv, glob, io, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import gen_permission_seed as G   # noqa: E402

ROLES = [   # code, Arabic, English, description
    ('TA', 'مدير حساب المشترك', 'Tenant administrator', 'Users, roles, settings and audit; no business data by default (spec 10 section 2 note a).'),
    ('TM', 'مدير الخزينة', 'Treasury manager', 'Treasury approvals; holds the locked permissions with FO (BR-PLT-019).'),
    ('FO', 'مسؤول التسهيلات', 'Facilities officer', 'Facilities, collateral and statements; holds the locked permissions with TM.'),
    ('TE', 'موظف الخزينة', 'Treasury officer', 'Treasury execution: requests, letters of credit, monthly figures.'),
    ('FA', 'محلل مالي', 'Financial analyst', 'Enters statements and prepares credit assessments (spec 12).'),
    ('RQ', 'الجهة الطالبة', 'Requester', 'Purchasing and other requesting units: their own requests only.'),
    ('AU', 'المدقق', 'Auditor', 'Read only; may endorse an approved credit assessment (ADR 0029).'),
    ('RK', 'مسؤول المخاطر', 'Risk officer', 'Independent of the preparing and approving line: reads what the auditor reads, endorses credit assessments and receives the red warnings (owner decision 35).'),
]
CODES = [r[0] for r in ROLES]
ALIAS = {'PR': 'RQ'}
TOKEN = re.compile(r'(?<![A-Z])(TA|TM|FO|TE|FA|RQ|AU|RK)(?![A-Z])')
ENDORSE, PREPARE = 'fin.credit.endorse', {'fin.credit.assess', 'fin.credit.approve'}


def read_cell(value, code):
    """(granted, restricted) for one role and one code."""
    v = value.replace('*', '').strip()
    if v in ('✔',):
        return True, False
    if v == '◐':
        return True, True
    view = 'view' in code.split('.')
    if v == 'R':
        return view, False
    if v == 'M':
        return view and code not in G.SENSITIVE, False
    if v in ('—', '-', ''):
        return False, False
    raise SystemExit(f'unknown cell value {value!r} for {code}')


def matrices(grants, sources):
    for f in sorted(glob.glob(os.path.join(ROOT, 'docs/10-detailed-analysis/1[1-4]-*.md'))):
        lines = open(f, encoding='utf-8').read().split('\n')
        h = next(k for k, l in enumerate(lines) if l.startswith('|') and '| الصلاحية |' in l and ' TA ' in l)
        head = [c.strip() for c in lines[h].strip().strip('|').split('|')]
        pcol = head.index('الصلاحية')
        cols = {k: ALIAS.get(c, c) for k, c in enumerate(head) if ALIAS.get(c, c) in CODES}
        rel = os.path.relpath(f, ROOT)
        for k in range(h + 2, len(lines)):
            l = lines[k]
            if not l.startswith('|'):
                break
            cells = [c.strip() for c in l.strip().strip('|').split('|')]
            codes = G.CODE.findall(cells[pcol])
            if not codes:
                continue
            for c, role in cols.items():
                values = cells[c].split('/') if len(codes) > 1 and '/' in cells[c] else [cells[c]] * len(codes)
                # "a · b" are two actions: one value may stand for both only when it means the same for each (✔ R M —).
                # A ◐ says that something is restricted, not which: one value per code (x/y). "a + b" is one action.
                if '·' in cells[pcol] and '/' not in cells[c] and cells[c].strip() == '◐':
                    raise SystemExit(f'{rel}:{k + 1}: one ◐ for {len(codes)} codes in the column {role}: write one value per code')
                if len(values) != len(codes):
                    raise SystemExit(f'{rel}:{k + 1}: {len(codes)} codes but {len(values)} values for {role}')
                for code, value in zip(codes, values):
                    ok, restricted = read_cell(value, code)
                    if ok:
                        prev = grants.get((role, code))
                        grants[(role, code)] = restricted and (prev is None or prev)
                        sources.setdefault((role, code), set()).add(f'{rel}:{k + 1}')


def default_role_tables(grants, sources):
    """DOC-F07 section 3 and DOC-F09 section 3.2: a column of default roles in free text."""
    for pattern, start, col in (('DOC-F07*.md', '## 3.', 2), ('DOC-F09*.md', '### 3.2', 1)):
        f = glob.glob(os.path.join(ROOT, 'docs/30-readiness', pattern))[0]
        lines = open(f, encoding='utf-8').read().split('\n')
        i = next(k for k, l in enumerate(lines) if l.startswith(start))
        rel = os.path.relpath(f, ROOT)
        for k in range(i + 1, len(lines)):
            l = lines[k]
            if k > i + 1 and l.startswith('#'):
                break
            if not l.startswith('| `'):
                continue
            cells = [c.strip() for c in l.strip().strip('|').split('|')]
            codes = G.CODE.findall(cells[0])
            text = cells[col]
            roles = {}
            if 'الجميع' in text or text.startswith('ضمن النطاق'):
                roles = {r: False for r in CODES}
            for clause in text.split('؛'):   # "TM، FO؛ TA وTE ◐": a ◐ restricts every role of its clause
                for m in TOKEN.finditer(clause):
                    roles[m.group(1)] = '◐' in clause
            for code in codes:
                for role, restricted in roles.items():
                    prev = grants.get((role, code))
                    grants[(role, code)] = restricted and (prev is None or prev)
                    sources.setdefault((role, code), set()).add(f'{rel}:{k + 1}')


def build():
    grants, sources = {}, {}
    matrices(grants, sources)
    default_role_tables(grants, sources)
    catalogue = G.codes_from_documents()
    errors = []
    unknown = sorted({c for _, c in grants} - catalogue)
    if unknown:
        errors.append(f'codes not in the permission catalogue: {unknown}')
    for (role, code) in grants:
        if code in G.LOCKED and role not in ('TM', 'FO'):
            errors.append(f'locked {code} given to {role} (BR-PLT-019)')
    for role in CODES:
        held = {c for r, c in grants if r == role}
        if not held:
            errors.append(f'role {role} has no permission')
        if ENDORSE in held and held & PREPARE:
            errors.append(f'role {role} would endorse what it prepares or approves (ADR 0029): {sorted(held & PREPARE)}')
    if errors:
        raise SystemExit('CORE.ROLES: ' + '; '.join(errors))
    unassigned = sorted(catalogue - {c for _, c in grants})
    return grants, sources, unassigned


def csv_text(header, rows):
    out = io.StringIO()
    w = csv.writer(out, lineterminator='\n')
    w.writerow(header)
    w.writerows(rows)
    return out.getvalue()


def q(s):
    return "N'" + s.replace("'", "''") + "'"


def main():
    root = ROOT
    if len(sys.argv) == 3 and sys.argv[1] == '--out':
        root = sys.argv[2]
    elif len(sys.argv) != 1:
        raise SystemExit(__doc__)
    grants, sources, unassigned = build()
    order = {r: k for k, r in enumerate(CODES)}
    links = sorted(grants.items(), key=lambda kv: (order[kv[0][0]], kv[0][1]))
    pack = os.path.join(root, 'db', 'seed', 'packs', 'CORE.ROLES', 'v1')
    os.makedirs(pack, exist_ok=True)
    with open(os.path.join(pack, 'sec.Role.csv'), 'w', encoding='utf-8') as f:
        f.write(csv_text(['SeedKey', 'Code', 'NameAr', 'NameEn', 'Description', 'IsSystem'],
                         [[f'ROLE.{c}', c, ar, en, d, 1] for c, ar, en, d in ROLES]))
    with open(os.path.join(pack, 'sec.RolePermission.csv'), 'w', encoding='utf-8') as f:
        f.write(csv_text(['RoleSeedKey', 'PermissionCode', 'Restricted', 'Source'],
                         [[f'ROLE.{r}', c, 1 if restricted else 0, ' '.join(sorted(sources[(r, c)]))] for (r, c), restricted in links]))
    per_role = {r: sum(1 for (x, _) in grants if x == r) for r in CODES}
    manifest = {
        'PackKey': 'CORE.ROLES',
        'SeedVersion': 1,
        'Slice': 'S0',
        'Status': 'Generated from the role matrices of specs 11 to 14, DOC-F07 section 3 and DOC-F09 section 3.2, '
                  'approved by the owner (DQ-B05-12, DQ-F07-1, DQ-F09-1, decision 35). Do not edit by hand: run '
                  'tools/dbgen/core_roles_pack.py.',
        'Tables': ['sec.Role.csv', 'sec.RolePermission.csv'],
        'References': {'PermissionCode': 'sec.Permission.Code of db/seed/102_permissions.sql',
                       'RoleSeedKey': 'sec.Role.SeedKey of this pack'},
        'Apply': 'In the database: sec.usp_SeedCoreRoles (db/static/057_core_roles.sql), run by the onboarding job '
                 'JOB-PLT-ONBOARD before sec.usp_InviteFirstAdministrator. Insert only: a run adds what is missing '
                 'the first time; a later run of the same version adds nothing and reports what the tenant changed.',
        'Reading': '✔ and ◐ grant (◐ = Restricted 1: the application narrows it by scope, audience or ownership); R '
                   'grants a view code only; M grants a view code that is not sensitive; — grants nothing.',
        'NotSeeded': {'PO': 'the platform operator, not a tenant role', 'RQM': "the requester's manager, resolved "
                      'by the assignment rule REQUESTER_MANAGER (spec 13)', 'SL': 'the sales roles, custom roles '
                      'seeded with the S4 templates (spec 14)'},
        'PermissionsPerRole': per_role,
        'Links': len(links),
        'CatalogueCodesWithoutDefaultRole': unassigned,
        'Sources': ['docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md section 2',
                    'docs/10-detailed-analysis/12-m5-facilities-pricing-collateral-obligations.md section 2',
                    'docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md section 2',
                    'docs/10-detailed-analysis/14-m7-m8-letters-of-credit.md section 2',
                    'docs/30-readiness/DOC-F07-use-case-catalogue-m0-m1.md section 3',
                    'docs/30-readiness/DOC-F09-use-case-catalogue-m2-m8.md section 3.2'],
    }
    with open(os.path.join(pack, 'manifest.json'), 'w', encoding='utf-8') as f:
        f.write(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

    role_rows = ',\n'.join(f"        ('ROLE.{c}', '{c}', {q(ar)}, {q(en)}, {q(d)})" for c, ar, en, d in ROLES)
    link_rows = ',\n'.join(f"        ('ROLE.{r}', '{c}')" for (r, c), _ in links)
    sql = f"""/* ============================================================================
   BankFas - 057: the tenant pack CORE.ROLES in the database (FR-PLT-008, FR-PLT-018, DOC-B05 section 5.1,
   DQ-B05-12, owner decision 35; ADR 0035; external review v5.0, E2)
   GENERATED by tools/dbgen/core_roles_pack.py from the role matrices — do not edit by hand. The same pack is in
   db/seed/packs/CORE.ROLES/v1 for the application's tenant seeder.

   sec.usp_SeedCoreRoles   run by the onboarding job JOB-PLT-ONBOARD bound to the new tenant (stage B of 038),
                           before sec.usp_InviteFirstAdministrator, which needs the role TA. It writes the {len(ROLES)} system
                           roles (IsSystem 1, SeedKey ROLE.<code>) and their {len(links)} default permissions, and logs
                           the run in cfg.SeedRun (PackKey CORE.ROLES, version 1). Insert only (FR-PLT-008):
                             - the first run (INITIAL) adds every role and link;
                             - a later run (RERUN) adds nothing: a link the tenant removed stays removed, and a role
                               the tenant renamed keeps its name; the run counts them (SkippedModifiedCount) and lists
                               them in DiffJson for review.
                           Locked permissions go to TM and FO only, as sec.TR_RolePermission_Locked requires.
   Roles: {', '.join(f'{c} {n}' for c, n in per_role.items())} permissions.
   EXECUTE: tp_jobs. Errors: 50003 not bound as the onboarding job of an open tenant, 50029 the catalogue lacks a
   permission of the pack (seed 102 first).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER PROCEDURE sec.usp_SeedCoreRoles
    @Created INT = NULL OUTPUT,
    @Skipped INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @Created = 0, @Skipped = 0;
    DECLARE @tenant INT = CAST(SESSION_CONTEXT(N'TenantId') AS INT), @svc BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
            @kind VARCHAR(7), @diff NVARCHAR(MAX), @started DATETIME2(3) = SYSUTCDATETIME();
    IF @tenant IS NULL
       OR CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)) IS NULL
       OR CAST(SESSION_CONTEXT(N'JobKey') AS VARCHAR(80)) <> 'JOB-PLT-ONBOARD'
       OR NOT EXISTS (SELECT 1 FROM sec.SessionBinding WHERE SessionId = @@SPID AND BindingKind = 'JOB')
       OR NOT EXISTS (SELECT 1 FROM rls.fn_BoundWrite(@tenant))
        THROW 50003, 'The connection is not bound as the onboarding job of an open tenant', 1;
    DECLARE @roles TABLE (SeedKey VARCHAR(80) PRIMARY KEY, Code VARCHAR(50), NameAr NVARCHAR(200), NameEn NVARCHAR(200), Description NVARCHAR(MAX));
    INSERT @roles VALUES
{role_rows};
    DECLARE @links TABLE (SeedKey VARCHAR(80), PermissionCode VARCHAR(100), PRIMARY KEY (SeedKey, PermissionCode));
    INSERT @links VALUES
{link_rows};
    IF EXISTS (SELECT 1 FROM @links AS l LEFT JOIN sec.Permission AS p ON p.Code = l.PermissionCode AND p.IsActive = 1 WHERE p.PermissionId IS NULL)
        THROW 50029, 'The permission catalogue lacks a permission of CORE.ROLES: run db/seed/102_permissions.sql first', 1;
    BEGIN TRANSACTION;
    SET @kind = CASE WHEN EXISTS (SELECT 1 FROM cfg.SeedRun WITH (UPDLOCK, HOLDLOCK)
                                  WHERE TenantId = @tenant AND PackKey = 'CORE.ROLES' AND SeedVersion = 1 AND Status = 'SUCCEEDED')
                     THEN 'RERUN' ELSE 'INITIAL' END;
    IF @kind = 'INITIAL'
    BEGIN
        INSERT sec.Role (TenantId, Code, NameAr, NameEn, Description, IsSystem, IsActive, SeedKey, CreatedBy)
        SELECT @tenant, r.Code, r.NameAr, r.NameEn, r.Description, 1, 1, r.SeedKey, @svc
        FROM @roles AS r
        WHERE NOT EXISTS (SELECT 1 FROM sec.Role AS x WHERE x.TenantId = @tenant AND (x.SeedKey = r.SeedKey OR x.Code = r.Code));
        SET @Created = @@ROWCOUNT;
        INSERT sec.RolePermission (TenantId, RoleId, PermissionId, AssignedBy)
        SELECT @tenant, x.RoleId, p.PermissionId, @svc
        FROM @links AS l
        JOIN sec.Role AS x ON x.TenantId = @tenant AND x.SeedKey = l.SeedKey
        JOIN sec.Permission AS p ON p.Code = l.PermissionCode
        WHERE NOT EXISTS (SELECT 1 FROM sec.RolePermission AS rp WHERE rp.TenantId = @tenant AND rp.RoleId = x.RoleId AND rp.PermissionId = p.PermissionId);
        SET @Created += @@ROWCOUNT;
    END;
    -- What differs from the pack now: roles missing or renamed, links missing (on a rerun: what the tenant changed).
    SET @diff = (SELECT
        (SELECT r.SeedKey AS seedKey, CASE WHEN x.RoleId IS NULL THEN 'MISSING' ELSE 'RENAMED' END AS change
         FROM @roles AS r LEFT JOIN sec.Role AS x ON x.TenantId = @tenant AND x.SeedKey = r.SeedKey
         WHERE x.RoleId IS NULL OR x.NameAr <> r.NameAr OR x.NameEn <> r.NameEn
         ORDER BY r.SeedKey FOR JSON PATH) AS roles,
        (SELECT l.SeedKey AS seedKey, l.PermissionCode AS permission
         FROM @links AS l
         LEFT JOIN sec.Role AS x ON x.TenantId = @tenant AND x.SeedKey = l.SeedKey
         LEFT JOIN sec.Permission AS p ON p.Code = l.PermissionCode
         WHERE NOT EXISTS (SELECT 1 FROM sec.RolePermission AS rp WHERE rp.TenantId = @tenant AND rp.RoleId = x.RoleId AND rp.PermissionId = p.PermissionId)
         ORDER BY l.SeedKey, l.PermissionCode FOR JSON PATH) AS missingLinks
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @Skipped = ISNULL((SELECT COUNT(*) FROM OPENJSON(@diff, '$.roles')), 0) + ISNULL((SELECT COUNT(*) FROM OPENJSON(@diff, '$.missingLinks')), 0);
    INSERT cfg.SeedRun (TenantId, PackKey, SeedVersion, RunKind, Status, CreatedCount, UpdatedCount, SkippedModifiedCount, DiffJson, StartedAt, FinishedAt, CreatedBy)
    VALUES (@tenant, 'CORE.ROLES', 1, @kind, 'SUCCEEDED', @Created, 0, @Skipped, @diff, @started, SYSUTCDATETIME(), @svc);
    EXEC aud.usp_WriteEvent @TenantId = @tenant, @Action = 'SEED_PACK_APPLIED', @Category = 'CONFIG', @ActorType = 'JOB', @ActorUserId = @svc,
         @EntityType = 'cfg.SeedRun', @AfterJson = N'{{"pack":"CORE.ROLES","version":1}}';
    COMMIT;
END;
GO
GRANT EXECUTE ON sec.usp_SeedCoreRoles TO [tp_jobs];
GO
"""
    os.makedirs(os.path.join(root, 'db', 'static'), exist_ok=True)
    with open(os.path.join(root, 'db', 'static', '057_core_roles.sql'), 'w', encoding='utf-8') as f:
        f.write(sql)
    print(f'CORE.ROLES: {len(ROLES)} roles, {len(links)} links ({", ".join(f"{r} {n}" for r, n in per_role.items())}); '
          f'{len(unassigned)} catalogue codes without a default role')


if __name__ == '__main__':
    main()
