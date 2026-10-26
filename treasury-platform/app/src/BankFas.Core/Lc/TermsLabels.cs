namespace BankFas.Core.Lc;

/// <summary>
/// The words of the printed terms (docs/60 section 6): the field dictionary's sections, the list values of the terms,
/// the terms' statuses and the charges matrix, in Arabic and English, so the print shows words and not codes. The terms
/// screen holds the same Arabic words in web/src/ar.ts. A value that is not a known code prints as it is.
/// </summary>
public static class TermsLabels
{
    private static readonly Dictionary<string, (string Ar, string En)> Words = new(StringComparer.Ordinal)
    {
        // sections of lc.LcFieldDefinition
        ["PAYMENT"] = ("الدفع", "Payment"), ["PARTIES"] = ("الأطراف", "Parties"), ["AMOUNT"] = ("المبلغ", "Amount"),
        ["DATES"] = ("التواريخ", "Dates"), ["SHIPPING"] = ("الشحن", "Shipping"), ["GOODS"] = ("البضاعة", "Goods"),
        ["DOCUMENTS"] = ("المستندات", "Documents"), ["CHARGES"] = ("الرسوم", "Charges"), ["TREASURY"] = ("الخزينة", "Treasury"),
        ["PREVIOUS_LC"] = ("الاعتماد السابق", "Previous credit"),
        // statuses of lc.LcTerms
        ["DRAFT"] = ("مسودة", "Draft"), ["LOCKED"] = ("مقفلة", "Locked"), ["SUPERSEDED"] = ("مستبدلة", "Superseded"),
        // list values of the terms
        ["SIGHT"] = ("اطلاع", "Sight"), ["DEFERRED_PAYMENT"] = ("دفع مؤجل", "Deferred payment"), ["ACCEPTANCE"] = ("قبول", "Acceptance"),
        ["NEGOTIATION"] = ("تداول", "Negotiation"), ["MIXED"] = ("دفع مختلط", "Mixed payment"),
        ["SHIPMENT_DATE"] = ("تاريخ الشحن", "Shipment date"), ["DELIVERY_NOTE_DATE"] = ("تاريخ إشعار التسليم", "Delivery note date"),
        ["INVOICE_DATE"] = ("تاريخ الفاتورة", "Invoice date"), ["DOCUMENTS_RECEIPT_DATE"] = ("تاريخ استلام المستندات", "Documents receipt date"),
        ["ACCEPTANCE_DATE"] = ("تاريخ القبول", "Acceptance date"),
        ["ADVISING_BANK"] = ("البنك المبلِّغ", "Advising bank"), ["ISSUING_BANK"] = ("البنك المصدِر", "Issuing bank"), ["ANY_BANK"] = ("أي بنك", "Any bank"),
        ["NOMINATED_BANK"] = ("البنك المسمّى", "Nominated bank"),
        ["WITHOUT"] = ("بدون تعزيز", "Without"), ["MAY_ADD"] = ("يجوز التعزيز", "May add"), ["CONFIRMED"] = ("معزَّز", "Confirmed"),
        ["NONE"] = ("لا يوجد", "None"), ["ABOUT"] = ("حوالي (±10%)", "About (±10%)"), ["PLUS_MINUS"] = ("زيادة ونقص", "Plus or minus"),
        ["ABSOLUTE"] = ("تاريخ محدد", "A set date"), ["DAYS_AFTER_ISSUE"] = ("أيام بعد الإصدار", "Days after issue"),
        ["ALLOWED"] = ("مسموح", "Allowed"), ["NOT_ALLOWED"] = ("غير مسموح", "Not allowed"), ["NOT_APPLICABLE"] = ("لا ينطبق", "Not applicable"),
        ["SEA"] = ("بحري", "Sea"), ["AIR"] = ("جوي", "Air"), ["ROAD"] = ("بري", "Road"), ["RAIL"] = ("بالقطار", "Rail"), ["COURIER"] = ("بريد سريع", "Courier"),
        ["MULTIMODAL"] = ("متعدد الوسائط", "Multimodal"), ["DOMESTIC_DELIVERY"] = ("تسليم محلي", "Domestic delivery"),
        ["APPLICANT"] = ("طالب الاعتماد", "Applicant"), ["BENEFICIARY"] = ("المستفيد", "Beneficiary"), ["SHARED"] = ("مشتركة", "Shared"),
        ["NOT_REQUIRED_BY_TERMS"] = ("غير مطلوب في الشروط", "Not required by the terms"),
        ["EN"] = ("الإنجليزية", "English"), ["AR"] = ("العربية", "Arabic"), ["BOTH"] = ("العربية والإنجليزية", "Arabic and English"),
        ["PURCHASE"] = ("مشتريات", "Purchase"), ["SALES"] = ("مبيعات", "Sales"),
        ["DOMESTIC"] = ("محلي", "Domestic"), ["INTERNATIONAL"] = ("دولي", "International"),
        // 40E, applicable rules: the words of the MT700 message itself
        ["UCP600"] = ("UCP LATEST VERSION", "UCP LATEST VERSION"),
        // the charges matrix
        ["ISSUING_BANK_LOCAL"] = ("رسوم البنك المصدِر", "Issuing bank's charges"), ["ADVISING"] = ("رسوم التبليغ", "Advising"),
        ["CONFIRMATION"] = ("رسوم التعزيز", "Confirmation"), ["NEGOTIATION_SETTLEMENT"] = ("رسوم التداول والسداد", "Negotiation and settlement"),
        ["AMENDMENT"] = ("رسوم التعديل", "Amendment"), ["OTHER_OUTSIDE_ISSUING"] = ("رسوم أخرى خارج البنك المصدِر", "Other charges outside the issuing bank"),
    };

    /// <summary>The word for a code, or the value itself when it is not a known code.</summary>
    public static string Of(string? value, bool arabic) =>
        value is not null && Words.TryGetValue(value, out var w) ? (arabic ? w.Ar : w.En) : value ?? "";

    /// <summary>The MT700 field of a term: the dictionary's tag, 42C instead of 42P for an acceptance credit's drafts.</summary>
    public static string? Tag(string? hint, string? lcType) =>
        string.IsNullOrWhiteSpace(hint) ? null : hint == "42P" && lcType == "ACCEPTANCE" ? "42C" : hint;
}
