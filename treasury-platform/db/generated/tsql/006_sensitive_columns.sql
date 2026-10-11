/* مُولَّد آليًا من نموذج البيانات (tools/dbgen) — لا يُعدَّل يدويًا؛ عدِّل النموذج وأعد التوليد. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;  -- مطلوبة للفهارس المصفّاة والأعمدة المحسوبة المخزَّنة (sqlcmd يفترض QUOTED_IDENTIFIER OFF)
GO
/* حجب الأعمدة الحساسة (sens في النموذج) عن دور القراءة/التقارير tp_readonly؛ تقرؤها طبقة التطبيق عبر tp_app فقط */
DENY SELECT ON [plat].[PlatformOperator]([PasswordHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [plat].[PlatformOperator]([MfaSecretEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[AppUser]([PasswordHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[AppUser]([MfaSecretEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[UserSession]([TokenHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[MfaRecoveryCode]([CodeHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[UserToken]([TokenHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[UserPasswordHistory]([PasswordHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [sec].[TenantKey]([WrappedKey]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[IdentityDocument]([NumberEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[IdentityDocument]([NumberMask]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[IdentityDocument]([NumberHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCustomField]([ValueEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([IsPep]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([IsRelatedToPep]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([IsSanctioned]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([IsUnderInvestigation]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([HasImmunity]) TO [tp_readonly]; -- restricted
DENY SELECT ON [pty].[PartyCompliance]([Details]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([AccountNoEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([AccountNoMask]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([AccountNoHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([IbanEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([IbanMask]) TO [tp_readonly]; -- restricted
DENY SELECT ON [acc].[BankAccount]([IbanHash]) TO [tp_readonly]; -- restricted
DENY SELECT ON [col].[Collateral]([Attributes]) TO [tp_readonly]; -- restricted
DENY SELECT ON [lc].[LcTerms]([BeneficiaryAccountIbanEnc]) TO [tp_readonly]; -- restricted
DENY SELECT ON [lc].[LcTerms]([BeneficiaryAccountIbanMask]) TO [tp_readonly]; -- restricted
DENY SELECT ON [lc].[LcTerms]([BeneficiaryAccountIbanHash]) TO [tp_readonly]; -- restricted
GO
