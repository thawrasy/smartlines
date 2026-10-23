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

        [Fact]
        public async Task AC_REQ_1_a_purchase_letter_of_credit_from_draft_to_close_in_the_facility_limits()
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

            // The facility: 10,000,000 SAR, a documentary credit limit with one purchase LC line.
            var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IMP", nameAr = "شركة الاستيراد", nameEn = "Importer", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
            var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNKC", nameAr = "بنك الاعتمادات", nameEn = "Credits Bank", type = "BANK", country = "SA" }));
            var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
            {
                borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 10_000_000, effectiveFrom = D(Today.AddMonths(-1)), expiryDate = D(Today.AddYears(2)),
            }));
            await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
            var l0 = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الكلي", amount = 10_000_000, noSourceReason = "Clause 1" })).GetProperty("id").GetString()!;
            var l1 = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "DC", limitType = "DOCUMENTARY_CREDITS", nameAr = "الاعتمادات", parent = l0, pctOfParent = 100, noSourceReason = "Clause 2" })).GetProperty("id").GetString()!;
            var line = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits/{l1}/lines", new { product = "LC_PURCHASE_CONV", bankProductCode = "LC1", amount = 10_000_000, noSourceReason = "Clause 3" })).GetProperty("id").GetString()!;
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
    }
}
