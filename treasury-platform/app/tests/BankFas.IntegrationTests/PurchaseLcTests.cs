using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;

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
        private async Task<Bed> BedAsync(decimal total, string? pack = null)
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
            if (pack is not null) return await PackBedAsync(t, tm, fo, te, rq, mgr, company, pack);
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

        /// <summary>The bed on a DS-AGR pack moved to be in force a month before the run date; the line is the pack's documentary credit line.</summary>
        private async Task<Bed> PackBedAsync(TestTenant t, HttpClient tm, HttpClient fo, HttpClient te, HttpClient rq, HttpClient mgr, string company, string pack)
        {
            var agreement = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "DS-AGR", pack, "v1", "agreement.json"), TestContext.Current.CancellationToken)).RootElement;
            var from = DateTime.Parse(agreement.GetProperty("facility").GetProperty("effectiveFrom").GetString()!, CultureInfo.InvariantCulture);
            var target = Today.AddMonths(-1);
            var loaded = await AgreementPackTests.LoadAsync(f, fo, tm, company, pack, (target.Year - from.Year) * 12 + target.Month - from.Month);
            var bankCode = agreement.GetProperty("bank").GetProperty("code").GetString();
            var bank = (await tm.GetJsonAsync("/api/v1/institutions")).GetProperty("items").EnumerateArray().Single(i => i.GetProperty("code").GetString() == bankCode).GetProperty("id").GetString()!;
            var line = (await fo.GetJsonAsync($"/api/v1/facilities/{loaded.Facility}/limits")).GetProperty("limits").EnumerateArray()
                .SelectMany(l => l.GetProperty("lines").EnumerateArray()).Single(l => l.GetProperty("product").GetString() == "LC_PURCHASE_CONV").GetProperty("id").GetString()!;
            async Task<(decimal Used, decimal Reserved, decimal Avail)> LineAsync()
            {
                var a = await tm.GetJsonAsync($"/api/v1/facilities/{loaded.Facility}/availability?line={Uri.EscapeDataString(line)}&company={company}");
                return (a.GetProperty("used").GetDecimal(), a.GetProperty("reservedForOthers").GetDecimal(), a.GetProperty("avail").GetDecimal());
            }
            return new Bed(t, tm, fo, te, rq, mgr, company, bank, loaded.Facility, line, LineAsync);
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
        private async Task<string> AtTreasuryApprovalAsync(Bed b, string supplier, decimal amount, string title, HttpClient? selector = null)
        {
            var sel = selector ?? b.Fo;
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
            await ActAsync(sel, id, "claim");
            await sel.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/allocation", new { facility = b.Fac, line = b.Line });
            await ActAsync(sel, id, "complete");
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
            // FR-LCI-010: the bank's receipt of the execution before the issuance.
            Assert.Equal((422, "V-LCI-RECEIPT"), await RefusedAsync(te, id, "complete"));
            var receipt = await DocumentAsync(tm, company, "BANK_ACKNOWLEDGEMENT", "Bank receipt");
            Assert.Equal((403, "FORBIDDEN"), await rq.ProblemAsync(HttpMethod.Put, $"/api/v1/requests/{id}/execution", new { channel = "BANK_PORTAL", receipt }));
            await te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/execution", new { channel = "BANK_PORTAL", bankReference = "BR-77", receipt });
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

        /// <summary>From the treasury manager's approval to the issued credit: the ERP reference, the second approval, the execution and the issuance.</summary>
        private async Task<string> IssuedAsync(Bed b, string id, string lcNumber, DateTime? issueDate = null)
        {
            await ActAsync(b.Tm, id, "approve");
            await b.Rq.PostOkAsync($"/api/v1/requests/{id}/external-refs", new { systemCode = "ERP", refType = "PURCHASE_REQUEST", value = "45" + Guid.NewGuid().ToString("N")[..8] });
            await ActAsync(b.Rq, id, "complete");
            await ActAsync(b.Mgr, id, "approve");
            await ActAsync(b.Te, id, "claim");
            var receipt = await DocumentAsync(b.Tm, b.Company, "BANK_ACKNOWLEDGEMENT", "Bank receipt " + lcNumber);
            await b.Te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/execution", new { channel = "MANUAL_FORM", receipt });
            await ActAsync(b.Te, id, "complete");
            var copy = await DocumentAsync(b.Tm, b.Company, "LC_COPY", "LC copy " + lcNumber);
            await b.Tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = copy, slot = "LC_COPY" });
            await b.Te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/issuance", new { lcNumber, issueDate = D(issueDate ?? Today), institution = b.Bank });
            await ActAsync(b.Te, id, "complete");
            var list = (await b.Tm.GetJsonAsync($"/api/v1/lcs?q={Uri.EscapeDataString(lcNumber)}")).GetProperty("items").EnumerateArray().ToList();
            return list.Single().GetProperty("id").GetString()!;
        }

        /// <summary>
        /// The credit after its issuance (S3 batches F and G; FR-LCI-023, 030, 031; BR-LCI-009, 013): the register finds
        /// it by its number written differently and the requester sees their own; a presentation within the exposure,
        /// one above it refused (V-LCI-05); the bank accepts, the payment lowers the utilisation; the close waits for
        /// the open presentations and then releases the rest; the nightly reconciliation finds nothing; and a second
        /// credit past its expiry is EXPIRED by its job with its utilisation released.
        /// </summary>
        [Fact]
        public async Task An_issued_credit_is_drawn_paid_closed_and_another_expires()
        {
            var b = await BedAsync(10_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var r1 = await AtTreasuryApprovalAsync(b, supplier, 3_000_000, "One");
            var lc = await IssuedAsync(b, r1, "ILC/26/0101");
            Assert.Equal((3_150_000m, 0m, 6_850_000m), await b.LineAsync());
            Assert.Single((await b.Tm.GetJsonAsync("/api/v1/lcs?q=ilc%2F26%2F%200101")).GetProperty("items").EnumerateArray());
            Assert.Single((await b.Rq.GetJsonAsync("/api/v1/lcs")).GetProperty("items").EnumerateArray());
            var mine = await b.Rq.GetJsonAsync($"/api/v1/lcs/{lc}");
            Assert.False(mine.GetProperty("lc").TryGetProperty("utilized", out _));
            Assert.Equal(3_150_000m, (await b.Tm.GetJsonAsync($"/api/v1/lcs/{lc}")).GetProperty("lc").GetProperty("utilized").GetDecimal());

            // Presentations: within the exposure of 3,150,000; the bank's decision; the payment.
            Assert.Equal((403, "FORBIDDEN"), await b.Rq.PostProblemAsync($"/api/v1/lcs/{lc}/drawings", new { amount = 1_000_000, presentationDate = D(Today) }));
            Assert.Equal(1, (await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings", new { amount = 1_000_000, presentationDate = D(Today), bankAdviceRef = "ADV-1" })).GetProperty("drawingNo").GetInt32());
            Assert.Equal((422, "V-LCI-05"), await b.Te.PostProblemAsync($"/api/v1/lcs/{lc}/drawings", new { amount = 2_200_000, presentationDate = D(Today) }));
            Assert.Equal((409, "INVALID_STATE"), await b.Te.PostProblemAsync($"/api/v1/lcs/{lc}/drawings/1/settlements", new { amount = 1_000_000, settledOn = D(Today) }));
            await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings/1/decision", new { status = "ACCEPTED" });
            Assert.Equal((409, "INVALID_STATE"), await b.Tm.PostProblemAsync($"/api/v1/lcs/{lc}/close", new { reason = "Done" }));
            await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings/1/settlements", new { amount = 1_000_000, settledOn = D(Today) });
            Assert.Equal((2_150_000m, 0m, 7_850_000m), await b.LineAsync());
            var card = await b.Tm.GetJsonAsync($"/api/v1/lcs/{lc}");
            Assert.Equal(("SETTLED", 1_000_000m), (card.GetProperty("drawings")[0].GetProperty("status").GetString(), card.GetProperty("lc").GetProperty("settled").GetDecimal()));

            var ct = TestContext.Current.CancellationToken;
            var tenantId = await TestEnvironment.TenantIdAsync(b.T.Code);
            await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-LC-RECONCILE", Guid.NewGuid(), ct);
            Assert.Equal(0, await BankFas.Data.Lc.LcStore.ReconcileAsync(c, Today, ct));

            // The close releases the rest.
            Assert.Equal((422, "V-WFL-REASON"), await b.Tm.PostProblemAsync($"/api/v1/lcs/{lc}/close", new { reason = "" }));
            await b.Tm.PostOkAsync($"/api/v1/lcs/{lc}/close", new { reason = "Shipment complete" });
            Assert.Equal((0m, 0m, 10_000_000m), await b.LineAsync());
            Assert.Equal("CLOSED", (await b.Tm.GetJsonAsync($"/api/v1/lcs/{lc}")).GetProperty("lc").GetProperty("status").GetString());

            // A second credit past its expiry.
            var r2 = await AtTreasuryApprovalAsync(b, supplier, 2_000_000, "Two");
            var lc2 = await IssuedAsync(b, r2, "ILC/26/0102", Today.AddDays(-30));
            Assert.Equal((2_100_000m, 0m, 7_900_000m), await b.LineAsync());
            await Dapper.SqlMapper.ExecuteAsync(c, "UPDATE lc.LetterOfCredit SET ExpiryDate = DATEADD(DAY, -2, CAST(SYSUTCDATETIME() AS DATE)), LatestShipmentDate = NULL WHERE PublicId = @id;",
                new { id = Guid.Parse(lc2) });
            var zone = await Dapper.SqlMapper.ExecuteScalarAsync<string>(c, "SELECT TimeZone FROM plat.v_CurrentTenant;");
            var job = new BankFas.Data.Workflow.LcExpiryJob(f.Env.Db, TimeProvider.System);
            Assert.True(await job.RunTenantAsync(new BankFas.Data.JobTenant(tenantId, "ACTIVE", zone!), ct));
            Assert.Equal("EXPIRED", (await b.Tm.GetJsonAsync($"/api/v1/lcs/{lc2}")).GetProperty("lc").GetProperty("status").GetString());
            Assert.Equal((0m, 0m, 10_000_000m), await b.LineAsync());
            Assert.Equal(0, await BankFas.Data.Lc.LcStore.ReconcileAsync(c, Today, ct));
        }

        /// <summary>
        /// Amendments (FR-LCI-018 to 022, BR-LCI-011, AC-WFL-7 on a line of 4,000,000): the credit of 3,000,000 (exposure
        /// 3,150,000) leaves 850,000; an increase of 500,000 (exposure 525,000) goes to the treasury manager, whose approval
        /// reserves it (325,000 left); a second amendment is refused while the first is open (V-LCI-07); the bank's result
        /// with the beneficiary's acceptance applies it: the credit is 3,500,000 with amendment 1 and its utilisation
        /// 3,675,000, the reservation gone. A second increase of 500,000 is then refused at the TM's approval
        /// (INSUFFICIENT_AVAILABLE), and an extension alone does not pass the TM.
        /// </summary>
        [Fact]
        public async Task An_increase_is_reserved_at_the_TM_approval_and_applied_on_the_beneficiarys_acceptance()
        {
            var b = await BedAsync(4_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var r1 = await AtTreasuryApprovalAsync(b, supplier, 3_000_000, "Base");
            var lc = await IssuedAsync(b, r1, "ILC/26/0201");
            Assert.Equal((3_150_000m, 0m, 850_000m), await b.LineAsync());

            Assert.Equal((422, "V-LCI-07"), await b.Rq.PostProblemAsync($"/api/v1/lcs/{lc}/amendments", new { changeKinds = new[] { "INCREASE_AMOUNT" }, amountDelta = -5 }));
            var amd = PlatformFixture.Id(await b.Rq.PostOkAsync($"/api/v1/lcs/{lc}/amendments", new { changeKinds = new[] { "INCREASE_AMOUNT" }, amountDelta = 500_000, reason = "More pipes" }));
            Assert.Equal((422, "V-LCI-07"), await b.Rq.PostProblemAsync($"/api/v1/lcs/{lc}/amendments",
                new { changeKinds = new[] { "EXTEND_EXPIRY" }, newExpiryDate = D(Today.AddDays(200)) }));
            await ActAsync(b.Rq, amd, "submit");
            await ActAsync(b.Mgr, amd, "approve");
            Assert.Equal("TM_APPROVAL", (await b.Tm.GetJsonAsync($"/api/v1/requests/{amd}")).GetProperty("staff").GetProperty("stage").GetString());
            await ActAsync(b.Tm, amd, "approve");
            Assert.Equal((3_150_000m, 525_000m, 325_000m), await b.LineAsync());
            await ActAsync(b.Te, amd, "claim");
            var advice = await DocumentAsync(b.Tm, b.Company, "LC_AMENDMENT_ADVICE", "Amendment advice");
            await b.Tm.PostOkAsync($"/api/v1/requests/{amd}/attachments", new { document = advice, slot = "AMENDMENT_ADVICE" });
            await ActAsync(b.Te, amd, "complete");
            Assert.Equal((422, "V-LCI-08"), await RefusedAsync(b.Te, amd, "complete"));
            await b.Te.OkAsync(HttpMethod.Put, $"/api/v1/requests/{amd}/amendment-result",
                new { amendmentNo = 1, bankIssuedOn = D(Today), bankAmendmentRef = "AMD-1", beneficiaryResponse = "ACCEPTED" });
            await ActAsync(b.Te, amd, "complete");
            Assert.Equal((3_675_000m, 0m, 325_000m), await b.LineAsync());
            var card = (await b.Tm.GetJsonAsync($"/api/v1/lcs/{lc}")).GetProperty("lc");
            Assert.Equal((3_500_000m, 1, 3_675_000m), (card.GetProperty("amount").GetDecimal(), card.GetProperty("amendmentNo").GetInt32(), card.GetProperty("utilized").GetDecimal()));

            // The second increase does not fit; an extension alone skips the TM.
            var amd2 = PlatformFixture.Id(await b.Rq.PostOkAsync($"/api/v1/lcs/{lc}/amendments", new { changeKinds = new[] { "INCREASE_AMOUNT" }, amountDelta = 500_000 }));
            await ActAsync(b.Rq, amd2, "submit");
            await ActAsync(b.Mgr, amd2, "approve");
            Assert.Equal((409, "INSUFFICIENT_AVAILABLE"), await RefusedAsync(b.Tm, amd2, "approve"));
            await ActAsync(b.Tm, amd2, "cancel", new { comment = "Not now" });
            var ext = PlatformFixture.Id(await b.Rq.PostOkAsync($"/api/v1/lcs/{lc}/amendments", new { changeKinds = new[] { "EXTEND_EXPIRY" }, newExpiryDate = D(Today.AddDays(200)) }));
            await ActAsync(b.Rq, ext, "submit");
            await ActAsync(b.Mgr, ext, "approve");
            Assert.Equal("TREASURY_QUEUE", (await b.Tm.GetJsonAsync($"/api/v1/requests/{ext}")).GetProperty("staff").GetProperty("stage").GetString());
        }

        /// <summary>OQ-9 (DQ-F10-9, BR-WFL-006): the treasury manager who chose the facility does not approve its reservation; another treasury manager does.</summary>
        [Fact]
        public async Task The_user_who_chose_the_facility_does_not_approve_its_reservation()
        {
            var b = await BedAsync(5_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var id = await AtTreasuryApprovalAsync(b, supplier, 1_000_000, "Chosen by TM", b.Tm);
            Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(b.Tm, id, "approve"));
            Assert.Equal((0m, 0m, 5_000_000m), await b.LineAsync());
            var (tm2, _, _) = await f.UserWithRoleAsync(b.T, "TM");
            await ActAsync(tm2, id, "approve");
            Assert.Equal((0m, 1_050_000m, 3_950_000m), await b.LineAsync());
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

        /// <summary>
        /// The rest of the terms (FR-REQ-024, FR-LCT-005, 017, 025; OQ-14; SCR-REQ-10 to 12): the beneficiary's IBAN is
        /// checked, sealed and shown masked, locked with the terms at the submission, and revealed in clear only to a
        /// holder of lc.view.internal with a reason; the printed terms carry the UCP footnote, which cannot be switched off
        /// while an article in use is unverified; the bank form waits for an active template and then fills its targets;
        /// the three dashboards follow the permissions.
        /// </summary>
        [Fact]
        public async Task The_IBAN_the_printed_terms_the_bank_form_and_the_dashboards()
        {
            var b = await BedAsync(10_000_000);
            var supplier = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new { kind = "SUPPLIER", nameEn = "Steel Pipes Ltd", country = "CN", erpCode = "V-1001" }));
            var id = (await b.Rq.PostOkAsync("/api/v1/requests", new { type = "PURCHASE_LC", company = b.Company, data = new { title = "IBAN", supplierName = "Steel Pipes Ltd" } }))
                .GetProperty("id").GetString()!;
            await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new { fields = Terms(supplier, 1_000_000) });
            await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/documents", new object[] { new { clause = "COMMERCIAL_INVOICE", originals = 3, copies = 2 } });
            Assert.Equal((422, "V-LCT-IBAN"), await b.Rq.ProblemAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/beneficiary-iban", new { iban = "SA0380000000608010167518" }));
            var mask = (await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/beneficiary-iban", new { iban = "sa03 8000 0000 6080 1016 7519" })).GetProperty("iban").GetString()!;
            Assert.DoesNotContain("60801016", mask, StringComparison.Ordinal);
            Assert.Equal(mask, (await b.Rq.GetJsonAsync($"/api/v1/requests/{id}/terms")).GetProperty("beneficiaryIban").GetString());

            // The requester's dashboard shows the draft.
            var mine = await b.Rq.GetJsonAsync("/api/v1/dashboards/requester");
            Assert.Equal(1, mine.GetProperty("counters").GetProperty("open").GetInt32());
            Assert.Equal((403, "FORBIDDEN"), await b.Rq.ProblemAsync(HttpMethod.Get, "/api/v1/dashboards/manager"));

            await ActAsync(b.Rq, id, "submit");
            Assert.Equal((409, "TERMS_LOCKED"), await b.Rq.ProblemAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/beneficiary-iban", new { iban = "" }));
            Assert.Equal((403, "FORBIDDEN"), await b.Rq.PostProblemAsync($"/api/v1/requests/{id}/terms/beneficiary-iban/reveal", new { reason = "Check" }));
            Assert.Equal((422, "VALIDATION_FAILED"), await b.Tm.PostProblemAsync($"/api/v1/requests/{id}/terms/beneficiary-iban/reveal", new { reason = "" }));
            Assert.Equal("SA0380000000608010167519",
                (await b.Tm.PostOkAsync($"/api/v1/requests/{id}/terms/beneficiary-iban/reveal", new { reason = "Bank form" })).GetProperty("iban").GetString());

            // The printed terms: HTML with its own CSP, the mask, the footnote and the hash.
            var print = await b.Rq.SendAsync(HttpMethod.Get, $"/api/v1/requests/{id}/terms/print?lang=en");
            var html = await print.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
            Assert.True(print.IsSuccessStatusCode, html);
            Assert.Contains("style-src 'sha256-", print.Headers.GetValues("Content-Security-Policy").Single(), StringComparison.Ordinal);
            Assert.Contains("Letter of credit terms", html, StringComparison.Ordinal);
            Assert.Contains(mask, html, StringComparison.Ordinal);
            Assert.Contains("SHA-256 ", html, StringComparison.Ordinal);
            Assert.DoesNotContain("60801016", html, StringComparison.Ordinal);
            Assert.Contains("ICC", html, StringComparison.Ordinal);
            Assert.Equal((422, "V-LCT-UCP-FOOTNOTE"),
                await b.T.Portal.ProblemAsync(HttpMethod.Patch, "/api/v1/settings", new { values = new Dictionary<string, object> { ["lc.print.ucp_disclaimer"] = false } }));

            // The bank form: none active, then a template of the bank with two maps.
            Assert.Equal((409, "NO_FORM_TEMPLATE"), await b.Tm.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{id}/bank-form"));
            Assert.Equal((403, "FORBIDDEN"), await b.Rq.PostProblemAsync("/api/v1/lc-form-templates", new { code = "BNKC-LC", formKind = "LC_APPLICATION", effectiveFrom = D(Today) }));
            var tpl = (await b.Fo.PostOkAsync("/api/v1/lc-form-templates", new { code = "BNKC-LC", formKind = "LC_APPLICATION", institution = b.Bank, effectiveFrom = D(Today.AddDays(-1)) }))
                .GetProperty("id").GetString()!;
            Assert.Equal((422, "V-LCT-MAP"), await b.Fo.ProblemAsync(HttpMethod.Put, $"/api/v1/lc-form-templates/{tpl}/field-maps", new object[] { new { targetName = "x", sourceExpr = "sec.password" } }));
            await b.Fo.OkAsync(HttpMethod.Put, $"/api/v1/lc-form-templates/{tpl}/field-maps", new object[]
            {
                new { targetName = "Applicant", sourceExpr = "company.nameEn", transform = "UPPER", isRequired = true, seqNo = 1 },
                new { targetName = "Amount in words", sourceExpr = "terms.amount", transform = "AMOUNT_WORDS_EN", seqNo = 2 },
                new { targetName = "Sight", sourceExpr = "terms.lcType", transform = "CHECKBOX_EQ", transformArg = "SIGHT", seqNo = 3 },
                new { targetName = "Facility", sourceExpr = "facility.facilityNo", isRequired = true, seqNo = 4 },
            });
            await b.Fo.OkAsync(HttpMethod.Post, $"/api/v1/lc-form-templates/{tpl}/activate", new { });
            Assert.Equal((409, "TEMPLATE_PUBLISHED"), await b.Fo.ProblemAsync(HttpMethod.Put, $"/api/v1/lc-form-templates/{tpl}/field-maps", Array.Empty<object>()));

            await ActAsync(b.Mgr, id, "approve");
            var original = await DocumentAsync(b.Tm, b.Company, "SIGNED_REQUEST_ORIGINAL", "Signed original IBAN");
            await b.Tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = original, slot = "SIGNED_ORIGINAL" });
            await ActAsync(b.Rq, id, "complete");
            var sheet = await b.Tm.GetJsonAsync($"/api/v1/requests/{id}/bank-form");
            Assert.False(sheet.GetProperty("official").GetBoolean());
            Assert.Equal(["Facility"], sheet.GetProperty("missingRequired").EnumerateArray().Select(x => x.GetString()!).ToArray());
            var items = sheet.GetProperty("items").EnumerateArray().ToDictionary(x => x.GetProperty("target").GetString()!, x => x.GetProperty("value").GetString()!);
            Assert.Equal("IMPORTER", items["Applicant"]);
            Assert.Equal("X", items["Sight"]);
            Assert.Contains("million", items["Amount in words"], StringComparison.OrdinalIgnoreCase);

            await ActAsync(b.Fo, id, "claim");
            await b.Fo.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/allocation", new { facility = b.Fac, line = b.Line });
            await ActAsync(b.Fo, id, "complete");
            Assert.True((await b.Tm.GetJsonAsync($"/api/v1/requests/{id}/bank-form")).GetProperty("official").GetBoolean());

            // The manager's dashboard: the approval with the line's available amount; the officer's.
            var manager = await b.Tm.GetJsonAsync("/api/v1/dashboards/manager");
            var approval = manager.GetProperty("approvals").EnumerateArray().Single();
            Assert.Equal(10_000_000m, approval.GetProperty("available").GetDecimal());
            Assert.Equal(1, manager.GetProperty("counters").GetProperty("approvals").GetInt32());
            Assert.Equal(0, (await b.Te.GetJsonAsync("/api/v1/dashboards/officer")).GetProperty("counters").GetProperty("tasks").GetInt32());
        }

        /// <summary>
        /// The S3 exit on synthetic data (OQ-13): DS-AGR C's documentary credit line of 50,000,000 with the four credits of
        /// DS-LC-C. Two are issued (exposures 13,200,000 and 21,000,000), the first drawn by 5,000,000 and paid; the third
        /// is approved and holds its reservation of 19,800,000; the fourth needs 2,000,000 where 1,000,000 is left and the
        /// treasury manager's approval is refused. The line shows the pack's expected figures after each step.
        /// </summary>
        [Fact]
        public async Task S3_exit_the_synthetic_credits_of_DS_LC_C_on_agreement_C()
        {
            var ct = TestContext.Current.CancellationToken;
            var dir = Path.Combine(AppContext.BaseDirectory, "DS-LC-C", "v1");
            foreach (var (file, print) in JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(dir, "manifest.json"), ct))!["fingerprints"]!.AsObject())
                Assert.Equal(print!.GetValue<string>(), "sha256:" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(Path.Combine(dir, file), ct))));
            var pack = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(dir, "credits.json"), ct))!.AsObject();
            var b = await BedAsync(0, "C");
            var suppliers = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var s in pack["suppliers"]!.AsArray())
                suppliers[(string)s!["key"]!] = PlatformFixture.Id(await b.Rq.PostOkAsync("/api/v1/counterparties", new
                {
                    kind = (string)s["kind"]!, nameEn = (string)s["nameEn"]!, country = (string)s["country"]!, erpCode = (string)s["erpCode"]!,
                }));
            var expected = pack["expected"]!.AsArray().ToDictionary(e => (string)e!["after"]!, e => ((decimal)e!["used"]!, (decimal)e["reserved"]!, (decimal)e["avail"]!));
            foreach (var n in pack["credits"]!.AsArray())
            {
                var credit = n!.AsObject();
                var key = (string)credit["key"]!;
                var terms = Terms(suppliers[(string)credit["supplier"]!], (decimal)credit["amount"]!);
                var plus = (decimal)credit["tolerancePlusPct"]!;
                if (plus == 0) { terms["toleranceMode"] = "NONE"; terms.Remove("tolerancePlusPct"); terms.Remove("toleranceMinusPct"); }
                else (terms["tolerancePlusPct"], terms["toleranceMinusPct"]) = (plus, plus);
                foreach (var (field, from) in new[] { ("goodsDescription", "goodsDescription"), ("incotermId", "incoterm"), ("transportMode", "transportMode"), ("portOfLoading", "portOfLoading"), ("portOfDischarge", "portOfDischarge") })
                    terms[field] = (string)credit[from]!;
                var id = (await b.Rq.PostOkAsync("/api/v1/requests", new { type = "PURCHASE_LC", company = b.Company, data = new { title = (string)credit["title"]!, supplierName = "Synthetic" } }))
                    .GetProperty("id").GetString()!;
                await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new { fields = terms });
                await b.Rq.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/documents", credit["documents"]!.AsArray().Select(d => (object)new
                {
                    clause = (string)d!["clause"]!, originals = (int)d["originals"]!, copies = (int)d["copies"]!,
                }).ToArray());
                await ActAsync(b.Rq, id, "submit");
                await ActAsync(b.Mgr, id, "approve");
                var original = await DocumentAsync(b.Tm, b.Company, "SIGNED_REQUEST_ORIGINAL", "Signed original " + key);
                await b.Tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = original, slot = "SIGNED_ORIGINAL" });
                await ActAsync(b.Rq, id, "complete");
                await ActAsync(b.Fo, id, "claim");
                await b.Fo.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/allocation", new { facility = b.Fac, line = b.Line });
                await ActAsync(b.Fo, id, "complete");
                switch ((string)credit["outcome"]!)
                {
                    case "REFUSED_AT_TM":
                        Assert.Equal((409, (string)credit["refusal"]!), await RefusedAsync(b.Tm, id, "approve"));
                        break;
                    case "APPROVED":
                        await ActAsync(b.Tm, id, "approve");
                        break;
                    default:
                        var lc = await IssuedAsync(b, id, (string)credit["lcNumber"]!);
                        Assert.Equal(expected[key], await b.LineAsync());
                        var no = 0;
                        foreach (var d in credit["drawings"]!.AsArray())
                        {
                            no = (await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings", new { amount = (decimal)d!["amount"]!, presentationDate = D(Today) })).GetProperty("drawingNo").GetInt32();
                            await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings/{no}/decision", new { status = (string)d["decision"]! });
                            if ((bool)d["settle"]!) await b.Te.PostOkAsync($"/api/v1/lcs/{lc}/drawings/{no}/settlements", new { amount = (decimal)d["amount"]!, settledOn = D(Today) });
                        }
                        if (no > 0) key += ".drawings";
                        break;
                }
                Assert.Equal(expected[key], await b.LineAsync());
            }
        }
}
}
