using BankFas.Data.Jobs;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>
/// RESERVATION (CORE.EXPIRY v4; FR-FAC-018, BR-WFL-017): an active reservation of a request with its expiry date raises
/// FAC.RESERVATION_ALERT at 7 and 1 days. What happens on the day after is JOB-FAC-RESERVATION's: the reservation is
/// released as EXPIRED and the request's reservation is LOST.
/// </summary>
internal sealed class ReservationExpiry : IExpiryItemProvider
{
    public string ItemType => "RESERVATION";
    public string EventCode => "FAC.RESERVATION_ALERT";
    public string TargetType => "fac.LimitReservation";
    public bool ValidThroughExpiryDate => true;

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string FacilityNo { get; init; } = "";
        public string? RequestNo { get; init; }
        public string DraftRef { get; init; } = "";
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT lr.LimitReservationId AS Id, lr.ExpiresOn AS ExpiryDate, lr.CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, f.FacilityNo,
                   r.RequestNo, r.DraftRef
              FROM fac.LimitReservation AS lr JOIN org.Company AS co ON co.CompanyId = lr.CompanyId JOIN fac.Facility AS f ON f.FacilityId = lr.FacilityId
              JOIN wfl.Request AS r ON r.RequestId = lr.RequestId
             WHERE lr.Status = 'ACTIVE' AND lr.ExpiresOn IS NOT NULL AND lr.ExpiresOn <= @horizon AND lr.ExpiresOn >= @today;
            """, new { today, horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn), ["facilityNo"] = r.FacilityNo,
                ["itemLabel"] = ExpiryItemProviders.Text($"حجز الطلب {r.RequestNo ?? r.DraftRef}", $"the reservation of request {r.RequestNo ?? r.DraftRef}"),
                ["reasonLabel"] = ExpiryItemProviders.Text("قرب انتهاء الحجز", "the reservation is about to expire"),
            }))];
}

/// <summary>
/// LC_EXPIRY and LC_LATEST_SHIPMENT (CORE.EXPIRY v4; FR-LCI-018, 14m section 9): the expiry date and the latest shipment
/// date of an ACTIVE letter of credit raise LC.EXPIRY_DUE for its company at 30, 15 and 7 days (and the rule's reminder
/// after the expiry, until the credit is expired or closed).
/// </summary>
internal sealed class LcDateExpiry(bool shipment) : IExpiryItemProvider
{
    public string ItemType => shipment ? "LC_LATEST_SHIPMENT" : "LC_EXPIRY";
    public string EventCode => "LC.EXPIRY_DUE";
    public string TargetType => "lc.LetterOfCredit";
    public bool ValidThroughExpiryDate => true;

    private sealed class Row
    {
        public long Id { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long CompanyId { get; init; }
        public string LcNumber { get; init; } = "";
        public string? RequestNo { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
    }

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<Row>(new CommandDefinition(
            $"""
            SELECT l.LetterOfCreditId AS Id, l.{(shipment ? "LatestShipmentDate" : "ExpiryDate")} AS ExpiryDate, l.CompanyId, l.LcNumber, r.RequestNo,
                   co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn
              FROM lc.LetterOfCredit AS l JOIN org.Company AS co ON co.CompanyId = l.CompanyId LEFT JOIN wfl.Request AS r ON r.RequestId = l.RequestId
             WHERE l.Status = 'ACTIVE' AND l.{(shipment ? "LatestShipmentDate" : "ExpiryDate")} IS NOT NULL AND l.{(shipment ? "LatestShipmentDate" : "ExpiryDate")} <= @horizon;
            """, new { horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.ExpiryDate, r.CompanyId, new Dictionary<string, object?>
            {
                ["lcNo"] = r.LcNumber, ["requestNo"] = r.RequestNo, ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                ["stageLabel"] = shipment ? ExpiryItemProviders.Text("آخر موعد للشحن", "the latest shipment date") : ExpiryItemProviders.Text("انتهاء الاعتماد", "the expiry of the credit"),
            }))];
}

/// <summary>LC_DRAWING_DUE (CORE.EXPIRY v4; JOB-LC-MATURITY): the maturity of an accepted or pending deferred drawing not yet paid raises LC.DRAWING_DUE at 7, 3, 1 and 0 days.</summary>
internal sealed class LcDrawingDue : IExpiryItemProvider
{
    public string ItemType => "LC_DRAWING_DUE";
    public string EventCode => "LC.DRAWING_DUE";
    public string TargetType => "lc.LcDrawing";
    public bool ValidThroughExpiryDate => true;

    public async Task<IReadOnlyList<ExpiryItem>> ItemsAsync(SqlConnection c, DateTime today, DateTime horizon, CancellationToken ct) =>
        [.. (await c.QueryAsync<(long Id, DateTime Due, long CompanyId, string LcNumber, int DrawingNo)>(new CommandDefinition(
            """
            SELECT d.LcDrawingId, d.MaturityDate, d.CompanyId, l.LcNumber, d.DrawingNo FROM lc.LcDrawing AS d JOIN lc.LetterOfCredit AS l ON l.LetterOfCreditId = d.LcId
             WHERE d.MaturityDate IS NOT NULL AND d.MaturityDate <= @horizon AND d.Status IN ('PRESENTED', 'DISCREPANT', 'ACCEPTED');
            """, new { horizon }, cancellationToken: ct)).ConfigureAwait(false))
            .Select(r => new ExpiryItem(r.Id, r.Due, r.CompanyId, new Dictionary<string, object?> { ["lcNo"] = r.LcNumber, ["drawingNo"] = r.DrawingNo }))];
}
