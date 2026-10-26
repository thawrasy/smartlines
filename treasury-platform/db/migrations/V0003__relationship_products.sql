-- V0003: the bank relationship's products with their agreed rates and their volumes (docs/31 row 76):
-- ins.RelationshipProductRate and ins.RelationshipProductVolume as db/model/12-institutions-accounts-catalogs.model builds
-- them (db/generated/tsql 001 to 003; their row filters and grants come with the repeatable scripts), and the product
-- families DEPOSIT, INVESTMENT, DERIVATIVE and WEALTH of cat.Product. No data moves.
-- A rate the company agreed with the bank for a product of the relationship: a charge of the product (PRODUCT_CHARGE list, by the product's nature: mada, Visa and Mastercard, GCC network for POS; transfer within the bank, to other banks, to payroll cards for payroll) as a percent with a minimum and a cap, or a fixed amount, from a date (docs/31 row 76)
CREATE TABLE [ins].[RelationshipProductRate] (
    [TenantId] INT NOT NULL,
    [RelationshipProductRateId] BIGINT IDENTITY(1,1) NOT NULL,
    [RelationshipProductId] BIGINT NOT NULL,
    [ChargeItemId] INT NOT NULL,
    [Basis] VARCHAR(10) NOT NULL,
    [RatePct] DECIMAL(9,4) NULL,
    [FixedAmount] DECIMAL(19,4) NULL,
    [MinAmount] DECIMAL(19,4) NULL,
    [MaxAmount] DECIMAL(19,4) NULL,
    [CurrencyId] INT NOT NULL,
    [ValidFrom] DATE NOT NULL,
    [ValidTo] DATE NULL,
    [Notes] NVARCHAR(500) NULL,
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_RelationshipProductRate_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_RelationshipProductRate] PRIMARY KEY CLUSTERED ([RelationshipProductRateId]),
    CONSTRAINT [UQ_RelationshipProductRate_Tenant] UNIQUE ([TenantId], [RelationshipProductRateId]),
    CONSTRAINT [UQ_RelationshipProductRate_RelationshipProductId_ChargeItemId_ValidFrom] UNIQUE ([TenantId], [RelationshipProductId], [ChargeItemId], [ValidFrom]),
    CONSTRAINT [CK_RelationshipProductRate_1] CHECK ((Basis = 'PERCENT' AND RatePct IS NOT NULL AND RatePct >= 0 AND RatePct <= 100) OR (Basis = 'FIXED' AND FixedAmount IS NOT NULL AND FixedAmount >= 0)),
    CONSTRAINT [CK_RelationshipProductRate_2] CHECK (MinAmount IS NULL OR MaxAmount IS NULL OR MaxAmount >= MinAmount),
    CONSTRAINT [CK_RelationshipProductRate_3] CHECK (ValidTo IS NULL OR ValidTo >= ValidFrom),
    CONSTRAINT [CK_RelationshipProductRate_Basis] CHECK ([Basis] IS NULL OR [Basis] IN ('PERCENT', 'FIXED'))
);
GO
-- The business of a product of the relationship over a period, entered by the company: the volume and the number of transactions, the commissions and charges the bank took, the bank's profit or interest, the company's return, and the balance at the end (deposits, funds, portfolios); the cross-sale view of the bank sums it (docs/31 row 76)
CREATE TABLE [ins].[RelationshipProductVolume] (
    [TenantId] INT NOT NULL,
    [RelationshipProductVolumeId] BIGINT IDENTITY(1,1) NOT NULL,
    [RelationshipProductId] BIGINT NOT NULL,
    [PeriodStart] DATE NOT NULL,
    [PeriodEnd] DATE NOT NULL,
    [CurrencyId] INT NOT NULL,
    [Volume] DECIMAL(19,4) NOT NULL,
    [TxnCount] INT NULL,
    [FeesPaid] DECIMAL(19,4) NULL,
    [BankProfit] DECIMAL(19,4) NULL,
    [CompanyReturn] DECIMAL(19,4) NULL,
    [EndBalance] DECIMAL(19,4) NULL,
    [Notes] NVARCHAR(500) NULL,
    [CreatedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_RelationshipProductVolume_CreatedAt] DEFAULT SYSUTCDATETIME(),
    [CreatedBy] BIGINT NULL,
    [UpdatedAt] DATETIME2(3) NULL,
    [UpdatedBy] BIGINT NULL,
    [RowVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_RelationshipProductVolume] PRIMARY KEY CLUSTERED ([RelationshipProductVolumeId]),
    CONSTRAINT [UQ_RelationshipProductVolume_Tenant] UNIQUE ([TenantId], [RelationshipProductVolumeId]),
    CONSTRAINT [UQ_RelationshipProductVolume_RelationshipProductId_PeriodStart_CurrencyId] UNIQUE ([TenantId], [RelationshipProductId], [PeriodStart], [CurrencyId]),
    CONSTRAINT [CK_RelationshipProductVolume_1] CHECK (PeriodEnd >= PeriodStart),
    CONSTRAINT [CK_RelationshipProductVolume_2] CHECK (Volume >= 0 AND (TxnCount IS NULL OR TxnCount >= 0) AND (FeesPaid IS NULL OR FeesPaid >= 0))
);
GO
ALTER TABLE [ins].[RelationshipProductRate] ADD CONSTRAINT [FK_RelationshipProductRate_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [ins].[RelationshipProductRate] ADD CONSTRAINT [FK_RelationshipProductRate_RelationshipProductId] FOREIGN KEY ([TenantId], [RelationshipProductId]) REFERENCES [ins].[RelationshipProduct] ([TenantId], [RelationshipProductId]);
ALTER TABLE [ins].[RelationshipProductRate] ADD CONSTRAINT [FK_RelationshipProductRate_ChargeItemId] FOREIGN KEY ([TenantId], [ChargeItemId]) REFERENCES [cat].[LookupItem] ([TenantId], [LookupItemId]);
ALTER TABLE [ins].[RelationshipProductRate] ADD CONSTRAINT [FK_RelationshipProductRate_CurrencyId] FOREIGN KEY ([CurrencyId]) REFERENCES [ref].[Currency] ([CurrencyId]);
ALTER TABLE [ins].[RelationshipProductVolume] ADD CONSTRAINT [FK_RelationshipProductVolume_Tenant] FOREIGN KEY ([TenantId]) REFERENCES [plat].[Tenant] ([TenantId]);
ALTER TABLE [ins].[RelationshipProductVolume] ADD CONSTRAINT [FK_RelationshipProductVolume_RelationshipProductId] FOREIGN KEY ([TenantId], [RelationshipProductId]) REFERENCES [ins].[RelationshipProduct] ([TenantId], [RelationshipProductId]);
ALTER TABLE [ins].[RelationshipProductVolume] ADD CONSTRAINT [FK_RelationshipProductVolume_CurrencyId] FOREIGN KEY ([CurrencyId]) REFERENCES [ref].[Currency] ([CurrencyId]);
GO
CREATE NONCLUSTERED INDEX [IX_RelationshipProductRate_ChargeItemId] ON [ins].[RelationshipProductRate] ([TenantId], [ChargeItemId]);
CREATE NONCLUSTERED INDEX [IX_RelationshipProductRate_CurrencyId] ON [ins].[RelationshipProductRate] ([TenantId], [CurrencyId]);
CREATE NONCLUSTERED INDEX [IX_RelationshipProductVolume_RelationshipProductId_PeriodEnd] ON [ins].[RelationshipProductVolume] ([TenantId], [RelationshipProductId], [PeriodEnd]);
CREATE NONCLUSTERED INDEX [IX_RelationshipProductVolume_CurrencyId] ON [ins].[RelationshipProductVolume] ([TenantId], [CurrencyId]);
GO
ALTER TABLE [cat].[Product] DROP CONSTRAINT [CK_Product_ProductFamily];
GO
ALTER TABLE [cat].[Product] ADD CONSTRAINT [CK_Product_ProductFamily] CHECK ([ProductFamily] IS NULL OR [ProductFamily] IN ('LC', 'GUARANTEE', 'FINANCING', 'COLLECTION', 'FX', 'PAYMENT', 'CARD', 'ACCOUNT_SERVICE', 'DEPOSIT', 'INVESTMENT', 'DERIVATIVE', 'WEALTH', 'OTHER'));
GO
