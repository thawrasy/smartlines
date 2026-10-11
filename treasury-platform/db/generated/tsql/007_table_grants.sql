/* مُولَّد آليًا من نموذج البيانات (tools/dbgen) — لا يُعدَّل يدويًا؛ عدِّل النموذج وأعد التوليد. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- مطلوبة للفهارس المصفّاة والأعمدة المحسوبة المخزَّنة (sqlcmd يفترض QUOTED_IDENTIFIER OFF)
GO
/* صلاحيات الجداول الصريحة (يولّدها النموذج). القواعد في tools/dbgen/dbgen.py عند الحلقة grant_lines. */
-- plat.Plan
GRANT SELECT ON [plat].[Plan] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [plat].[Plan] TO [tp_platform];
-- plat.PlanModule
GRANT SELECT ON [plat].[PlanModule] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [plat].[PlanModule] TO [tp_platform];
-- plat.Tenant  (noapp: بلا منح لتطبيق المشترك)
GRANT SELECT, INSERT, UPDATE ON [plat].[Tenant] TO [tp_platform];
-- plat.ReservedSubdomain  (noapp: بلا منح لتطبيق المشترك)
GRANT SELECT, INSERT, UPDATE ON [plat].[ReservedSubdomain] TO [tp_platform];
-- plat.PlatformOperator  (noapp: بلا منح لتطبيق المشترك)
GRANT SELECT, INSERT, UPDATE ON [plat].[PlatformOperator] TO [tp_platform];
-- plat.TenantModule  (noapp: بلا منح لتطبيق المشترك)
GRANT SELECT, INSERT, UPDATE ON [plat].[TenantModule] TO [tp_platform];
-- plat.SupportAccessGrant
GRANT SELECT, INSERT, UPDATE ON [plat].[SupportAccessGrant] TO [tp_app];
-- sec.AppUser
GRANT SELECT, INSERT, UPDATE ON [sec].[AppUser] TO [tp_app];
-- sec.Role
GRANT SELECT, INSERT, UPDATE ON [sec].[Role] TO [tp_app];
-- sec.Permission
GRANT SELECT ON [sec].[Permission] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [sec].[Permission] TO [tp_platform];
-- sec.RolePermission
GRANT SELECT, INSERT, UPDATE ON [sec].[RolePermission] TO [tp_app];
-- sec.UserRole
GRANT SELECT, INSERT, UPDATE ON [sec].[UserRole] TO [tp_app];
-- sec.UserCompanyScope
GRANT SELECT, INSERT, UPDATE ON [sec].[UserCompanyScope] TO [tp_app];
-- sec.LoginAttempt
GRANT SELECT, INSERT ON [sec].[LoginAttempt] TO [tp_app];
-- sec.UserSession
GRANT SELECT, INSERT, UPDATE ON [sec].[UserSession] TO [tp_app];
-- sec.MfaRecoveryCode
GRANT SELECT, INSERT, UPDATE ON [sec].[MfaRecoveryCode] TO [tp_app];
-- sec.UserToken
GRANT SELECT, INSERT, UPDATE ON [sec].[UserToken] TO [tp_app];
-- sec.UserPasswordHistory
GRANT SELECT, INSERT ON [sec].[UserPasswordHistory] TO [tp_app];
-- sec.ExternalIdentity
GRANT SELECT, INSERT, UPDATE ON [sec].[ExternalIdentity] TO [tp_app];
-- sec.TenantKey
GRANT SELECT, INSERT, UPDATE ON [sec].[TenantKey] TO [tp_app];
-- sec.KeyEvent
GRANT SELECT, INSERT ON [sec].[KeyEvent] TO [tp_app];
-- aud.AuditLog
GRANT SELECT, INSERT ON [aud].[AuditLog] TO [tp_app];
GRANT SELECT, INSERT ON [aud].[AuditLog] TO [tp_platform];
-- aud.SensitiveAccessLog
GRANT SELECT, INSERT ON [aud].[SensitiveAccessLog] TO [tp_app];
-- doc.Document
GRANT SELECT, INSERT, UPDATE ON [doc].[Document] TO [tp_app];
-- doc.DocumentVersion
GRANT SELECT, INSERT, UPDATE ON [doc].[DocumentVersion] TO [tp_app];
-- doc.DocumentLink
GRANT SELECT, INSERT, UPDATE ON [doc].[DocumentLink] TO [tp_app];
-- cfg.SettingDefinition
GRANT SELECT ON [cfg].[SettingDefinition] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [cfg].[SettingDefinition] TO [tp_platform];
-- cfg.TenantSetting
GRANT SELECT, INSERT, UPDATE ON [cfg].[TenantSetting] TO [tp_app];
-- cfg.NumberSequenceDefinition
GRANT SELECT, INSERT, UPDATE ON [cfg].[NumberSequenceDefinition] TO [tp_app];
-- cfg.NumberSequence
GRANT SELECT, INSERT, UPDATE ON [cfg].[NumberSequence] TO [tp_app];
-- cfg.NumberIssue
GRANT SELECT, INSERT, UPDATE ON [cfg].[NumberIssue] TO [tp_app];
-- cfg.ExpiryAlertRule
GRANT SELECT, INSERT, UPDATE ON [cfg].[ExpiryAlertRule] TO [tp_app];
-- cfg.ExpiryAlertLog
GRANT SELECT, INSERT ON [cfg].[ExpiryAlertLog] TO [tp_app];
-- cfg.DataExportJob
GRANT SELECT, INSERT, UPDATE ON [cfg].[DataExportJob] TO [tp_app];
-- cfg.NonWorkingDay
GRANT SELECT, INSERT, UPDATE ON [cfg].[NonWorkingDay] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [cfg].[NonWorkingDay] TO [tp_platform];
-- cfg.OutboxEvent
GRANT SELECT, INSERT, UPDATE ON [cfg].[OutboxEvent] TO [tp_app];
-- cfg.JobRun
GRANT SELECT, INSERT, UPDATE ON [cfg].[JobRun] TO [tp_app];
-- cfg.SeedRun
GRANT SELECT, INSERT ON [cfg].[SeedRun] TO [tp_app];
-- org.Company
GRANT SELECT, INSERT, UPDATE ON [org].[Company] TO [tp_app];
-- org.CompanyTaxRate
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyTaxRate] TO [tp_app];
-- org.Department
GRANT SELECT, INSERT, UPDATE ON [org].[Department] TO [tp_app];
-- org.Shareholding
GRANT SELECT, INSERT, UPDATE ON [org].[Shareholding] TO [tp_app];
-- org.GoverningBody
GRANT SELECT, INSERT, UPDATE ON [org].[GoverningBody] TO [tp_app];
-- org.BodyMember
GRANT SELECT, INSERT, UPDATE ON [org].[BodyMember] TO [tp_app];
-- org.AuthorityGrant
GRANT SELECT, INSERT, UPDATE ON [org].[AuthorityGrant] TO [tp_app];
-- org.CompanyProfile
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyProfile] TO [tp_app];
-- org.CompanyBranch
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyBranch] TO [tp_app];
-- org.CompanyKycFinancialProfile
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyKycFinancialProfile] TO [tp_app];
-- org.CompanyExpectedFlow
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyExpectedFlow] TO [tp_app];
-- org.CompanyWealthSource
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyWealthSource] TO [tp_app];
-- org.CompanyDisclosure
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyDisclosure] TO [tp_app];
-- org.CompanyKeyRelation
GRANT SELECT, INSERT, UPDATE ON [org].[CompanyKeyRelation] TO [tp_app];
-- pty.Party
GRANT SELECT, INSERT, UPDATE ON [pty].[Party] TO [tp_app];
-- pty.IdentityDocument
GRANT SELECT, INSERT, UPDATE ON [pty].[IdentityDocument] TO [tp_app];
-- pty.Address
GRANT SELECT, INSERT, UPDATE ON [pty].[Address] TO [tp_app];
-- pty.ContactMethod
GRANT SELECT, INSERT, UPDATE ON [pty].[ContactMethod] TO [tp_app];
-- pty.CustomFieldDefinition
GRANT SELECT, INSERT, UPDATE ON [pty].[CustomFieldDefinition] TO [tp_app];
-- pty.PartyCustomField
GRANT SELECT, INSERT, UPDATE ON [pty].[PartyCustomField] TO [tp_app];
-- pty.KycProfile
GRANT SELECT, INSERT, UPDATE ON [pty].[KycProfile] TO [tp_app];
-- pty.KycProfileItem
GRANT SELECT, INSERT, UPDATE ON [pty].[KycProfileItem] TO [tp_app];
-- pty.KycProfileItemLegalForm
GRANT SELECT, INSERT, UPDATE ON [pty].[KycProfileItemLegalForm] TO [tp_app];
-- pty.PartyCompliance
GRANT SELECT, INSERT, UPDATE ON [pty].[PartyCompliance] TO [tp_app];
-- pty.TaxIdentity
GRANT SELECT, INSERT, UPDATE ON [pty].[TaxIdentity] TO [tp_app];
-- ref.Country
GRANT SELECT ON [ref].[Country] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [ref].[Country] TO [tp_platform];
-- ref.Currency
GRANT SELECT ON [ref].[Currency] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [ref].[Currency] TO [tp_platform];
-- cat.TenantCurrency
GRANT SELECT, INSERT, UPDATE ON [cat].[TenantCurrency] TO [tp_app];
-- cat.InstitutionType
GRANT SELECT, INSERT, UPDATE ON [cat].[InstitutionType] TO [tp_app];
-- cat.AccountType
GRANT SELECT, INSERT, UPDATE ON [cat].[AccountType] TO [tp_app];
-- cat.LegalEntityType
GRANT SELECT, INSERT, UPDATE ON [cat].[LegalEntityType] TO [tp_app];
-- cat.DocumentType
GRANT SELECT, INSERT, UPDATE ON [cat].[DocumentType] TO [tp_app];
-- cat.Position
GRANT SELECT, INSERT, UPDATE ON [cat].[Position] TO [tp_app];
-- cat.PowerType
GRANT SELECT, INSERT, UPDATE ON [cat].[PowerType] TO [tp_app];
-- cat.OperationType
GRANT SELECT, INSERT, UPDATE ON [cat].[OperationType] TO [tp_app];
-- cat.OperationTypePowerType
GRANT SELECT, INSERT, UPDATE ON [cat].[OperationTypePowerType] TO [tp_app];
-- cat.ProductCategory
GRANT SELECT, INSERT, UPDATE ON [cat].[ProductCategory] TO [tp_app];
-- cat.Product
GRANT SELECT, INSERT, UPDATE ON [cat].[Product] TO [tp_app];
-- cat.FeeType
GRANT SELECT, INSERT, UPDATE ON [cat].[FeeType] TO [tp_app];
-- cat.FinancingType
GRANT SELECT, INSERT, UPDATE ON [cat].[FinancingType] TO [tp_app];
-- cat.ProductFeeType
GRANT SELECT, INSERT, UPDATE ON [cat].[ProductFeeType] TO [tp_app];
-- cat.ProductFinancingType
GRANT SELECT, INSERT, UPDATE ON [cat].[ProductFinancingType] TO [tp_app];
-- cat.FacilityType
GRANT SELECT, INSERT, UPDATE ON [cat].[FacilityType] TO [tp_app];
-- cat.LimitType
GRANT SELECT, INSERT, UPDATE ON [cat].[LimitType] TO [tp_app];
-- cat.LimitTypeProduct
GRANT SELECT, INSERT, UPDATE ON [cat].[LimitTypeProduct] TO [tp_app];
-- cat.CollateralType
GRANT SELECT, INSERT, UPDATE ON [cat].[CollateralType] TO [tp_app];
-- cat.CollateralTypeAttribute
GRANT SELECT, INSERT, UPDATE ON [cat].[CollateralTypeAttribute] TO [tp_app];
-- cat.ObligationType
GRANT SELECT, INSERT, UPDATE ON [cat].[ObligationType] TO [tp_app];
-- cat.BaseRate
GRANT SELECT, INSERT, UPDATE ON [cat].[BaseRate] TO [tp_app];
-- cat.BaseRateAlias
GRANT SELECT, INSERT, UPDATE ON [cat].[BaseRateAlias] TO [tp_app];
-- cat.BaseRateValue
GRANT SELECT, INSERT, UPDATE ON [cat].[BaseRateValue] TO [tp_app];
-- cat.LookupList
GRANT SELECT, INSERT, UPDATE ON [cat].[LookupList] TO [tp_app];
-- cat.LookupItem
GRANT SELECT, INSERT, UPDATE ON [cat].[LookupItem] TO [tp_app];
-- ins.Institution
GRANT SELECT, INSERT, UPDATE ON [ins].[Institution] TO [tp_app];
-- ins.InstitutionUnit
GRANT SELECT, INSERT, UPDATE ON [ins].[InstitutionUnit] TO [tp_app];
-- ins.Contact
GRANT SELECT, INSERT, UPDATE ON [ins].[Contact] TO [tp_app];
-- ins.Relationship
GRANT SELECT, INSERT, UPDATE ON [ins].[Relationship] TO [tp_app];
-- ins.RelationshipContact
GRANT SELECT, INSERT, UPDATE ON [ins].[RelationshipContact] TO [tp_app];
-- ins.RelationshipProduct
GRANT SELECT, INSERT, UPDATE ON [ins].[RelationshipProduct] TO [tp_app];
-- acc.BankAccount
GRANT SELECT, INSERT, UPDATE ON [acc].[BankAccount] TO [tp_app];
-- acc.FacilityAccount
GRANT SELECT, INSERT, UPDATE ON [acc].[FacilityAccount] TO [tp_app];
-- acc.Signatory
GRANT SELECT, INSERT, UPDATE ON [acc].[Signatory] TO [tp_app];
-- acc.SignatoryAuthority
GRANT SELECT, INSERT, UPDATE ON [acc].[SignatoryAuthority] TO [tp_app];
-- acc.SignatoryAuthorityJointClass
GRANT SELECT, INSERT, UPDATE ON [acc].[SignatoryAuthorityJointClass] TO [tp_app];
-- acc.AuthorityConflict
GRANT SELECT, INSERT, UPDATE ON [acc].[AuthorityConflict] TO [tp_app];
-- fac.Facility
GRANT SELECT, INSERT, UPDATE ON [fac].[Facility] TO [tp_app];
-- fac.FacilityRevision
GRANT SELECT, INSERT, UPDATE ON [fac].[FacilityRevision] TO [tp_app];
-- fac.FacilityDocument
GRANT SELECT, INSERT, UPDATE ON [fac].[FacilityDocument] TO [tp_app];
-- fac.FacilityLender
GRANT SELECT, INSERT, UPDATE ON [fac].[FacilityLender] TO [tp_app];
-- fac.OutstandingSnapshot
GRANT SELECT, INSERT, UPDATE ON [fac].[OutstandingSnapshot] TO [tp_app];
-- fac.Limit
GRANT SELECT, INSERT, UPDATE ON [fac].[Limit] TO [tp_app];
-- fac.LimitProductLine
GRANT SELECT, INSERT, UPDATE ON [fac].[LimitProductLine] TO [tp_app];
-- fac.LimitCompanyRule
GRANT SELECT, INSERT, UPDATE ON [fac].[LimitCompanyRule] TO [tp_app];
-- fac.ProductLineTerm
GRANT SELECT, INSERT, UPDATE ON [fac].[ProductLineTerm] TO [tp_app];
-- fac.Utilization
GRANT SELECT, INSERT, UPDATE ON [fac].[Utilization] TO [tp_app];
-- fac.LimitReservation
GRANT SELECT, INSERT, UPDATE ON [fac].[LimitReservation] TO [tp_app];
-- fac.LimitMovement
GRANT SELECT, INSERT ON [fac].[LimitMovement] TO [tp_app];
-- fac.ValueConflict
GRANT SELECT, INSERT, UPDATE ON [fac].[ValueConflict] TO [tp_app];
-- prc.TariffSchedule
GRANT SELECT, INSERT, UPDATE ON [prc].[TariffSchedule] TO [tp_app];
-- prc.TariffItem
GRANT SELECT, INSERT, UPDATE ON [prc].[TariffItem] TO [tp_app];
-- prc.TariffTier
GRANT SELECT, INSERT, UPDATE ON [prc].[TariffTier] TO [tp_app];
-- prc.PricingRule
GRANT SELECT, INSERT, UPDATE ON [prc].[PricingRule] TO [tp_app];
-- prc.PricingTier
GRANT SELECT, INSERT, UPDATE ON [prc].[PricingTier] TO [tp_app];
-- cmp.TermType
GRANT SELECT, INSERT, UPDATE ON [cmp].[TermType] TO [tp_app];
-- cmp.TermValue
GRANT SELECT, INSERT, UPDATE ON [cmp].[TermValue] TO [tp_app];
-- col.Collateral
GRANT SELECT, INSERT, UPDATE ON [col].[Collateral] TO [tp_app];
-- col.CollateralLink
GRANT SELECT, INSERT, UPDATE ON [col].[CollateralLink] TO [tp_app];
-- col.Guarantee
GRANT SELECT, INSERT, UPDATE ON [col].[Guarantee] TO [tp_app];
-- col.PromissoryNote
GRANT SELECT, INSERT, UPDATE ON [col].[PromissoryNote] TO [tp_app];
-- col.PromissoryNoteSigner
GRANT SELECT, INSERT, UPDATE ON [col].[PromissoryNoteSigner] TO [tp_app];
-- col.InsurancePolicyAssignment
GRANT SELECT, INSERT, UPDATE ON [col].[InsurancePolicyAssignment] TO [tp_app];
-- col.ValuationSchedule
GRANT SELECT, INSERT, UPDATE ON [col].[ValuationSchedule] TO [tp_app];
-- obl.Obligation
GRANT SELECT, INSERT, UPDATE ON [obl].[Obligation] TO [tp_app];
-- obl.ObligationCompany
GRANT SELECT, INSERT, UPDATE ON [obl].[ObligationCompany] TO [tp_app];
-- obl.ReportingObligation
GRANT SELECT, INSERT, UPDATE ON [obl].[ReportingObligation] TO [tp_app];
-- obl.ReportingInstance
GRANT SELECT, INSERT, UPDATE ON [obl].[ReportingInstance] TO [tp_app];
-- obl.Covenant
GRANT SELECT, INSERT, UPDATE ON [obl].[Covenant] TO [tp_app];
-- obl.CovenantAccount
GRANT SELECT, INSERT, UPDATE ON [obl].[CovenantAccount] TO [tp_app];
-- obl.CovenantTest
GRANT SELECT, INSERT, UPDATE ON [obl].[CovenantTest] TO [tp_app];
-- obl.ObligationBreach
GRANT SELECT, INSERT, UPDATE ON [obl].[ObligationBreach] TO [tp_app];
-- fin.LineCatalogItem
GRANT SELECT, INSERT, UPDATE ON [fin].[LineCatalogItem] TO [tp_app];
-- fin.LineCatalogItemAlias
GRANT SELECT, INSERT, UPDATE ON [fin].[LineCatalogItemAlias] TO [tp_app];
-- fin.FinancialStatement
GRANT SELECT, INSERT, UPDATE ON [fin].[FinancialStatement] TO [tp_app];
-- fin.StatementLine
GRANT SELECT, INSERT, UPDATE ON [fin].[StatementLine] TO [tp_app];
-- fin.AccountMonthlyStat
GRANT SELECT, INSERT, UPDATE ON [fin].[AccountMonthlyStat] TO [tp_app];
-- fin.BankFlowEntry
GRANT SELECT, INSERT, UPDATE ON [fin].[BankFlowEntry] TO [tp_app];
-- fin.MeasureFormula
GRANT SELECT, INSERT, UPDATE ON [fin].[MeasureFormula] TO [tp_app];
-- wfl.RequestType
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestType] TO [tp_app];
-- wfl.RequestTypeAudience
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestTypeAudience] TO [tp_app];
-- wfl.ExternalPhase
GRANT SELECT, INSERT, UPDATE ON [wfl].[ExternalPhase] TO [tp_app];
-- wfl.WorkflowTemplate
GRANT SELECT, INSERT, UPDATE ON [wfl].[WorkflowTemplate] TO [tp_app];
-- wfl.WorkflowStage
GRANT SELECT, INSERT, UPDATE ON [wfl].[WorkflowStage] TO [tp_app];
-- wfl.StageApprover
GRANT SELECT, INSERT, UPDATE ON [wfl].[StageApprover] TO [tp_app];
-- wfl.WorkflowTransition
GRANT SELECT, INSERT, UPDATE ON [wfl].[WorkflowTransition] TO [tp_app];
-- wfl.WorkflowStageHook
GRANT SELECT, INSERT, UPDATE ON [wfl].[WorkflowStageHook] TO [tp_app];
-- wfl.TemplateField
GRANT SELECT, INSERT, UPDATE ON [wfl].[TemplateField] TO [tp_app];
-- wfl.TemplateAttachmentRule
GRANT SELECT, INSERT, UPDATE ON [wfl].[TemplateAttachmentRule] TO [tp_app];
-- wfl.Request
GRANT SELECT, INSERT, UPDATE ON [wfl].[Request] TO [tp_app];
-- wfl.RequestComment
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestComment] TO [tp_app];
-- wfl.RequestAttachment
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestAttachment] TO [tp_app];
-- wfl.RequestExternalRef
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestExternalRef] TO [tp_app];
-- wfl.RequestStageInstance
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestStageInstance] TO [tp_app];
-- wfl.RequestApproval
GRANT SELECT, INSERT, UPDATE ON [wfl].[RequestApproval] TO [tp_app];
-- wfl.RequestAction
GRANT SELECT, INSERT ON [wfl].[RequestAction] TO [tp_app];
-- wfl.HookExecution
GRANT SELECT, INSERT, UPDATE ON [wfl].[HookExecution] TO [tp_app];
-- wfl.UserDelegation
GRANT SELECT, INSERT, UPDATE ON [wfl].[UserDelegation] TO [tp_app];
-- ntf.NotificationEventType
GRANT SELECT, INSERT, UPDATE ON [ntf].[NotificationEventType] TO [tp_app];
-- ntf.NotificationRule
GRANT SELECT, INSERT, UPDATE ON [ntf].[NotificationRule] TO [tp_app];
-- ntf.NotificationTemplate
GRANT SELECT, INSERT, UPDATE ON [ntf].[NotificationTemplate] TO [tp_app];
-- ntf.NotificationPreference
GRANT SELECT, INSERT, UPDATE ON [ntf].[NotificationPreference] TO [tp_app];
-- ntf.DigestBatch
GRANT SELECT, INSERT, UPDATE ON [ntf].[DigestBatch] TO [tp_app];
-- ntf.Notification
GRANT SELECT, INSERT, UPDATE ON [ntf].[Notification] TO [tp_app];
-- ntf.NotificationDelivery
GRANT SELECT, INSERT, UPDATE ON [ntf].[NotificationDelivery] TO [tp_app];
-- ref.Incoterm
GRANT SELECT ON [ref].[Incoterm] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [ref].[Incoterm] TO [tp_platform];
-- ref.UcpArticle
GRANT SELECT, INSERT, UPDATE ON [ref].[UcpArticle] TO [tp_app];
GRANT SELECT, INSERT, UPDATE ON [ref].[UcpArticle] TO [tp_platform];
-- lc.LcFieldDefinition
GRANT SELECT, INSERT, UPDATE ON [lc].[LcFieldDefinition] TO [tp_app];
-- lc.LcFieldUcpRef
GRANT SELECT, INSERT, UPDATE ON [lc].[LcFieldUcpRef] TO [tp_app];
-- lc.Counterparty
GRANT SELECT, INSERT, UPDATE ON [lc].[Counterparty] TO [tp_app];
-- lc.LcDocumentClause
GRANT SELECT, INSERT, UPDATE ON [lc].[LcDocumentClause] TO [tp_app];
-- lc.LcDocumentClauseUcpRef
GRANT SELECT, INSERT, UPDATE ON [lc].[LcDocumentClauseUcpRef] TO [tp_app];
-- lc.LcTerms
GRANT SELECT, INSERT, UPDATE ON [lc].[LcTerms] TO [tp_app];
-- lc.LcTermsDocument
GRANT SELECT, INSERT, UPDATE ON [lc].[LcTermsDocument] TO [tp_app];
-- lc.LcChargesMatrix
GRANT SELECT, INSERT, UPDATE ON [lc].[LcChargesMatrix] TO [tp_app];
-- lc.LcFormTemplate
GRANT SELECT, INSERT, UPDATE ON [lc].[LcFormTemplate] TO [tp_app];
-- lc.LcFormFieldMap
GRANT SELECT, INSERT, UPDATE ON [lc].[LcFormFieldMap] TO [tp_app];
-- lc.LetterOfCredit
GRANT SELECT, INSERT, UPDATE ON [lc].[LetterOfCredit] TO [tp_app];
-- lc.LcExternalRef
GRANT SELECT, INSERT, UPDATE ON [lc].[LcExternalRef] TO [tp_app];
-- lc.LcAmendment
GRANT SELECT, INSERT, UPDATE ON [lc].[LcAmendment] TO [tp_app];
-- lc.LcDrawing
GRANT SELECT, INSERT, UPDATE ON [lc].[LcDrawing] TO [tp_app];
-- lc.LcSalesOrder
GRANT SELECT, INSERT, UPDATE ON [lc].[LcSalesOrder] TO [tp_app];
-- lc.LcDrawingAllocation
GRANT SELECT, INSERT, UPDATE ON [lc].[LcDrawingAllocation] TO [tp_app];
-- lc.LcDiscrepancy
GRANT SELECT, INSERT, UPDATE ON [lc].[LcDiscrepancy] TO [tp_app];
-- lc.ProformaInvoice
GRANT SELECT, INSERT, UPDATE ON [lc].[ProformaInvoice] TO [tp_app];
-- lc.ProformaLine
GRANT SELECT, INSERT, UPDATE ON [lc].[ProformaLine] TO [tp_app];
-- lc.LcTermsComparison
GRANT SELECT, INSERT, UPDATE ON [lc].[LcTermsComparison] TO [tp_app];
-- lc.LcTermsComparisonLine
GRANT SELECT, INSERT, UPDATE ON [lc].[LcTermsComparisonLine] TO [tp_app];
GO
