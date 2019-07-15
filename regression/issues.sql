USE [master]
GO
/****** Issue 91 ******/
CREATE TABLE [candidate].[PersonalIdentityHashes](
	[OrganizationId] [int] NOT NULL,
	[PersonalIdentity] [char](64) NOT NULL,
	[PersonalIdentityHash] [binary](64) NOT NULL,
	[PersonalIdentityHash2] [varbinary](64) NOT NULL,
	[CandidateId] [bigint] NOT NULL,
 CONSTRAINT [PK_candidatePersonalIdentityHashes] PRIMARY KEY CLUSTERED
(
	[OrganizationId] ASC,
	[PersonalIdentityHash] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO

/****** Issue 98 ******/
CREATE TABLE [etl].[account_handle](
	[acct_event_id] [bigint] NOT NULL ,
	[acct_id] [bigint] NOT NULL ,
	[comment_id] [bigint] NULL,
	[descrip] [varchar] NULL,
	[event_cat_id] [bigint] NOT NULL ,
	[event_date] [datetime] NOT NULL ,
	[event_end_time] [varchar] NULL,
	[event_start_time] [varchar] NULL,
	[event_type_id] [bigint] NOT NULL ,
	[problem_cd] [bigint] NULL,
	[reason_cd] [bigint] NULL,
	[resolution] [varchar] NULL,
	[user_id] [bigint] NULL,
	[ext_user_name] [varchar] NULL,
	[level1_id] [bigint] NULL,
	[level2_id] [bigint] NULL,
	[level3_id] [bigint] NULL,
	[level4_id] [bigint] NULL,
	[group_id] [bigint] NULL,
	[escalation_id] [bigint] NULL,
	[level5_id] [bigint] NULL,
	[reference_id] [bigint] NULL,
	[entity] [varchar] NULL,
	[modified_ts] [datetime] NOT NULL ,
	[device_type_id] [bigint] NULL,
	[device_error_codes] [varchar] NULL,
 PRIMARY KEY CLUSTERED
(
	[acct_event_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
