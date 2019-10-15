CREATE TABLE [dbo].[AFElementAttributeCategory](
	[rid] [bigint] IDENTITY(-1,-1) NOT NULL,
	[id] [uniqueidentifier] NOT NULL,
	[rowversion] [timestamp] NOT NULL,
	[fkelementversionid] [bigint] NOT NULL,
	[fkparentattributeid] [uniqueidentifier] NULL,
	[fkcategoryid] [uniqueidentifier] NOT NULL,
	[changedby] [int] NOT NULL,
 CONSTRAINT [PK_AFElementAttributeCategory] PRIMARY KEY CLUSTERED 
(
	[rid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [ASSETS]
) ON [ASSETS]
GO

CREATE TABLE [dbo].[AFCaseAdjustment](
	[rid] [bigint] IDENTITY(-1,-1) NOT NULL,
	[id] [uniqueidentifier] NOT NULL,
	[rowversion] [timestamp] NOT NULL,
	[fkcaseid] [bigint] NOT NULL,
	[attributeid] [uniqueidentifier] NOT NULL,
	[adjustedvalue] [varbinary](max) NULL,
	[comment] [nvarchar](1000) NULL,
	[previousvalue] [varbinary](max) NULL,
	[creator] [nvarchar](50) NULL,
	[creationdate] [datetime2](7) NULL,
	[changedby] [int] NOT NULL,
 CONSTRAINT [PK_AFCaseAdjustment] PRIMARY KEY NONCLUSTERED 
(
	[rid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [ANALYSIS]
) ON [ANALYSIS] TEXTIMAGE_ON [ANALYSIS]
GO

CREATE TABLE [dbo].[sd](
	[rid] [int] IDENTITY(1000,1) NOT NULL,
	[rowversion] [timestamp] NOT NULL,
	[sd] [nvarchar](max) NOT NULL,
	[ownerRights] [int] NOT NULL,
	[lupd] [datetime2](7) NULL,
 CONSTRAINT [pk_sd] PRIMARY KEY CLUSTERED 
(
	[rid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [ASSETS]
) ON [ASSETS] TEXTIMAGE_ON [ASSETS]
GO