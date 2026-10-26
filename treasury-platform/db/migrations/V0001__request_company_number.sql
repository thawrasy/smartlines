-- V0001: the company number of a request (docs/31 row 72). The table as db/model/15-workflow-notifications.model
-- builds it (db/generated/tsql 001 to 003); its row filter and grant come with the repeatable scripts that migrate.sh
-- runs after this one (004, 007). No data moves: a request gets its company number when the bank issues it.
-- The company number of a request, given once when the bank issues it (the workflow's successful end): the company's code, the department code of the request type and a gap-free sequence of the company and department, as SA05-IMP-00001 (docs/31 row 72)
CREATE TABLE [wfl].[RequestCompanyNumber] (
    [TenantId] INT NOT NULL,
    [RequestCompanyNumberId] BIGINT IDENTITY(1,1) NOT NULL,
    [RequestId] BIGINT NOT NULL,
    [CompanyId] BIGINT NOT NULL,
    [NumberCode] VARCHAR(6) NOT NULL,
    [CompanyRequestNo] NVARCHAR(60) NOT NULL,
    [NumberIssueId] BIGINT NOT NULL,
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_RequestCompanyNumber_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_RequestCompanyNumber] PRIMARY KEY CLUSTERED ([RequestCompanyNumberId]),
    CONSTRAINT [UQ_RequestCompanyNumber_Tenant] UNIQUE ([TenantId], [RequestCompanyNumberId]),
    CONSTRAINT [UQ_RequestCompanyNumber_RequestId] UNIQUE ([TenantId], [RequestId]),
    CONSTRAINT [UQ_RequestCompanyNumber_CompanyRequestNo] UNIQUE ([TenantId], [CompanyRequestNo]),
    CONSTRAINT [UQ_RequestCompanyNumber_NumberIssueId] UNIQUE ([TenantId], [NumberIssueId]),
    CONSTRAINT [CK_RequestCompanyNumber_1] CHECK (NumberCode COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%' AND LEN(NumberCode) >= 2)
);
GO
ALTER TABLE [wfl].[RequestCompanyNumber] ADD CONSTRAINT [FK_RequestCompanyNumber_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [wfl].[RequestCompanyNumber] ADD CONSTRAINT [FK_RequestCompanyNumber_RequestId] FOREIGN KEY ([TenantId], [RequestId]) REFERENCES [wfl].[Request] ([TenantId], [RequestId]);
ALTER TABLE [wfl].[RequestCompanyNumber] ADD CONSTRAINT [FK_RequestCompanyNumber_CompanyId] FOREIGN KEY ([TenantId], [CompanyId]) REFERENCES [org].[Company] ([TenantId], [CompanyId]);
ALTER TABLE [wfl].[RequestCompanyNumber] ADD CONSTRAINT [FK_RequestCompanyNumber_NumberIssueId] FOREIGN KEY ([TenantId], [NumberIssueId]) REFERENCES [cfg].[NumberIssue] ([TenantId], [NumberIssueId]);
GO
CREATE NONCLUSTERED INDEX [IX_RequestCompanyNumber_CompanyId] ON [wfl].[RequestCompanyNumber] ([TenantId], [CompanyId]);
