/* 056_schema_fingerprint.sql — one hash for the schema of this database (DOC-B11 section 6.3, ADR 0034).

   plat.fn_SchemaFingerprintParts lists the parts of the schema, each as the SHA-256 of a canonical text of its rows
   in a fixed (binary) order, and plat.fn_SchemaFingerprint the SHA-256 of the parts together:
     schemas        the schemas
     columns        each table's columns: type, length, precision, scale, nullability, identity, collation, default
                    and computed definition
     keys           primary keys, unique and check constraints, foreign keys with their columns and actions
     indexes        each index: unique, filter, key columns in order and direction, included columns
     modules        each procedure, function, view and trigger: its definition, and whether a trigger is disabled
     policies       each security policy and its predicates
     roles          the database roles
     permissions    what is granted or denied to a role, on what, and which column
   Database users and role membership are left out: the service logins and their users are made after the
   deployment (provision_logins.sh, provision_monitor.sh) and differ between servers by design. Data is left out.
   tools/deploy/migrate.sh records the fingerprint after every step in plat.SchemaMigration, and refuses to go on
   when the database's fingerprint is not the one the journal holds: the schema was changed outside the journal.
   CI runs the repeatable scripts a second time on a deployed database and requires the same fingerprint (the
   scripts can run again on any version), and checks that a versioned script changes it.
   No role may read these functions; the deployment login (db_owner) does. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER FUNCTION plat.fn_SchemaFingerprintParts ()
RETURNS TABLE
AS RETURN
    WITH lines AS (
        SELECT N'schemas' AS Part, CAST(s.name AS NVARCHAR(MAX)) AS Line
        FROM sys.schemas AS s WHERE s.schema_id BETWEEN 5 AND 16383 OR s.name = N'dbo'
        UNION ALL
        SELECT N'columns', CONCAT(SCHEMA_NAME(t.schema_id), N'.', t.name, N'.', c.name, N'|', TYPE_NAME(c.user_type_id), N'|',
                                  c.max_length, N'|', c.precision, N'|', c.scale, N'|', c.is_nullable, N'|', c.is_identity, N'|',
                                  c.collation_name, N'|', c.column_id, N'|', OBJECT_NAME(c.default_object_id), N'=',
                                  OBJECT_DEFINITION(c.default_object_id), N'|', cc.definition)
        FROM sys.tables AS t
        JOIN sys.columns AS c ON c.object_id = t.object_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        WHERE t.is_ms_shipped = 0
        UNION ALL
        SELECT N'keys', CONCAT(SCHEMA_NAME(k.schema_id), N'.', OBJECT_NAME(k.parent_object_id), N'|', k.name, N'|', k.type, N'|',
                               (SELECT STRING_AGG(CAST(c.name AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                                FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                WHERE ic.object_id = k.parent_object_id AND ic.index_id = k.unique_index_id))
        FROM sys.key_constraints AS k
        UNION ALL
        SELECT N'keys', CONCAT(SCHEMA_NAME(ck.schema_id), N'.', OBJECT_NAME(ck.parent_object_id), N'|', ck.name, N'|C|',
                               ck.definition, N'|', ck.is_disabled, N'|', ck.is_not_trusted)
        FROM sys.check_constraints AS ck
        UNION ALL
        SELECT N'keys', CONCAT(SCHEMA_NAME(fk.schema_id), N'.', OBJECT_NAME(fk.parent_object_id), N'|', fk.name, N'|F|',
                               OBJECT_SCHEMA_NAME(fk.referenced_object_id), N'.', OBJECT_NAME(fk.referenced_object_id), N'|',
                               (SELECT STRING_AGG(CAST(CONCAT(pc.name, N'>', rc.name) AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                                FROM sys.foreign_key_columns AS fc
                                JOIN sys.columns AS pc ON pc.object_id = fc.parent_object_id AND pc.column_id = fc.parent_column_id
                                JOIN sys.columns AS rc ON rc.object_id = fc.referenced_object_id AND rc.column_id = fc.referenced_column_id
                                WHERE fc.constraint_object_id = fk.object_id), N'|',
                               fk.delete_referential_action, N'|', fk.update_referential_action, N'|', fk.is_disabled, N'|', fk.is_not_trusted)
        FROM sys.foreign_keys AS fk
        UNION ALL
        SELECT N'indexes', CONCAT(OBJECT_SCHEMA_NAME(i.object_id), N'.', OBJECT_NAME(i.object_id), N'|', i.name, N'|', i.type, N'|',
                                  i.is_unique, N'|', i.filter_definition, N'|', i.is_disabled, N'|',
                                  (SELECT STRING_AGG(CAST(CONCAT(c.name, CASE WHEN ic.is_descending_key = 1 THEN N' DESC' END) AS NVARCHAR(MAX)), N',')
                                          WITHIN GROUP (ORDER BY ic.key_ordinal)
                                   FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                   WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0), N'|',
                                  (SELECT STRING_AGG(CAST(c.name AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY c.name)
                                   FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                   WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1))
        FROM sys.indexes AS i
        JOIN sys.tables AS t ON t.object_id = i.object_id AND t.is_ms_shipped = 0
        WHERE i.index_id > 0
        UNION ALL
        SELECT N'modules', CONCAT(OBJECT_SCHEMA_NAME(m.object_id), N'.', o.name, N'|', o.type, N'|', tr.is_disabled, N'|',
                                  CONVERT(NVARCHAR(64), HASHBYTES('SHA2_256', CAST(m.definition AS NVARCHAR(MAX))), 2), N'|',
                                  m.execute_as_principal_id)
        FROM sys.sql_modules AS m
        JOIN sys.objects AS o ON o.object_id = m.object_id AND o.is_ms_shipped = 0
        LEFT JOIN sys.triggers AS tr ON tr.object_id = m.object_id
        UNION ALL
        SELECT N'policies', CONCAT(SCHEMA_NAME(p.schema_id), N'.', p.name, N'|', p.is_enabled, N'|', sp.predicate_type, N'|',
                                   sp.operation, N'|', OBJECT_SCHEMA_NAME(sp.target_object_id), N'.', OBJECT_NAME(sp.target_object_id), N'|',
                                   sp.predicate_definition)
        FROM sys.security_policies AS p
        JOIN sys.security_predicates AS sp ON sp.object_id = p.object_id
        UNION ALL
        SELECT N'roles', CAST(r.name AS NVARCHAR(MAX))
        FROM sys.database_principals AS r WHERE r.type = 'R' AND r.is_fixed_role = 0 AND r.name <> N'public'
        UNION ALL
        SELECT N'permissions', CONCAT(g.name, N'|', p.state, N'|', p.permission_name, N'|', p.class, N'|',
                                      CASE p.class WHEN 0 THEN N'DATABASE' WHEN 1 THEN CONCAT(OBJECT_SCHEMA_NAME(p.major_id), N'.', OBJECT_NAME(p.major_id))
                                                   WHEN 3 THEN SCHEMA_NAME(p.major_id) ELSE CAST(p.major_id AS NVARCHAR(20)) END, N'|',
                                      CASE WHEN p.class = 1 AND p.minor_id > 0 THEN COL_NAME(p.major_id, p.minor_id) END)
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS g ON g.principal_id = p.grantee_principal_id AND g.type = 'R'
        WHERE NOT (g.name = N'public' AND p.class = 0 AND p.permission_name = N'CONNECT'))
    SELECT Part, COUNT_BIG(*) AS Items,
           CAST(HASHBYTES('SHA2_256', STRING_AGG(Line COLLATE Latin1_General_100_BIN2, NCHAR(10))
                                      WITHIN GROUP (ORDER BY Line COLLATE Latin1_General_100_BIN2)) AS VARBINARY(32)) AS PartHash
    FROM lines
    GROUP BY Part;
GO
CREATE OR ALTER FUNCTION plat.fn_SchemaFingerprint ()
RETURNS TABLE
AS RETURN
    SELECT CAST(HASHBYTES('SHA2_256', STRING_AGG(CAST(CONCAT(Part, N'=', CONVERT(NVARCHAR(64), PartHash, 2)) AS NVARCHAR(MAX)), NCHAR(10))
                                      WITHIN GROUP (ORDER BY Part)) AS VARBINARY(32)) AS Fingerprint
    FROM plat.fn_SchemaFingerprintParts();
GO
