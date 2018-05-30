CREATE TABLE [dbo].[ACCOUNT](
	[ID] [char](36) NOT NULL,
	[VERSION] [numeric](10, 0) NOT NULL,
	[APPLICATION_ID] [char](36) NOT NULL,
	[ACCOUNT_NUMBER] [nvarchar](35) NOT NULL,
	[DELETED] [numeric](1, 0) NOT NULL,
	[DELETED_BY] [char](36) NULL,
	[DELETED_ON] [datetime2](0) NULL,
	[CREATED_ON] [datetime2](0) NULL,
	[CREATED_BY] [char](36) NULL,
	[DAILY_LIMIT] [numeric](21, 7) NULL,
	[BIC] [varchar](35) NULL,
	[IBAN] [varchar](35) NULL,
	[BACK_OFFICE_ACCOUNT_NUMBER] [varchar](35) NULL,
	[BANK_ACCOUNT_NUMBER] [varchar](35) NULL,
	[OWNER_ID] [char](36) NULL,
	[ALLOW_PENDING] [numeric](1, 0) NOT NULL DEFAULT ((0)),
 CONSTRAINT [SYS_C0010802] PRIMARY KEY CLUSTERED 
(
	[ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]



EXEC sys.sp_addextendedproperty @name=N'MS_SSMA_SOURCE', @value=N'ONEBANK.ACCOUNT.ID' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'TABLE',@level1name=N'ACCOUNT', @level2type=N'COLUMN',@level2name=N'ID'
GO
