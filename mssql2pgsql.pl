#!/usr/bin/perl -w

# This script takes a sql server SQL schema dump, and creates a postgresql dump
# Optionnaly, if asked, generate a kettle job to transfer all data. This is done via -k dir

use Getopt::Long;
use Data::Dumper;
use Cwd;
use Encode::Guess;

use strict;



# Global table definition structure: we need it to store all seen tables, detect which ones have LOBS (different kettle job)
# and if their PK is a simple integer (so we can parallelize readings on these tables)
# For now used only by kettle, but who knows
# The structure is like this:
# %tablestruct = {
#           'TABLES' => {
#                         'EmailsTrafficStat' => {
#                                                  'haslobs' => 0,
#                                                   'PK' => [
#                                                             'AccountGroupId',
#                                                             'Locale'
#                                                  'cols' => {
#                                                              'EmailOrigin' => {
#                                                                                 'TYPE' => 'varchar(32)',
#                                                                                 'POS' => 3
#                                                                               },
#                                                              'EmailLength' => {
#                                                                                 'TYPE' => 'int',
#                                                                                 'POS' => 4
#                                                                               },
#                                                              'EmailDate' => {
#                                                                               'TYPE' => 'timestamp',
#                                                                               'POS' => 1
#                                                                             },
#                                                              'TrafficType' => {
#                                                                                 'TYPE' => 'int',
#                                                                                 'POS' => 2
#                                                                               }
#                                                            }
#                                                },
# 
my %tablestruct;


my ($sd,$sh,$sp,$su,$sw,$pd,$ph,$pp,$pu,$pw);# Connection args
my $filename;# Filename passed as arg
my $case_insensitive=0; # Passed as arg: was SQL Server installation case insensitive

my $template;     # These two variables are loaded in the BEGIN block at the end (they are very big, putting them there
my $template_lob; # won't pollute the code as much)

my ($job_header,$job_middle,$job_footer); # These are used to create the static parts of the job
my ($job_entry,$job_hop); # These are used to create the dynamic parts of the job


my %types=('int'=>'int',
           'nvarchar'=>'varchar',
           'nchar'=>'char',
	   'varchar'=>'varchar',
	   'char'=>'char',
	   'smallint'=>'smallint',
	   'tinyint'=>'smallint',
	   'datetime'=>'timestamp',
           'char'=>'char',
	   'image'=>'bytea',
	   'text'=>'text',
	   'bigint'=>'bigint',
	   'timestamp'=>'timestamp',
	   'numeric'=>'numeric',
	   'decimal'=>'numeric'
	   );
sub convert_type
{
	my ($sqlstype,$sqlqual,$colname,$tablename,$typname)=@_;
	my $rettype;
	if (defined $types{$sqlstype})
	{
		if (defined $sqlqual)
		{
			$rettype= ($types{$sqlstype}."($sqlqual)");
		}
		else
		{
			$rettype= $types{$sqlstype};
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
	die "Cannot determine the PostgreSQL's datatype corresponding to $sqlstype\n" unless $rettype;
	# We special case when type is varchar, to be case insensitive
	if ($sqlstype =~ /text|varchar/ and $case_insensitive)
	{
		$rettype="citext";
		# Do we have a SQL Qual ? (we'll have to do check constraints then)
		if ($sqlqual)
		{
			# Check we have a table name and a colname, or a typname
			if (defined $colname and defined $tablename) # We are called from a CREATE TABLE, we have to add a check constraint
			{
				print AFTER "ALTER TABLE $tablename ADD CHECK (char_length($colname) <= $sqlqual);\n";
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
	print "$0 [-k kettle_output_directory] -b before_file -a after_file -f sql_server_schema_file[-h] [-i]\n";
	print "\nExpects a SQL Server SQL structure dump as -f (preferably unicode)\n";
	print "-i tells PostgreSQL to create a case-insensitive PostgreSQL schema\n";
	print "before_file contains the structure\n";
	print "after_file contains index, constraints\n";
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

# This function generates kettle transformations, and a kettle job, for all tables
sub generate_kettle
{
	my ($dir)=@_;
	# first, create the kettle directory
	unless (-d $dir)
	{
		mkdir ($dir) or die "Cannot create $dir, $!\n";
	}
	# For each table in %tablestruct, we generate a kettle file in the directory

	foreach my $table (keys %{$tablestruct{TABLES}})
	{
		# First, does this table have LOBs ? The template depends on this
		my $newtemplate;
		if ($tablestruct{TABLES}->{$table}->{haslobs})
		{
			$newtemplate=$template_lob;
			# Is the PK int and on only one column ?
			# If yes, we can use several threads to read this table
			if (scalar(@{$tablestruct{TABLES}->{$table}->{PK}})==1
			    and
			    ($tablestruct{TABLES}->{$table}->{cols}->{($tablestruct{TABLES}->{$table}->{PK}->[0])}->{TYPE} =~ /int$/)
			   )
			{
				my $wherefilter='WHERE ' . $tablestruct{TABLES}->{$table}->{PK}->[0]
				. '% ${Internal.Step.Unique.Count} = ${Internal.Step.Unique.Number}';
				$newtemplate =~ s/__sqlserver_where_filter__/$wherefilter/;
				$newtemplate =~ s/__sqlserver_copies__/4/g;
			}
			else
			# No way to do this optimization
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
		$newtemplate =~ s/__sqlserver_table_name__/$table/g;
		$newtemplate =~ s/__postgres_table_name__/$table/g;
		# Store this new transformation into its file
		open FILE, ">$dir/$table.ktr" or die "Cannot write to $dir/$table.ktr, $!\n";
		print FILE $newtemplate;
		close FILE;
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
	foreach my $table (sort {lc($a) cmp lc($b)}keys %{$tablestruct{TABLES}})
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
	
	print FILE $job_header;
	print FILE $entries;
	print FILE $job_middle;
	print FILE $hops;
	print FILE $job_footer;
	close FILE;


}




# Parse command line
my $kettle=0;
my $help=0;
my $before_file='';
my $after_file='';

my $options = GetOptions ( "k=s"   => \$kettle,
			   "b=s"   => \$before_file,
			   "a=s"   => \$after_file,
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
			   );

if (not $options or $help or not $before_file or not $after_file or not $filename)
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

# Open the input file or die. This first pass is to detect encoding, and open it correctly afterwards
my $data;
open IN,"<$filename" or die "Cannot open $filename, $!\n";
while (my $line=<IN>)
{
	$data.=$line;
}
close IN;

# We now ask guess...
my $decoder=guess_encoding($data, qw/iso8859-15/);
die $decoder unless ref($decoder);

# If we got to here, it means we have found the right decoder
open IN,"<:encoding(".$decoder->name.")",$filename or die "Cannot open $filename, $!\n";

# Open the output files (except kettle, we'll do that at the end)
open BEFORE,">:utf8",$before_file or die "Cannot open $before_file, $!\n";
open AFTER,">:utf8",$after_file or die "Cannot open $after_file, $!\n";

# Parsing loop variables
my $create_table=0; # Are we in a create table statement ?
my $table_name=''; # If yes, what's the table name ?
my $colnumber=0; # Column number (just to put the commas in the right places) ?

print BEFORE "\\set ON_ERROR_STOP\n";
print BEFORE "BEGIN;\n";
print AFTER "\\set ON_ERROR_STOP\n";
print AFTER "BEGIN;\n";

# Are we case insensitive ? We have to install citext then
if ($case_insensitive)
{
	print BEFORE "CREATE EXTENSION citext;\n";
}

MAIN: while (my $line=<IN>)
{
	if ($line =~ /^CREATE TABLE \[.*\]\.\[(.*)\]\(/)
	{
		$create_table=1;
		$table_name=$1;
		$colnumber=0;
		print BEFORE "CREATE TABLE $table_name (\n";
		$tablestruct{'TABLES'}->{$table_name}->{haslobs}=0;
	}
	elsif ($line =~ /^\t\[(.*)\] (?:\[.*\]\.)?\[(.*)\](\(.+?\))?( IDENTITY\(\d+,\s*\d+\))? (NOT NULL|NULL)(,)?/)
	{
		if ($create_table) # We are inside a create table, this is a column definition
		{
			$colnumber++;
			my $colname=$1;
			my $coltype=$2;
			my $colqual=$3;
			my $isidentity=$4;
			my $colisnull=$5;
			my $col=$colname;
			if ($colqual)
			{
				# We need the number (or 2 numbers) in this qual
				$colqual=~ /\((\d+(?:,\s*\d+)?)\)/ or die "Cannot parse colqual <$colqual>\n"; 
				$colqual= "$1";
			}
			my $newtype=convert_type($coltype,$colqual,$colname,$table_name);
			# If it is an identity, we'll map to serial/bigserial
			if ($isidentity)
			{
				# We have an identity field. We set the default value and
				# initialize the sequence correctly in the after script
				$isidentity=~ /IDENTITY\((\d+),\s*(\d+)\)/ or die "Cannot understand <$isidentity>\n";
				my $startseq=$1;
				my $stepseq=$2;
				print AFTER "CREATE SEQUENCE ".lc("${table_name}_${colname}_seq")." INCREMENT BY $stepseq START WITH $startseq OWNED BY ${table_name}.${colname};\n";
				print AFTER "ALTER TABLE ${table_name} ALTER COLUMN $colname SET DEFAULT nextval('".lc("${table_name}_${colname}_seq")."');\n";

			}
			$col .= " " . $newtype;
			# If there is a bytea generated, this table will contain a blob:
			# use a special kettle transformation for it if generating kettle
			if ($newtype eq 'bytea' or $coltype eq 'ntext') # Ntext is very slow, stored out of page
			{
				$tablestruct{'TABLES'}->{$table_name}->{haslobs}=1;
			}
			# We store the datatype for each table in the global hash. Will be needed by kettle
			$tablestruct{'TABLES'}->{$table_name}->{cols}->{$colname}->{POS}=$colnumber;
			$tablestruct{'TABLES'}->{$table_name}->{cols}->{$colname}->{TYPE}=$newtype;

			
			if ($colisnull eq 'NOT NULL')
			{
				$col .= " NOT NULL";
			}
			if ($colnumber>1)
			{
				print BEFORE ",";
			}
			print BEFORE $col,"\n";
		}
		else
		{
			die "I don't understand $line. This is a bug\n";
		}
	}
	elsif ($line =~ /^(?: CONSTRAINT \[(.*)\] )?PRIMARY KEY (?:NON)?CLUSTERED/)
	{
		die "PK defined outside a table\n: $line" unless ($create_table); # This is not forbidden by SQL, of course. I just never saw this in a sql server dump, so it should be an error for now (it will be syntaxically different if outside a table anyhow)
		if (defined $1)
		{
			print AFTER "ALTER TABLE $table_name ADD CONSTRAINT $1 PRIMARY KEY ( ";
		}
		else
		{
			print AFTER "ALTER TABLE $table_name ADD PRIMARY KEY ( ";
		}

		# Here is the PK. We read following lines until the end of the constraint
		while (my $pk=<IN>)
		{
			# Exit when read a line beginning with ). The constraint is complete
			if ($pk =~ /^\)/)
			{
				print AFTER ");\n";
				next MAIN;
			}
			if ($pk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
			{
				print AFTER "$1 $3"; # PG doesn't have ASC/DESC in the PK definition, it seems
				push (@{$tablestruct{'TABLES'}->{$table_name}->{PK}},($1));
			}
		}
	}
	elsif ($line =~ /^\s*(?:CONSTRAINT \[(.*)\] )?UNIQUE/)
	{
		if (defined $1)
		{
			print AFTER "ALTER TABLE $table_name ADD CONSTRAINT $1 UNIQUE (";
		}
		else
		{
			print AFTER "ALTER TABLE $table_name ADD UNIQUE (";
		}
		# Unique key definition. We read following lines until the end of the constraint
		while (my $uk=<IN>)
		{
			# Exit when read a line beginning with ). The constraint is complete
			if ($uk =~ /^\)/)
			{
				print AFTER ");";
				next MAIN;
			}
			if ($uk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
			{
				print AFTER "$1 $3"; # No ASC/DESC in UNIQUE constraint either
			}
		}

	}
	# Ignore USE, GO, and things that have no meaning for postgresql
	elsif ($line =~ /^USE\s|^GO\s*$|\/\*\*\*\*|^SET ANSI_NULLS ON|^SET QUOTED_IDENTIFIER ON|^SET ANSI_PADDING|CHECK CONSTRAINT/)
	{
		next;
	}
	# Don't know what it is. If you have an idea, and it is worth converting, tell me :)
	elsif ($line =~ /^EXEC .*bindrule/)
	{
		next;
	}
	# Ignore users and roles
	elsif ($line =~ /^CREATE (ROLE|USER)/)
	{
		next;
	}
	elsif ($line =~ /^CREATE TYPE \[.*?\]\.\[(.*?)\] FROM \[(.*?)](?:\((\d+(?:,\s*\d+)?)?\))?/)
	{
		my $newtype=convert_type($2,$3,undef,undef,$1);
		print BEFORE "CREATE DOMAIN $1 $newtype;\n";
		# We add them to known data types, as they probably will be used
		$types{$1}=$1;
	}
	elsif ($line =~ /^\) ON \[PRIMARY\]/)
	{
		# Fin de la table
		print BEFORE ");\n";
		$create_table=0;
		$table_name='';
	}
	elsif ($line =~ /^CREATE (UNIQUE )?NONCLUSTERED INDEX \[(.*)\] ON \[.*\]\.\[(.*)\]/)
	{
		# Creation d'index
		no warnings;
		print AFTER "CREATE $1INDEX $2 ON $3 (";
		use warnings;
		while (my $idx=<IN>)
		{
			# Exit when read a line beginning with ). The index is complete
			if ($idx =~ /^\)/)
			{
				print AFTER ");\n";
				next MAIN;
			}
			next if ($idx =~ /^\(/); # Begin of the columns declaration
			if ($idx =~ /\t\[(.*)\] (ASC|DESC)(,)?/)
			{
				no warnings;
				print AFTER "$1 $2 $3";
				use warnings;
			}
		}
	}
	elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \(\(((?:-)?\d+)\)\) FOR \[(.*)\]/)
	{
		# Default value, for a numeric (yes sql server puts it in another pair of parenthesis, don't know why)
		print AFTER "ALTER TABLE $1 ALTER COLUMN $3 SET DEFAULT $2;\n";
	}
	elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \('(.*)'\) FOR \[(.*)\]/)
	{
		# Default text value, text, between commas
		print AFTER "ALTER TABLE $1 ALTER COLUMN $3 SET DEFAULT '$2';\n";
	}
	elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \((\d)\) FOR \[(.*)\]/)
	{
		# Weird one: for bit type, there is no supplementary parenthesis... for now, let's say this is a bit type, and
		# convert to true/false
		if ($2 eq '0')
		{
			print AFTER "ALTER TABLE $1 ALTER COLUMN $3 SET DEFAULT false;\n";
		}
		elsif ($2 eq '1')
		{
			print AFTER "ALTER TABLE $1 ALTER COLUMN $3 SET DEFAULT true;\n";
		}
		else
		{
			die "not expected for a boolean: $line $. This is a bug\n"; # Get an error if the true/false hypothesis is wrong
		}
	}
	elsif ($line =~ /^ALTER TABLE \[.*\]\.\[(.*)\]\s+WITH (?:NO)?CHECK ADD\s+CONSTRAINT \[(.*)\] FOREIGN KEY\((.*?)\)/)
	{
		# This is a FK definition. We have the foreign table definition in next line.
		my $normalized_columns=$3;
		my $table=$1;
		my $constraint=$2;
		$normalized_columns=~ s/\[|\]//g; # Suppression des crochets
		print AFTER "ALTER TABLE $table ADD CONSTRAINT $constraint FOREIGN KEY ($normalized_columns) ";
		while (my $fk = <IN>)
		{
			if ($fk =~ /^GO/)
			{
				print AFTER ";\n";
				next MAIN;
			}
			elsif ($fk =~ /^REFERENCES \[.*\]\.\[(.*)\] \((.*?)\)/)
			{
				$normalized_columns=$2;
				$table=$1;
				$normalized_columns=~ s/\[|\]//g; # Get rid of square brackets
				print AFTER "REFERENCES $table ($normalized_columns)";
			}
			elsif ($fk =~ /^ON DELETE CASCADE\s*$/)
			{
				print AFTER "ON DELETE CASCADE ";
			}
			else
			{
				die "Cannot parse $fk $., in a FK. This is a bug\n";
			}
		}
	}
	elsif ($line =~ /ALTER TABLE \[.*\]\.\[(.*)\]  WITH (?:NO)?CHECK ADD  CONSTRAINT \[(.*)\] CHECK  ((.*))/ )
	{
		# Check constraint. We'll do what we can
		my $table=$1;
		my $consname=$2;
		my $constxt=$3;
		$constxt =~ s/\[(\S+)\]/$1/g; # We remove the []. And hope this will parse
		print AFTER "ALTER TABLE $table ADD CONSTRAINT $consname CHECK ($constxt);\n";
	}
	elsif ($line =~ /^EXEC sys.sp_addextendedproperty/)
	{ 
		# These are comments on objets. They can be multiline, so aggregate everything 
		# Until next GO command
		my $sqlcomment=$line;
		while (my $inline=<IN>)
		{
			last if ($inline =~ /^GO/);
			$sqlcomment.=$inline
		}
		# Remove CR character... no place here
		$sqlcomment =~ s/\r//g;
		# We have all the comment. Let's parse it.
		# Spaces are mostly random it seems, in SQL Server's dump code. So \s* everywhere :(
		# There can be quotes inside a string. So (?<!')' matches only a ' not preceded by a '.
		$sqlcomment =~ /^EXEC sys.sp_addextendedproperty \@name=N'(.*?)'\s*,\s*\@value=N'(.*?)(?<!')'\s*,\s*\@level0type=N'(.*?)'\s*,\s*\@level0name=N'(.*?)'\s*(?:,\s*\@level1type=N'(.*?)'\s*,\s*\@level1name=N'(.*?)')\s*?(?:,\s*\@level2type=N'(.*?)'\s*,\s*\@level2name=N'(.*?)')?/s;
		my ($comment,$obj,$objname,$subobj,$subobjname)=($2,$5,$6,$7,$8);
		if ($obj eq 'TABLE' and not defined $subobj)
		{
			print AFTER "COMMENT ON TABLE $objname IS '$comment';\n";
		}
		elsif ($obj eq 'TABLE' and $subobj eq 'COLUMN')
		{
			print AFTER "COMMENT ON COLUMN $objname.$subobjname IS '$comment';\n";
		}
		else
		{
			die "Cannot understand this comment: $sqlcomment\n";
		}
	}
	else
	{
		die "Line <$line> ($.) not understood. This is a bug\n";
	}
}

print BEFORE "COMMIT;\n";
print AFTER "COMMIT;\n";
close BEFORE;
close AFTER;
close IN;

#print Dumper(\%tablestruct);

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
