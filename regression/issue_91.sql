
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
