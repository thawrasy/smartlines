/* 054_key_guard.sql — no row points at a key that may no longer be used (the rest of DR-20; DOC-S02 section 6,
   ADR 0032, BR-PLT-015).

   Every encrypted or blind-indexed column names its key in sec.TenantKey, and since DR-02 the purpose of the key too.
   What the foreign keys cannot say is the key's status. Here:
     reference triggers   one per table that references sec.TenantKey (all but the key log sec.KeyEvent), built from
                          sys.foreign_keys so a new encrypted column is covered when this script runs again: a new row,
                          or a row whose key column changes, may name only an ACTIVE key (50098). A row that keeps its
                          key keeps it while the key is RETIRING, so it can still be read and updated while the
                          rotation job re-encrypts it; a row on a REVOKED key is frozen until it is moved to an ACTIVE
                          key or its key column is cleared, so nothing is written again under a compromised key
                          (internal review v6, A8). The key is read under REPEATABLEREAD: a key cannot leave ACTIVE
                          between the check and the commit of the row written on it (A9).
     sec.TR_TenantKey_Lifecycle
                          a key is created PENDING; the status moves only forward: PENDING to ACTIVE, ACTIVE to
                          RETIRING, RETIRING to RETIRED or back to ACTIVE (a rotation given up), and any of them to
                          REVOKED; RETIRED and REVOKED are final (50098). A key becomes RETIRED only when no row
                          references it any more (50098). Its tenant, purpose and version never change; its wrapped
                          bytes change only together with the master key that wraps them (a re-wrap under a new
                          master key), and never once the key is RETIRED or REVOKED (A5). tp_app, which holds the keys
                          for the application's envelope encryption (DOC-S02 section 6), keeps INSERT and UPDATE on
                          the table: the trigger, not the grant, holds the lifecycle.
                          Revocation is an emergency and is never held back: the rows still on a REVOKED key are
                          listed by sec.v_KeyReferences until the rotation job moves or destroys them.
     sec.v_KeyReferences  per key, the rows that still reference it, by table and column. The rotation job (tp_jobs,
                          bound to its tenant, so the row filters keep it to that tenant) reads it to know when a key
                          can retire (A4). Operators, who see no tenant data, read the counts across tenants through
                          sec.usp_KeyReferenceCounts (tp_platform): key, status and number of rows, no row itself.
   So no row references a RETIRED key, and no row is written onto any key that is not ACTIVE. Errors: 50098. */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
-- The key columns: each foreign key to sec.TenantKey, its table and the column that holds the key id.
IF OBJECT_ID(N'tempdb..#KeyRef') IS NOT NULL DROP TABLE #KeyRef;
SELECT s.name AS SchemaName, t.name AS TableName, c.name AS KeyColumn, pk.name AS PkColumn
INTO #KeyRef
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fc ON fc.constraint_object_id = fk.object_id
JOIN sys.columns AS rc ON rc.object_id = fk.referenced_object_id AND rc.column_id = fc.referenced_column_id AND rc.name = N'TenantKeyId'
JOIN sys.columns AS c ON c.object_id = fk.parent_object_id AND c.column_id = fc.parent_column_id
JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
CROSS APPLY (SELECT TOP (1) pc.name
             FROM sys.indexes AS i
             JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
             JOIN sys.columns AS pc ON pc.object_id = ic.object_id AND pc.column_id = ic.column_id
             WHERE i.object_id = t.object_id AND i.is_primary_key = 1) AS pk
WHERE fk.referenced_object_id = OBJECT_ID(N'sec.TenantKey')
  AND NOT (s.name = N'sec' AND t.name = N'KeyEvent');   -- the key log records events of any key
IF (SELECT COUNT(*) FROM #KeyRef) < 9 THROW 50098, 'Fewer key columns than the model holds: the key guard would miss some', 1;
-- A primary key of one column is what the triggers join inserted and deleted on.
IF EXISTS (SELECT 1 FROM #KeyRef AS r
           JOIN sys.indexes AS i ON i.object_id = OBJECT_ID(QUOTENAME(r.SchemaName) + N'.' + QUOTENAME(r.TableName)) AND i.is_primary_key = 1
           WHERE (SELECT COUNT(*) FROM sys.index_columns AS ic WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id) <> 1)
    THROW 50098, 'A table with a key column has a composite primary key; the key guard needs one column', 1;
GO
-- The reference triggers: one per table, covering each of its key columns.
DECLARE @s sysname, @t sysname, @pk sysname, @cond NVARCHAR(MAX), @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SchemaName, TableName, PkColumn FROM #KeyRef ORDER BY SchemaName, TableName;
OPEN c; FETCH NEXT FROM c INTO @s, @t, @pk;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @cond = STRING_AGG(CAST(CONCAT(N'
               OR EXISTS (SELECT 1 FROM inserted AS i
                          JOIN sec.TenantKey AS k WITH (REPEATABLEREAD) ON k.TenantId = i.TenantId AND k.TenantKeyId = i.', QUOTENAME(KeyColumn), N'
                          LEFT JOIN deleted AS d ON d.', QUOTENAME(@pk), N' = i.', QUOTENAME(@pk), N'
                          WHERE k.Status <> ''ACTIVE''
                            AND (k.Status = ''REVOKED'' OR d.', QUOTENAME(@pk), N' IS NULL OR d.', QUOTENAME(KeyColumn), N' IS NULL OR d.', QUOTENAME(KeyColumn), N' <> i.', QUOTENAME(KeyColumn), N'))') AS NVARCHAR(MAX)), N'')
                   WITHIN GROUP (ORDER BY KeyColumn)
    FROM #KeyRef WHERE SchemaName = @s AND TableName = @t;
    SET @sql = CONCAT(N'CREATE OR ALTER TRIGGER ', QUOTENAME(@s), N'.', QUOTENAME(N'TR_' + @t + N'_KeyStatus'), N' ON ', QUOTENAME(@s), N'.', QUOTENAME(@t), N'
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    -- 054 (DR-20): a new row, or a row whose key changes, names an ACTIVE key only
    IF 1 = 0', @cond, N'
        THROW 50098, ''A row is written only with an ACTIVE key; a PENDING, RETIRING, RETIRED or REVOKED key takes no new row, and a row on a REVOKED key is moved or cleared before it changes (DR-20)'', 1;
END;');
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @s, @t, @pk;
END;
CLOSE c; DEALLOCATE c;
GO
-- sec.v_KeyReferences and the lifecycle trigger read every key column, so they are built from the same list.
DECLARE @refs NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @refs = STRING_AGG(CAST(CONCAT(N'
    SELECT TenantId, ', QUOTENAME(KeyColumn), N' AS TenantKeyId, N''', SchemaName, N'.', TableName, N''' AS TableName, N''', KeyColumn, N''' AS KeyColumn
    FROM ', QUOTENAME(SchemaName), N'.', QUOTENAME(TableName), N' WHERE ', QUOTENAME(KeyColumn), N' IS NOT NULL') AS NVARCHAR(MAX)), N'
    UNION ALL') WITHIN GROUP (ORDER BY SchemaName, TableName, KeyColumn)
FROM #KeyRef;
SET @sql = CONCAT(N'CREATE OR ALTER VIEW sec.v_KeyReferences
AS
-- 054 (DR-20): the rows that still reference each key, by table and column (built from sys.foreign_keys)
SELECT k.TenantId, k.TenantKeyId, k.Purpose, k.KeyVersion, k.Status, r.TableName, r.KeyColumn, COUNT_BIG(*) AS RowCnt
FROM sec.TenantKey AS k
JOIN (', @refs, N'
) AS r ON r.TenantId = k.TenantId AND r.TenantKeyId = k.TenantKeyId
GROUP BY k.TenantId, k.TenantKeyId, k.Purpose, k.KeyVersion, k.Status, r.TableName, r.KeyColumn;');
EXEC sys.sp_executesql @sql;
SET @sql = N'CREATE OR ALTER TRIGGER sec.TR_TenantKey_Lifecycle ON sec.TenantKey
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    -- 054 (A5): a key is created PENDING; what it is never changes, and its bytes change only in a re-wrap
    IF EXISTS (SELECT 1 FROM inserted AS i LEFT JOIN deleted AS d ON d.TenantKeyId = i.TenantKeyId
               WHERE d.TenantKeyId IS NULL AND i.Status <> ''PENDING'')
        THROW 50098, ''A key is created PENDING and then activated (DR-20)'', 1;
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.TenantKeyId = i.TenantKeyId
               WHERE i.TenantId <> d.TenantId OR i.Purpose <> d.Purpose OR i.KeyVersion <> d.KeyVersion
                  OR ((i.WrappedKey <> d.WrappedKey OR i.MasterKeyRef <> d.MasterKeyRef)
                      AND (d.Status IN (''RETIRED'', ''REVOKED'') OR i.WrappedKey = d.WrappedKey OR i.MasterKeyRef = d.MasterKeyRef)))
        THROW 50098, ''A key keeps its tenant, purpose and version; its wrapped bytes change only with the master key that wraps them, and never once it is RETIRED or REVOKED (DR-20)'', 1;
    -- 054 (DR-20): the status moves only forward; RETIRED and REVOKED are final
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.TenantKeyId = i.TenantKeyId
               WHERE i.Status <> d.Status
                 AND NOT (   (d.Status = ''PENDING''  AND i.Status IN (''ACTIVE'', ''REVOKED''))
                          OR (d.Status = ''ACTIVE''   AND i.Status IN (''RETIRING'', ''REVOKED''))
                          OR (d.Status = ''RETIRING'' AND i.Status IN (''RETIRED'', ''ACTIVE'', ''REVOKED''))))
        THROW 50098, ''A key moves PENDING, ACTIVE, RETIRING, RETIRED, or to REVOKED from any of them; RETIRED and REVOKED are final (DR-20)'', 1;
    -- a key retires only when no row references it
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.TenantKeyId = i.TenantKeyId
               JOIN sec.v_KeyReferences AS r ON r.TenantId = i.TenantId AND r.TenantKeyId = i.TenantKeyId
               WHERE i.Status = ''RETIRED'' AND d.Status <> ''RETIRED'')
        THROW 50098, ''A key retires only when no row references it any more; sec.v_KeyReferences lists the rows still on it (DR-20)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
-- The rotation job reads the view for its bound tenant (the row filters of the tables it joins keep it there).
GRANT SELECT ON sec.v_KeyReferences TO [tp_jobs];
GO
-- The operators' view of a revocation: per tenant and key, how many rows are still on it, and nothing of the rows.
CREATE OR ALTER PROCEDURE sec.usp_KeyReferenceCounts
    @Status VARCHAR(20) = NULL   -- e.g. REVOKED; all statuses when NULL
WITH EXECUTE AS N'tp_auth_exec'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TenantId, TenantKeyId, Purpose, KeyVersion, Status, SUM(RowCnt) AS RowCnt
    FROM sec.v_KeyReferences
    WHERE @Status IS NULL OR Status = @Status
    GROUP BY TenantId, TenantKeyId, Purpose, KeyVersion, Status
    ORDER BY TenantId, TenantKeyId;
END;
GO
GRANT EXECUTE ON sec.usp_KeyReferenceCounts TO [tp_platform];
GO
DROP TABLE #KeyRef;
GO
