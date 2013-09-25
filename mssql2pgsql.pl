#!/usr/bin/perl -w

# This script takes a sql server SQL schema dump, and creates a postgresql dump
# Optionnaly, if asked, generate a kettle job to transfer all data. This is done via -k dir
# Details in the README file

# This program is made to die on all error conditions: if there is something not understood in
# a dump, it has to be added, or manually ignored (in order to improve this program rapidly)

# Licence: GPLv3
# Copyright Marc Cousin, Dalibo

use Getopt::Long;
use Data::Dumper;
use Cwd;
use Encode::Guess;
use Carp;

use strict;



# Global objects definition structure: we need it to store all seen tables, detect which ones have LOBS 
# and if their PK is a simple integer (so we can parallelize readings on these tables in a special
# kettle transformation)

# $objects will contain the parsed structure of the SQL Server dump
# If you have to hack and want to understand its structure, just uncomment the call to Dumper() in the code
my $objects;


my ($sd,$sh,$sp,$su,$sw,$pd,$ph,$pp,$pu,$pw);# Connection args
my $filename;# Filename passed as arg
my $case_insensitive=0; # Passed as arg: was SQL Server installation case insensitive ? PostgreSQL can't ignore accents anyway
			# If yes, we will generate citext with CHECK constraints...
my $norelabel_dbo=0; # Passed as arg: should we convert DBO to public ? FIXME:todo

my $template;     # These two variables are loaded in the BEGIN block at the end of this file (they are very big
my $template_lob; # putting them there won't pollute the code as much)

my ($job_header,$job_middle,$job_footer); # These are used to create the static parts of the job
my ($job_entry,$job_hop); # These are used to create the dynamic parts of the job (XML file)


my %types=('int'=>'int',
           'nvarchar'=>'varchar',
           'nchar'=>'char',
	   'varchar'=>'varchar',
	   'char'=>'char',
	   'smallint'=>'smallint',
	   'tinyint'=>'smallint',
	   'datetime'=>'timestamp',
	   'smalldatetime'=>'timestamp',
           'char'=>'char',
	   'image'=>'bytea',
	   'text'=>'text',
	   'bigint'=>'bigint',
	   'timestamp'=>'timestamp',
	   'numeric'=>'numeric',
	   'decimal'=>'numeric',
	   'binary'=>'bytea',
	   'varbinary'=>'bytea',
	   );

# Types with no qualifier, and no point in putting one
my %unqual=('bytea'=>1);

# This function uses the two static lists above, plus domains and citext types that
# may have been created during parsing, to convert mssql's types to pgsql's
sub convert_type
{
	my ($sqlstype,$sqlqual,$colname,$tablename,$typname,$schemaname)=@_;
	my $rettype;
	if (defined $types{$sqlstype})
	{
		if ((defined $sqlqual and defined ($unqual{$types{$sqlstype}})) or not defined $sqlqual)
		{ 
			# This is one of the few types that have to be unqualified (binary type)
			$rettype= $types{$sqlstype};
		}
		elsif (defined $sqlqual)
		{
			$rettype= ($types{$sqlstype}."($sqlqual)");
		}
	}
	elsif ($sqlstype eq 'bit' and not defined $sqlqual)
	{
		$rettype= "boolean";
	}
	elsif ($sqlstype eq 'ntext' and not defined $sqlqual)
	{
		$rettype= "text";
	}
	else
	{
		print "Types: " , Dumper(\%types);
		croak "Cannot determine the PostgreSQL's datatype corresponding to $sqlstype. This is a bug\n";
	}
	# We special case when type is varchar, to be case insensitive
	if ($sqlstype =~ /text|varchar/ and $case_insensitive)
	{
		$rettype="citext";
		# Do we have a SQL qualifier ? (we'll have to do check constraints then)
		if ($sqlqual)
		{
			# Check we have a table name and a colname, or a typname
			if (defined $colname and defined $tablename) # We are called from a CREATE TABLE, we have to add a check constraint
			{
				my $constraint;
				$constraint->{TYPE}='CHECK_GENERATED';
				$constraint->{TABLE}=$tablename;
				$constraint->{TEXT}="char_length($colname) <= $sqlqual";
				push @{$objects->{$schemaname}->{TABLES}->{$tablename}->{CONSTRAINTS}},($constraint);
			}
			elsif (defined $typname) # We are called from a CREATE TYPE, which will be converted to a CREATE DOMAIN
			{
				$rettype="citext CHECK(char_length(value)<=$sqlqual)";
			}
			else
			{
				die "Called in a case sensitive, trying to generate a check constraint, failed. This is a bug!\n";
			}
		}
	}
	return $rettype;
}

# This gives the next column position for a table
# It is used when we receive alter tables in the sql server dump
sub next_col_pos
{
	my ($schema,$table)=@_;
	if (defined $objects->{$schema}->{TABlES}->{$table}->{COLS})
	{
		my $max=0;
		foreach my $col(values (%{$objects->{$schema}->{TABlES}->{$table}->{COLS}}))
		{
			if ($col->{POS} > $max)
			{
				$max=$col->{POS};
			}
		}
		return $max+1;
	}
	else
	{
		die "We tried to add a column to an unknown table\n";
	}
}

# This relabels the string if it is dbo and we want to relabel it to public
sub dboreplace
{
	my ($schema)=@_;
	return $schema if ($schema ne 'dbo');
	return 'public' unless ($norelabel_dbo);
	return 'dbo';
}

sub is_windows
{
	if ($^O =~ /win/i)
	{
		return 1;
	}
	return 0;
}

sub kettle_die
{
	my ($file)=@_;
	die "You have to set up KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y in $file.\nIf this file doesn't exist yet, start spoon from the kettle directory once.\n";
}


# This sub checks ~/.kettle/kettle.properties to be sure
# KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y is in place
sub check_kettle_properties
{
	my $ok=0;
	my $file;
	if (!is_windows())
	{
		$file= $ENV{'HOME'}.'/.kettle/kettle.properties';
	}
	else
	{
		$file= $ENV{'USERPROFILE'}.'/.kettle/kettle.properties';
	}
	open FILE, $file or kettle_die($file);
	while (<FILE>)
	{
		next unless (/KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL\s*=\s*Y/);
		$ok=1;
	}
	close FILE;
	if (not $ok)
	{
		kettle_die($file);
	}
	return 0;
}


sub usage
{
	print "$0 [-k kettle_output_directory] -b before_file -a after_file -u unsure_file -f sql_server_schema_file[-h] [-i]\n";
	print "\nExpects a SQL Server SQL structure dump as -f (preferably unicode)\n";
	print "-i tells $0 to create a case-insensitive PostgreSQL schema\n";
	print "-nr tells $0 not to convert the dbo schema to public. dbo will stay dbo\n";
	print "before_file contains the structure\n";
	print "after_file contains index, constraints\n";
	print "unsure_file contains things we cannot guarantee will work, such as views\n";
	print "\n";
	print "If you are generating for kettle, you'll need to provide connection information\n";
	print "for connecting to both databases:\n";
	print "-sd: sqlserver database\n";
	print "-sh: sqlserver host\n";
	print "-sp: sqlserver port\n";
	print "-su: sqlserver username\n";
	print "-sw: sqlserver password\n";
	print "-pd: postgresql database\n";
	print "-ph: postgresql host\n";
	print "-pp: postgresql port\n";
	print "-pu: postgresql username\n";
	print "-pw: postgresql password\n";
}

# This function generates kettle transformations, and a kettle job running all these
# transformations sequentially, for all the tables in sql server's dump
sub generate_kettle
{
	my ($dir)=@_;
	# first, create the kettle directory
	unless (-d $dir)
	{
		mkdir ($dir) or die "Cannot create $dir, $!\n";
	}
	# For each table in each schema in $objects, we generate a kettle file in the directory

	while (my ($schema,$refschema)=each %{$objects})
	{
		my $targetschema=dboreplace($schema);
	
		foreach my $table (keys %{$refschema->{TABLES}})
		{
			# First, does this table have LOBs ? The template depends on this
			my $newtemplate;
			if ($refschema->{TABLES}->{$table}->{haslobs})
			{
				$newtemplate=$template_lob;
				# Is the PK int and on only one column ?
				# If yes, we can use several threads in kettle to read this table to
				# improve performance
				if (defined ($refschema->{TABLES}->{$table}->{PK}->{COLS}) and scalar(@{$refschema->{TABLES}->{$table}->{PK}->{COLS}})==1
				    and
				    ($refschema->{TABLES}->{$table}->{COLS}->{($refschema->{TABLES}->{$table}->{PK}->{COLS}->[0])}->{TYPE} =~ /int$/)
				   )
				{
					my $wherefilter='WHERE ' . $refschema->{TABLES}->{$table}->{PK}->{COLS}->[0]
					. '% ${Internal.Step.Unique.Count} = ${Internal.Step.Unique.Number}';
					$newtemplate =~ s/__sqlserver_where_filter__/$wherefilter/;
					$newtemplate =~ s/__sqlserver_copies__/4/g;
				}
				else
				# No way to do this optimization. Use standard template
				{
					$newtemplate =~ s/__sqlserver_where_filter__//;
					$newtemplate =~ s/__sqlserver_copies__/1/g
				}
			}
			else
			{
				$newtemplate=$template;
			}
			# Substitute every connection placeholder with the real value
			$newtemplate =~ s/__sqlserver_database__/$sd/g;
			$newtemplate =~ s/__sqlserver_host__/$sh/g;
			$newtemplate =~ s/__sqlserver_port__/$sp/g;
			$newtemplate =~ s/__sqlserver_username__/$su/g;
			$newtemplate =~ s/__sqlserver_password__/$sw/g;
			$newtemplate =~ s/__postgres_database__/$pd/g;
			$newtemplate =~ s/__postgres_host__/$ph/g;
			$newtemplate =~ s/__postgres_port__/$pp/g;
			$newtemplate =~ s/__postgres_username__/$pu/g;
			$newtemplate =~ s/__postgres_password__/$pw/g;
			# FIXME: add schema correction
			$newtemplate =~ s/__sqlserver_table_name__/$schema.$table/g;
			$newtemplate =~ s/__postgres_table_name__/lc($targetschema.$table)/g;
			# Store this new transformation into its file
			open FILE, ">$dir/$table.ktr" or die "Cannot write to $dir/$table.ktr, $!\n";
			print FILE $newtemplate;
			close FILE;
		}
	}
	# All transformations are done
	# We have to create a job to launch everything in one go
	open FILE, ">$dir/migration.kjb" or die "Cannot write to $dir/migration.kjb, $!\n";
	my $real_dir=getcwd;
	my $entries='';
	my $hops='';
	my $prev_node='START';
	my $cur_vert_pos=100; # Not that useful, it's just not to be ugly if someone wanted to open
	                      # the job with spoon (kettle's gui)
	# We sort only so that it will be easier to find a transformation in the job if one needed to
	# edit it. It's also easier to track progress if tables are sorted alphabetically
	while (my ($schema,$refschema)=each %{$objects})
	{
		foreach my $table (sort {lc($a) cmp lc($b)}keys %{$refschema->{TABLES}})
		{
			my $tmp_entry=$job_entry;
			# We build the entries with regexp substitutions:
			$tmp_entry =~ s/__table_name__/$table/;
			# Filename to use. We need the full path to the transformations
			my $filename;
			if ( $dir =~ /^(\\|\/)/) # Absolute path
			{
				$filename = $dir . '/' . $table . '.ktr';
			}
			else
			{
				$filename = $real_dir . '/' . $dir . '/' . $table . '.ktr';
			}
			# Different for windows and linux, obviously: we change / to \ for windows
			unless (is_windows())
			{
				$filename =~ s/\//&#47;/g;
			}
			else
			{
				$filename =~ s/\//\\/g;
			}
			$tmp_entry =~ s/__file_name__/$filename/;
			$tmp_entry =~ s/__y_loc__/$cur_vert_pos/;
			$entries.=$tmp_entry;

			# We build the hop with the regexp too
			my $tmp_hop=$job_hop;
			$tmp_hop =~ s/__table_1__/$prev_node/;
			$tmp_hop =~ s/__table_2__/$table/;
			if ($prev_node eq 'START')
			{
				# Specific to the start node. It has to be unconditional
				$tmp_hop =~ s/<unconditional>N<\/unconditional>/<unconditional>Y<\/unconditional>/;
			}
			$hops.=$tmp_hop;
			
			# We increment everything for next loop
			$prev_node=$table; # For the next hop
			$cur_vert_pos+=80; # To be pretty in spoon
		}
	}
	
	print FILE $job_header;
	print FILE $entries;
	print FILE $job_middle;
	print FILE $hops;
	print FILE $job_footer;
	close FILE;


}

# sql server's dump may contain multiline C style comments (/* */)
# This sub reads a line and cleans it up, removing comments, \r, exec sp_executesql,...
{
	my $in_comment=0;
	sub read_and_clean
	{
		my ($fd)=@_;
		my $line=<$fd>;
		return undef if (not defined $line);
		$line =~ s/\r//g; # Remove \r from windows output
		$line =~ s/EXEC(ute)?\s*(dbo|sys)\.sp_executesql( \@statement =)? N'//i; # Remove executesql… we are already executing sql
		# If we are not in comment, we look for /*
		# If we are in comment, we look for */, and we remove everything until */
		if (not $in_comment)
		{
			# We first remove all one-line only comments (there may be several on this line)
			$line =~ s/\/\*.*?\*\///g;
			# Is there a comment left ?
			if ($line =~ /\/\*/)
			{
				$in_comment=1;
				$line =~ s/\/\*.*//; # Remove everything after the comment
			}
		}
		else
		{
			# We do the reverse: keep only what is not commented
		       $line =~ s/\*\/(.*?)\/\*/$1/g;
		       # Is there an uncomment left ?
		       if ($line =~ /\*\//)
		       {
			       $in_comment=0;
			       $line =~ s/.*\*\///; # Remove everything before the uncomment
		       }
		       else
		       {
			       # There is no uncomment. The line should be empty
			       $line = "\n";
		       }
		}
		return $line;
	}
}
# Reads the dump passed as -f
# Generates the $object structure
sub parse_dump
{
	# Open the input file or die. This first pass is to detect encoding, and open it correctly afterwards
	my $data;
	my $file;
	open $file,"<$filename" or die "Cannot open $filename, $!\n";
	while (my $line=<$file>)
	{
		$data.=$line;
	}
	close $file;

	# We now ask guess...
	my $decoder=guess_encoding($data, qw/iso8859-15/);
	die $decoder unless ref($decoder);

	# If we got to here, it means we have found the right decoder
	open $file,"<:encoding(".$decoder->name.")",$filename or die "Cannot open $filename, $!\n";

	# Parsing loop variables
	my $create_table=0; # Are we in a create table statement ?
	my $tablename=''; # If yes, what's the table name ?
	my $schemaname=''; # If yes, what's the schema name ?
	my $colnumber=0; # Column number (just to put the commas in the right places) ?
	# Tagged because sql statements are often multi-line, so there are inner loops in some conditions
	MAIN: while (my $line=read_and_clean($file))
	{
		# Create table, obviously. There will be other lines below for the rest of the table definition
		if ($line =~ /^CREATE TABLE \[(.*)\]\.\[(.*)\]\(/)
		{
			$create_table=1; # We are now inside a create table
			$schemaname=$1;
			$tablename=$2;
			$colnumber=0;
			$objects->{$schemaname}->{TABLES}->{$tablename}->{haslobs}=0;
		}
		# Here is a col definition. We should be inside a create table
		elsif ($line =~ /^\t\[(.*)\] (?:\[(.*)\]\.)?\[(.*)\](\(.+?\))?( IDENTITY\(\d+,\s*\d+\))? (NOT NULL|NULL)(,)?/)
		{
			if ($create_table) # We are inside a create table, this is a column definition
			{
				$colnumber++;
				my $colname=$1;
				my $coltypeschema=$2;
				my $coltype=$3;
				if (defined $coltypeschema)
				{
					# The datatype is a user defined datatype
					# It has already been declared before. We just need to find it
					$coltype=$coltypeschema . '.' . $coltype; 
				}
				my $colqual=$4;
				my $isidentity=$5;
				my $colisnull=$6;
				if ($colqual)
				{
					if ($colqual eq '(max)')
					{
						$colqual=undef; # max in sql server is the same as putting no colqual in pg
					}
					else
					{
						# We need the number (or 2 numbers) in this qual
						$colqual=~ /\((\d+(?:,\s*\d+)?)\)/ or die "Cannot parse colqual <$colqual>\n"; 
						$colqual= "$1";
					}
				}
				my $newtype=convert_type($coltype,$colqual,$colname,$tablename,undef,$schemaname);
				# If it is an identity, we'll map to serial/bigserial (create a sequence, then link it
				# to the column)
				if ($isidentity)
				{
					# We have an identity field. We remember the default value and
					# initialize the sequence correctly in the after script
					$isidentity=~ /IDENTITY\((\d+),\s*(\d+)\)/ or die "Cannot understand <$isidentity>\n";
					my $startseq=$1;
					my $stepseq=$2;
					my $seqname= lc("${tablename}_${colname}_seq");
					$objects->{$schemaname}->{TABLES}->{$tablename}->{COLS}->{$colname}->{DEFAULT}= 
					   "nextval('" . dboreplace(${schemaname}) . '.' . ${seqname}. "')";
					$objects->{$schemaname}->{SEQUENCES}->{$seqname}->{START}=$startseq;
					$objects->{$schemaname}->{SEQUENCES}->{$seqname}->{STEP}=$stepseq;
					$objects->{$schemaname}->{SEQUENCES}->{$seqname}->{OWNERTABLE}=$tablename . "." . $colname;
					$objects->{$schemaname}->{SEQUENCES}->{$seqname}->{OWNERSCHEMA}=$schemaname;
				}
				# If there is a bytea generated, this table will contain a blob:
				# use a special kettle transformation for it if generating kettle
				# (see generate_kettle() )
				if ($newtype eq 'bytea' or $coltype eq 'ntext') # Ntext is very slow, stored out of page
				{
					$objects->{$schemaname}->{'TABLES'}->{$tablename}->{haslobs}=1;
				}
				$objects->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}->{$colname}->{POS}=$colnumber;
				$objects->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}->{$colname}->{TYPE}=$newtype;

				
				if ($colisnull eq 'NOT NULL')
				{
					$objects->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}->{$colname}->{NOT_NULL}=1;
				}
				else
				{
					$objects->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}->{$colname}->{NOT_NULL}=0;
				}
			}
			else
			{
				die "I don't understand $line. This is a bug\n";
			}
		}
		elsif ($line =~ /^(?: CONSTRAINT \[(.*)\] )?PRIMARY KEY (?:NON)?CLUSTERED/)
		{
			# This is not forbidden by SQL, of course. I just never saw this in a sql server dump,
			# so it should be an error for now (it will be syntaxically different if outside a table anyhow)
			die "PK defined outside a table\n: $line" unless ($create_table); 
			
			my $constraint; # We put everything inside this hashref, we'll push it into the constraint list later
			$constraint->{TYPE}='PK';
			if (defined $1)
			{
				$constraint->{NAME}=$1;
			}

			# Here is the PK. We read the following lines until the end of the constraint
			while (my $pk=read_and_clean($file))
			{
				# Exit when read a line beginning with ). The constraint is complete. We store it and go back to main loop
				if ($pk =~ /^\)/)
				{
					push @{$objects->{$schemaname}->{TABLES}->{$tablename}->{CONSTRAINTS}},($constraint);
					# We also directly put the constraint reference in a direct path (for ease of use in generate_kettle)
					$objects->{$schemaname}->{TABLES}->{$tablename}->{PK}=$constraint;
					next MAIN;
				}
				if ($pk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
				{
					push @{$constraint->{COLS}},($1);
				}
			}
		}
		elsif ($line =~ /^\s*(?:CONSTRAINT \[(.*)\] )?UNIQUE/)
		{
			my $constraint; # We put everything inside this hashref, we'll push it into the constraint list later
			$constraint->{TYPE}='UNIQUE';
			if (defined $1)
			{
				$constraint->{NAME}=$1;
			}
			# Unique key definition. We read following lines until the end of the constraint
			while (my $uk=read_and_clean($file))
			{
				# Exit when read a line beginning with ). The constraint is complete
				if ($uk =~ /^\)/)
				{
					push @{$objects->{$schemaname}->{'TABLES'}->{$tablename}->{CONSTRAINTS}},($constraint);
					next MAIN;
				}
				if ($uk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
				{
					push @{$constraint->{COLS}},($1);
				}
			}

		}
		elsif ($line =~ /CREATE SCHEMA \[(.*)\] AUTHORIZATION \[.*\]/)
		{
			$objects->{$1}=undef; # Nothing to add here, we create the undef schema
		}
		elsif ($line =~ /CREATE\s+PROC(?:EDURE)?\s+\[.*\]\.\[(.*)\]/i)
		{
			print STDERR "Procedure $1 ignored\n";
			# We have to find next GO to know we are out of the procedure
			while (my $contline=read_and_clean($file))
			{
				next MAIN if ($contline =~ /^GO$/);
			}
		}
		elsif ($line =~ /CREATE\s+FUNCTION\s+\[.*\]\.\[(.*)\]/i)
		{
			print STDERR "Function $1 ignored\n";
			# We have to find next GO to know we are out of the procedure
			while (my $contline=read_and_clean($file))
			{
				next MAIN if ($contline =~ /^GO$/);
			}
		}
		elsif ($line =~ /CREATE\s+TRIGGER\s+\[(.*)\]/i)
		{
			print STDERR "Trigger $1 ignored\n";
			# We have to find next GO to know we are out of the procedure
			while (my $contline=read_and_clean($file))
			{
				next MAIN if ($contline =~ /^GO$/);
			}
		}
		# Ignore USE, GO, and things that have no meaning for postgresql
		elsif ($line =~ /^USE\s|^GO\s*$|\/\*\*\*\*|^SET ANSI_NULLS ON|^SET QUOTED_IDENTIFIER|^SET ANSI_PADDING|CHECK CONSTRAINT|BEGIN|END/)
		{
			next;
		}
		elsif ($line =~ /^--/) # Comment
		{
			next;
		}
		# Don't know what it is. If you know, and it is worth converting, tell me :)
		elsif ($line =~ /^EXEC .*bindrule/)
		{
			next;
		}
		# Ignore users and roles. Security models will probably be very different between the two databases
		elsif ($line =~ /^CREATE (ROLE|USER)/)
		{
			next;
		}
		# Ignore existence tests… how could the object already exist anyway ? For now, only seen for views
		elsif ($line =~ /^IF NOT EXISTS/)
		{
			next;
		}
		# Ignore EXEC dbo.sp_executesql, for now only seen for a create view. Views sql command aren't executed directly, don't know why
		elsif ($line =~ /^EXEC dbo.sp_executesql/)
		{
			next;
		}
		# Still on views: there are empty lines, and C-style comments
		elsif ($line =~ /^\s*$/)
		{
			next;
		}
		# Now we parse the create view. It is multi-line, so the code looks like like create table: we parse everything until a line
		# containing only a single quote (end of the dbo.sp_executesql)
		elsif ($line =~ /^\s*(create\s*view)\s*(?:\[(\S+)\])?\.\[(.*?)\]\s*(.*)$/i)
		{
			my $viewname=$3;
			my $schemaname;
			if (defined $2)
			{
				$schemaname=$2;
			}
			else
			{
				$schemaname='dbo';
			}
			my $sql=$1 . ' ' . $3 . ' ' . $4 . "\n";
			while (my $line_cont=read_and_clean($file))
			{
				if ($line_cont =~ /^\s*'\s*$/)
				{
					# The view definition is complete.
					# We get rid of dbo. schemas
					$sql =~ s/dbo\.//g; # We put this in the current schema
					# Views will be stored without the full schema in them. We will
					# have to generate the schema in the output file
					$objects->{$schemaname}->{'VIEWS'}->{$viewname}->{SQL}=$sql;
					next MAIN;
				}
				$sql.=$line_cont;
			}
		}
		#
		# I only have seen types with added constraints ( create type foo varchar(50)) for now
		# These are domains with PostgreSQL
		elsif ($line =~ /^CREATE TYPE \[(.*?)\]\.\[(.*?)\] FROM \[(.*?)](?:\((\d+(?:,\s*\d+)?)?\))?/)
		{
			# Dependancy between types is not done for now. If the problem arises, it should be added
			my ($schema,$type,$origtype,$quals)=($1,$2,$3,$4);
			my $newtype=convert_type($origtype,$quals,undef,undef,$type,$schema);
			$objects->{$schema}->{DOMAINS}->{$type}=$newtype;
			# We add them to known data types, as they probably will be used in table definitions
			# but they point to themselves, with the schema corrected: we want them substituted by themselve
			$types{$schema . '.' . $type}=dboreplace($schema) . '.' . $type; # We store the schema with it
		}
		elsif ($line =~ /^\) ON \[PRIMARY\]/)
		{
			# End of the table
			$create_table=0;
			$tablename='';
		}
		elsif ($line =~ /^CREATE (UNIQUE )?NONCLUSTERED INDEX \[(.*)\] ON \[(.*)\]\.\[(.*)\]/)
		{
			# Index creation. Index are namespaced per table in SQL Server, not in PostgreSQL
			# In PostgreSQL they are in the same namespace as the tables, and in the same
			# schema as the table they are attached to
			# So we store them in $objects, attached to the table
			# Conflicts will be sorted by resolve_name_conflicts() later 
			my $isunique=$1;
			my $idxname=$2;
			my $schemaname=$3;
			my $tablename=$4;
			if ($isunique)
			{
				$objects->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}->{$idxname}->{UNIQUE}=1;
			}
			else
			{
				$objects->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}->{$idxname}->{UNIQUE}=0;
			}
			while (my $idx=read_and_clean($file))
			{
				# Exit when read a line beginning with ). The index is complete
				if ($idx =~ /^\)/)
				{
					next MAIN;
				}
				next if ($idx =~ /^\(/); # Begin of the columns declaration
				if ($idx =~ /\t\[(.*)\] (ASC|DESC)(,)?/)
				{
					if (defined $2)
					{
						push @{$objects->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}->{$idxname}->{COLS}}, ("$1 $2");
					}
					else
					{
						push @{$objects->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}->{$idxname}->{COLS}}, ("$1");
					}
				}
			}
		}
		# Added table columns… this seems to appear in SQL Server when some columns have ansi padding, and some not.
		# PG follows ansi, that is not an option. The end of the regexp is pasted from the create table
		elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\] ADD \[(.*)\] (?:\[.*\]\.)?\[(.*)\](\(.+?\))?( .*\(\d+,\s*\d+\))? (NOT NULL|NULL)$/)
		{
			die "$line: not understood. This is a bug\n";
		}
		# Table constraints
		# Primary key. Multiline
		elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[(.*)\])? PRIMARY KEY (?:CLUSTERED)?/)
		{
			die "$line: not understood. This is a bug\n";
			while (my $contline=read_and_clean($file))
			{
				next MAIN if ($contline =~ /^GO/);
			}
		}

		elsif ($line =~ /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \(\(((?:-)?\d+)\)\) FOR \[(.*)\]/)
		{
			$objects->{$1}->{TABLES}->{$2}->{COLS}->{$4}->{DEFAULT}=$3;
			# Default value, for a numeric (yes sql server puts it in another pair of parenthesis, don't know why)
		}
		elsif ($line =~ /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \('(.*)'\) FOR \[(.*)\]/)
		{
			# Default text value, text, between commas
			$objects->{$1}->{TABLES}->{$2}->{COLS}->{$4}->{DEFAULT}="'$3'";
		}
		elsif ($line =~ /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \((\d)\) FOR \[(.*)\]/)
		{
			# Weird one: for bit type, there is no supplementary parenthesis... for now, let's say this is a bit type, and
			# convert to true/false
			if ($3 eq '0')
			{
				$objects->{$1}->{TABLES}->{$2}->{COLS}->{$4}->{DEFAULT}='false';
			}
			elsif ($3 eq '1')
			{
				$objects->{$1}->{TABLES}->{$2}->{COLS}->{$4}->{DEFAULT}='true';
			}
			else
			{
				die "not expected for a boolean: $line $. This is a bug\n"; # Get an error if the true/false hypothesis is wrong
			}
		}
		elsif ($line =~ /^ALTER TABLE \[(.*)\]\.\[(.*)\]\s+WITH (?:NO)?CHECK ADD\s+CONSTRAINT \[(.*)\] FOREIGN KEY\((.*?)\)/)
		{
			# This is a FK definition. We have the foreign table definition in next line.
			my $constraint;
			my $table=$2;
			my $schema=$1;
			$constraint->{TYPE}='FK';
			$constraint->{LOCAL_COLS}=$4;
			$constraint->{LOCAL_TABLE}=$2;
			$constraint->{LOCAL_COLS} =~ s/\[|\]//g; # Remove brackets
			while (my $fk = read_and_clean($file))
			{
				if ($fk =~ /^GO/)
				{
					push @{$objects->{$schema}->{'TABLES'}->{$table}->{CONSTRAINTS}},($constraint);
					next MAIN;
				}
				elsif ($fk =~ /^REFERENCES \[(.*)\]\.\[(.*)\] \((.*?)\)/)
				{
					$constraint->{REMOTE_COLS}=$3;
					$constraint->{REMOTE_TABLE}=$2;
					$constraint->{REMOTE_SCHEMA}=$1;
					$constraint->{REMOTE_COLS} =~ s/\[|\]//g; # Get rid of square brackets
				}
				elsif ($fk =~ /^ON DELETE CASCADE\s*$/)
				{
					$constraint->{ON_DEL_CASC}=1;
				}
				else
				{
					die "Cannot parse $fk $., in a FK. This is a bug\n";
				}
			}
		}
		elsif ($line =~ /ALTER TABLE \[(.*)\]\.\[(.*)\]  WITH (?:NO)?CHECK ADD  CONSTRAINT \[(.*)\] CHECK  \(\((.*)\)\)/ )
		{
			# Check constraint. We'll do what we can, syntax may be different.
			my $constraint;
			my $table=$2;
			my $constxt=$4;
			my $schema=$1;
			$constraint->{TABLE}=$table;
			$constraint->{NAME}=$3;
			$constraint->{TYPE}='CHECK';
			$constxt =~ s/\[(\S+)\]/$1/g; # We remove the []. And hope this will parse
			$constraint->{TEXT}=$constxt;
			push @{$objects->{$schema}->{'TABLES'}->{$table}->{CONSTRAINTS}},($constraint);
		}
		# These are comments or extended attributes on objets. They can be multiline, so aggregate everything 
		# Until next GO command
		# If fact in can be a lot of things. So we have to ignore things like MS_DiagramPaneCount
		elsif ($line =~ /^EXEC sys.sp_addextendedproperty/)
		{ 
			my $sqlproperty=$line;
			while (my $inline=read_and_clean($file))
			{
				last if ($inline =~ /^GO/);
				$sqlproperty.=$inline
			}


			# We have all the extended property. Let's parse it.

			# First step: what kind is it ? we are only interested in comments for now
			$sqlproperty =~ /\@name=N'(.*?)'/ or die "Cannot find a name for this extended property: $sqlproperty\n";
			my $propertyname=$1;
			if ($propertyname =~ /^(MS_DiagramPaneCount|MS_DiagramPane1)$/)
			{
				# We don't dump these. They are graphical descriptions of the GUI
				next;
			}

			elsif ($propertyname eq 'MS_Description')
			{
				# This is a comment. We parse it.
				# Spaces are mostly random it seems, in SQL Server's dump code. So \s* everywhere :(
				# There can be quotes inside a string. So (?<!')' matches only a ' not preceded by a '.
				# I hope it will be sufficient (won't be if someone decides to end a comment with a quote)

				$sqlproperty =~ /^EXEC sys.sp_addextendedproperty \@name=N'(.*?)'\s*,\s*\@value=N'(.*?)(?<!')'\s*,\s*\@level0type=N'(.*?)'\s*,\s*\@level0name=N'(.*?)'\s*(?:,\s*\@level1type=N'(.*?)'\s*,\s*\@level1name=N'(.*?)')\s*?(?:,\s*\@level2type=N'(.*?)'\s*,\s*\@level2name=N'(.*?)')?/s
				  or die "Could not parse $sqlproperty. This is a bug.\n";
				my ($comment,$schema,$obj,$objname,$subobj,$subobjname)=($2,$4,$5,$6,$7,$8);
				if ($obj eq 'TABLE' and not defined $subobj)
				{
					$objects->{$schema}->{TABLES}->{$objname}->{COMMENT}=$comment;
				}
				elsif ($obj eq 'VIEW' and not defined $subobj)
				{
					$objects->{$schema}->{VIEWS}->{$objname}->{COMMENT}=$comment;
				}
				elsif ($obj eq 'TABLE' and $subobj eq 'COLUMN')
				{
					$objects->{$schema}->{TABLES}->{$objname}->{COLS}->{$subobjname}->{COMMENT}=$comment;
				}
				else
				{
					die "Cannot understand this comment: $sqlproperty\n";
				}
			}
			else
			{
				die "Don't know what to do with this extendedproperty: $sqlproperty\n";
			}
		}
		else
		{
			die "Line <$line> ($.) not understood. This is a bug\n";
		}
	}
	close $file;
}

# Creates the SQL scripts from $object
# We generate alphabetically, to make things less random (this data comes from a hash)
sub generate_schema
{
	my ($before_file,$after_file,$unsure_file)=@_;
	# Open the output files (except kettle, we'll do that at the end)
	open BEFORE,">:utf8",$before_file or die "Cannot open $before_file, $!\n";
	open AFTER,">:utf8",$after_file or die "Cannot open $after_file, $!\n";
	open UNSURE,">:utf8",$unsure_file or die "Cannot open $unsure_file, $!\n";
	print BEFORE "\\set ON_ERROR_STOP\n";
	print BEFORE "BEGIN;\n";
	print AFTER "\\set ON_ERROR_STOP\n";
	print AFTER "BEGIN;\n";
	print UNSURE "\\set ON_ERROR_STOP\n";
	print UNSURE "BEGIN;\n";

	# Are we case insensitive ? We have to install citext then
	# Won't work on pre-9.1 database. But as this is a migration tool
	# if someone wants to start with an older version, it's their problem :)
	if ($case_insensitive)
	{
		print BEFORE "CREATE EXTENSION citext;\n";
	}

	# Ok, we have parsed everything, and definitions are in $objects
	# We will put in the BEFORE file only table and columns definitions. 
	# The rest will go in the AFTER script (check constraints, put default values, etc...)

	# The schemas. don't create empty schema, sql server creates a schema per user, even if it ends empty
	foreach my $schema (sort keys %{$objects})
	{
		unless (dboreplace($schema) eq 'public' or not defined $objects->{$schema})
		{
			print BEFORE "CREATE SCHEMA $schema;\n";
		}
	}

	# For the rest, we iterate over schemas
	# The tables, columns, etc... will be created in the before script, so there is no dependancy
	# problem with constraints, that will be in the after script
	while (my ($schema,$refschema)=each %{$objects})
	{
		$schema=dboreplace($schema); # If dbo, put into public, unless asked otherwise
		# The user-defined types (domains, etc)
		foreach my $domain (sort keys %{$refschema->{DOMAINS}})
		{
			print BEFORE "CREATE DOMAIN $schema.$domain " . $refschema->{DOMAINS}->{$domain} . ";\n";
		}

		print BEFORE "\n"; # We change sections in the dump file

		# The tables
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			my @colsdef;
			foreach my $col (sort  { $refschema->{TABLES}->{$table}->{COLS}->{$a}->{POS} 
						  <=> 
						 $refschema->{TABLES}->{$table}->{COLS}->{$b}->{POS}
					       } (keys %{$refschema->{TABLES}->{$table}->{COLS}}) )
				
			{
				my $colref=$refschema->{TABLES}->{$table}->{COLS}->{$col};
				my $coldef=$col . " " . $colref->{TYPE};
				if ($colref->{NOT_NULL})
				{
					$coldef .= ' NOT NULL';
				}
				push @colsdef,($coldef);
			}
			print BEFORE "CREATE TABLE $schema.$table ( \n\t" . join (",\n\t",@colsdef) . ");\n\n";
		}

		# We now add all "AFTER" objects
		# We start with SEQUENCES, PKs and INDEXES (will be needed for FK)

		foreach my $sequence (sort keys %{$refschema->{SEQUENCES}})
		{
			my $seqref=$refschema->{SEQUENCES}->{$sequence};
			print AFTER "CREATE SEQUENCE $schema.$sequence INCREMENT BY " . $seqref->{STEP} 
				     . " START WITH " . $seqref->{START} 
				     . " OWNED BY " . dboreplace($seqref->{OWNERSCHEMA}) . '.' . $seqref->{OWNERTABLE} . ";\n";
		}

		# Now PK. We have to go through all tables
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			my $refpk= $refschema->{TABLES}->{$table}->{PK};
			# Warn if no PK!
			if (not defined $refpk)
			{
				# Don't know if it should be displayed
				#print STDERR "Warning: $table has no primary key.\n"; 
				next;
			}
			my $pkdef= "ALTER TABLE $schema.$table ADD";
			if (defined $refpk->{NAME})
			{
				$pkdef .= " CONSTRAINT " . $refpk->{NAME};
			}
			$pkdef .= " PRIMARY KEY (" . join (',',@{$refpk->{COLS}}) . ");\n";
			print AFTER $pkdef;
		}

		# Now The UNIQUE constraints. They may be used for FK (if columns are not null)
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			foreach my $constraint (@{$refschema->{TABLES}->{$table}->{CONSTRAINTS}})
			{
				next unless ($constraint->{TYPE} eq 'UNIQUE');
				my $consdef= "ALTER TABLE $schema.$table ADD";
				if (defined $constraint->{NAME})
				{
					$consdef.= " CONSTRAINT " . $constraint->{NAME};
				}
				$consdef.= " UNIQUE (" . join (",",@{$constraint->{COLS}}) . ");\n";
				print AFTER $consdef;
			}
		}

		# We have all we need for FKs now. We can put all other constraints (except PK of course)
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			foreach my $constraint (@{$refschema->{TABLES}->{$table}->{CONSTRAINTS}})
			{
				next if ($constraint->{TYPE} =~ /^UNIQUE|PK$/);
				my $consdef= "ALTER TABLE $schema.$table ADD";
				if (defined $constraint->{NAME})
				{
					$consdef.= " CONSTRAINT " . $constraint->{NAME};
				}
				if ($constraint->{TYPE} eq 'FK') # COLS are already a comma separated list
				{
					$consdef.= " FOREIGN KEY (" . $constraint->{LOCAL_COLS} . ")" .
						   " REFERENCES " . dboreplace($constraint->{REMOTE_SCHEMA}) . '.' . $constraint->{REMOTE_TABLE} .
						   " ( " . $constraint->{REMOTE_COLS} . ")";
					if (defined $constraint->{ON_DEL_CASC} and $constraint->{ON_DEL_CASC})
					{
						$consdef.= " ON DELETE CASCADE";
					}
					$consdef.=  ";\n";
					print AFTER $consdef;
				}
				elsif ($constraint->{TYPE} eq 'CHECK')
				{
					$consdef.= " CHECK (" . $constraint->{TEXT} . ");\n";
					print UNSURE $consdef; # Check constraints are SQL, so cannot be sure
				}
				elsif ($constraint->{TYPE} eq 'CHECK_GENERATED') 
				{
					# These have been generated here, for citext mostly. So we know their syntax is ok
					$consdef.= " CHECK (" . $constraint->{TEXT} . ");\n";
					print AFTER $consdef; # Check constraints are SQL, so cannot be sure
				}
				else
				{
					# Shouldn't get there. it would mean I have forgotten a type of constraint
					die "I couldn't translate a constraint. This is a bug\n";
				}
			}
		}

		# Indexes
		# They don't have a schema qualifier. But their table has, and they are in the same schema as their table
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			foreach my $index (sort keys %{$refschema->{TABLES}->{$table}->{INDEXES}})
			{
				my $idxref=$refschema->{TABLES}->{$table}->{INDEXES}->{$index};
				my $idxdef="CREATE";
				if ($idxref->{UNIQUE})
				{
					$idxdef.=" UNIQUE";
				}
				$idxdef.= " INDEX $index ON $schema.$table ("  .
					  join(",",@{$idxref->{COLS}}) .
					  ");\n";
				print AFTER $idxdef;
			}
		}

		# Default values
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			foreach my $col (sort keys %{$refschema->{TABLES}->{$table}->{COLS}})
			{
				my $colref=$refschema->{TABLES}->{$table}->{COLS}->{$col};
				next unless (defined $colref->{DEFAULT});
				print AFTER "ALTER TABLE $schema.$table ALTER COLUMN $col SET DEFAULT " . $colref->{DEFAULT} . ";\n";
			}
		}

		# Comments on tables
		foreach my $table (sort keys %{$refschema->{TABLES}})
		{
			if (defined ($refschema->{TABLES}->{$table}->{COMMENT}))
			{
				print AFTER "COMMENT ON TABLE $schema.$table IS '" .
					    $refschema->{TABLES}->{$table}->{COMMENT} .
					    "';\n";
			}
			foreach my $col (sort keys %{$refschema->{TABLES}->{$table}->{COLS}})
			{
				my $colref=$refschema->{TABLES}->{$table}->{COLS}->{$col};
				if (defined ($colref->{COMMENT}))
				{
					print AFTER "COMMENT ON COLUMN $schema.$table.$col IS '" .
						    $colref->{COMMENT} . "';\n";
				}
			}
		}

		# The views, and comments
		foreach my $view (sort keys %{$refschema->{VIEWS}})
		{
			print UNSURE $refschema->{VIEWS}->{$view}->{SQL},";\n";
			if (defined $refschema->{VIEWS}->{$view}->{COMMENT})
			{
				print UNSURE "COMMENT ON VIEW $schema.$view IS '" .
					     $refschema->{VIEWS}->{$view}->{COMMENT} .
					     "';\n";
			}
		}
	}

	print BEFORE "COMMIT;\n";
	print AFTER "COMMIT;\n";
	print UNSURE "COMMIT;\n";
	close BEFORE;
	close AFTER;
	close UNSURE;

}

# This sub tries to avoid naming conflicts:
# Under PostgreSQL, types, tables and indexes share the same namespace
# As the table name is the one that will be used directly, types and indexes will be renamed
# Print a warning for each renamed type
# We do this schema per schema
sub resolve_name_conflicts
{
	while (my ($schema,$refschema)=each %{$objects})
	{
		my %known_names;
		# Store all known names
		foreach my $table (keys %{$refschema->{TABLES}})
		{
			$known_names{$table}=1;
		}

		# We scan all types. For now, this tool only generates domains, so we scan domains
		foreach my $domain (keys %{$refschema->{DOMAINS}})
		{
			if (not defined ($known_names{$domain}))
			{
				# Great. Just skip to the next and remember this name
				$known_names{$domain}=1;
			}
			else
			{
				# We rename
				$refschema->{DOMAINS}->{$domain."2pgd"} = $refschema->{DOMAINS}->{$domain};
				delete $refschema->{DOMAINS}->{$domain};
				print STDERR "Warning: I had to rename domain $domain to ${domain}2pgd because of naming conflicts between a table and a domain, in source schema $schema\n";
				# I also have to check all cols type to rename this
				foreach my $table (values %{$refschema->{TABLES}})
				{
					foreach my $col (values %{$table->{COLS}})
					{
						# If a column has a custom type, it will be prefixed by schema
						# The schema will be the destination schema: dbo may have been replaced by public
						if ($col->{TYPE} eq (dboreplace($schema) . '.' . $domain) ) 
						{
							$col->{TYPE} = dboreplace($schema) . '.' . $domain . "2pgd";
						}
					}
				}
			}

		}

		# Then we scan all indexes
		foreach my $table (keys %{$refschema->{TABLES}})
		{
			foreach my $idx (keys %{$refschema->{TABLES}->{$table}->{INDEXES}})
			{
				if (not defined ($known_names{$idx}))
				{
					# Great. Just skip to the next and remember this name
					$known_names{$idx}=1;
				}
				else
				{
					# We have to rename :/
					# Postfix with a 2pg
					# We have to update the name in the $refschema hash
					$refschema->{TABLES}->{$table}->{INDEXES}->{"$idx"."2pgi"}=$refschema->{TABLES}->{$table}->{INDEXES}->{$idx};
					delete $refschema->{TABLES}->{$table}->{INDEXES}->{$idx};
					print STDERR "Warning: I had to rename index $table.$idx to ${idx}2pgi because of naming conflicts in source schema $schema\n";
					$known_names{$idx . "2pgi"}=1;
				}
			}
		}
	}
}

# Main

# Parse command line
my $kettle=0;
my $help=0;
my $before_file='';
my $after_file='';
my $unsure_file='';

my $options = GetOptions ( "k=s"   => \$kettle,
			   "b=s"   => \$before_file,
			   "a=s"   => \$after_file,
			   "u=s"   => \$unsure_file,
		           "h"     => \$help,
			   "sd=s"  => \$sd,
			   "sh=s"  => \$sh,
			   "sp=s"  => \$sp,
			   "su=s"  => \$su,
			   "sw=s"  => \$sw,
			   "pd=s"  => \$pd,
			   "ph=s"  => \$ph,
			   "pp=s"  => \$pp,
			   "pu=s"  => \$pu,
			   "pw=s"  => \$pw,
			   "f=s"   => \$filename,
			   "i"     => \$case_insensitive,
			   "nr"	   => \$norelabel_dbo,
			   );

if (not $options or $help or not $before_file or not $after_file or not $unsure_file or not $filename)
{
	usage();
	exit 1;
}
if ($kettle and (not $sd or not $sh or not $sp or not $su or not $sw or not $pd or not $ph or not $pp or not $pu or not $pw))
{
	usage();
	print "You have to provide all connection information, if using -k\n";
	exit 1;
}

parse_dump();
#print Dumper($objects);

resolve_name_conflicts();

generate_schema($before_file, $after_file, $unsure_file);


if ( $kettle and (defined $ENV{'HOME'} or defined $ENV{'USERPROFILE'} ) )
{
	check_kettle_properties();
}

generate_kettle($kettle) if ($kettle);




#####################################################################################################################################


# Begin block to load ugly template variables
BEGIN
{
	$template= <<EOF;
<transformation>
  <info>
    <name>__sqlserver_table_name__</name>
    <description/>
    <extended_description/>
    <trans_version/>
    <trans_type>Normal</trans_type>
    <trans_status>0</trans_status>
    <directory>&#47;</directory>
    <parameters>
    </parameters>
    <log>
<trans-log-table><connection/>
<schema/>
<table/>
<size_limit_lines/>
<interval/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STATUS</id><enabled>Y</enabled><name>STATUS</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name><subject/></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name><subject/></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name><subject/></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name><subject/></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name><subject/></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name><subject/></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>STARTDATE</id><enabled>Y</enabled><name>STARTDATE</name></field><field><id>ENDDATE</id><enabled>Y</enabled><name>ENDDATE</name></field><field><id>LOGDATE</id><enabled>Y</enabled><name>LOGDATE</name></field><field><id>DEPDATE</id><enabled>Y</enabled><name>DEPDATE</name></field><field><id>REPLAYDATE</id><enabled>Y</enabled><name>REPLAYDATE</name></field><field><id>LOG_FIELD</id><enabled>Y</enabled><name>LOG_FIELD</name></field></trans-log-table>
<perf-log-table><connection/>
<schema/>
<table/>
<interval/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>SEQ_NR</id><enabled>Y</enabled><name>SEQ_NR</name></field><field><id>LOGDATE</id><enabled>Y</enabled><name>LOGDATE</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STEPNAME</id><enabled>Y</enabled><name>STEPNAME</name></field><field><id>STEP_COPY</id><enabled>Y</enabled><name>STEP_COPY</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>INPUT_BUFFER_ROWS</id><enabled>Y</enabled><name>INPUT_BUFFER_ROWS</name></field><field><id>OUTPUT_BUFFER_ROWS</id><enabled>Y</enabled><name>OUTPUT_BUFFER_ROWS</name></field></perf-log-table>
<channel-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>LOGGING_OBJECT_TYPE</id><enabled>Y</enabled><name>LOGGING_OBJECT_TYPE</name></field><field><id>OBJECT_NAME</id><enabled>Y</enabled><name>OBJECT_NAME</name></field><field><id>OBJECT_COPY</id><enabled>Y</enabled><name>OBJECT_COPY</name></field><field><id>REPOSITORY_DIRECTORY</id><enabled>Y</enabled><name>REPOSITORY_DIRECTORY</name></field><field><id>FILENAME</id><enabled>Y</enabled><name>FILENAME</name></field><field><id>OBJECT_ID</id><enabled>Y</enabled><name>OBJECT_ID</name></field><field><id>OBJECT_REVISION</id><enabled>Y</enabled><name>OBJECT_REVISION</name></field><field><id>PARENT_CHANNEL_ID</id><enabled>Y</enabled><name>PARENT_CHANNEL_ID</name></field><field><id>ROOT_CHANNEL_ID</id><enabled>Y</enabled><name>ROOT_CHANNEL_ID</name></field></channel-log-table>
<step-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STEPNAME</id><enabled>Y</enabled><name>STEPNAME</name></field><field><id>STEP_COPY</id><enabled>Y</enabled><name>STEP_COPY</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>LOG_FIELD</id><enabled>N</enabled><name>LOG_FIELD</name></field></step-log-table>
    </log>
    <maxdate>
      <connection/>
      <table/>
      <field/>
      <offset>0.0</offset>
      <maxdiff>0.0</maxdiff>
    </maxdate>
    <size_rowset>2000</size_rowset>
    <sleep_time_empty>50</sleep_time_empty>
    <sleep_time_full>50</sleep_time_full>
    <unique_connections>N</unique_connections>
    <feedback_shown>Y</feedback_shown>
    <feedback_size>50000</feedback_size>
    <using_thread_priorities>Y</using_thread_priorities>
    <shared_objects_file/>
    <capture_step_performance>N</capture_step_performance>
    <step_performance_capturing_delay>1000</step_performance_capturing_delay>
    <step_performance_capturing_size_limit>100</step_performance_capturing_size_limit>
    <dependencies>
    </dependencies>
    <partitionschemas>
    </partitionschemas>
    <slaveservers>
    </slaveservers>
    <clusterschemas>
    </clusterschemas>
  <created_user>-</created_user>
  <created_date>2013&#47;02&#47;28 14:04:49.560</created_date>
  <modified_user>-</modified_user>
  <modified_date>2013&#47;04&#47;08 11:49:18.185</modified_date>
  </info>
  <notepads>
  </notepads>
  <connection>
    <name>__sqlserver_db__</name>
    <server>__sqlserver_host__</server>
    <type>MSSQL</type>
    <access>Native</access>
    <database>__sqlserver_database__</database>
    <port>__sqlserver_port__</port>
    <username>__sqlserver_username__</username>
    <password>__sqlserver_password__</password>
    <servername/>
    <data_tablespace/>
    <index_tablespace/>
    <attributes>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>N</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>N</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>
  <connection>
    <name>__postgres_db__</name>
    <server>__postgres_host__</server>
    <type>POSTGRESQL</type>
    <access>Native</access>
    <database>__postgres_database__</database>
    <port>__postgres_port__</port>
    <username>__postgres_username__</username>
    <password>__postgres_password__</password>
    <servername/>
    <data_tablespace/>
    <index_tablespace/>
    <attributes>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>N</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>
  <order>
  <hop> <from>Table input</from><to>Modified Java Script Value</to><enabled>Y</enabled> </hop>  <hop> <from>Modified Java Script Value</from><to>Table output</to><enabled>Y</enabled> </hop>  </order>
  <step>
    <name>Modified Java Script Value</name>
    <type>ScriptValueMod</type>
    <description/>
    <distribute>Y</distribute>
    <copies>4</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <compatible>N</compatible>
    <optimizationLevel>9</optimizationLevel>
    <jsScripts>      <jsScript>        <jsScript_type>0</jsScript_type>
        <jsScript_name>Script 1</jsScript_name>
        <jsScript_script>for (var i=0;i&lt;getInputRowMeta().size();i++) { 
  var valueMeta = getInputRowMeta().getValueMeta(i);
  if (valueMeta.getTypeDesc().equals(&quot;String&quot;)) {
    row[i]=replace(row[i],&quot;\\00&quot;,&apos;&apos;);
  }
}</jsScript_script>
      </jsScript>    </jsScripts>    <fields>    </fields>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>243</xloc>
      <yloc>159</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table input</name>
    <type>TableInput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__sqlserver_db__</connection>
    <sql>SELECT * FROM __sqlserver_table_name__ WITH(NOLOCK)</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table output</name>
    <type>TableOutput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>4</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <schema/>
    <table>__postgres_table_name__</table>
    <commit>500</commit>
    <truncate>Y</truncate>
    <ignore_errors>N</ignore_errors>
    <use_batch>Y</use_batch>
    <specify_fields>N</specify_fields>
    <partitioning_enabled>N</partitioning_enabled>
    <partitioning_field/>
    <partitioning_daily>N</partitioning_daily>
    <partitioning_monthly>Y</partitioning_monthly>
    <tablename_in_field>N</tablename_in_field>
    <tablename_field/>
    <tablename_in_table>Y</tablename_in_table>
    <return_keys>N</return_keys>
    <return_field/>
    <fields>
    </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>371</xloc>
      <yloc>158</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step_error_handling>
  </step_error_handling>
   <slave-step-copy-partition-distribution>
</slave-step-copy-partition-distribution>
   <slave_transformation>N</slave_transformation>
</transformation>
EOF
####################################################################################
	$template_lob= <<EOF;
<transformation>
  <info>
    <name>__sqlserver_table_name__</name>
    <description/>
    <extended_description/>
    <trans_version/>
    <trans_type>Normal</trans_type>
    <trans_status>0</trans_status>
    <directory>&#47;</directory>
    <parameters>
    </parameters>
    <log>
<trans-log-table><connection/>
<schema/>
<table/>
<size_limit_lines/>
<interval/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STATUS</id><enabled>Y</enabled><name>STATUS</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name><subject/></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name><subject/></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name><subject/></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name><subject/></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name><subject/></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name><subject/></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>STARTDATE</id><enabled>Y</enabled><name>STARTDATE</name></field><field><id>ENDDATE</id><enabled>Y</enabled><name>ENDDATE</name></field><field><id>LOGDATE</id><enabled>Y</enabled><name>LOGDATE</name></field><field><id>DEPDATE</id><enabled>Y</enabled><name>DEPDATE</name></field><field><id>REPLAYDATE</id><enabled>Y</enabled><name>REPLAYDATE</name></field><field><id>LOG_FIELD</id><enabled>Y</enabled><name>LOG_FIELD</name></field></trans-log-table>
<perf-log-table><connection/>
<schema/>
<table/>
<interval/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>SEQ_NR</id><enabled>Y</enabled><name>SEQ_NR</name></field><field><id>LOGDATE</id><enabled>Y</enabled><name>LOGDATE</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STEPNAME</id><enabled>Y</enabled><name>STEPNAME</name></field><field><id>STEP_COPY</id><enabled>Y</enabled><name>STEP_COPY</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>INPUT_BUFFER_ROWS</id><enabled>Y</enabled><name>INPUT_BUFFER_ROWS</name></field><field><id>OUTPUT_BUFFER_ROWS</id><enabled>Y</enabled><name>OUTPUT_BUFFER_ROWS</name></field></perf-log-table>
<channel-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>LOGGING_OBJECT_TYPE</id><enabled>Y</enabled><name>LOGGING_OBJECT_TYPE</name></field><field><id>OBJECT_NAME</id><enabled>Y</enabled><name>OBJECT_NAME</name></field><field><id>OBJECT_COPY</id><enabled>Y</enabled><name>OBJECT_COPY</name></field><field><id>REPOSITORY_DIRECTORY</id><enabled>Y</enabled><name>REPOSITORY_DIRECTORY</name></field><field><id>FILENAME</id><enabled>Y</enabled><name>FILENAME</name></field><field><id>OBJECT_ID</id><enabled>Y</enabled><name>OBJECT_ID</name></field><field><id>OBJECT_REVISION</id><enabled>Y</enabled><name>OBJECT_REVISION</name></field><field><id>PARENT_CHANNEL_ID</id><enabled>Y</enabled><name>PARENT_CHANNEL_ID</name></field><field><id>ROOT_CHANNEL_ID</id><enabled>Y</enabled><name>ROOT_CHANNEL_ID</name></field></channel-log-table>
<step-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>TRANSNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>STEPNAME</id><enabled>Y</enabled><name>STEPNAME</name></field><field><id>STEP_COPY</id><enabled>Y</enabled><name>STEP_COPY</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>LOG_FIELD</id><enabled>N</enabled><name>LOG_FIELD</name></field></step-log-table>
    </log>
    <maxdate>
      <connection/>
      <table/>
      <field/>
      <offset>0.0</offset>
      <maxdiff>0.0</maxdiff>
    </maxdate>
    <size_rowset>100</size_rowset>
    <sleep_time_empty>50</sleep_time_empty>
    <sleep_time_full>50</sleep_time_full>
    <unique_connections>N</unique_connections>
    <feedback_shown>Y</feedback_shown>
    <feedback_size>1000</feedback_size>
    <using_thread_priorities>Y</using_thread_priorities>
    <shared_objects_file/>
    <capture_step_performance>N</capture_step_performance>
    <step_performance_capturing_delay>1000</step_performance_capturing_delay>
    <step_performance_capturing_size_limit>100</step_performance_capturing_size_limit>
    <dependencies>
    </dependencies>
    <partitionschemas>
    </partitionschemas>
    <slaveservers>
    </slaveservers>
    <clusterschemas>
    </clusterschemas>
  <created_user>-</created_user>
  <created_date>2013&#47;02&#47;28 14:04:49.560</created_date>
  <modified_user>-</modified_user>
  <modified_date>2013&#47;04&#47;08 11:49:18.185</modified_date>
  </info>
  <notepads>
  </notepads>
  <connection>
    <name>__sqlserver_db__</name>
    <server>__sqlserver_host__</server>
    <type>MSSQL</type>
    <access>Native</access>
    <database>__sqlserver_database__</database>
    <port>__sqlserver_port__</port>
    <username>__sqlserver_username__</username>
    <password>__sqlserver_password__</password>
    <servername/>
    <data_tablespace/>
    <index_tablespace/>
    <attributes>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>N</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>N</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>
  <connection>
    <name>__postgres_db__</name>
    <server>__postgres_host__</server>
    <type>POSTGRESQL</type>
    <access>Native</access>
    <database>__postgres_database__</database>
    <port>__postgres_port__</port>
    <username>__postgres_username__</username>
    <password>__postgres_password__</password>
    <servername/>
    <data_tablespace/>
    <index_tablespace/>
    <attributes>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>N</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>
  <order>
  <hop> <from>Table input</from><to>Modified Java Script Value</to><enabled>Y</enabled> </hop>  <hop> <from>Modified Java Script Value</from><to>Table output</to><enabled>Y</enabled> </hop>  </order>
  <step>
    <name>Modified Java Script Value</name>
    <type>ScriptValueMod</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__sqlserver_copies__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <compatible>N</compatible>
    <optimizationLevel>9</optimizationLevel>
    <jsScripts>      <jsScript>        <jsScript_type>0</jsScript_type>
        <jsScript_name>Script 1</jsScript_name>
        <jsScript_script>for (var i=0;i&lt;getInputRowMeta().size();i++) { 
  var valueMeta = getInputRowMeta().getValueMeta(i);
  if (valueMeta.getTypeDesc().equals(&quot;String&quot;)) {
    row[i]=replace(row[i],&quot;\\00&quot;,&apos;&apos;);
  }
}</jsScript_script>
      </jsScript>    </jsScripts>    <fields>    </fields>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>243</xloc>
      <yloc>159</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table input</name>
    <type>TableInput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__sqlserver_copies__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__sqlserver_db__</connection>
    <sql>SELECT * FROM __sqlserver_table_name__ WITH(NOLOCK) __sqlserver_where_filter__</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table output</name>
    <type>TableOutput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>4</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <schema/>
    <table>__postgres_table_name__</table>
    <commit>100</commit>
    <truncate>Y</truncate>
    <ignore_errors>N</ignore_errors>
    <use_batch>Y</use_batch>
    <specify_fields>N</specify_fields>
    <partitioning_enabled>N</partitioning_enabled>
    <partitioning_field/>
    <partitioning_daily>N</partitioning_daily>
    <partitioning_monthly>Y</partitioning_monthly>
    <tablename_in_field>N</tablename_in_field>
    <tablename_field/>
    <tablename_in_table>Y</tablename_in_table>
    <return_keys>N</return_keys>
    <return_field/>
    <fields>
    </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>371</xloc>
      <yloc>158</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step_error_handling>
  </step_error_handling>
   <slave-step-copy-partition-distribution>
</slave-step-copy-partition-distribution>
   <slave_transformation>N</slave_transformation>
</transformation>
EOF
####################################################################################

	$job_header= <<EOF;
<job>
  <name>Migration</name>
    <description/>
    <extended_description/>
    <job_version/>
    <job_status>0</job_status>
  <directory>&#47;</directory>
  <created_user>-</created_user>
  <created_date>2013&#47;04&#47;08 14:05:05.685</created_date>
  <modified_user>-</modified_user>
  <modified_date>2013&#47;04&#47;08 14:08:27.625</modified_date>
    <parameters>
    </parameters>
    <slaveservers>
    </slaveservers>
<job-log-table><connection/>
<schema/>
<table/>
<size_limit_lines/>
<interval/>
<timeout_days/>
<field><id>ID_JOB</id><enabled>Y</enabled><name>ID_JOB</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>JOBNAME</id><enabled>Y</enabled><name>JOBNAME</name></field><field><id>STATUS</id><enabled>Y</enabled><name>STATUS</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>STARTDATE</id><enabled>Y</enabled><name>STARTDATE</name></field><field><id>ENDDATE</id><enabled>Y</enabled><name>ENDDATE</name></field><field><id>LOGDATE</id><enabled>Y</enabled><name>LOGDATE</name></field><field><id>DEPDATE</id><enabled>Y</enabled><name>DEPDATE</name></field><field><id>REPLAYDATE</id><enabled>Y</enabled><name>REPLAYDATE</name></field><field><id>LOG_FIELD</id><enabled>Y</enabled><name>LOG_FIELD</name></field></job-log-table>
<jobentry-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>JOBNAME</id><enabled>Y</enabled><name>TRANSNAME</name></field><field><id>JOBENTRYNAME</id><enabled>Y</enabled><name>STEPNAME</name></field><field><id>LINES_READ</id><enabled>Y</enabled><name>LINES_READ</name></field><field><id>LINES_WRITTEN</id><enabled>Y</enabled><name>LINES_WRITTEN</name></field><field><id>LINES_UPDATED</id><enabled>Y</enabled><name>LINES_UPDATED</name></field><field><id>LINES_INPUT</id><enabled>Y</enabled><name>LINES_INPUT</name></field><field><id>LINES_OUTPUT</id><enabled>Y</enabled><name>LINES_OUTPUT</name></field><field><id>LINES_REJECTED</id><enabled>Y</enabled><name>LINES_REJECTED</name></field><field><id>ERRORS</id><enabled>Y</enabled><name>ERRORS</name></field><field><id>RESULT</id><enabled>Y</enabled><name>RESULT</name></field><field><id>NR_RESULT_ROWS</id><enabled>Y</enabled><name>NR_RESULT_ROWS</name></field><field><id>NR_RESULT_FILES</id><enabled>Y</enabled><name>NR_RESULT_FILES</name></field><field><id>LOG_FIELD</id><enabled>N</enabled><name>LOG_FIELD</name></field><field><id>COPY_NR</id><enabled>N</enabled><name>COPY_NR</name></field></jobentry-log-table>
<channel-log-table><connection/>
<schema/>
<table/>
<timeout_days/>
<field><id>ID_BATCH</id><enabled>Y</enabled><name>ID_BATCH</name></field><field><id>CHANNEL_ID</id><enabled>Y</enabled><name>CHANNEL_ID</name></field><field><id>LOG_DATE</id><enabled>Y</enabled><name>LOG_DATE</name></field><field><id>LOGGING_OBJECT_TYPE</id><enabled>Y</enabled><name>LOGGING_OBJECT_TYPE</name></field><field><id>OBJECT_NAME</id><enabled>Y</enabled><name>OBJECT_NAME</name></field><field><id>OBJECT_COPY</id><enabled>Y</enabled><name>OBJECT_COPY</name></field><field><id>REPOSITORY_DIRECTORY</id><enabled>Y</enabled><name>REPOSITORY_DIRECTORY</name></field><field><id>FILENAME</id><enabled>Y</enabled><name>FILENAME</name></field><field><id>OBJECT_ID</id><enabled>Y</enabled><name>OBJECT_ID</name></field><field><id>OBJECT_REVISION</id><enabled>Y</enabled><name>OBJECT_REVISION</name></field><field><id>PARENT_CHANNEL_ID</id><enabled>Y</enabled><name>PARENT_CHANNEL_ID</name></field><field><id>ROOT_CHANNEL_ID</id><enabled>Y</enabled><name>ROOT_CHANNEL_ID</name></field></channel-log-table>
   <pass_batchid>N</pass_batchid>
   <shared_objects_file/>
  <entries>
    <entry>
      <name>START</name>
      <description/>
      <type>SPECIAL</type>
      <start>Y</start>
      <dummy>N</dummy>
      <repeat>N</repeat>
      <schedulerType>0</schedulerType>
      <intervalSeconds>0</intervalSeconds>
      <intervalMinutes>60</intervalMinutes>
      <hour>12</hour>
      <minutes>0</minutes>
      <weekDay>1</weekDay>
      <DayOfMonth>1</DayOfMonth>
      <parallel>N</parallel>
      <draw>Y</draw>
      <nr>0</nr>
      <xloc>38</xloc>
      <yloc>73</yloc>
      </entry>
EOF
####################################################################################

	$job_middle= <<EOF;
  </entries>
  <hops>
EOF
####################################################################################

	$job_footer= <<EOF;
  </hops>
  <notepads>
  </notepads>
</job>
EOF
####################################################################################

	$job_entry= <<EOF;
    <entry>
      <name>__table_name__</name>
      <description/>
      <type>TRANS</type>
      <specification_method>filename</specification_method>
      <trans_object_id/>
      <filename>__file_name__</filename>
      <transname/>
      <arg_from_previous>N</arg_from_previous>
      <params_from_previous>N</params_from_previous>
      <exec_per_row>N</exec_per_row>
      <clear_rows>N</clear_rows>
      <clear_files>N</clear_files>
      <set_logfile>N</set_logfile>
      <logfile/>
      <logext/>
      <add_date>N</add_date>
      <add_time>N</add_time>
      <loglevel>Basic</loglevel>
      <cluster>N</cluster>
      <slave_server_name/>
      <set_append_logfile>N</set_append_logfile>
      <wait_until_finished>Y</wait_until_finished>
      <follow_abort_remote>N</follow_abort_remote>
      <create_parent_folder>N</create_parent_folder>
      <parameters>        <pass_all_parameters>Y</pass_all_parameters>
      </parameters>      <parallel>N</parallel>
      <draw>Y</draw>
      <nr>0</nr>
      <xloc>197</xloc>
      <yloc>__y_loc__</yloc>
      </entry>
EOF
####################################################################################

	$job_hop= <<EOF;
    <hop>
      <from>__table_1__</from>
      <to>__table_2__</to>
      <from_nr>0</from_nr>
      <to_nr>0</to_nr>
      <enabled>Y</enabled>
      <evaluation>Y</evaluation>
      <unconditional>N</unconditional>
    </hop>
EOF
####################################################################################

}
