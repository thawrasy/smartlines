using System.Globalization;
using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests
{
    /// <summary>
    /// The purchase letter of credit from draft to close (AC-REQ-1, the S3 exit; S3 batches D to F), on a facility of 10,000,000
    /// SAR with a documentary credit line: the requester writes the terms, which the submission checks (V-LCT) and locks;
    /// the originator's slot completes by the submission and the line manager approves; the number LCP-yy-0001 is
    /// allocated on the signed-original stage, which needs the scanned original; the treasury chooses the line on the
    /// panel; the treasury manager's approval reserves the exposure with the plus tolerance (3,000,000 + 5% = 3,150,000);
    /// the ERP reference and the manager's second approval; the claim, the execution and the issuance, which convert the
    /// reservation into the letter of credit's utilisation in one transaction; and the close. The limits show it at each
    /// step, and the requester sees only the visible phase.
    /// </summary>
    [Collection("database")]
    public sealed class PurchaseLcTests(PlatformFixture f)
    {
        private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-FAC-05", "V-FAC-08", "V-COL-KYC", "V-COL-NOT-APPROVED"];
        private DateTime Today => f.Env.Clock.GetUtcNow().UtcDateTime.Date;
        private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

        private static async Task<(JsonElement Body, string ETag)> ActAsync(HttpClient c, string id, string action, object? body = null)
        {
            var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
            var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
            var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
            Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {text}");
            return (JsonDocument.Parse(text).RootElement.Clone(), response.Headers.ETag!.ToString());
        }

        private static async Task<(int, string)> RefusedAsync(HttpClient c, string id, string action, object? body = null)
        {
            var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
            return await c.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
        }

        private static async Task<string> DocumentAsync(HttpClient c, string company, string type, string title)
        {
            var up = await CompanyDocumentTests.UploadAsync(c, "/api/v1/documents", CompanyDocumentTests.Pdf(title), title + ".pdf",
                new Dictionary<string, string> { ["documentType"] = type, ["title"] = title, ["company"] = company });
            var text = await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
            Assert.True(up.IsSuccessStatusCode, text);
            return JsonDocument.Parse(text).RootElement.GetProperty("id").GetString()!;
        }

        private static string Phase(JsonElement detail) => detail.GetProperty("request").GetProperty("head").GetProperty("phase").GetString()!;

        private sealed record Bed(TestTenant T, HttpClient Tm, HttpClient Fo, HttpClient Te, HttpClient Rq, HttpClient Mgr, string Company, string Bank, string Fac, string Line,
            Func<Task<(decimal Used, decimal Reserved, decimal Avail)>> LineAsync);

        /// <summary>A tenant with the four roles, a requester with a line manager, and an approved facility of the given amount with one purchase LC line.</summary>
        private async Task<Bed> BedAsync(decimal total)
        {
            var t = await f.CreateTenantAsync();
            var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
            var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
            var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
            var (rq, _, rqEmail) = await f.UserWithRoleAsync(t, "RQ");
            var (mgr, _, mgrEmail) = await f.UserWithRoleAsync(t, "RQ");
            var users = (await t.Portal.GetJsonAsync("/api/v1/users")).GetProperty("items").EnumerateArray().ToList();
            string IdOf(string email) => users.First(u => u.GetProperty("email").GetString() == email).GetProperty("id").GetString()!;
            var (_, tag) = await t.Portal.GetWithETagAsync($"/api/v1/users/{IdOf(rqEmail)}");
            await t.Portal.OkAsync(HttpMethod.Patch, $"/api/v1/users/{IdOf(rqEmail)}", new { lineManager = IdOf(mgrEmail) }, tag);

            // The facility in SAR, a documentary credit limit with one purchase LC line.
            var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IMP", nameAr = "شركة الاستيراد", nameEn = "Importer", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
            var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNKC", nameAr = "بنك الاعتمادات", nameEn = "Credits Bank", type = "BANK", country = "SA" }));
            var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
            {
                borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = total, effectiveFrom = D(Today.AddMonths(-1)), expiryDate = D(Today.AddYears(2)),
            }));
            await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
            var l0 = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الكلي", amount = total, noSourceReason = "Clause 1" })).GetProperty("id").GetString()!;
            var l1 = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "DC", limitType = "DOCUMENTARY_CREDITS", nameAr = "الاعتمادات", parent = l0, pctOfParent = 100, noSourceReason = "Clause 2" })).GetProperty("id").GetString()!;
            var line = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits/{l1}/lines", new { product = "LC_PURCHASE_CONV", bankProductCode = "LC1", amount = total, noSourceReason = "Clause 3" })).GetProperty("id").GetString()!;
            var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
            var check = await fo.GetJsonAsync($"/api/v1/facilities/{fac}/revisions/{rev}/check");
            await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
            await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve",
                new { acknowledge = check.GetProperty("warnings").EnumerateArray().Select(w => w.GetProperty("code").GetString()).Concat(Ack).Distinct().ToArray() });
            async Task<(decimal Used, decimal Reserved, decimal Avail)> LineAsync()
            {
                var a = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/availability?line={Uri.EscapeDataString(line)}&company={company}");
                return (a.GetProperty("used").GetDecimal(), a.GetProperty("reservedForOthers").GetDecimal(), a.GetProperty("avail").GetDecimal());
            }
            return new Bed(t, tm, fo, te, rq, mgr, company, bank, fac, line, LineAsync);
        }

        private Dictionary<string, object?> Terms(string supplier, decimal amount) => new()
        {
            ["lcType"] = "SIGHT", ["availableWith"] = "ADVISING_BANK", ["confirmation"] = "WITHOUT", ["beneficiary"] = supplier,
            ["advisingBankName"] = "Advising Bank", ["advisingBankAddress"] = "Shanghai", ["advisingBankBic"] = "ADVBCNSH",
            ["currencyId"] = "SAR", ["amount"] = amount, ["toleranceMode"] = "PLUS_MINUS", ["tolerancePlusPct"] = 5, ["toleranceMinusPct"] = 5,
            ["expiryRule"] = "ABSOLUTE", ["expiryDate"] = D(Today.AddDays(150)), ["expiryPlace"] = "Riyadh", ["latestShipmentRule"] = "ABSOLUTE",
            ["latestShipmentDate"] = D(Today.AddDays(120)), ["presentationDays"] = 21, ["presentationBasis"] = "SHIPMENT_DATE", ["partialShipments"] = "ALLOWED",
            ["transhipment"] = "ALLOWED", ["transportMode"] = "SEA", ["portOfLoading"] = "Shanghai", ["portOfDischarge"] = "Dammam", ["incotermId"] = "CFR",
            ["incotermPlace"] = "Dammam", ["goodsCategory"] = "STEEL_PIPES", ["goodsDescription"] = "Seamless steel pipes as per proforma", ["insuranceResponsibility"] = "APPLICANT",
            ["lcTextLanguage"] = "EN",
        };

        /// <summary>A purchase LC request driven to the treasury manager's approval: terms, submission, manager, signed original, facility selection.</summary>
        private async Task<string> AtTreasuryApprovalAsync(Bed b, string supplier, decimal amount, string title)
        {
            var id = (await b.Rq.PostOkAsync("/api/v1/requests", new { type = "PURCHASE_LC", company = b.Company, data = new { title, supplierName = "Steel Pipes Ltd", supplierCode = "V-1001" } }))
                .GetProperty("id").GetString()!;
            await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new { fields = Terms(supplier, amount) });
            await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/documents", new object[]
            {
                new { clause = "COMMERCIAL_INVOICE", originals = 3, copies = 2 }, new { clause = "BL_SEA", originals = 3, copies = 3 },
            });
            await ActAsync(b.Rq, id, "submit");
            await ActAsync(b.Mgr, id, "approve");
            var original = await DocumentAsync(b.Tm, b.Company, "SIGNED_REQUEST_ORIGINAL", "Signed original " + title);
            await b.Tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = original, slot = "SIGNED_ORIGINAL" });
            await ActAsync(b.Rq, id, "complete");
            await ActAsync(b.Fo, id, "claim");
            await b.Fo.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/allocation", new { facility = b.Fac, line = b.Line });
            await ActAsync(b.Fo, id, "complete");
            return id;
        }

        [Fact]
        public async Task AC_REQ_1_a_purchase_letter_of_credit_from_draft_to_close_in_the_facility_limits()
        {
            var b = await BedAsync(10_000_000);
            var (t, tm, fo, te, rq, mgr) = (b.T, b.Tm, b.Fo, b.Te, b.Rq, b.Mgr);
            var (company, bank, fac, line, LineAsync) = (b.Company, b.Bank, b.Fac, b.Line, b.LineAsync);
            Assert.Equal((0m, 0m, 10_000_000m), await LineAsync());

            // The supplier and the draft; the submission checks the terms first.
            var supplier = PlatformFixture.Id(await rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var id = (await rq.PostOkAsync("/api/v1/requests", new { type = "PURCHASE_LC", company, data = new { title = "Steel pipes", supplierName = "Steel Pipes Ltd", supplierCode = "V-1001" } }))
                .GetProperty("id").GetString()!;
            var empty = await rq.GetJsonAsync($"/api/v1/requests/{id}/terms");
            Assert.Equal("DRAFT", empty.GetProperty("status").GetString());
            Assert.Contains(empty.GetProperty("findings").EnumerateArray(), x => x.GetProperty("severity").GetString() == "E");
            Assert.Equal(422, (await RefusedAsync(rq, id, "submit")).Item1);
            await rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new
            {
                fields = new Dictionary<string, object?>
                {
                    ["lcType"] = "SIGHT", ["availableWith"] = "ADVISING_BANK", ["confirmation"] = "WITHOUT", ["beneficiary"] = supplier,
                    ["advisingBankName"] = "Advising Bank", ["advisingBankAddress"] = "Shanghai", ["advisingBankBic"] = "ADVBCNSH",
                    ["currencyId"] = "SAR", ["amount"] = 3_000_000, ["toleranceMode"] = "PLUS_MINUS", ["tolerancePlusPct"] = 5, ["toleranceMinusPct"] = 5,
                    ["expiryRule"] = "ABSOLUTE", ["expiryDate"] = D(Today.AddDays(150)), ["expiryPlace"] = "Riyadh", ["latestShipmentRule"] = "ABSOLUTE",
                    ["latestShipmentDate"] = D(Today.AddDays(120)), ["presentationDays"] = 21, ["presentationBasis"] = "SHIPMENT_DATE", ["partialShipments"] = "ALLOWED",
                    ["transhipment"] = "ALLOWED", ["transportMode"] = "SEA", ["portOfLoading"] = "Shanghai", ["portOfDischarge"] = "Dammam", ["incotermId"] = "CFR",
                    ["incotermPlace"] = "Dammam", ["goodsCategory"] = "STEEL_PIPES", ["goodsDescription"] = "Seamless steel pipes as per proforma", ["insuranceResponsibility"] = "APPLICANT",
                    ["lcTextLanguage"] = "EN",
                },
            });
            Assert.Equal((403, "FORBIDDEN"), await rq.ProblemAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new { fields = new { marginPct = 10 } }));
            await rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/documents", new object[]
            {
                new { clause = "COMMERCIAL_INVOICE", originals = 3, copies = 2 }, new { clause = "BL_SEA", originals = 3, copies = 3 },
            });
            var ready = await rq.GetJsonAsync($"/api/v1/requests/{id}/terms");
            Assert.DoesNotContain(ready.GetProperty("findings").EnumerateArray(), x => x.GetProperty("severity").GetString() == "E");
            await ActAsync(rq, id, "submit");
            var locked = await rq.GetJsonAsync($"/api/v1/requests/{id}/terms");
            Assert.Equal(("LOCKED", "SAUDI RIYAL THREE MILLION ONLY"), (locked.GetProperty("status").GetString(), locked.GetProperty("fields").GetProperty("amountInWordsEn").GetString()));
            Assert.Equal("IN_APPROVAL", Phase(await rq.GetJsonAsync($"/api/v1/requests/{id}")));

            // The manager approves; the number is allocated on the signed-original stage, which needs the scanned original.
            await ActAsync(mgr, id, "approve");
            var signed = await rq.GetJsonAsync($"/api/v1/requests/{id}");
            Assert.Equal("AWAITING_REQUESTER", Phase(signed));
            Assert.Matches(@"^LCP-\d{2}-0001$", signed.GetProperty("request").GetProperty("requestNo").GetString()!);
            Assert.Equal((422, "V-WFL-ATTACHMENT"), await RefusedAsync(rq, id, "complete"));
            var original = await DocumentAsync(tm, company, "SIGNED_REQUEST_ORIGINAL", "Signed original");
            await tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = original, slot = "SIGNED_ORIGINAL" });
            await ActAsync(rq, id, "complete");
            Assert.Equal("IN_PROGRESS", Phase(await rq.GetJsonAsync($"/api/v1/requests/{id}")));

            // The facility selection: the treasury claims, reads the panel (the requester may not) and allocates the line.
            Assert.Equal((404, "NOT_FOUND"), await rq.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{id}/availability"));
            await ActAsync(fo, id, "claim");
            var panel = await fo.GetJsonAsync($"/api/v1/requests/{id}/availability");
            Assert.Equal(3_150_000m, panel.GetProperty("exposureAmount").GetDecimal());
            var choice = panel.GetProperty("items").EnumerateArray().Single(x => x.GetProperty("product").GetString() == "LC_PURCHASE_CONV");
            Assert.Equal(10_000_000m, choice.GetProperty("available").GetDecimal());
            Assert.Equal((422, "V-REQ-ALLOCATION"), await RefusedAsync(fo, id, "complete"));
            await fo.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/allocation", new { facility = fac, line = choice.GetProperty("line").GetString() });
            await ActAsync(fo, id, "complete");

            // The treasury manager's approval reserves the exposure with the plus tolerance.
            await ActAsync(tm, id, "approve");
            Assert.Equal((0m, 3_150_000m, 6_850_000m), await LineAsync());
            var staff = await tm.GetJsonAsync($"/api/v1/requests/{id}");
            Assert.Equal(("RESERVED", 3_150_000m), (staff.GetProperty("staff").GetProperty("reservationState").GetString(), staff.GetProperty("staff").GetProperty("reservedAmount").GetDecimal()));
            Assert.DoesNotContain("reserv", (await rq.GetJsonAsync($"/api/v1/requests/{id}")).GetRawText(), StringComparison.OrdinalIgnoreCase);

            // The ERP reference, as entered in Arabic-Indic digits, and the manager's approval after it.
            Assert.Equal((422, "V-WFL-EXTREF"), await RefusedAsync(rq, id, "complete"));
            var erp = await rq.PostOkAsync($"/api/v1/requests/{id}/external-refs", new { systemCode = "ERP", refType = "PURCHASE_REQUEST", value = "٤٥٠٠١٢٣٤٥٦" });
            Assert.Equal("4500123456", erp.GetProperty("normalised").GetString());
            await ActAsync(rq, id, "complete");
            await ActAsync(mgr, id, "approve");

            // The claim, the execution and the issuance.
            await ActAsync(te, id, "claim");
            await ActAsync(te, id, "complete");
            Assert.Equal((422, "V-WFL-ATTACHMENT"), await RefusedAsync(te, id, "complete"));
            var copy = await DocumentAsync(tm, company, "LC_COPY", "LC copy");
            await tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = copy, slot = "LC_COPY" });
            Assert.Equal((422, "V-LCI-ISSUANCE"), await RefusedAsync(te, id, "complete"));
            // V-LCI-02 (OQ-3): an issued exposure above the reserved one is refused at the issuance.
            await te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/issuance", new { lcNumber = "ILC/26/0042", issueDate = D(Today), institution = bank, issuedAmount = 3_300_000 });
            Assert.Equal((422, "V-LCI-02"), await RefusedAsync(te, id, "complete"));
            Assert.Equal((0m, 3_150_000m, 6_850_000m), await LineAsync());
            await te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/issuance", new { lcNumber = "ILC/26/0042", issueDate = D(Today), institution = bank });
            await ActAsync(te, id, "complete");
            Assert.Equal((3_150_000m, 0m, 6_850_000m), await LineAsync());
            var waiting = await rq.GetJsonAsync($"/api/v1/requests/{id}");
            Assert.Equal(("ACTIVE", "IN_PROGRESS"), (waiting.GetProperty("request").GetProperty("status").GetString(), Phase(waiting)));

            // The close by the treasury manager.
            await ActAsync(tm, id, "close");
            var done = await rq.GetJsonAsync($"/api/v1/requests/{id}");
            Assert.Equal(("COMPLETED", "COMPLETED"), (done.GetProperty("request").GetProperty("status").GetString(), Phase(done)));
            var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
            var ct = TestContext.Current.CancellationToken;
            await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), ct);
            var lc = await Dapper.SqlMapper.QuerySingleAsync<(string LcNumberNormalized, decimal Amount, decimal ExposureAmount, string Status, string ReservationState, string TermsPurpose)>(c,
                """
                SELECT l.LcNumberNormalized, l.Amount, l.ExposureAmount, l.Status, r.ReservationState, t.Purpose
                  FROM lc.LetterOfCredit AS l JOIN wfl.Request AS r ON r.LcId = l.LetterOfCreditId JOIN lc.LcTerms AS t ON t.LcTermsId = l.CurrentTermsId;
                """);
            Assert.Equal(("ILC/26/0042", 3_000_000m, 3_150_000m, "ACTIVE", "CONVERTED", "ISSUED"), lc);
        }

        /// <summary>
        /// AC-WFL-3 and the S3 part of AC-FAC-2: two requests on a line of 5,000,000 that holds one of them. A's approval
        /// reserves 3,150,000; B's is refused INSUFFICIENT_AVAILABLE and nothing of it is kept (B stays at the treasury
        /// manager's stage with its slot pending); an override is refused while the account's setting is off; cancelling A
        /// releases its reservation and B's approval then reserves. With the setting on, a third request reserves above
        /// the available amount only with a reason, marked OverLimit and alerted (FR-FAC-020).
        /// </summary>
        [Fact]
        public async Task AC_WFL_3_two_requests_on_one_limit_the_second_is_refused_until_the_first_is_cancelled()
        {
            var b = await BedAsync(5_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var a = await AtTreasuryApprovalAsync(b, supplier, 3_000_000, "A");
            var r = await AtTreasuryApprovalAsync(b, supplier, 3_000_000, "B");
            await ActAsync(b.Tm, a, "approve");
            Assert.Equal((0m, 3_150_000m, 1_850_000m), await b.LineAsync());

            var (status, code) = await RefusedAsync(b.Tm, r, "approve");
            Assert.Equal((409, "INSUFFICIENT_AVAILABLE"), (status, code));
            var kept = await b.Tm.GetJsonAsync($"/api/v1/requests/{r}");
            Assert.Equal("NONE", kept.GetProperty("staff").GetProperty("reservationState").GetString());
            Assert.Contains(kept.GetProperty("request").GetProperty("actions").EnumerateArray(), x => x.GetString() == "approve");
            Assert.Equal((409, "OVERRIDE_NOT_ALLOWED"), await RefusedAsync(b.Tm, r, "approve", new { overrideRequested = true, overrideReason = "Bank agreed by phone" }));
            Assert.Equal((0m, 3_150_000m, 1_850_000m), await b.LineAsync());

            await ActAsync(b.Tm, a, "cancel", new { comment = "Supplier withdrew" });
            Assert.Equal((0m, 0m, 5_000_000m), await b.LineAsync());
            Assert.Equal("RELEASED", (await b.Tm.GetJsonAsync($"/api/v1/requests/{a}")).GetProperty("staff").GetProperty("reservationState").GetString());
            await ActAsync(b.Tm, r, "approve");
            Assert.Equal((0m, 3_150_000m, 1_850_000m), await b.LineAsync());

            // AC-FAC-2 (S3): with the setting on, the override reserves above the available amount with a reason.
            Assert.Equal(HttpStatusCode.NoContent, (await b.T.Portal.SendAsync(HttpMethod.Patch, "/api/v1/settings",
                new { values = new Dictionary<string, object> { ["fac.override_limit.enabled"] = true } })).StatusCode);
            var c3 = await AtTreasuryApprovalAsync(b, supplier, 3_000_000, "C");
            Assert.Equal((409, "INSUFFICIENT_AVAILABLE"), await RefusedAsync(b.Tm, c3, "approve"));
            Assert.Equal((409, "OVERRIDE_REASON_REQUIRED"), await RefusedAsync(b.Tm, c3, "approve", new { overrideRequested = true }));
            await ActAsync(b.Tm, c3, "approve", new { overrideRequested = true, overrideReason = "Temporary excess agreed with the bank" });
            Assert.Equal((0m, 6_300_000m, -1_300_000m), await b.LineAsync());
            var ct = TestContext.Current.CancellationToken;
            var tenantId = await TestEnvironment.TenantIdAsync(b.T.Code);
            await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), ct);
            var over = await Dapper.SqlMapper.QueryAsync<(bool OverLimit, string? OverrideReason)>(c,
                "SELECT OverLimit, OverrideReason FROM fac.LimitReservation WHERE Status = 'ACTIVE' ORDER BY LimitReservationId;");
            Assert.Equal([(false, null), (true, "Temporary excess agreed with the bank")], over.ToList());
            Assert.Equal(1, await Dapper.SqlMapper.ExecuteScalarAsync<int>(c, "SELECT COUNT(*) FROM cfg.OutboxEvent WHERE AggregateType = 'ntf.fac.LimitReservation' AND JSON_VALUE(PayloadJson, '$.eventCode') = 'FAC.RESERVATION_ALERT';"));
        }

        /// <summary>
        /// JOB-FAC-RESERVATION (FR-FAC-018, BR-WFL-017): a reservation past its expiry date is released as EXPIRED, the line
        /// is free again, the request's reservation reads LOST with RESERVATION_LOST on its record, and a second pass does nothing.
        /// </summary>
        [Fact]
        public async Task An_expired_reservation_is_released_and_the_request_loses_it()
        {
            var b = await BedAsync(5_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var a = await AtTreasuryApprovalAsync(b, supplier, 1_000_000, "A");
            await ActAsync(b.Tm, a, "approve");
            Assert.Equal((0m, 1_050_000m, 3_950_000m), await b.LineAsync());
            var ct = TestContext.Current.CancellationToken;
            var tenantId = await TestEnvironment.TenantIdAsync(b.T.Code);

            await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-RESERVATION", Guid.NewGuid(), ct);
            await Dapper.SqlMapper.ExecuteAsync(c, 
                "UPDATE lr SET ExpiresOn = DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS DATE)) FROM fac.LimitReservation AS lr JOIN wfl.Request AS r ON r.RequestId = lr.RequestId WHERE r.PublicId = @id;",
                new { id = Guid.Parse(a) });
            var zone = await Dapper.SqlMapper.ExecuteScalarAsync<string>(c, "SELECT TimeZone FROM plat.v_CurrentTenant;");
            var job = new BankFas.Data.Workflow.FacilityReservationJob(f.Env.Db, TimeProvider.System);
            Assert.True(await job.RunTenantAsync(new BankFas.Data.JobTenant(tenantId, "ACTIVE", zone!), ct));
            Assert.False(await job.RunTenantAsync(new BankFas.Data.JobTenant(tenantId, "ACTIVE", zone!), ct));
            Assert.Equal((0m, 0m, 5_000_000m), await b.LineAsync());
            Assert.Equal("LOST", (await b.Tm.GetJsonAsync($"/api/v1/requests/{a}")).GetProperty("staff").GetProperty("reservationState").GetString());
            Assert.Equal(("EXPIRED", 1), await Dapper.SqlMapper.QuerySingleAsync<(string, int)>(c,
                """
                SELECT lr.ReleaseReason, (SELECT COUNT(*) FROM wfl.RequestAction AS x WHERE x.RequestId = r.RequestId AND x.ActionType = 'RESERVATION_LOST')
                  FROM fac.LimitReservation AS lr JOIN wfl.Request AS r ON r.RequestId = lr.RequestId WHERE r.PublicId = @id;
                """, new { id = Guid.Parse(a) }));
        }
    }
}
