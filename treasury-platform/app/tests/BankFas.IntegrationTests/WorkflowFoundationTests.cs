using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// The foundation of S3 (S3 brief, batch S3-A): a new account has the visible phases, the six request types active
/// with their audiences and gap-free numbering, and the five seeded templates published and current with the stages
/// and hooks FR-WFL-002 asks for; a second run of the installer adds nothing; a published template does not change
/// (044); and the S3 packs (lookups, expiry rules, events) and settings are there.
/// </summary>
[Collection("database")]
public sealed class WorkflowFoundationTests(PlatformFixture f)
{
    private static async Task<T> InTenantAsync<T>(PlatformFixture f, int tenantId, Func<SqlConnection, Task<T>> work)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        return await work(c);
    }

    [Fact]
    public async Task A_new_account_has_the_seeded_templates_published_with_their_hooks()
    {
        var t = await f.CreateTenantAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        var counts = await InTenantAsync(f, tenantId, c => Dapper.SqlMapper.QuerySingleAsync<(int, int, int, int, int, int, int, int)>(c,
            """
            SELECT (SELECT COUNT(*) FROM wfl.ExternalPhase WHERE IsSystem = 1),
                   (SELECT COUNT(*) FROM wfl.RequestType WHERE IsActive = 1 AND SeedKey LIKE 'WFL.TYPE.%'),
                   (SELECT COUNT(*) FROM wfl.WorkflowTemplate WHERE Status = 'PUBLISHED' AND IsCurrent = 1 AND SourceSeedVersion = 1 AND PublishedBy IS NOT NULL),
                   (SELECT COUNT(*) FROM wfl.RequestTypeAudience),
                   (SELECT COUNT(*) FROM cfg.NumberSequenceDefinition WHERE SequenceKey LIKE 'req:%' AND GapPolicy = 'GAP_FREE' AND IsActive = 1),
                   (SELECT COUNT(*) FROM cat.LookupList WHERE Code IN ('TRANSPORT_MODE', 'SWIFT_MESSAGE_KIND', 'LC_DOCREQ_KIND', 'GOODS_CATEGORY')),
                   (SELECT COUNT(*) FROM cfg.ExpiryAlertRule WHERE ItemType IN ('LC_EXPIRY', 'LC_LATEST_SHIPMENT', 'RESERVATION', 'LC_DRAWING_DUE')),
                   (SELECT COUNT(*) FROM ntf.NotificationEventType WHERE Code LIKE 'REQ.%' OR Code LIKE 'LC.%');
            """));
        Assert.Equal((8, 6, 6, 24, 6, 4, 4, 33), counts);

        // FR-WFL-002: lc.validate_terms on SUBMIT and RESUBMIT of PURCHASE_LC, the explicit TM_APPROVAL with the reservation, AMENDMENT_RESULT.
        var hooks = await InTenantAsync(f, tenantId, async c => (await Dapper.SqlMapper.QueryAsync<string>(c,
            """
            SELECT CONCAT(t.TemplateKey, ':', s.StageKey, ':', h.TriggerKind, ':', ISNULL(h.ActionFilter, '-'), ':', h.HookKey)
              FROM wfl.WorkflowStageHook AS h JOIN wfl.WorkflowStage AS s ON s.TenantId = h.TenantId AND s.WorkflowStageId = h.StageId
              JOIN wfl.WorkflowTemplate AS t ON t.TenantId = s.TenantId AND t.WorkflowTemplateId = s.TemplateId
             WHERE t.IsCurrent = 1;
            """)).ToHashSet());
        Assert.Contains("PURCHASE_LC:DRAFT:ON_ACTION:SUBMIT:lc.validate_terms", hooks);
        Assert.Contains("PURCHASE_LC:RETURNED:ON_ACTION:RESUBMIT:lc.validate_terms", hooks);
        Assert.Contains("PURCHASE_LC:TM_APPROVAL:ON_ACTION:APPROVE:fac.reserve_limit", hooks);
        Assert.Contains("PURCHASE_LC:ISSUANCE:ON_EXIT:-:fac.convert_reservation", hooks);
        Assert.Contains("PURCHASE_LC:ISSUANCE:ON_EXIT:-:lc.record_issuance", hooks);
        Assert.Contains("PURCHASE_LC:CANCELLED:ON_ENTER:-:fac.release_reservation", hooks);
        Assert.Contains("CHILD_AMENDMENT:AMENDMENT_RESULT:ON_EXIT:-:lc.apply_amendment", hooks);
        Assert.Contains("CHILD_AMENDMENT:TM_APPROVAL:ON_ACTION:APPROVE:fac.adjust_utilization", hooks);
        var shape = await InTenantAsync(f, tenantId, c => Dapper.SqlMapper.QuerySingleAsync<(int, string, int)>(c,
            """
            SELECT (SELECT COUNT(*) FROM wfl.WorkflowStage AS s JOIN wfl.WorkflowTemplate AS t ON t.TenantId = s.TenantId AND t.WorkflowTemplateId = s.TemplateId
                     WHERE t.TemplateKey = 'PURCHASE_LC' AND t.IsCurrent = 1),
                   (SELECT NumberOnStageKey FROM wfl.WorkflowTemplate WHERE TemplateKey = 'PURCHASE_LC' AND IsCurrent = 1),
                   (SELECT COUNT(*) FROM wfl.WorkflowStage AS s JOIN wfl.WorkflowTemplate AS t ON t.TenantId = s.TenantId AND t.WorkflowTemplateId = s.TemplateId
                     WHERE t.TemplateKey = 'PURCHASE_LC' AND t.IsCurrent = 1 AND s.StageKey = 'TM_APPROVAL' AND s.IsReservationPoint = 1 AND s.ApprovalMode = 'ANY');
            """));
        Assert.Equal((14, "SIGNED_ORIGINAL", 1), shape);

        // A second run of the installer adds nothing.
        var again = await InTenantAsync(f, tenantId, async c =>
        {
            await using var tx = c.BeginTransaction();
            var r = await BankFas.Data.Workflow.WorkflowSeed.InstallAsync(c, tx,
                Path.Combine(BankFas.Data.Seeding.TenantSeeder.PacksDirectory(null), "WFL.BASE", "v1"), 1, TestContext.Current.CancellationToken);
            await tx.RollbackAsync(TestContext.Current.CancellationToken);
            return (r.Created, r.Skipped);
        });
        Assert.Equal((0, 6), again);

        // A published template does not change (044, 50057).
        var refused = await InTenantAsync(f, tenantId, async c =>
        {
            try
            {
                await Dapper.SqlMapper.ExecuteAsync(c,
                    """
                    UPDATE s SET SlaHours = 99 FROM wfl.WorkflowStage AS s JOIN wfl.WorkflowTemplate AS t ON t.TenantId = s.TenantId AND t.WorkflowTemplateId = s.TemplateId
                     WHERE t.TemplateKey = 'PURCHASE_LC' AND t.IsCurrent = 1 AND s.StageKey = 'EXECUTION';
                    """);
                return 0;
            }
            catch (SqlException e) { return e.Number; }
        });
        Assert.Equal(50057, refused);

        var settings = (await t.Portal.GetJsonAsync("/api/v1/settings")).GetProperty("items").EnumerateArray()
            .ToDictionary(s => s.GetProperty("key").GetString()!, s => s.GetProperty("effective").GetRawText());
        Assert.Equal("false", settings["fac.override_limit.enabled"]);
        Assert.Equal("30", settings["lc.reserve.buffer_days"]);
        Assert.Equal("true", settings["lc.auto_release_on_expiry"]);
    }
}
