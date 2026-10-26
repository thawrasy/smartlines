-- V0002: the facility file of a company with a bank (docs/31 row 75): fac.FacilityFile, fac.FacilityFileFacility and
-- fac.FacilityFileEntry as db/model/13-facilities-pricing-terms.model builds them (db/generated/tsql 001 to 003; their row
-- filters and grants come with the repeatable scripts), and the company's code in a facility reference up to six
-- characters, a letter first, such as SA05 (org.Company.RefCode, db/model/11-organization-party.model). No data moves.
-- The facility file of a company with a bank (docs/31 row 75): COMPANY-BANK-NNNN, such as SA05-ANB-0001; it holds every facility of the relation over its life (each contract by its class, CAP-SA05-ANB-0001, and its renewals), and the correspondence and renewal requests with the bank
CREATE TABLE [fac].[FacilityFile] (
    [TenantId] INT NOT NULL,
    [FacilityFileId] BIGINT IDENTITY(1,1) NOT NULL,
    [FileRef] VARCHAR(20) NOT NULL,
    [CompanyId] BIGINT NOT NULL,
    [InstitutionId] BIGINT NOT NULL,
    [Serial] INT NOT NULL,
    [Status] VARCHAR(10) NOT NULL CONSTRAINT [DF_FacilityFile_Status] DEFAULT 'OPEN',
    [OpenedOn] DATE NOT NULL,
    [Notes] NVARCHAR(1000) NULL,
    [PublicId] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_FacilityFile_PublicId] DEFAULT NEWSEQUENTIALID(),
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_FacilityFile_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_FacilityFile] PRIMARY KEY CLUSTERED ([FacilityFileId]),
    CONSTRAINT [UQ_FacilityFile_Tenant] UNIQUE ([TenantId], [FacilityFileId]),
    CONSTRAINT [UQ_FacilityFile_PublicId] UNIQUE ([PublicId]),
    CONSTRAINT [UQ_FacilityFile_FileRef] UNIQUE ([TenantId], [FileRef]),
    CONSTRAINT [UQ_FacilityFile_CompanyId_InstitutionId_Serial] UNIQUE ([TenantId], [CompanyId], [InstitutionId], [Serial]),
    CONSTRAINT [CK_FacilityFile_1] CHECK (Serial >= 1 AND Serial <= 9999),
    CONSTRAINT [CK_FacilityFile_2] CHECK (FileRef COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9-]%'),
    CONSTRAINT [CK_FacilityFile_Status] CHECK ([Status] IS NULL OR [Status] IN ('OPEN', 'CLOSED'))
);
GO
-- A facility (a contract) in its facility file: its class and its order among the contracts of that class in the file; the reference is CLASS-FILE (CAP-SA05-ANB-0001) for the first, CLASS-FILE-NN for each renewal (CAP-SA05-ANB-0001-02)
CREATE TABLE [fac].[FacilityFileFacility] (
    [TenantId] INT NOT NULL,
    [FacilityFileFacilityId] BIGINT IDENTITY(1,1) NOT NULL,
    [FacilityFileId] BIGINT NOT NULL,
    [FacilityId] BIGINT NOT NULL,
    [ClassCode] VARCHAR(3) NOT NULL,
    [SeqInClass] INT NOT NULL,
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_FacilityFileFacility_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_FacilityFileFacility] PRIMARY KEY CLUSTERED ([FacilityFileFacilityId]),
    CONSTRAINT [UQ_FacilityFileFacility_Tenant] UNIQUE ([TenantId], [FacilityFileFacilityId]),
    CONSTRAINT [UQ_FacilityFileFacility_FacilityId] UNIQUE ([TenantId], [FacilityId]),
    CONSTRAINT [UQ_FacilityFileFacility_FacilityFileId_ClassCode_SeqInClass] UNIQUE ([TenantId], [FacilityFileId], [ClassCode], [SeqInClass]),
    CONSTRAINT [CK_FacilityFileFacility_1] CHECK (SeqInClass >= 1 AND SeqInClass <= 99),
    CONSTRAINT [CK_FacilityFileFacility_2] CHECK (ClassCode COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z][A-Z]')
);
GO
-- The correspondence of a facility file: letters, e-mails, offers and renewal requests to and from the bank, with their date, direction and document (docs/31 row 75)
CREATE TABLE [fac].[FacilityFileEntry] (
    [TenantId] INT NOT NULL,
    [FacilityFileEntryId] BIGINT IDENTITY(1,1) NOT NULL,
    [FacilityFileId] BIGINT NOT NULL,
    [EntryDate] DATE NOT NULL,
    [Direction] VARCHAR(10) NOT NULL,
    [Kind] VARCHAR(15) NOT NULL,
    [Subject] NVARCHAR(300) NOT NULL,
    [BankRef] NVARCHAR(80) NULL,
    [DocumentId] BIGINT NULL,
    [FacilityId] BIGINT NULL,
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_FacilityFileEntry_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_FacilityFileEntry] PRIMARY KEY CLUSTERED ([FacilityFileEntryId]),
    CONSTRAINT [UQ_FacilityFileEntry_Tenant] UNIQUE ([TenantId], [FacilityFileEntryId]),
    CONSTRAINT [CK_FacilityFileEntry_Direction] CHECK ([Direction] IS NULL OR [Direction] IN ('INCOMING', 'OUTGOING')),
    CONSTRAINT [CK_FacilityFileEntry_Kind] CHECK ([Kind] IS NULL OR [Kind] IN ('LETTER', 'EMAIL', 'OFFER', 'RENEWAL_REQUEST', 'OTHER'))
);
GO
ALTER TABLE [fac].[FacilityFile] ADD CONSTRAINT [FK_FacilityFile_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [fac].[FacilityFile] ADD CONSTRAINT [FK_FacilityFile_CompanyId] FOREIGN KEY ([TenantId], [CompanyId]) REFERENCES [org].[Company] ([TenantId], [CompanyId]);
ALTER TABLE [fac].[FacilityFile] ADD CONSTRAINT [FK_FacilityFile_InstitutionId] FOREIGN KEY ([TenantId], [InstitutionId]) REFERENCES [ins].[Institution] ([TenantId], [InstitutionId]);
ALTER TABLE [fac].[FacilityFileFacility] ADD CONSTRAINT [FK_FacilityFileFacility_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [fac].[FacilityFileFacility] ADD CONSTRAINT [FK_FacilityFileFacility_FacilityFileId] FOREIGN KEY ([TenantId], [FacilityFileId]) REFERENCES [fac].[FacilityFile] ([TenantId], [FacilityFileId]);
ALTER TABLE [fac].[FacilityFileFacility] ADD CONSTRAINT [FK_FacilityFileFacility_FacilityId] FOREIGN KEY ([TenantId], [FacilityId]) REFERENCES [fac].[Facility] ([TenantId], [FacilityId]);
ALTER TABLE [fac].[FacilityFileEntry] ADD CONSTRAINT [FK_FacilityFileEntry_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [fac].[FacilityFileEntry] ADD CONSTRAINT [FK_FacilityFileEntry_FacilityFileId] FOREIGN KEY ([TenantId], [FacilityFileId]) REFERENCES [fac].[FacilityFile] ([TenantId], [FacilityFileId]);
ALTER TABLE [fac].[FacilityFileEntry] ADD CONSTRAINT [FK_FacilityFileEntry_DocumentId] FOREIGN KEY ([TenantId], [DocumentId]) REFERENCES [doc].[Document] ([TenantId], [DocumentId]);
ALTER TABLE [fac].[FacilityFileEntry] ADD CONSTRAINT [FK_FacilityFileEntry_FacilityId] FOREIGN KEY ([TenantId], [FacilityId]) REFERENCES [fac].[Facility] ([TenantId], [FacilityId]);
GO
CREATE NONCLUSTERED INDEX [IX_FacilityFile_InstitutionId] ON [fac].[FacilityFile] ([TenantId], [InstitutionId]);
CREATE NONCLUSTERED INDEX [IX_FacilityFileEntry_FacilityFileId_EntryDate] ON [fac].[FacilityFileEntry] ([TenantId], [FacilityFileId], [EntryDate]);
CREATE NONCLUSTERED INDEX [IX_FacilityFileEntry_DocumentId] ON [fac].[FacilityFileEntry] ([TenantId], [DocumentId]) WHERE DocumentId IS NOT NULL;
CREATE NONCLUSTERED INDEX [IX_FacilityFileEntry_FacilityId] ON [fac].[FacilityFileEntry] ([TenantId], [FacilityId]) WHERE FacilityId IS NOT NULL;
GO
DROP INDEX [UQ_Company_RefCode] ON [org].[Company];
ALTER TABLE [org].[Company] DROP CONSTRAINT [CK_Company_2];
GO
ALTER TABLE [org].[Company] ALTER COLUMN [RefCode] VARCHAR(6) NULL;
GO
ALTER TABLE [org].[Company] ADD CONSTRAINT [CK_Company_2] CHECK (RefCode IS NULL OR (LEN(RefCode) >= 2 AND RefCode COLLATE Arabic_100_BIN2 LIKE '[A-Z]%' AND RefCode COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%'));
CREATE UNIQUE NONCLUSTERED INDEX [UQ_Company_RefCode] ON [org].[Company] ([TenantId], [RefCode]) WHERE RefCode IS NOT NULL;
