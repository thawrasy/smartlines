# مخططات العلاقات (ERD) حسب المخطط

> مُولَّد آليًا. تظهر العلاقات بين الجداول (مفتاح أجنبي ← جدول مرجعي) داخل المخطط، وتُختصَر العلاقات العابرة للمخططات في جدول.

## مخطط `plat` (7 جدولًا)

```mermaid
erDiagram
  Plan ||--o{ PlanModule : "PlanId"
  Plan ||--o{ Tenant : "PlanId"
  PlatformOperator ||--o{ SupportAccessGrant : "OperatorId"
  PlatformOperator ||--o{ TenantModule : "EnabledBy"
  ReservedSubdomain { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| SupportAccessGrant | GrantedBy | sec.AppUser |
| SupportAccessGrant | RevokedBy | sec.AppUser |
| Tenant | HomeCountryId | ref.Country |

## مخطط `sec` (14 جدولًا)

```mermaid
erDiagram
  AppUser ||--o{ ExternalIdentity : "UserId"
  AppUser ||--o{ LoginAttempt : "UserId"
  AppUser ||--o{ MfaRecoveryCode : "UserId"
  AppUser ||--o{ RolePermission : "AssignedBy"
  AppUser ||--o{ UserCompanyScope : "UserId"
  AppUser ||--o{ UserPasswordHistory : "UserId"
  AppUser ||--o{ UserRole : "AssignedBy"
  AppUser ||--o{ UserRole : "UserId"
  AppUser ||--o{ UserSession : "EndedBy"
  AppUser ||--o{ UserSession : "UserId"
  AppUser ||--o{ UserToken : "RequestedByUserId"
  AppUser ||--o{ UserToken : "UserId"
  Permission ||--o{ RolePermission : "PermissionId"
  Role ||--o{ RolePermission : "RoleId"
  Role ||--o{ UserRole : "RoleId"
  TenantKey ||--o{ AppUser : "MfaKeyId"
  TenantKey ||--o{ KeyEvent : "TenantKeyId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| AppUser | DepartmentId | org.Department |
| UserCompanyScope | CompanyId | org.Company |

## مخطط `aud` (2 جدولًا)

```mermaid
erDiagram
  AuditLog { int _ }
  SensitiveAccessLog { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| SensitiveAccessLog | ActorUserId | sec.AppUser |
| SensitiveAccessLog | OperatorId | plat.PlatformOperator |

## مخطط `doc` (3 جدولًا)

```mermaid
erDiagram
  Document ||--o{ DocumentLink : "DocumentId"
  Document ||--o{ DocumentVersion : "DocumentId"
  DocumentVersion ||--o{ Document : "CurrentVersionId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Document | DeletedBy | sec.AppUser |
| Document | DocumentTypeId | cat.DocumentType |
| Document | OwnerCompanyId | org.Company |
| DocumentLink | UnlinkedBy | sec.AppUser |
| DocumentVersion | KeyId | sec.TenantKey |

## مخطط `cfg` (12 جدولًا)

```mermaid
erDiagram
  ExpiryAlertRule ||--o{ ExpiryAlertLog : "ExpiryAlertRuleId"
  NumberSequence ||--o{ NumberIssue : "SequenceId"
  NumberSequenceDefinition ||--o{ NumberSequence : "DefinitionId"
  SettingDefinition { int _ }
  TenantSetting { int _ }
  DataExportJob { int _ }
  NonWorkingDay { int _ }
  OutboxEvent { int _ }
  JobRun { int _ }
  SeedRun { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| DataExportJob | ApprovedBy | sec.AppUser |
| DataExportJob | PackageDocumentId | doc.Document |
| DataExportJob | RequestedBy | sec.AppUser |
| NonWorkingDay | CountryId | ref.Country |
| NumberIssue | VoidedBy | sec.AppUser |
| NumberSequence | CompanyId | org.Company |

## مخطط `org` (14 جدولًا)

```mermaid
erDiagram
  BodyMember ||--o{ AuthorityGrant : "BodyMemberId"
  Company ||--o{ AuthorityGrant : "CompanyId"
  Company ||--o{ BodyMember : "CompanyId"
  Company ||--o{ CompanyBranch : "CompanyId"
  Company ||--o{ CompanyDisclosure : "CompanyId"
  Company ||--o{ CompanyKeyRelation : "CompanyId"
  Company ||--o{ CompanyKycFinancialProfile : "CompanyId"
  Company ||--o{ CompanyProfile : "CompanyId"
  Company ||--o{ CompanyTaxRate : "CompanyId"
  Company ||--o{ Department : "CompanyId"
  Company ||--o{ GoverningBody : "CompanyId"
  Company ||--o{ Shareholding : "CompanyId"
  CompanyKycFinancialProfile ||--o{ CompanyExpectedFlow : "FinancialProfileId"
  CompanyKycFinancialProfile ||--o{ CompanyWealthSource : "FinancialProfileId"
  GoverningBody ||--o{ AuthorityGrant : "BodyId"
  GoverningBody ||--o{ BodyMember : "BodyId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| AuthorityGrant | ApprovedBy | sec.AppUser |
| AuthorityGrant | CeilingCurrencyId | ref.Currency |
| AuthorityGrant | InstitutionId | ins.Institution |
| AuthorityGrant | PartyId | pty.Party |
| AuthorityGrant | PowerTypeId | cat.PowerType |
| AuthorityGrant | SourceDocumentId | doc.Document |
| BodyMember | AppointmentDocumentId | doc.Document |
| BodyMember | PartyId | pty.Party |
| BodyMember | PositionId | cat.Position |
| BodyMember | RepresentedPartyId | pty.Party |
| Company | BaseCurrencyId | ref.Currency |
| Company | CountryId | ref.Country |
| Company | LegalEntityTypeId | cat.LegalEntityType |
| Company | PartyId | pty.Party |
| CompanyBranch | CountryId | ref.Country |
| CompanyDisclosure | SourceDocumentId | doc.Document |
| CompanyExpectedFlow | CurrencyId | ref.Currency |
| CompanyKycFinancialProfile | AccountCurrencyId | ref.Currency |
| CompanyKycFinancialProfile | RevenueBandId | cat.LookupItem |
| CompanyProfile | EmployeeBandId | cat.LookupItem |
| CompanyProfile | HeadquartersCountryId | ref.Country |
| CompanyProfile | SectorId | cat.LookupItem |
| CompanyWealthSource | WealthSourceId | cat.LookupItem |
| Department | HeadUserId | sec.AppUser |
| GoverningBody | SourceDocumentId | doc.Document |
| Shareholding | CurrencyId | ref.Currency |
| Shareholding | HolderPartyId | pty.Party |
| Shareholding | SourceDocumentId | doc.Document |

## مخطط `pty` (11 جدولًا)

```mermaid
erDiagram
  CustomFieldDefinition ||--o{ PartyCustomField : "DefinitionId"
  KycProfile ||--o{ KycProfileItem : "ProfileId"
  KycProfileItem ||--o{ KycProfileItemLegalForm : "KycProfileItemId"
  Party ||--o{ IdentityDocument : "PartyId"
  Party ||--o{ PartyCompliance : "PartyId"
  Party ||--o{ PartyCustomField : "PartyId"
  Party ||--o{ TaxIdentity : "PartyId"
  Address { int _ }
  ContactMethod { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Address | CountryId | ref.Country |
| CustomFieldDefinition | InstitutionId | ins.Institution |
| IdentityDocument | EncKeyId | sec.TenantKey |
| IdentityDocument | HashKeyId | sec.TenantKey |
| IdentityDocument | IssuingCountryId | ref.Country |
| IdentityDocument | VerifiedBy | sec.AppUser |
| KycProfile | InstitutionId | ins.Institution |
| KycProfile | SourceDocumentId | doc.Document |
| KycProfileItemLegalForm | LegalEntityTypeId | cat.LegalEntityType |
| Party | BirthCountryId | ref.Country |
| Party | CountryId | ref.Country |
| Party | EducationLevelId | cat.LookupItem |
| Party | LinkedCompanyId | org.Company |
| PartyCompliance | CompanyId | org.Company |
| PartyCompliance | SourceDocumentId | doc.Document |
| PartyCustomField | CurrencyId | ref.Currency |
| PartyCustomField | EncKeyId | sec.TenantKey |
| TaxIdentity | CountryId | ref.Country |
| TaxIdentity | CrsClassificationId | cat.LookupItem |
| TaxIdentity | FatcaClassificationId | cat.LookupItem |
| TaxIdentity | SourceDocumentId | doc.Document |

## مخطط `ref` (4 جدولًا)

```mermaid
erDiagram
  Country { int _ }
  Currency { int _ }
  Incoterm { int _ }
  UcpArticle { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| UcpArticle | VerifiedBy | plat.PlatformOperator |

## مخطط `cat` (26 جدولًا)

```mermaid
erDiagram
  BaseRate ||--o{ BaseRateAlias : "BaseRateId"
  BaseRate ||--o{ BaseRateValue : "BaseRateId"
  CollateralType ||--o{ CollateralTypeAttribute : "CollateralTypeId"
  FeeType ||--o{ ProductFeeType : "FeeTypeId"
  FinancingType ||--o{ ProductFinancingType : "FinancingTypeId"
  LimitType ||--o{ LimitTypeProduct : "LimitTypeId"
  LookupList ||--o{ LookupItem : "LookupListId"
  OperationType ||--o{ OperationTypePowerType : "OperationTypeId"
  PowerType ||--o{ OperationTypePowerType : "PowerTypeId"
  Product ||--o{ LimitTypeProduct : "ProductId"
  Product ||--o{ ProductFeeType : "ProductId"
  Product ||--o{ ProductFinancingType : "ProductId"
  ProductCategory ||--o{ Product : "ProductCategoryId"
  TenantCurrency { int _ }
  InstitutionType { int _ }
  AccountType { int _ }
  LegalEntityType { int _ }
  DocumentType { int _ }
  Position { int _ }
  FacilityType { int _ }
  ObligationType { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| BaseRate | CurrencyId | ref.Currency |
| BaseRate | InstitutionId | ins.Institution |
| BaseRateAlias | InstitutionId | ins.Institution |
| BaseRateValue | EnteredBy | sec.AppUser |
| LegalEntityType | CountryId | ref.Country |
| TenantCurrency | CurrencyId | ref.Currency |

## مخطط `ins` (6 جدولًا)

```mermaid
erDiagram
  Contact ||--o{ RelationshipContact : "ContactId"
  Contact ||--o{ RelationshipProduct : "DefaultContactId"
  Institution ||--o{ Contact : "InstitutionId"
  Institution ||--o{ InstitutionUnit : "InstitutionId"
  Institution ||--o{ Relationship : "InstitutionId"
  Institution ||--o{ RelationshipContact : "InstitutionId"
  Institution ||--o{ RelationshipProduct : "InstitutionId"
  InstitutionUnit ||--o{ Contact : "UnitId"
  Relationship ||--o{ RelationshipContact : "RelationshipId"
  Relationship ||--o{ RelationshipProduct : "RelationshipId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Contact | PartyId | pty.Party |
| Institution | CountryId | ref.Country |
| Institution | InstitutionTypeId | cat.InstitutionType |
| Institution | PartyId | pty.Party |
| InstitutionUnit | UnitTypeId | cat.LookupItem |
| Relationship | CompanyId | org.Company |
| RelationshipContact | RoleId | cat.LookupItem |
| RelationshipProduct | ProductId | cat.Product |

## مخطط `acc` (6 جدولًا)

```mermaid
erDiagram
  BankAccount ||--o{ FacilityAccount : "BankAccountId"
  BankAccount ||--o{ SignatoryAuthority : "BankAccountId"
  Signatory ||--o{ SignatoryAuthority : "SignatoryId"
  SignatoryAuthority ||--o{ AuthorityConflict : "SignatoryAuthorityId"
  SignatoryAuthority ||--o{ SignatoryAuthorityJointClass : "SignatoryAuthorityId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| AuthorityConflict | ReviewedBy | sec.AppUser |
| BankAccount | AccountTypeId | cat.AccountType |
| BankAccount | BranchUnitId | ins.InstitutionUnit |
| BankAccount | CompanyId | org.Company |
| BankAccount | CurrencyId | ref.Currency |
| BankAccount | EncKeyId | sec.TenantKey |
| BankAccount | HashKeyId | sec.TenantKey |
| BankAccount | InstitutionId | ins.Institution |
| BankAccount | RelationshipId | ins.Relationship |
| FacilityAccount | CurrencyId | ref.Currency |
| FacilityAccount | FacilityId | fac.Facility |
| FacilityAccount | PurposeId | cat.LookupItem |
| Signatory | AuthorisationBasisId | cat.LookupItem |
| Signatory | AuthorizationDocumentId | doc.Document |
| Signatory | CashWithdrawalCurrencyId | ref.Currency |
| Signatory | PartyId | pty.Party |
| Signatory | PositionId | cat.Position |
| Signatory | RelationshipId | ins.Relationship |
| Signatory | SignatureClassId | cat.LookupItem |
| Signatory | SpecimenDocumentId | doc.Document |
| SignatoryAuthority | CurrencyId | ref.Currency |
| SignatoryAuthority | OperationTypeId | cat.OperationType |
| SignatoryAuthority | RelationshipId | ins.Relationship |
| SignatoryAuthority | SourceDocumentId | doc.Document |
| SignatoryAuthorityJointClass | SignatureClassId | cat.LookupItem |

## مخطط `fac` (13 جدولًا)

```mermaid
erDiagram
  Facility ||--o{ FacilityDocument : "FacilityId"
  Facility ||--o{ FacilityLender : "FacilityId"
  Facility ||--o{ FacilityRevision : "FacilityId"
  Facility ||--o{ Limit : "FacilityId"
  Facility ||--o{ LimitCompanyRule : "FacilityId"
  Facility ||--o{ LimitMovement : "FacilityId"
  Facility ||--o{ LimitProductLine : "FacilityId"
  Facility ||--o{ LimitReservation : "FacilityId"
  Facility ||--o{ OutstandingSnapshot : "FacilityId"
  Facility ||--o{ ProductLineTerm : "FacilityId"
  Facility ||--o{ Utilization : "FacilityId"
  Facility ||--o{ ValueConflict : "FacilityId"
  Limit ||--o{ LimitCompanyRule : "LimitId"
  Limit ||--o{ LimitProductLine : "LimitId"
  Limit ||--o{ LimitReservation : "LimitId"
  Limit ||--o{ OutstandingSnapshot : "LimitId"
  Limit ||--o{ Utilization : "LimitId"
  LimitProductLine ||--o{ LimitReservation : "LimitProductLineId"
  LimitProductLine ||--o{ ProductLineTerm : "LimitProductLineId"
  LimitProductLine ||--o{ Utilization : "LimitProductLineId"
  LimitReservation ||--o{ LimitMovement : "LimitReservationId"
  Utilization ||--o{ LimitMovement : "UtilizationId"
  Utilization ||--o{ LimitReservation : "ConvertedUtilizationId"
  ValueConflict ||--o{ Limit : "ConflictId"
  ValueConflict ||--o{ LimitCompanyRule : "ConflictId"
  ValueConflict ||--o{ LimitProductLine : "ConflictId"
  ValueConflict ||--o{ OutstandingSnapshot : "ConflictId"
  ValueConflict ||--o{ ProductLineTerm : "ConflictId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Facility | BorrowerCompanyId | org.Company |
| Facility | CurrencyId | ref.Currency |
| Facility | FacilityTypeId | cat.FacilityType |
| FacilityDocument | DocumentId | doc.Document |
| FacilityLender | ContactId | ins.Contact |
| FacilityLender | InstitutionId | ins.Institution |
| FacilityRevision | ApprovedBy | sec.AppUser |
| FacilityRevision | SubmittedBy | sec.AppUser |
| Limit | LimitTypeId | cat.LimitType |
| Limit | SourceDocumentId | doc.Document |
| Limit | VerifiedBy | sec.AppUser |
| LimitCompanyRule | CompanyId | org.Company |
| LimitCompanyRule | SourceDocumentId | doc.Document |
| LimitCompanyRule | VerifiedBy | sec.AppUser |
| LimitMovement | ActorUserId | sec.AppUser |
| LimitMovement | CurrencyId | ref.Currency |
| LimitProductLine | ProductId | cat.Product |
| LimitProductLine | SourceDocumentId | doc.Document |
| LimitProductLine | VerifiedBy | sec.AppUser |
| LimitReservation | CompanyId | org.Company |
| LimitReservation | CurrencyId | ref.Currency |
| LimitReservation | RequestId | wfl.Request |
| OutstandingSnapshot | CurrencyId | ref.Currency |
| OutstandingSnapshot | ProductId | cat.Product |
| OutstandingSnapshot | SourceDocumentId | doc.Document |
| OutstandingSnapshot | VerifiedBy | sec.AppUser |
| ProductLineTerm | SourceDocumentId | doc.Document |
| ProductLineTerm | VerifiedBy | sec.AppUser |
| Utilization | CompanyId | org.Company |
| Utilization | CurrencyId | ref.Currency |
| ValueConflict | CandidateASourceDocumentId | doc.Document |
| ValueConflict | CandidateBSourceDocumentId | doc.Document |
| ValueConflict | ResolvedBy | sec.AppUser |

## مخطط `prc` (5 جدولًا)

```mermaid
erDiagram
  PricingRule ||--o{ PricingTier : "PricingRuleId"
  TariffItem ||--o{ PricingRule : "TariffItemId"
  TariffItem ||--o{ TariffTier : "TariffItemId"
  TariffSchedule ||--o{ TariffItem : "ScheduleId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| PricingRule | BaseRateId | cat.BaseRate |
| PricingRule | ConflictId | fac.ValueConflict |
| PricingRule | CurrencyId | ref.Currency |
| PricingRule | FacilityId | fac.Facility |
| PricingRule | FeeTypeId | cat.FeeType |
| PricingRule | FinancingTypeId | cat.FinancingType |
| PricingRule | ScopeCompanyId | org.Company |
| PricingRule | ScopeLimitId | fac.Limit |
| PricingRule | ScopeLimitProductLineId | fac.LimitProductLine |
| PricingRule | ScopeProductId | cat.Product |
| PricingRule | SourceDocumentId | doc.Document |
| PricingRule | VerifiedBy | sec.AppUser |
| PricingTier | FacilityId | fac.Facility |
| TariffItem | ConflictId | fac.ValueConflict |
| TariffItem | CurrencyId | ref.Currency |
| TariffItem | FeeTypeId | cat.FeeType |
| TariffItem | ProductId | cat.Product |
| TariffItem | SourceDocumentId | doc.Document |
| TariffItem | VerifiedBy | sec.AppUser |
| TariffSchedule | ApprovedBy | sec.AppUser |
| TariffSchedule | FacilityId | fac.Facility |
| TariffSchedule | InstitutionId | ins.Institution |
| TariffSchedule | SourceDocumentId | doc.Document |

## مخطط `cmp` (2 جدولًا)

```mermaid
erDiagram
  TermType ||--o{ TermValue : "TermTypeId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| TermValue | CompanyId | org.Company |
| TermValue | ConflictId | fac.ValueConflict |
| TermValue | CurrencyId | ref.Currency |
| TermValue | FacilityId | fac.Facility |
| TermValue | LimitId | fac.Limit |
| TermValue | LimitProductLineId | fac.LimitProductLine |
| TermValue | ProductId | cat.Product |
| TermValue | SourceDocumentId | doc.Document |
| TermValue | VerifiedBy | sec.AppUser |

## مخطط `col` (7 جدولًا)

```mermaid
erDiagram
  Collateral ||--o{ CollateralLink : "CollateralId"
  Collateral ||--o{ Guarantee : "CollateralId"
  Collateral ||--o{ InsurancePolicyAssignment : "CollateralId"
  Collateral ||--o{ PromissoryNote : "CollateralId"
  Collateral ||--o{ ValuationSchedule : "CollateralId"
  PromissoryNote ||--o{ PromissoryNoteSigner : "PromissoryNoteId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Collateral | ApprovedBy | sec.AppUser |
| Collateral | CollateralTypeId | cat.CollateralType |
| Collateral | ConflictId | fac.ValueConflict |
| Collateral | OwnerPartyId | pty.Party |
| Collateral | ReleaseDocumentId | doc.Document |
| Collateral | SourceDocumentId | doc.Document |
| Collateral | VerifiedBy | sec.AppUser |
| CollateralLink | FacilityId | fac.Facility |
| CollateralLink | LimitId | fac.Limit |
| Guarantee | CurrencyId | ref.Currency |
| Guarantee | DeedDocumentId | doc.Document |
| Guarantee | GuarantorIdentityDocumentId | pty.IdentityDocument |
| Guarantee | GuarantorPartyId | pty.Party |
| InsurancePolicyAssignment | AssignedToInstitutionId | ins.Institution |
| InsurancePolicyAssignment | CurrencyId | ref.Currency |
| InsurancePolicyAssignment | PolicyDocumentId | doc.Document |
| PromissoryNote | CurrencyId | ref.Currency |
| PromissoryNote | NoteDocumentId | doc.Document |
| PromissoryNoteSigner | PartyId | pty.Party |
| ValuationSchedule | CurrencyId | ref.Currency |

## مخطط `obl` (8 جدولًا)

```mermaid
erDiagram
  Covenant ||--o{ CovenantAccount : "CovenantId"
  Covenant ||--o{ CovenantTest : "CovenantId"
  CovenantTest ||--o{ ObligationBreach : "CovenantTestId"
  Obligation ||--o{ Covenant : "ObligationId"
  Obligation ||--o{ ObligationBreach : "ObligationId"
  Obligation ||--o{ ObligationCompany : "ObligationId"
  Obligation ||--o{ ReportingObligation : "ObligationId"
  ReportingInstance ||--o{ ObligationBreach : "ReportingInstanceId"
  ReportingObligation ||--o{ ReportingInstance : "ReportingObligationId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Covenant | CurrencyId | ref.Currency |
| Covenant | FormulaId | fin.MeasureFormula |
| Covenant | TestedCompanyId | org.Company |
| CovenantAccount | BankAccountId | acc.BankAccount |
| CovenantTest | EvaluatedBy | sec.AppUser |
| CovenantTest | EvidenceDocumentId | doc.Document |
| CovenantTest | ReviewedBy | sec.AppUser |
| Obligation | ConflictId | fac.ValueConflict |
| Obligation | FacilityId | fac.Facility |
| Obligation | ObligationTypeId | cat.ObligationType |
| Obligation | ParamCurrencyId | ref.Currency |
| Obligation | ScopeLimitId | fac.Limit |
| Obligation | ScopeProductLineId | fac.LimitProductLine |
| Obligation | SourceDocumentId | doc.Document |
| Obligation | VerifiedBy | sec.AppUser |
| ObligationBreach | WaiverBankContactId | ins.Contact |
| ObligationBreach | WaiverDocumentId | doc.Document |
| ObligationCompany | CompanyId | org.Company |
| ReportingInstance | CurrencyId | ref.Currency |
| ReportingInstance | EvidenceDocumentId | doc.Document |
| ReportingInstance | SubmissionChannelUsedId | cat.LookupItem |
| ReportingObligation | SubmissionChannelId | cat.LookupItem |

## مخطط `fin` (7 جدولًا)

```mermaid
erDiagram
  FinancialStatement ||--o{ StatementLine : "StatementId"
  LineCatalogItem ||--o{ LineCatalogItemAlias : "LineCatalogItemId"
  LineCatalogItem ||--o{ StatementLine : "LineCatalogItemId"
  AccountMonthlyStat { int _ }
  BankFlowEntry { int _ }
  MeasureFormula { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| AccountMonthlyStat | BankAccountId | acc.BankAccount |
| AccountMonthlyStat | DocumentId | doc.Document |
| BankFlowEntry | CompanyId | org.Company |
| BankFlowEntry | CurrencyId | ref.Currency |
| BankFlowEntry | DocumentId | doc.Document |
| BankFlowEntry | FacilityId | fac.Facility |
| BankFlowEntry | FlowKindId | cat.LookupItem |
| BankFlowEntry | InstitutionId | ins.Institution |
| FinancialStatement | ApprovedBy | sec.AppUser |
| FinancialStatement | CompanyId | org.Company |
| FinancialStatement | CurrencyId | ref.Currency |
| FinancialStatement | PreparedBy | sec.AppUser |
| FinancialStatement | SourceDocumentId | doc.Document |
| MeasureFormula | ApprovedBy | sec.AppUser |
| MeasureFormula | ConflictId | fac.ValueConflict |
| MeasureFormula | FacilityId | fac.Facility |
| MeasureFormula | SourceDocumentId | doc.Document |
| MeasureFormula | VerifiedBy | sec.AppUser |

## مخطط `wfl` (19 جدولًا)

```mermaid
erDiagram
  ExternalPhase ||--o{ Request : "ExternalPhaseId"
  ExternalPhase ||--o{ WorkflowStage : "ExternalPhaseId"
  Request ||--o{ HookExecution : "RequestId"
  Request ||--o{ RequestAction : "RequestId"
  Request ||--o{ RequestApproval : "RequestId"
  Request ||--o{ RequestAttachment : "RequestId"
  Request ||--o{ RequestComment : "RequestId"
  Request ||--o{ RequestExternalRef : "RequestId"
  Request ||--o{ RequestStageInstance : "RequestId"
  RequestStageInstance ||--o{ HookExecution : "StageInstanceId"
  RequestStageInstance ||--o{ Request : "CurrentStageInstanceId"
  RequestStageInstance ||--o{ RequestAction : "StageInstanceId"
  RequestStageInstance ||--o{ RequestApproval : "StageInstanceId"
  RequestStageInstance ||--o{ RequestAttachment : "StageInstanceId"
  RequestStageInstance ||--o{ RequestComment : "StageInstanceId"
  RequestType ||--o{ Request : "RequestTypeId"
  RequestType ||--o{ RequestTypeAudience : "RequestTypeId"
  RequestType ||--o{ UserDelegation : "RequestTypeId"
  RequestType ||--o{ WorkflowTemplate : "RequestTypeId"
  UserDelegation ||--o{ RequestApproval : "DelegationId"
  WorkflowStage ||--o{ Request : "CurrentStageId"
  WorkflowStage ||--o{ RequestStageInstance : "ResumeStageId"
  WorkflowStage ||--o{ RequestStageInstance : "StageId"
  WorkflowStage ||--o{ StageApprover : "StageId"
  WorkflowStage ||--o{ WorkflowStageHook : "StageId"
  WorkflowStage ||--o{ WorkflowTransition : "FromStageId"
  WorkflowStage ||--o{ WorkflowTransition : "ResumeStageId"
  WorkflowStage ||--o{ WorkflowTransition : "ToStageId"
  WorkflowTemplate ||--o{ Request : "TemplateId"
  WorkflowTemplate ||--o{ TemplateAttachmentRule : "TemplateId"
  WorkflowTemplate ||--o{ TemplateField : "TemplateId"
  WorkflowTemplate ||--o{ WorkflowStage : "TemplateId"
  WorkflowTemplate ||--o{ WorkflowTransition : "TemplateId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Request | AssigneeUserId | sec.AppUser |
| Request | ClosedByUserId | sec.AppUser |
| Request | CompanyId | org.Company |
| Request | CreatedByUserId | sec.AppUser |
| Request | CurrencyId | ref.Currency |
| Request | DepartmentId | org.Department |
| Request | FacilityId | fac.Facility |
| Request | InstitutionId | ins.Institution |
| Request | LcId | lc.LetterOfCredit |
| Request | LimitId | fac.Limit |
| Request | LimitProductLineId | fac.LimitProductLine |
| Request | ProductId | cat.Product |
| Request | RequesterUserId | sec.AppUser |
| Request | ReservationId | fac.LimitReservation |
| Request | SubmittedByUserId | sec.AppUser |
| RequestAction | ActorUserId | sec.AppUser |
| RequestAction | OnBehalfOfUserId | sec.AppUser |
| RequestApproval | ActedByUserId | sec.AppUser |
| RequestApproval | AssignedRoleId | sec.Role |
| RequestApproval | AssignedUserId | sec.AppUser |
| RequestApproval | OnBehalfOfUserId | sec.AppUser |
| RequestAttachment | DocumentId | doc.Document |
| RequestComment | AuthorUserId | sec.AppUser |
| RequestComment | RetractedBy | sec.AppUser |
| RequestExternalRef | EnteredBy | sec.AppUser |
| RequestStageInstance | AssigneeUserId | sec.AppUser |
| RequestTypeAudience | DepartmentId | org.Department |
| RequestTypeAudience | RoleId | sec.Role |
| RequestTypeAudience | UserId | sec.AppUser |
| StageApprover | DepartmentId | org.Department |
| StageApprover | FallbackRoleId | sec.Role |
| StageApprover | RoleId | sec.Role |
| StageApprover | UserId | sec.AppUser |
| TemplateAttachmentRule | DocumentTypeId | cat.DocumentType |
| UserDelegation | FromUserId | sec.AppUser |
| UserDelegation | RevokedBy | sec.AppUser |
| UserDelegation | ToUserId | sec.AppUser |
| WorkflowStage | AssigneeDepartmentId | org.Department |
| WorkflowStage | AssigneeRoleId | sec.Role |
| WorkflowStage | AssigneeUserId | sec.AppUser |
| WorkflowStage | FallbackRoleId | sec.Role |
| WorkflowStage | PoolPermissionId | sec.Permission |
| WorkflowTemplate | PublishedBy | sec.AppUser |

## مخطط `ntf` (7 جدولًا)

```mermaid
erDiagram
  DigestBatch ||--o{ NotificationDelivery : "DigestBatchId"
  Notification ||--o{ NotificationDelivery : "NotificationId"
  NotificationEventType ||--o{ Notification : "EventTypeId"
  NotificationEventType ||--o{ NotificationRule : "EventTypeId"
  NotificationEventType ||--o{ NotificationTemplate : "EventTypeId"
  NotificationPreference { int _ }
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| DigestBatch | UserId | sec.AppUser |
| Notification | CompanyId | org.Company |
| Notification | UserId | sec.AppUser |
| NotificationPreference | UserId | sec.AppUser |
| NotificationRule | PermissionId | sec.Permission |
| NotificationRule | RoleId | sec.Role |
| NotificationRule | UserId | sec.AppUser |

## مخطط `lc` (21 جدولًا)

```mermaid
erDiagram
  Counterparty ||--o{ LcTerms : "ApplicantCounterpartyId"
  Counterparty ||--o{ LcTerms : "BeneficiaryCounterpartyId"
  Counterparty ||--o{ LetterOfCredit : "CounterpartyId"
  Counterparty ||--o{ ProformaInvoice : "CustomerId"
  LcDocumentClause ||--o{ LcDocumentClauseUcpRef : "LcDocumentClauseId"
  LcDocumentClause ||--o{ LcTermsDocument : "ClauseId"
  LcDrawing ||--o{ LcDiscrepancy : "DrawingId"
  LcDrawing ||--o{ LcDrawingAllocation : "DrawingId"
  LcFieldDefinition ||--o{ LcFieldUcpRef : "LcFieldDefinitionId"
  LcFormTemplate ||--o{ LcFormFieldMap : "TemplateId"
  LcSalesOrder ||--o{ LcDrawingAllocation : "SalesOrderId"
  LcTerms ||--o{ LcAmendment : "TermsId"
  LcTerms ||--o{ LcChargesMatrix : "LcTermsId"
  LcTerms ||--o{ LcTermsComparison : "BaselineTermsId"
  LcTerms ||--o{ LcTermsComparison : "ReceivedTermsId"
  LcTerms ||--o{ LcTermsDocument : "LcTermsId"
  LcTerms ||--o{ LetterOfCredit : "CurrentTermsId"
  LcTerms ||--o{ ProformaInvoice : "TermsId"
  LcTermsComparison ||--o{ LcTermsComparisonLine : "ComparisonId"
  LetterOfCredit ||--o{ LcAmendment : "LcId"
  LetterOfCredit ||--o{ LcDiscrepancy : "LcId"
  LetterOfCredit ||--o{ LcDrawing : "LcId"
  LetterOfCredit ||--o{ LcDrawingAllocation : "LcId"
  LetterOfCredit ||--o{ LcExternalRef : "LcId"
  LetterOfCredit ||--o{ LcSalesOrder : "LcId"
  ProformaInvoice ||--o{ LetterOfCredit : "ProformaId"
  ProformaInvoice ||--o{ ProformaLine : "ProformaId"
```

| الجدول | العمود | يشير إلى |
|---|---|---|
| Counterparty | CountryId | ref.Country |
| Counterparty | PartyId | pty.Party |
| LcAmendment | AppliedBy | sec.AppUser |
| LcAmendment | CurrencyId | ref.Currency |
| LcAmendment | RequestId | wfl.Request |
| LcDiscrepancy | DecidedBy | sec.AppUser |
| LcDocumentClause | InstitutionId | ins.Institution |
| LcDocumentClauseUcpRef | UcpArticleId | ref.UcpArticle |
| LcDrawing | CurrencyId | ref.Currency |
| LcDrawing | RequestId | wfl.Request |
| LcDrawing | SettlementAccountId | acc.BankAccount |
| LcDrawingAllocation | CurrencyId | ref.Currency |
| LcFieldUcpRef | UcpArticleId | ref.UcpArticle |
| LcFormTemplate | AnnexDocumentId | doc.Document |
| LcFormTemplate | CompanyId | org.Company |
| LcFormTemplate | InstitutionId | ins.Institution |
| LcFormTemplate | LetterheadDocumentId | doc.Document |
| LcFormTemplate | ProductId | cat.Product |
| LcFormTemplate | SourceDocumentId | doc.Document |
| LcSalesOrder | CurrencyId | ref.Currency |
| LcSalesOrder | RequestId | wfl.Request |
| LcTerms | ApplicantCompanyId | org.Company |
| LcTerms | BeneficiaryCompanyId | org.Company |
| LcTerms | ChargesAccountId | acc.BankAccount |
| LcTerms | CurrencyId | ref.Currency |
| LcTerms | EncKeyId | sec.TenantKey |
| LcTerms | FacilityAccountId | acc.BankAccount |
| LcTerms | HashKeyId | sec.TenantKey |
| LcTerms | IncotermId | ref.Incoterm |
| LcTerms | LockedBy | sec.AppUser |
| LcTerms | MarginSettlementAccountId | acc.BankAccount |
| LcTerms | PrevLcCurrencyId | ref.Currency |
| LcTermsComparison | RunBy | sec.AppUser |
| LetterOfCredit | CompanyId | org.Company |
| LetterOfCredit | CurrencyId | ref.Currency |
| LetterOfCredit | FacilityId | fac.Facility |
| LetterOfCredit | InstitutionId | ins.Institution |
| LetterOfCredit | LimitId | fac.Limit |
| LetterOfCredit | LimitProductLineId | fac.LimitProductLine |
| LetterOfCredit | ProductId | cat.Product |
| LetterOfCredit | RelationshipId | ins.Relationship |
| LetterOfCredit | RequestId | wfl.Request |
| LetterOfCredit | UtilizationId | fac.Utilization |
| ProformaInvoice | CompanyId | org.Company |
| ProformaInvoice | CurrencyId | ref.Currency |
| ProformaInvoice | DocumentId | doc.Document |
| ProformaInvoice | ProceedsAccountId | acc.BankAccount |
| ProformaInvoice | RequestId | wfl.Request |
| ProformaLine | CurrencyId | ref.Currency |
