/* مُولَّد آليًا من نموذج البيانات (tools/dbgen) — لا يُعدَّل يدويًا؛ عدِّل النموذج وأعد التوليد. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- مطلوبة للفهارس المصفّاة والأعمدة المحسوبة المخزَّنة (sqlcmd يفترض QUOTED_IDENTIFIER OFF)
GO
/* (1) الجداول المسموح للتطبيق بالحذف الفعلي منها (علامة deletable في النموذج)؛ بقية الجداول بلا صلاحية حذف أصلًا.
   (2) جداول الإضافة فقط (append) خارج aud: DENY UPDATE على التطبيق والمنصة فيصير «للإضافة فقط» مفروضًا بالصلاحيات لا بالعُرف. */
GRANT DELETE ON [sec].[RolePermission] TO [tp_app];
GRANT DELETE ON [sec].[UserRole] TO [tp_app];
GRANT DELETE ON [sec].[UserCompanyScope] TO [tp_app];
GRANT DELETE ON [sec].[LoginAttempt] TO [tp_app];
GRANT DELETE ON [sec].[UserSession] TO [tp_app];
GRANT DELETE ON [sec].[MfaRecoveryCode] TO [tp_app];
GRANT DELETE ON [sec].[UserToken] TO [tp_app];
GRANT DELETE ON [sec].[UserPasswordHistory] TO [tp_app];
GRANT DELETE ON [cfg].[NonWorkingDay] TO [tp_app];
GRANT DELETE ON [cfg].[OutboxEvent] TO [tp_app];
GRANT DELETE ON [cfg].[JobRun] TO [tp_app];
GRANT DELETE ON [org].[CompanyWealthSource] TO [tp_app];
GRANT DELETE ON [pty].[ContactMethod] TO [tp_app];
GRANT DELETE ON [pty].[KycProfileItem] TO [tp_app];
GRANT DELETE ON [pty].[KycProfileItemLegalForm] TO [tp_app];
GRANT DELETE ON [cat].[OperationTypePowerType] TO [tp_app];
GRANT DELETE ON [cat].[ProductFeeType] TO [tp_app];
GRANT DELETE ON [cat].[ProductFinancingType] TO [tp_app];
GRANT DELETE ON [cat].[LimitTypeProduct] TO [tp_app];
GRANT DELETE ON [cat].[BaseRateAlias] TO [tp_app];
GRANT DELETE ON [col].[PromissoryNoteSigner] TO [tp_app];
GRANT DELETE ON [obl].[ObligationCompany] TO [tp_app];
GRANT DELETE ON [obl].[CovenantAccount] TO [tp_app];
GRANT DELETE ON [fin].[LineCatalogItemAlias] TO [tp_app];
GRANT DELETE ON [wfl].[RequestTypeAudience] TO [tp_app];
GRANT DELETE ON [wfl].[WorkflowStage] TO [tp_app];
GRANT DELETE ON [wfl].[StageApprover] TO [tp_app];
GRANT DELETE ON [wfl].[WorkflowTransition] TO [tp_app];
GRANT DELETE ON [wfl].[WorkflowStageHook] TO [tp_app];
GRANT DELETE ON [wfl].[TemplateField] TO [tp_app];
GRANT DELETE ON [wfl].[TemplateAttachmentRule] TO [tp_app];
GRANT DELETE ON [ntf].[NotificationTemplate] TO [tp_app];
GRANT DELETE ON [lc].[LcFieldUcpRef] TO [tp_app];
GRANT DELETE ON [lc].[LcDocumentClauseUcpRef] TO [tp_app];
GRANT DELETE ON [lc].[LcTermsDocument] TO [tp_app];
GRANT DELETE ON [lc].[LcFormFieldMap] TO [tp_app];
DENY UPDATE ON [sec].[LoginAttempt] TO [tp_app], [tp_platform];
DENY UPDATE ON [sec].[UserPasswordHistory] TO [tp_app], [tp_platform];
DENY UPDATE ON [sec].[KeyEvent] TO [tp_app], [tp_platform];
DENY UPDATE ON [cfg].[ExpiryAlertLog] TO [tp_app], [tp_platform];
DENY UPDATE ON [cfg].[SeedRun] TO [tp_app], [tp_platform];
DENY UPDATE ON [fac].[LimitMovement] TO [tp_app], [tp_platform];
DENY UPDATE ON [wfl].[RequestAction] TO [tp_app], [tp_platform];
GO
