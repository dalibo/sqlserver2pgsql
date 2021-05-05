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
# There is just too many things in it, and it evolves all the time
my $objects;

# These are global variables, from configuration file or command line arguments
our ($sd, $sh, $si, $sp, $su, $sw, $pd, $ph, $pp, $pu, $pw);    # Connection args
our $conf_file;
our $filename;          # Filename passed as arg
our $case_insensitive;  # Passed as arg: was SQL Server installation case insensitive ? PostgreSQL can't ignore accents anyway
                        # If yes, we will generate citext with CHECK constraints, that's the best we can do
our $norelabel_dbo;     # Passed as arg: should we convert DBO to public ?
our $relabel_schemas;
our $convert_numeric_to_int; # Should we convert numerics to int when possible ? (numeric (4,0) could be converted an int, for instance)
our $drop_rowversion; # Should we remove MSSQL timestamp/rowversion columns when converting
our $kettle;
our $before_file;
our $after_file;
our $unsure_file;
our $case_treatment=1; # 1=convert to lowercase, 2=convert to snake_case, 0 do nothing
our $ignore_errors;
our $keep_identifier_case;
our $camel_to_snake;
our $validate_constraints;
our $parallelism_in;
our $parallelism_out;
our $sort_size;
our $use_pk_if_possible;
our $pforce_ssl;
our $stringtype_unspecified;
our $skip_citext_length_check;
our $use_identity_column;

# Will be set if we detect GIS objects
our $requires_postgis=0;

# These three variables are loaded in the BEGIN block at the end of this file (they are very big
my $template;
my $template_lob;
my $incremental_template;
my $incremental_template_sortable_pk;

my ($job_header, $job_middle, $job_footer)
    ;                # These are used to create the static parts of the job
my ($job_entry, $job_hop)
    ;    # These are used to create the dynamic parts of the job (XML file)
my @view_list; # array to keep view ordering from sql server's dump (a view may depend on another view)

# Opens the configuration file
# Sets $sd $sh $si $sp $su $sw $pd $ph $pp $pu $pw when they are not set in the command line already
# Also gets kettle parameters...
sub parse_conf_file
{

   # Correspondance between conf_file parameter and program variable
   # This is also used as the list of accepted parameters in the configuration file
   my %parameters = (
      'sql server database'      => 'sd',
      'sql server host'          => 'sh',
      'sql server host instance' => 'si',
      'sql server port'          => 'sp',
      'sql server username'      => 'su',
      'sql server password'      => 'sw',
      'postgresql database'      => 'pd',
      'postgresql host'          => 'ph',
      'postgresql port'          => 'pp',
      'postgresql username'      => 'pu',
      'postgresql password'      => 'pw',
      'kettle directory'         => 'kettle',
      'parallelism_in'           => 'parallelism_in',
      'parallelism_out'          => 'parallelism_out',
      'before file'              => 'before_file',
      'after file'               => 'after_file',
      'unsure file'              => 'unsure_file',
      'sql server dump filename' => 'filename',
      'case insensitive'         => 'case_insensitive',
      'no relabel dbo'           => 'norelabel_dbo',
      'convert numeric to int'   => 'convert_numeric_to_int',
      'drop rowversion'          => 'drop_rowversion',
      'relabel schemas'          => 'relabel_schemas',
      'keep identifier case'     => 'keep_identifier_case',
      'camelcasetosnake'         => 'camel_to_snake',
      'validate constraints'     => 'validate_constraints',
      'sort size'                => 'sort_size',
      'use pk if possible'       => 'use_pk_if_possible',
      'ignore errors'            => 'ignore_errors',
      'postgresql force ssl'     => 'pforce_ssl',
      'stringtype unspecified'   => 'stringtype_unspecified',
      'skip citext length check' => 'skip_citext_length_check',
      'use identity column'      => 'use_identity_column',
   );

   # Open the conf file or die
   open CONF, $conf_file or die "Cannot open $conf_file";
   while (my $line = <CONF>)
   {
        $line =~ s/#.*//;        # Remove comments
        $line =~ s/\s+=\s+/=/;   # Remove whitespaces around the =
        $line =~ s/\s+$//;       # Remove trailing whitespaces
        next
           if ($line =~ /^$/);  # Empty line after comments have been removed
        $line =~ /^(.*?)=(.*)$/ or die "Cannot parse $line from $conf_file";
        my ($param, $value) = ($1, $2);
        no strict 'refs';        # Using references by name, temporarily
        unless (defined $parameters{$param})
        {
            die "Cannot understand parameter $param in $conf_file";
        }
        my $param_name = $parameters{$param};
        if (defined $$param_name)
        {
            next;                # Parameter overriden in command line
        }
        $$param_name = $value;
        use strict 'refs';
    }

    close CONF;
}

sub set_default_conf_values
{
    # Hard coded default values, set only if not passed or found in configuration
    $case_insensitive=0 unless (defined ($case_insensitive));
    $norelabel_dbo=0 unless (defined ($norelabel_dbo));
    $convert_numeric_to_int=0 unless (defined ($convert_numeric_to_int));
    $drop_rowversion=0 unless (defined ($drop_rowversion));
    $case_treatment=0 if (defined ($keep_identifier_case));
    $case_treatment=2 if (defined ($camel_to_snake));
    $parallelism_in=1 unless (defined ($parallelism_in));# the jdbc driver often errors when there are several sessions to sql server
    $parallelism_out=8 unless (defined ($parallelism_out));
    $sort_size=10000 unless (defined ($sort_size));
    $use_pk_if_possible=0 unless (defined ($use_pk_if_possible));
    $validate_constraints='yes' unless (defined ($validate_constraints));
    $ignore_errors=0 unless (defined ($ignore_errors));
    # Default ports for PostgreSQL and SQL Server
    $pp=5432 unless (defined ($pp));
    $sp=1433 unless (defined ($sp));
    $pforce_ssl=0 unless (defined ($pforce_ssl));
    $stringtype_unspecified=0 unless (defined ($stringtype_unspecified));
    $skip_citext_length_check=0 unless (defined ($skip_citext_length_check));
    $use_identity_column=0 unless (defined ($use_identity_column));
}

# Converts numeric(4,0) and similar to int, bigint, smallint
sub convert_numeric_to_int
{
    my ($qual) = @_;
    croak "not a good qualifier $qual" unless ($qual =~ /^(\d+),\s*(\d+)$/);
    my $precision = $1;
    my $scale     = $2;
    croak "scale should be 0\n" unless ($scale eq '0');
    return 'smallint' if ($precision <= 4);
    return 'integer'  if ($precision <= 9);
    return 'bigint'   if ($precision <= 18);
    return "numeric($qual)";
}

# This is a list of the types that require a cast to be imported in kettle
# C = using CREATE CAST
# S = updating system catalog
my %types_to_cast = ('uuid'  => 'C','date'  => 'C','timestamp with time zone' => 'C','xml'  => 'S');

# This sub adds a cast (if not defined already) if
# - we generate for kettle
# - the passed type is in %types_to_cast
sub add_cast
{
    my ($type)=@_;
    if (defined $types_to_cast{$type})
    {
        $objects->{CASTS}->{$type}=$types_to_cast{$type};
    }
}



# These are the no-brainer conversions
# There is still a special case for text types and case insensitivity (see convert_type) though
my %types = ('int'              => 'int',
             'nvarchar'         => 'varchar',
             'nchar'            => 'char',
             'char'             => 'char',
             'varchar'          => 'varchar',
             'text'             => 'text',
             'char'             => 'char',
             'smallint'         => 'smallint',
             'tinyint'          => 'smallint',
             'bigint'           => 'bigint',
             'decimal'          => 'numeric',
             'float'            => 'double precision',
             'real'             => 'real',
             'date'             => 'date',
             'datetime'         => 'timestamp',
             'datetime2'        => 'timestamp',
             'smalldatetime'    => 'timestamp',
             'time'             => 'time',
             'timestamp'        => 'bytea',
             'rowversion'       => 'bytea',
             'datetimeoffset'   => 'timestamp with time zone',
             'image'            => 'bytea',
             'binary'           => 'bytea',
             'varbinary'        => 'bytea',
             'money'            => 'numeric',
             'smallmoney'       => 'numeric(6,4)',
             'uniqueidentifier' => 'uuid',
             'xml'              => 'xml',);

# Types with no qualifier, and no point in putting one
my %unqual = ('bytea' => 1, 'timestamp with time zone' => 1);

# This function uses the two static lists above, plus domains and citext types that
# may have been created during parsing, to convert mssql's types to pgsql's
sub convert_type
{
    my ($sqlstype, $sqlqual, $colname, $tablename, $typname, $schemaname) =
        @_;
    my $rettype;
    if (defined $types{$sqlstype})
    {
        if ((defined $sqlqual and defined($unqual{$types{$sqlstype}}))
            or not defined $sqlqual)
        {
	   # This is one of the few types that have to be unqualified (binary type)
	   $rettype = $types{$sqlstype};

	   # but we might add a check constraint for binary data
	   if ($sqlstype =~ 'binary' and defined $sqlqual) {
	      print STDERR "convert_type: $sqlstype, $sqlqual, $colname\n";
	      my $constraint;
	      $constraint->{TYPE}  = 'CHECK_BINARY_LENGTH';
	      $constraint->{TABLE} = $tablename;
	      $constraint->{TEXT}  = "octet_length(" . format_identifier($colname) . ") <= $sqlqual";
	      push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                        ->{CONSTRAINTS}}, ($constraint);
	   }
        }
        elsif (defined $sqlqual)
        {
            $rettype = ($types{$sqlstype} . "($sqlqual)");
        }
    }

    # A few special cases
    elsif ($sqlstype eq 'bit' and not defined $sqlqual)
    {
        $rettype = "boolean";
    }
    elsif ($sqlstype eq 'ntext' and not defined $sqlqual)
    {
        $rettype = "text";
    }
    elsif ($sqlstype eq 'numeric')
    {

        # Numeric is a special case:
        # No qualifier. We have to use numeric
        if (not $sqlqual)
        {
            $rettype='numeric';
        }
        elsif ($sqlqual !~ /\d+,\s*0/)
        {
            $rettype="numeric($sqlqual)";
        }
        elsif ( my $tmprettype=convert_numeric_to_int($sqlqual))
        {
            $rettype=$tmprettype;
        }
        else
        {
            $rettype="numeric($sqlqual)";
        }
    }
    elsif ($sqlstype eq 'sysname')
    {
        # Special case. This is an internal type, and should seldom be used in production. Converted to varchar(128)
        $rettype='varchar(128)';
    }

    # We special case also the geometry and geography data types
    elsif ( $sqlstype =~ /^geography$|^geometry$/i )
    {
	# These require that the destination database contains PostGIS
	unless ($requires_postgis)
	{
            print STDERR "WARNING: $sqlstype detected  (in $schemaname.$tablename.$colname).\n  You will need PostGIS (http://postgis.net/).\n  The generated script will perform the CREATE EXTENSION, but please install PostGIS on this server\n";
            $requires_postgis=1;
	}
	$rettype=lc($sqlstype);
    }
    elsif ($sqlstype eq 'sql_variant')
    {
	# There is no equivalent in PostgreSQL (and I think that's a good thing :) )
    	print STDERR "WARNING: $sqlstype detected (in $schemaname.$tablename.$colname).\n  This is a 'not typed' field in SQL Server. There is no equivalent in PostgreSQL.\n  This is converted to text, but you'll have rework to do on your client code\n";
	$rettype='text';
    }
    else
    {
        print "Types: ", Dumper(\%types);
        croak
            "Cannot determine the PostgreSQL's datatype corresponding to $sqlstype. This is a bug\n";
    }

    # We special case when type is varchar, to be case insensitive
    if ($sqlstype =~ /text|varchar/ and $case_insensitive)
    {
        $rettype = "citext";

        # Do we have a SQL qualifier ? (we'll have to do check constraints then)
        if ($sqlqual and not defined($skip_citext_length_check) or $sqlqual and $skip_citext_length_check == 0)
        {

            # Check we have a table name and a colname, or a typname
            if (    defined $colname
                and defined $tablename
               ) # We are called from a CREATE TABLE, we have to add a check constraint
            {
                my $constraint;
                $constraint->{TYPE}  = 'CHECK_CITEXT';
                $constraint->{TABLE} = $tablename;
                $constraint->{TEXT}  = "char_length(" . format_identifier($colname) . ") <= $sqlqual";
                push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                        ->{CONSTRAINTS}}, ($constraint);
            }
            elsif (defined $typname
                  ) # We are called from a CREATE TYPE, which will be converted to a CREATE DOMAIN
            {
                $rettype = "citext CHECK(char_length(value)<=$sqlqual)";
            }
            else
            {
                die
                    "Called in a case sensitive, trying to generate a check constraint, failed. This is a bug!";
            }
        }
    }
    # We special case SQL Server's TABLE types: they should be converted into an array
    if ( $sqlstype =~ /^(\S+)\.(\S+)$/)
    {
        # This is a namespaced type. So we check if this is a special array
        my ($schema,$type)=($1,$2);
        if (defined($objects->{SCHEMAS}->{$schema}->{TABLE_TYPES}->{$type}))
        {
            $rettype=$rettype.'[]';
        }
    }

    # Add this type to casts to perform if necessary
    add_cast($rettype);

    return $rettype;
}

# This function is used for selects from SQL Server, in kettle. It adds a function call
# if there is a conversion to be done.
# uniqueidentifier is upper case in SQL Server, whereas uuid is lower case in PG
# date is converted to varchar in the YYYY-MM-DD format
# timestamp with time zone is converted to varchar in the YYYY-MM-DD HH:MI:SS.MMM (24h) with time zone format
# xml columns with empty values will be converted to null since the empty values won't be accepted in PG (datalength of an empty xml column is 5)
sub sql_convert_column
{
    my ($colname,$coltype)=@_;
    my %functions = (
        'uuid' => 'lower({colname})',
        'date' => 'convert(varchar(50), {colname}, 120)',
        'timestamp with time zone(7)' => 'convert(varchar(50), {colname}, 121)',
        'xml' => 'case when datalength({colname}) > 5 then {colname} else null end');
    if (defined ($functions{$coltype}))
    {
	my $tmpcol=$functions{$coltype};
	$tmpcol =~ s/\{colname\}/[$colname]/g;
        return $tmpcol;
    }
    else
    {
        return "[$colname]";
    }
}

# This function is used for selects from PostgreSQL, in kettle. It adds a function call
# if there is a conversion to be done.
# uuid is converted to varchar and forced to lower case
# date is converted to varchar in the YYYY-MM-DD format
# timestamp with time zone is converted to varchar in the YYYY-MM-DD HH:MI:SS.US+00 format (UTC)
sub postgres_convert_column
{
    my ($colname,$coltype)=@_;
    my %functions = (
        'uuid' => 'lower(cast({colname} as varchar))',
        'date' => 'to_char({colname}, \'YYYY-MM-DD\')',
        'timestamp with time zone' => 'to_char({colname} AT TIME ZONE \'UTC\', \'YYYY-MM-DD HH:MI:SS.US+00\')');
    if (defined ($functions{$coltype}))
    {
       my $tmpcol = $functions{$coltype};
       $tmpcol =~ s/\{colname\}/$colname/;
       return $tmpcol;
    }
    else
    {
        return $colname;
    }
}

# This is used to convert camelCase to snake_case. The latter is more usual with PostgreSQL
sub camel_to_snake
{
    my ($string)=@_;
    $string =~ s/([[:lower:]])([[:upper:]]+)/$1_\l$2/g;
    $string=lc($string);
    return $string;
}

# This function is used to determine if a PK will be sorted the same in SQL 
# Server and PostgreSQL.
# It means that it doesn't depend on collation orders or other internals.
# For now, only numeric and date data types are considered OK.
# Used for incremental jobs, to know if we can ask the databases to send us 
# pre-sorted data.
# We also filter on $use_pk_if_possible.
sub is_pk_sort_order_safe
{
        my ($schema,$table)=@_;
        my %safe_types = ('numeric'          => 1,
                          'int'              => 1,
                          'bigint'           => 1,
                          'smallint'         => 1,
                          'real'             => 1,
                          'double precision' => 1,
                          'date'             => 1,
                          'timestamp'        => 1,
                      );
        return 0 unless (defined $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{PK}); # There is no PK
        return 0 unless ($use_pk_if_possible =~ /\b${schema}\.${table}\b/i or $use_pk_if_possible eq '1');
        my $pk=$objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{PK};
        my $isok=1;
        # It is OK as long as all types are in %safe_type
        foreach my $col (@{$pk->{COLS}})
        {
            $isok=0 unless defined ($safe_types{$objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{TYPE}});
        }
        return $isok;
}

# This function renames the identifiers
sub rename_identifier
{
    my ($identifier)=@_;

    if ($case_treatment==1)
    {
        $identifier=lc($identifier);
    }
    elsif ($case_treatment==2)
    {
        $identifier=camel_to_snake($identifier);
    }
    return $identifier;
}

# This function formats the identifiers (object name), putting double quotes around it
# It also converts case if asked
sub format_identifier
{
    my ($identifier)=@_;
    croak "identifier not defined in format_identifier" unless (defined $identifier);
    $identifier=rename_identifier($identifier);

    if (length($identifier) > 63)
    {
        print STDERR "WARNING: $identifier is more than 63 characters long; PostgreSQL will truncate the name internally\n";
    }

    # Now, we protect the identifier (similar to quote_ident in PG)
    $identifier=~ s/"/""/g;
    $identifier='"'.$identifier.'"';
    return $identifier;
}

# This is a bit of a ugly hack: for indexes, in the column definition, there may be ASC/DESC at the end
# Instead of changing the whole structure of the code, just detect this asc/desc and split it before calling format_identifier
sub format_identifier_cols_index
{
    my ($idx_identifier)=@_;
    $idx_identifier =~ /^(.*?)(?: (ASC|DESC))?$/;
    my ($col,$order)=($1,$2);
    my $formatted=format_identifier($col);
    return $formatted unless defined ($order);
    return $formatted . ' ' . $order;
}

# This one will try to convert what can obviously be converted from transact to PG
# Things such as getdate() which can become CURRENT_TIMESTAMP
sub convert_transact_function
{
   my ($code)=@_;
   $code =~ s/ISNULL\s*\(/COALESCE(/gi;
   $code =~ s/getdate\s*\(\)/CURRENT_TIMESTAMP/gi;
   $code =~ s/user_name\s*\(\)/CURRENT_USER/gi;
   $code =~ s/SPACE\s*\(/REPEAT(' ', /gi;
   $code =~ s/charindex\s*\(\s*(.*?)\s*\,\s*(.*?)\s*\)/dPOSITION('$1' in $2)/gi;
   $code =~ s/datepart\s*\(\s*(.*?)\s*\,\s*(.*?)\s*\)/date_part('$1', $2)/gi;
   $code =~ s/DATEADD\s*\(\s*(.*?)\s*\,\s*(.*?)\s*\,\s*(.*?)\s*\)/$3 + INTERVAL '$2 $1'/gi;
   $code =~ s/CONVERT\s*\(\s*NVARCHAR\s*(.*?)\s*\(\s*(.*?)\s*\s*\)\,\s*(.*?)\s*\)/CAST($3 AS varchar($2))/gi;
   $code =~ s/CONVERT\s*\(\s*(.*?)\s*\(\s*(.*?)\s*\s*\)\,\s*(.*?)\s*\)/CAST($3 AS $1($2))/gi;
   $code =~ s/CONVERT\s*\(\s*(.*?)\s*\,\s*(.*?)\s*\)/CAST($2 AS $1)/gi;
   return $code;
}

# This one will try to convert from transact to PG
# We check if we have several blocks separated by logical operators
# Code going through this function will go to UNSURE file
sub convert_transactsql_code
{
   my ($code)=@_;
   #print STDERR "convert: $code\n";

   if ($code =~ /^\((.+?)\)\s+(AND|OR)\s+\((.+?)\)$/) {
      my ($lhs,$op,$rhs)=($1,$2,$3);
      $code = "(".convert_transactsql_code("$lhs").") $op (".convert_transactsql_code("$rhs").")";
   }
   elsif ($code =~ /^(.+?)\s+(AND|OR)\s+(.+?)$/) {
      my ($lhs,$op,$rhs)=($1,$2,$3);
      $code = "(".convert_transactsql_code("$lhs")." $op ".convert_transactsql_code("$rhs").")";
   }
   else {
      if ($case_treatment==0) {
	 $code =~ s/[\[\]]/"/gi; # Bit brutal probably
      }
      else {
	 $code =~ s/\[(.*)\]/rename_identifier($1)/gie; # Bit brutal probably
      }
      $code = convert_transact_function($code);
   }
   #print STDERR "to: $code\n\n";
   return $code;
}

# This function does its best to convert MS's weird default values syntax into something logical
sub store_default_value
{
    my ($schema,$table,$col,$value,$line)=@_;
    if ($value =~ /^\(?(\d+(\.\d+)?)\)?$/) # Value is  numeric
    {
       $value = $1; # Get rid of parenthesis
       if ($objects->{SCHEMAS}->{relabel_schemas($schema)}->{TABLES}->{$table}->{COLS}->{$col}->{TYPE} eq 'boolean') {
	  # Ok, it IS a boolean, and we have received a number
	  if ($value eq '0') {
	     $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE} = 'false';
	  }
	  elsif ($value eq '1') {
	     $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE} = 'true';
	  }
	  else {
	     # We should not get here: we have a numeric which isn't 0 or 1, and is supposed to be a boolean
	     die "Got an unexpected boolean : $value, for line $line\n";
	  }
       }
       else {
	  $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE}
	     = $value;
       }
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{UNSURE}
	  = 0;
    }
    elsif ($value =~ /^NULL$/) # A NULL value
    {
       # NULL WITHOUT quotes around it !
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE}
	  = 'NULL';
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{UNSURE}
	  = 0;
    }
    elsif ($value =~ /^N?'(.*)'$/) # There is sometimes an N before a string.
    {
       $value = $1; # Get rid of junk
       # Default text value, text, between commas
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE}
	  = "'$1'";
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{UNSURE}
	  = 0;
    }
    else {
       #This must be a function call...
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{VALUE}
	  = convert_transactsql_code($value);
       $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}->{$col}->{DEFAULT}->{UNSURE}
	  = 1;
    }
}


# This gives the next column position for a table
# It is used when we add a new column
# These tables are added at the end of the table, in %objects
sub next_col_pos
{
    my ($schema, $table) = @_;
    if (defined $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS})
    {
        my $max = 0;
        foreach my $col (
                   values(%{$objects->{SCHEMAS}->{$schema}->{TABLES}->{$table}->{COLS}}))
        {
            if ($col->{POS} > $max)
            {
                $max = $col->{POS};
            }
        }
        return $max + 1;
    }
    elsif (defined $objects->{SCHEMAS}->{$schema}->{TABLES}->{$table})
    {
        # First column
        return 1;
    }
    else
    {
        die "We tried to add a column to an unknown table";
    }
}

{
    # This builds %relabel_schemas for use in the next function. Both are scoped so that %relabel_schemas is not visible from outside
    my %relabel_schemas;
    sub build_relabel_schemas
    {
       # Don't forget dbo -> public if it was asked (default)
        unless ($norelabel_dbo)
        {
            $relabel_schemas{'dbo'}='public';
        }
        # dbo can be overwritten in relabel_schema (the user will probably forget to deactivate the relabel).
        # so we do the real relabeling after the norelabel_dbo, to overwrite
        if (defined $relabel_schemas)
        {
            foreach my $pair (split (';',$relabel_schemas))
            {
                my @pair=split('=>',$pair);
                unless (scalar(@pair)==2)
                {
                    die "Cannot parse the schema list given as argument: <$relabel_schemas>\n";
                }
                $relabel_schemas{$pair[0]}=$pair[1];
            }
        }

    }


    # This relabels the schemas
    sub relabel_schemas
    {
        my ($schema) = @_;
        return $schema unless (defined $relabel_schemas{$schema});
        return $relabel_schemas{$schema};
    }
}
# Test if we are on windows. We will have to convert / to \ in the XML files
sub is_windows
{
    if ($^O =~ /MSWin32/)
    {
        return 1;
    }
    return 0;
}

# Die if kettle is not set up correctly
sub kettle_warn
{
    my ($file) = @_;
    print STDERR
        "Important WARNING: You have to set up KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y in $file.\nIf this file doesn't exist yet, start spoon from the kettle directory once.";
}

# This sub checks ~/.kettle/kettle.properties to be sure
# KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y is in place
# We die if not
sub check_kettle_properties
{
    my $ok = 0;
    my $file;
    if (!is_windows())
    {
        $file = $ENV{'HOME'} . '/.kettle/kettle.properties';
    }
    else
    {
        $file = $ENV{'USERPROFILE'} . '/.kettle/kettle.properties';
    }
    unless (open FILE, $file )
    {
        kettle_warn($file);
        return 1;
    }
    while (<FILE>)
    {
        next unless (/^KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y$/);
        $ok = 1;
    }
    close FILE;
    if (not $ok)
    {
        kettle_warn($file);
        return 1;
    }
    return 0;
}

# Usage, obviously. Has to be kept in sync with new command line options
sub usage
{
    print qq{
Usage: 
    sqlserver2pgsql.pl -b BEFORE_FILE -a AFTER_FILE -u UNSURE_FILE -f SQLSERVER_SCHEMA_FILE

Description:

    This script is a migration tool to convert a Microsoft SQL Server Database
    into a PostgreSQL database, as automatically as possible. It takes a Sql
    Server SQL schema dump, and creates a postgresql dump in 3 parts: 
    before_file, after_file and unsure_file.
    Optionnaly, using the '-k' option, it will generate a kettle job to 
    transfer all data.

Mandatory options:

  SQL Server schema input file:
    -f SQLSERVER_SCHEMA_FILE
            a readable SQL Server SQL structure dump.

  PostgreSQL output schema files:
    -b BEFORE_SCRIPT
            contains what is needed to import data: types, tables and columns.
    -a AFTER_SCRIPT
            contains the rest: indexes, constraints.
    -u UNSURE_SCRIPT
            contains objects we attempt to migrate, but cannot guarantee, such 
            as views or complex indexes.

Options:

    -conf CONFIGURATION_FILE
            uses a configuration file. All options can be set there. Command 
            line options will overwrite conf options.
    -i      the resulting PostgreSQL names will be case-insensitive.
    -nr     the SQL Server 'dbo' schema will not be translated to PostgreSQL 
            'public' schema. 'dbo' will stay 'dbo'.
    -camel_to_snake
            all object names are converted from 'camelCase' to 'camel_case', 
            which is more often used in PostgreSQL. Do not use this unless you
            are ready to do SQL query changes in the client.
    -relabel_schemas 'SOURCE1=>DEST1;SOURCE2=>DEST2'
            gives a list of schemas to rename. Quote this option to prevent the
            shell to alter it. The '-nr' option cancels the default 'dbo' to
            'public' remapping.
    -keep_identifier_case
            keep the case of SQL server database objects. This option is not
            advised. Default is to lowercase everything.
    -num    convert numeric 'xxx,0' to int, bigint, etc. Will not keep numeric
            scale and precision for the converted.
    -drop_rowversion (Default 0)
            should we drop the rowversion/timestamp columns when converting
    -validate_constraints {yes|no|after}
            should the constraints be validated. Set to "yes" by default. If
            set to "no", the constraints will be set as 'NOT VALID'. If set to
            "after", the constraints will be set as 
            'NOT VALID', but the validation queries will be enforced in the
            unsure file.
    -use_pk_if_possible {0|1|LIST_OF_TABLES} (Default 0)
            determine if a primary key will be sorted in the same way in SQL
            Server and PostgreSQL. Default '0', do not sort tables. If set to
            '1' sort all tables. LIST_OF_TABLES gives a comma separated list of
            tables to sort in the form 'schema1.table1,schema2.table2'. Cases 
            are compared insensitively.
    -skip_citext_length_check (Default 0)
            if set, do not add a CHECK (char_length()) check for citext fields
    -use_identity_column (Default 1)
            if set, use identity columns statements (GENERATED ALWAYS AS
            IDENTITY) instead of creating a dedicated sequence (CREATE SEQUENCE)

  Kettle options: 
    if you are generating for kettle, you must provide connection information.

    -sd SQLSERVER_DATABASE
    -sh SQLSERVER_HOST
    -si SQLSERVER_INSTANCE
    -sp SQLSERVER_PORT
    -su SQLSERVER_USERNAME
    -sw SQLSERVER_PASSWORD
    -pd POSTGRESQL_DATABASE
    -ph POSTGRESQL_HOST
    -pp POSTGRESQL_PORxT
    -pu POSTGRESQL_USERNAME
    -pw POSTGRESQL_PASSWORD
    -pi PARALLELISM_IN
            parallelism level for the kettle job (input, SQL Server). Default 1.
    -po PARALLELISM_OUT
            parallelism level for the kettle job (output, PostgreSQL). Default 8.
    -pforce_ssl
            force a SSL session to PostgreSQL
    -stringtype_unspecified
            By default, the data are sent as varchar. This can block date field
            migration. By using this option, make PostgreSQL infer the data type.

    -k KETTLE_OUTPUT_DIRECTORY
    -sort_size INTEGER
            set the size of the sort batch for the incremental job. If set to a
            small value, the process will be slow. If set to a too large value,
            you will get Java 'Out of Heap Memory' errors.
            The default value is 10000, which is very low, in order to avoid 
            problems. First, raise Java 'Heap Memory' in the kitchen script,
            then try higher values if you need more speed.
    -ignore_errors
            choose to ignore insert errors. If this option is used, inserting
            will be much slower.
};
        exit 0;
}

# This function generates kettle transformations, and a kettle job running all these
# transformations sequentially, for all the tables, in all the schemas, in sql server's dump
sub generate_kettle
{
    my ($dir) = @_;

    # first, create the kettle directory
    unless (-d $dir)
    {
        mkdir($dir) or die "Cannot create $dir";
    }

    # For each table in each schema in $objects, we generate a kettle file in the directory
    # We also create an incremental transformation

    foreach my $schema (sort keys %{$objects->{SCHEMAS}})
    {
        my $refschema    = $objects->{SCHEMAS}->{$schema};
        my $targetschema = $schema;

        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            my $origschema=$refschema->{TABLES}->{$table}->{origschema};
            # First, does this table have LOBs ? The template depends on this and is this
            # table having an int PK ?
            my $newtemplate;
            if (  $refschema->{TABLES}->{$table}->{haslobs}
              and defined($refschema->{TABLES}->{$table}->{PK}->{COLS})
              and scalar(@{$refschema->{TABLES}->{$table}->{PK}->{COLS}}) == 1
              and ($refschema->{TABLES}->{$table}->{COLS}->{($refschema->{TABLES}->{$table}->{PK}->{COLS}->[0])}->{TYPE} =~ /int$/)
               )
            {
                my $wherefilter;
                $newtemplate = $template_lob;
                $wherefilter =
                      'WHERE '
                   . $refschema->{TABLES}->{$table}->{PK}->{COLS}->[0]
                   . '% ${Internal.Step.Unique.Count} = ${Internal.Step.Unique.Number}';
                $newtemplate =~
                    s/__sqlserver_where_filter__/$wherefilter/;
            }
            else
            {
                $newtemplate = $template;
            }
            # We have a similar question for incremental jobs: can we use the primary key ?
            # We obviously need a primary key, and we need the sort order to be the same in both databases
            my $newincrementaltemplate;
            if (is_pk_sort_order_safe($schema,$table))
            {
                $newincrementaltemplate=$incremental_template_sortable_pk;
                my $collist=join(',',@{$refschema->{TABLES}->{$table}->{PK}->{COLS}});
                $newincrementaltemplate =~ s/__sqlserver_pk_condition__/$collist/g;
                $newincrementaltemplate =~ s/__pg_pk_condition__/$collist/g;
            }
            else
            {
                $newincrementaltemplate=$incremental_template;
            }


            # Build the column list of the table to put into the SQL Server query
            my @colsdef;
            my @pgcolsdef;
            foreach my $col (
                sort {
                    $refschema->{TABLES}->{$table}->{COLS}->{$a}->{POS}
                        <=> $refschema->{TABLES}->{$table}->{COLS}->{$b}
                        ->{POS}
                } (keys %{$refschema->{TABLES}->{$table}->{COLS}}))

            {
                my $coldef = sql_convert_column($col,$refschema->{TABLES}->{$table}->{COLS}->{$col}->{TYPE}) . " AS " . format_identifier($col);
                my $pgcoldef = postgres_convert_column(format_identifier($col),$refschema->{TABLES}->{$table}->{COLS}->{$col}->{TYPE}) . " AS " . format_identifier($col);
                push @colsdef,($coldef);
                push @pgcolsdef,($pgcoldef);
            }
            my $colsdef=join(',',@colsdef);
            my $pgcolsdef=join(',',@pgcolsdef);

            my $pgtable=format_identifier($table);
            my $pgschema=format_identifier($targetschema);

            my $sqlinstancename = '';
            if (defined $si) {
                $sqlinstancename = $si;
            }

            # Substitute every connection placeholder with the real value. We do this for both templates
            $newtemplate =~ s/__sqlserver_database__/$sd/g;
            $newtemplate =~ s/__sqlserver_database__/$sd/g;
            $newtemplate =~ s/__sqlserver_host__/$sh/g;
            $newtemplate =~ s/__sqlserver_port__/$sp/g;
            $newtemplate =~ s/__sqlserver_instance__/$sqlinstancename/g;
            $newtemplate =~ s/__sqlserver_username__/$su/g;
            $newtemplate =~ s/__sqlserver_password__/$sw/g;
            $newtemplate =~ s/__postgres_database__/$pd/g;
            $newtemplate =~ s/__postgres_host__/$ph/g;
            $newtemplate =~ s/__postgres_port__/$pp/g;
            $newtemplate =~ s/__postgres_username__/$pu/g;
            $newtemplate =~ s/__postgres_password__/$pw/g;
            $newtemplate =~ s/__sqlserver_table_name__/[$origschema].[$table]/g;
            $newtemplate =~ s/__sqlserver_table_cols__/$colsdef/g;
            $newtemplate =~ s/__postgres_table_name__/$pgtable/g;
            $newtemplate =~ s/__postgres_schema_name__/$pgschema/g;
            $newtemplate =~ s/__PARALLELISM_IN__/$parallelism_in/g;
            $newtemplate =~ s/__PARALLELISM_OUT__/$parallelism_out/g;

            if ($ignore_errors)
            {
                $newtemplate =~ s/<ignore_errors>N<\/ignore_errors>/<ignore_errors>Y<\/ignore_errors>/g;
                $newtemplate =~ s/<use_batch>Y<\/use_batch>/<use_batch>N<\/use_batch>/g; # Cannot use batch mode with ignore errors
            }

            if ($pforce_ssl)
            {
                    $newtemplate =~ s/__pforce_ssl__/<attribute><code>EXTRA_OPTION_POSTGRESQL.ssl<\/code><attribute>true<\/attribute><\/attribute>\n<attribute><code>EXTRA_OPTION_POSTGRESQL.sslfactory<\/code><attribute>org.postgresql.ssl.NonValidatingFactory<\/attribute><\/attribute>/g;
            }
            else
            {
                    $newtemplate =~ s/__pforce_ssl__//g;
            }

            if ($stringtype_unspecified) {
               $newtemplate =~ s/__stringtype_unspecified__/<attribute><code>EXTRA_OPTION_POSTGRESQL.stringtype<\/code><attribute>unspecified<\/attribute><\/attribute>\n/g;
            }
            else {
               $newtemplate =~ s/__stringtype_unspecified__//g;
            }

            $newincrementaltemplate =~ s/__sqlserver_database__/$sd/g;
            $newincrementaltemplate =~ s/__sqlserver_database__/$sd/g;
            $newincrementaltemplate =~ s/__sqlserver_host__/$sh/g;
            $newincrementaltemplate =~ s/__sqlserver_port__/$sp/g;
            $newincrementaltemplate =~ s/__sqlserver_username__/$su/g;
            $newincrementaltemplate =~ s/__sqlserver_password__/$sw/g;
            $newincrementaltemplate =~ s/__postgres_database__/$pd/g;
            $newincrementaltemplate =~ s/__sqlserver_instance__/$sqlinstancename/g;
            $newincrementaltemplate =~ s/__postgres_host__/$ph/g;
            $newincrementaltemplate =~ s/__postgres_port__/$pp/g;
            $newincrementaltemplate =~ s/__postgres_username__/$pu/g;
            $newincrementaltemplate =~ s/__postgres_password__/$pw/g;
            $newincrementaltemplate =~ s/__sqlserver_table_name__/[$origschema].[$table]/g;
            $newincrementaltemplate =~ s/__sqlserver_table_cols__/$colsdef/g;
            $newincrementaltemplate =~ s/__postgres_table_name__/$pgtable/g;
            $newincrementaltemplate =~ s/__postgres_schema_name__/$pgschema/g;
            $newincrementaltemplate =~ s/__postgres_table_cols__/$pgcolsdef/g;
            $newincrementaltemplate =~ s/__PARALLELISM_IN__/$parallelism_in/g;
            $newincrementaltemplate =~ s/__PARALLELISM_OUT__/$parallelism_out/g;
            $newincrementaltemplate =~ s/__sort_size__/$sort_size/g;

            if ($pforce_ssl)
            {
                    $newincrementaltemplate =~ s/__pforce_ssl__/<attribute><code>EXTRA_OPTION_POSTGRESQL.ssl<\/code><attribute>true<\/attribute><\/attribute>\n<attribute><code>EXTRA_OPTION_POSTGRESQL.sslfactory<\/code><attribute>org.postgresql.ssl.NonValidatingFactory<\/attribute><\/attribute>/g;
            }
            else
            {
                    $newincrementaltemplate =~ s/__pforce_ssl__//g;
            }
            if ($stringtype_unspecified) {
               $newincrementaltemplate =~ s/__stringtype_unspecified__/<attribute><code>EXTRA_OPTION_POSTGRESQL.stringtype<\/code><attribute>unspecified<\/attribute><\/attribute>\n/g;
            }
            else {
               $newincrementaltemplate =~ s/__stringtype_unspecified__//g;
            }
            # We have a bit of work to do on primary keys for the incremental template: we need them
            # to compare the tables…
            if (defined($refschema->{TABLES}->{$table}->{PK}->{COLS}))
            {
              my @pk=@{$refschema->{TABLES}->{$table}->{PK}->{COLS}};
              my $keys="";
              foreach my $pk(@pk)
              {
                $keys.="<key>$pk</key>\n";
              }
              $newincrementaltemplate =~ s/__KEYS_MERGE__/$keys/g;

	      my $sortkeys='';
              my $synckeys='';
	      foreach my $pk(@pk)
	      {
		$sortkeys.="<field>\n<name>$pk</name>\n<ascending>Y</ascending>\n<case_sensitive>Y</case_sensitive>\n</field>\n";
                my $outcol=$pk;
                $outcol=rename_identifier($outcol);
                $synckeys.="<key>\n<name>$pk</name>\n<field>$outcol</field>\n<condition>&#x3d;</condition>\n<name2/>\n</key>\n";

	      }
	      $newincrementaltemplate =~ s/__SORT_KEYS_SQLSERVER__/$sortkeys/g;
	      $newincrementaltemplate =~ s/__SORT_KEYS_PG__/$sortkeys/g;
              $newincrementaltemplate =~ s/__KEYS_SYNC__/$synckeys/g;

	      # We also need to tell the merge step to compare all columns
	      my $valuesmerge='';
              my $valuessync='';
	      foreach my $colname (keys(%{$refschema->{TABLES}->{$table}->{COLS}}))
	      {
		# Is it a member of the PK ? If yes, no need to use it for comparison
#FIXME:		unless (scalar(grep(/^${colname}$/,@pk))) # Does grep find an element in the array matching colname ?
#		{
		  $valuesmerge.="<value>$colname</value>\n";
                  # we need to use the correct case for postgresql output
                  my $outcol=$colname;
                  if ($case_treatment==1)
                  {
                    $outcol=lc($outcol);
                  }
                  elsif ($case_treatment==2)
                  {
                    $outcol=camel_to_snake($outcol);
                  }
                  $valuessync.="<value>\n<name>$outcol</name>\n<rename>$colname</rename>\n<update>Y</update>\n</value>\n";
#		}
	      }
              $newincrementaltemplate =~ s/__VALUES_MERGE__/$valuesmerge/g;
              $newincrementaltemplate =~ s/__VALUES_SYNC__/$valuessync/g;


	      # Produce the incremental transformation
	      open FILE, ">$dir/incremental-$schema-$table.ktr"
		  or die "Cannot write to $dir/incremental-$schema-$table.ktr";
	      binmode(FILE,":utf8");
	      print FILE $newincrementaltemplate;
	      close FILE;
	    }
            else
            {
              print STDERR "$schema/$table has no PK. Cannot create an incremental transformation\n";
            }
            # Store this new transformation into its file
            open FILE, ">$dir/$schema-$table.ktr"
                or die "Cannot write to $dir/$schema-$table.ktr";
            binmode(FILE,":utf8");
            print FILE $newtemplate;
            close FILE;
        }
    }

    # All transformations are done
    # We have to create a job to launch everything in one go
    # We also create an incremental job. This incremental job
    # first deactivates all constraints (with triggers), then
    # runs all incremental jobs, and "standard" jobs for all those
    # tables where we cannot do incremental (no PK...)
    open JOBFILE, ">$dir/migration.kjb"
        or die "Cannot write to $dir/migration.kjb";
    open INCFILE, ">$dir/incremental.kjb"
        or die "Cannot write to $dir/incremental.kjb";
    my $real_dir     = getcwd;
    my $entries      = '';
    my $incentries   = '';
    my $hops         = '';
    my $prev_node    = 'SQL SCRIPT START';
    # $cur_vert_pso is not that useful, it's just not to be ugly if someone wanted to open
    # the job with spoon (kettle's gui) and work on it graphically
    my $cur_vert_pos = 100;

    # First : the hop from START to SQL SCRIPT START
    my $tmp_hop = $job_hop;
    $tmp_hop =~ s/__table_1__/START/;
    $tmp_hop =~ s/__table_2__/SQL SCRIPT START/;
    # This is the first hop, so it is unconditionnal
    $tmp_hop =~ s/<unconditional>N<\/unconditional>/<unconditional>Y<\/unconditional>/;
    $hops.=$tmp_hop;

    # We sort only so that it will be easier to find a transformation in the job if one needed to
    # edit it. It's also easier to track progress if tables are sorted alphabetically

    foreach my $schema (sort keys %{$objects->{SCHEMAS}})
    {
        my $refschema = $objects->{SCHEMAS}->{$schema};
        foreach my $table (sort { lc($a) cmp lc($b) }
                           keys %{$refschema->{TABLES}})
        {
            my $tmp_entry = $job_entry;

            # We build the entries with regexp substitutions. The tablename contains the schema
            $tmp_entry =~ s/__table_name__/${schema}_${table}/;
            $tmp_entry =~ s/__y_loc__/$cur_vert_pos/;

            # JOBFILEname to use. We need the full path to the transformations
            # The only difference between normal and incremental job is the filename of the transformation
            my $JOBFILEname;
            my $INCJOBFILEname;
            if ($dir =~ /^([A-Za-z]:\\|\/)/)    # Absolute path
            {
                $JOBFILEname = $dir . '/' . $schema . '-' . $table . '.ktr';
                $INCJOBFILEname = $dir . '/' . 'incremental-' . $schema . '-' . $table . '.ktr';
            }
            else
            {
                $JOBFILEname =
                      $real_dir . '/'
                    . $dir . '/'
                    . $schema . '-'
                    . $table . '.ktr';
                $INCJOBFILEname =
                      $real_dir . '/'
                    . $dir . '/'
                    . 'incremental-'
                    . $schema . '-'
                    . $table . '.ktr';
            }
            # Does the incremental transformation exist ?
            unless (-e $INCJOBFILEname)
            {
                $INCJOBFILEname=$JOBFILEname;
            }

            # Different for windows and linux, obviously: we change / to \ for windows
            unless (is_windows())
            {
                $JOBFILEname =~ s/\//&#47;/g;
                $INCJOBFILEname =~ s/\//&#47;/g;
            }
            else
            {
                $JOBFILEname =~ s/\//\\/g;
                $INCJOBFILEname =~ s/\//\\/g;
            }
            my $inctmp_entry=$tmp_entry;
            $tmp_entry =~ s/__file_name__/$JOBFILEname/;
            $inctmp_entry =~ s/__file_name__/$INCJOBFILEname/;
            $entries .= $tmp_entry;
            $incentries.=$inctmp_entry;

            # We build the hop with the regexp too
            my $tmp_hop = $job_hop;
            $tmp_hop =~ s/__table_1__/$prev_node/;
            $tmp_hop =~ s/__table_2__/${schema}_${table}/;
            $hops .= $tmp_hop;

            # We increment everything for next loop
            $prev_node = "${schema}_${table}";    # For the next hop
            $cur_vert_pos += 80;                  # To be pretty in spoon
        }
    }
    # Put the final hop
    $tmp_hop = $job_hop;
    $tmp_hop =~ s/__table_1__/$prev_node/;
    $tmp_hop =~ s/__table_2__/SQL SCRIPT END/;
    $hops .= $tmp_hop;


    # Build the casts in the start/stop job entries
    my $beforescript;
    my $afterscript;
    if (defined ($objects->{CASTS}))
    {
        foreach my $cast (keys %{$objects->{CASTS}})
        {
            if ($objects->{CASTS}->{$cast} eq "C")
            {
                $beforescript.= "DROP CAST IF EXISTS &#x28;varchar as $cast&#x29;;\n";
                $beforescript.= "CREATE CAST &#x28;varchar as $cast&#x29; with inout as implicit;\n";
                $afterscript.= "DROP CAST &#x28;varchar as $cast&#x29;;\n";
            }
            elsif ($objects->{CASTS}->{$cast} eq "S")
            {
                $beforescript.= "UPDATE pg_cast SET castcontext='i' WHERE castsource='character varying'::regtype AND casttarget='$cast'::regtype;\n";
                $afterscript.= "UPDATE pg_cast SET castcontext='e' WHERE castsource='character varying'::regtype AND casttarget='$cast'::regtype;\n";
            }
        }
    }
    # Remove/restore triggers to be able to insert without FK checks
    foreach my $schema (sort keys %{$objects->{SCHEMAS}})
    {
        my $refschema = $objects->{SCHEMAS}->{$schema};
        foreach my $table (sort { lc($a) cmp lc($b) }
                           keys %{$refschema->{TABLES}})
        {
            $beforescript.= "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " DISABLE TRIGGER ALL;\n";

    $afterscript.= "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " ENABLE TRIGGER ALL;\n";
        }
    }


    # This is for the SQL Scripts. We also need to specify the PG connection
    $job_header =~ s/__SQL_SCRIPT_INIT__/$beforescript/g;
    $job_header =~ s/__SQL_SCRIPT_END__/$afterscript/g;
    $job_header =~ s/__postgres_database__/$pd/g;
    $job_header =~ s/__postgres_host__/$ph/g;
    $job_header =~ s/__postgres_port__/$pp/g;
    $job_header =~ s/__postgres_username__/$pu/g;
    $job_header =~ s/__postgres_password__/$pw/g;
    if ($pforce_ssl)
    {
        $job_header =~ s/__pforce_ssl__/<attribute><code>EXTRA_OPTION_POSTGRESQL.ssl<\/code><attribute>true<\/attribute><\/attribute>\n<attribute><code>EXTRA_OPTION_POSTGRESQL.sslfactory<\/code><attribute>org.postgresql.ssl.NonValidatingFactory<\/attribute><\/attribute>/g;
    }
    else
    {
        $job_header =~ s/__pforce_ssl__//g;
    }
    if ($stringtype_unspecified) {
       $job_header =~ s/__stringtype_unspecified__/<attribute><code>EXTRA_OPTION_POSTGRESQL.stringtype<\/code><attribute>unspecified<\/attribute><\/attribute>\n/g;
    }
    else {
       $job_header =~ s/__stringtype_unspecified__//g;
    }

    print JOBFILE $job_header;
    print JOBFILE $entries;
    print JOBFILE $job_middle;
    print JOBFILE $hops;
    print JOBFILE $job_footer;
    close JOBFILE;
    print INCFILE $job_header;
    print INCFILE $incentries;
    print INCFILE $job_middle;
    print INCFILE $hops;
    print INCFILE $job_footer;
    close INCFILE;

}

# sql server's dump may contain multiline C style comments (/* */)
# This sub reads a line and cleans it up, removing comments, \r, exec sp_executesql,...
# It takes into account the status (in or out of comment) of the previous line, hence
# the scoped $in_comment
{
    my $in_comment = 0;

    sub read_and_clean
    {
        my ($fd) = @_;
        my $line = <$fd>;
        return undef if (not defined $line);
        $line =~ s/\r//g;    # Remove \r from windows output
        $line =~
            s/EXEC(ute)?\s*(dbo|sys)\.sp_executesql( \@statement =)? N'//i
            ; # Remove executesql… it's a bit weird in the SQL Server's dump
              # If we are not in comment, we look for /*
         # If we are in comment, we look for */, and we remove everything until */
        if ($in_comment)
        {
          if ($line =~ /\*\//)
          {
            $in_comment = 0;
            $line =~ s/.*\*\///;  # Remove everything before the uncomment
          }
          else
          {
            $line = "\n";
          }
        }

        if (not $in_comment)
        {

            # We first remove all one-line only comments (there may be several on this line)
            $line =~ s/\/\*.*?\*\///g;

            # Is there a comment left ?
            if ($line =~ /\/\*/)
            {
                $in_comment = 1;
                $line =~ s/\/\*.*//;    # Remove everything after the comment
            }
        }

        return $line;
    }
}

# This adds a column we just read to a table
sub add_column_to_table
{
    my ($schemaname,$tablename,$colname,$coltypeschema,$coltype,$colqual,$isidentity,$colisnull)=@_;
    my $colnumber=next_col_pos($schemaname,$tablename);
    if (defined $coltypeschema)
    {

        # The datatype is a user defined datatype
        # It has already been declared before. We just need to find it
        $coltype = relabel_schemas($coltypeschema) . '.' . $coltype;
    }
    if ($colqual)
    {
        if ($coltype eq 'xml')
        {
            $colqual = undef
                ; # ignoring sql server xml schema since its not supported in pg
        }
        elsif ($colqual eq '(max)')
        {
            $colqual = undef
                ; # max in sql server is the same as putting no colqual in pg
        }
        else
        {
            # We need the number (or 2 numbers) in this qual
            $colqual =~ /\((\d+(?:,\s*\d+)?)\)/
                or die "Cannot parse colqual <$colqual>";
            $colqual = "$1";
        }
     }

    # in case of a rowversion or timestamp columns, check if we want to keep it
    if ($drop_rowversion
	   and ($coltype eq 'rowversion' or $coltype eq 'timestamp'))
    {
       # do nothing
       return;
    }

    my $newtype =
        convert_type($coltype,   $colqual, $colname,
                     $tablename, undef,    $schemaname);

    # If it is an identity, we'll map to serial/bigserial (create a sequence, then link it
    # to the column)
    if ($isidentity)
    {

        # We have an identity field. We remember the default value and
        # initialize the sequence correctly in the after script
        $isidentity =~ /IDENTITY\s*\((-?\d+),\s*(-?\d+)\)/
            or die "Cannot understand <$isidentity>";
        my $startseq = $1;
        my $stepseq  = $2;
        my $seqname  = lc("${tablename}_${colname}_seq");

        # We get a sure default value.
        $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{COLS}
            ->{$colname}->{DEFAULT}->{VALUE} =
              "nextval('"
            . format_identifier(relabel_schemas(${schemaname})) . '.'
            . format_identifier(${seqname}) . "')";
        $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{COLS}
            ->{$colname}->{DEFAULT}->{UNSURE} = 0;

        $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{START}
            = $startseq;
        $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{STEP}
            = $stepseq;
        $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}
            ->{OWNERTABLE} = $tablename;
        $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}
            ->{OWNERCOL} = $colname;
        $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}
            ->{OWNERSCHEMA} = $schemaname;
    }

    # If there is a bytea generated, this table will contain a blob:
    # use a special kettle transformation for it if generating kettle
    # (see generate_kettle() )
    if (   $newtype eq 'bytea'
        or $coltype eq 'ntext')    # Ntext is very slow, stored out of page
    {
        $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}
            ->{haslobs} = 1;
    }
    $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
        ->{$colname}->{POS} = $colnumber;
    $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
        ->{$colname}->{TYPE} = $newtype;

    if ($colisnull eq 'NOT NULL')
    {
        $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
            ->{$colname}->{NOT_NULL} = 1;
    }
    else
    {
        $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
            ->{$colname}->{NOT_NULL} = 0;
    }
}

# Reads the dump passed as -f
# Generates the $object structure
# That's THE MAIN FUNCTION
sub parse_dump
{

    # Open the input file or die. This first pass is to detect encoding, and open it correctly afterwards
    my $data;
    my $file;
    open $file, "<$filename" or die "Cannot open $filename";
    while (my $line = <$file>)
    {
        $data .= $line;
    }
    close $file;

    # We now ask guess...
    my $decoder = guess_encoding($data, qw/iso8859-15/);
    die $decoder unless ref($decoder);

    # If we got to here, it means we have found the right decoder
    # or at least, perl thinks it has :)
    open $file, "<:encoding(" . $decoder->name . ")", $filename
        or die "Cannot open $filename";

    # Tagged because sql statements are often multi-line, so there are inner loops in some conditions
    MAIN: while (my $line = read_and_clean($file))
    {

        # Create table, obviously. There will be other lines below for the rest of the table definition
        if ($line =~ /^CREATE TABLE \[(.*)\]\.\[(.*)\]\s*\(/)
        {
            my $schemaname   = relabel_schemas($1);
            my $orig_schema = $1;
            my $tablename    = $2;
            $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{haslobs} = 0;
            $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{origschema} = $orig_schema;
            # We are in a create table. Read everything until its end...
            TABLE: while (my $line = read_and_clean($file))
            {
                # Here is a col definition.
                # We ignore ROWGUIDCOL as it has no meaning in PostgreSQL and cannot be emulated
                # (it makes it possible to do a select xxx WHERE $ROWGUID, without knowing the
                # column name, typical microsoft stuff :( )
                # To make matters even worse, they seem to systematically add a space after it :)
                if ($line =~
                    /^\s+\[(.*)\]\s*(?:\[(.*)\]\.)?\[(.*)\]\s*(\(.+?\))?(?: COLLATE (\S+))?( IDENTITY\s*\(-?\d+,\s*-?\d+\))?(?: ROWGUIDCOL ?)? (?:NOT FOR REPLICATION )?(?:SPARSE +)?(NOT NULL|NULL)(?:\s+CONSTRAINT \[.*\])?(?:\s+DEFAULT \((.*)\))?(?:,|$)?/
                    )
                {
                    # Deported into a function because we can also meet alter table add columns on their own
                    my $colname       = $1;
                    my $coltypeschema = $2;
                    my $coltype       = $3;
                    my $colqual        =$4;
                    my $colcollate     =$5; # Ignore for now
                    my $isidentity     =$6;
                    my $colisnull      =$7;
                    my $default        =$8;
                    add_column_to_table($schemaname,$tablename,$colname,$coltypeschema,$coltype,$colqual,$isidentity,$colisnull);
		    if (defined $default)
		       {
			  store_default_value($schemaname,$tablename,$colname,$default,$line);
		       }
		 }

                # This is a computed column. PostgreSQL supports this as a generated column, starting with PG12
                # Will assume the data type is varchar, but this will need to be changed if the source columns are int, numeric, float, etc.
                elsif ($line =~ /^\s*\[(.*)\]\s+AS\s+\((.*)\)(.*)/)
                {
                    # Get the column name
                    my $colnumber=next_col_pos($schemaname,$tablename);
                    my $colname = $1;
                    my $code    = $2;
                    my $coltype = 'varchar';
                    my $other_param = $3;

                    # Replace square brackets in $code with double quotes
                    my $codequoted = $code =~ s/[\[\]]/"/gr;
                    my $generatedcode = " /* GENERATED ALWAYS AS ($codequoted)";
                    if ($other_param =~ /PERSISTED/) {
                       $generatedcode .= " STORED";
                    }
                    $generatedcode .= " */";

                    $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
                        ->{$colname}->{POS} = $colnumber;
                    $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
                        ->{$colname}->{TYPE} = $coltype . $generatedcode;

                    if ($other_param =~ /NOT NULL/) {
                       $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
                          ->{$colname}->{NOT_NULL} = 1;
                    }
                    else {
                       $objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}->{COLS}
                          ->{$colname}->{NOT_NULL} = 0;
                    }

                    # Show a warning
                    print STDERR
                        "\nWarning: There is a computed column: $schemaname.$tablename.$colname\n";
                    print STDERR
                        "\tPostgreSQL 12 supports this via GENERATED ALWAYS AS (...)\n";
                    print STDERR
                        "\tFor now it has been declared as a varchar and the calculation formula has been commented.\n";
                    print STDERR
                       "\tThe formula will likely need to be manually fixed to properly refer to other columns.\n";
                }
                elsif ($line =~
                       /^\s*(?:CONSTRAINT \[(.*)\] )?PRIMARY KEY (?:NON)?CLUSTERED(?: HASH)?/)
                {
                    my $constraint
                        ; # We put everything inside this hashref, we'll push it into the constraint list later
                    $constraint->{TYPE} = 'PK';
                    if (defined $1)
                    {
                        $constraint->{NAME} = $1;
                    }

                    # Here is the PK. We read the following lines until the end of the constraint
                    while (my $pk = read_and_clean($file))
                    {

                        # Exit when read a line beginning with ). The constraint is complete. We store it and go back to main loop
                        if ($pk =~ /^\)/)
                        {
                            push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                                    ->{CONSTRAINTS}}, ($constraint);

                            # We also directly put the constraint reference in a direct path (for ease of use in generate_kettle)
                            $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{PK} =
                                $constraint;
                            next TABLE;
                        }
                        if ($pk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
                        {
                            push @{$constraint->{COLS}}, ($1);
                        }
                    }
                }
                elsif ($line =~ /^\s*(?:CONSTRAINT \[(.*)\] )?UNIQUE/)
                {
                    my $constraint
                        ; # We put everything inside this hashref, we'll push it into the constraint list later
                    $constraint->{TYPE} = 'UNIQUE';
                    if (defined $1)
                    {
                        $constraint->{NAME} = $1;
                    }

                    # Unique key definition. We read following lines until the end of the constraint
                    while (my $uk = read_and_clean($file))
                    {
                        # Exit when read a line beginning with ). The constraint is complete
                        if ($uk =~ /^\)/)
                        {
                            push @{$objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}
                                    ->{CONSTRAINTS}}, ($constraint);
                            next TABLE;
                        }
                        if ($uk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
                        {
                            push @{$constraint->{COLS}}, ($1);
                        }
                    }

                }
                elsif ($line =~ /^\s*\) ON \[.*\]/)
                {
                    # End of the table
                    next MAIN;
                }
                else
                {
                    croak "Cannot understand $line\n";
                }
            }
        }
        ################################################################
        # From HERE, these SQL commands are not linked to a create table
        ################################################################
        elsif ($line =~ /^CREATE SEQUENCE \[(.*)\]\.\[(.*)\]/)
        {
	   my $schemaname   = relabel_schemas($1);
	   my $orig_schema = $1;
	   my $seqname     = $2;
	   while (my $contline = read_and_clean($file))
	   {
	      if ($contline =~ /^\s*AS \[.*\]\s*$/)
	      {
		 next; # We don't care, sequences are always bigint in PostgreSQL
	      }
	      elsif ($contline =~ /^\s*START WITH (\d+)\s*$/)
	      {
		 $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{START}=$1;
	      }
	      elsif ($contline =~ /^\s*INCREMENT BY (\d+)\s*$/)
	      {
		 $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{STEP}=$1;
	      }
	      elsif ($contline =~ /^\s*MINVALUE (-?\d+)\s*$/)
	      {
		 $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{MIN}=$1;
	      }
	      elsif ($contline =~ /^\s*MAXVALUE (-?\d+)\s*$/)
	      {
		 $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{MAX}=$1;
	      }
	      elsif ($contline =~ /^\s*(NO)?CACHE( \d+)?\s*$/)
	      {
		 if (defined $1)
		 {
		    # It's a no cache. Equivalent to CACHE = 1 in PostgreSQL
		    $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{CACHE}=1;
		 }
		 elsif (defined $2)
		 {
		    # We have a specified value
		    $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{CACHE}=$2;
		 }
		 else
		 {
		    # Cache, but not specified. SQL Server isn't very clear on the size of the cache. Let's say 100
		    $objects->{SCHEMAS}->{$schemaname}->{SEQUENCES}->{$seqname}->{CACHE}=100;
		 }
	      }
	      elsif ($contline =~ /^GO$/)
	      {
		 next MAIN;
	      }
	   }
	}
        elsif ($line =~ /^CREATE SCHEMA \[(.*)\]/)
        {
            $objects->{SCHEMAS}->{relabel_schemas($1)} = undef
                ; # Nothing to add here, we create the schema, and put undef in it for now
        }
        elsif ($line =~ /CREATE\s+PROC(?:EDURE)?\s+\[.*\]\.\[(.*)\]/i)
        {
            print STDERR "Warning: Procedure $1 ignored\n";

            # We have to find next GO to know we are out of the procedure
            while (my $contline = read_and_clean($file))
            {
                next MAIN if ($contline =~ /^GO$/);
            }
        }
        elsif ($line =~ /CREATE\s+FUNCTION\s+\[.*\]\.\[(.*)\]/i)
        {
            print STDERR "Warning: Function $1 ignored\n";

            # We have to find next GO to know we are out of the procedure
            while (my $contline = read_and_clean($file))
            {
                next MAIN if ($contline =~ /^GO$/);
            }
        }
        elsif ($line =~ /CREATE\s+TRIGGER\s+\[(.*)\]/i)
        {
            print STDERR "Warning: Trigger $1 ignored\n";

            # We have to find next GO to know we are out of the procedure
            while (my $contline = read_and_clean($file))
            {
                next MAIN if ($contline =~ /^GO$/);
            }
        }
        elsif ($line =~ /SET\s+IDENTITY_INSERT\s+\[(.*)\]/i)
        {
            print STDERR "Warning: SET IDENTITY_INSERT ignored\n";

            # We have to find next GO to know we are out of the procedure
            while (my $contline = read_and_clean($file))
            {
                next MAIN if ($contline eq '');
            }
        }

        # Now we parse the create view. It is multi-line, so the code looks like like create table: we parse everything until a line
        # containing only a single quote (end of the dbo.sp_executesql)
        # The problem is that SQL Server seems to be spitting the original query used to create the view, not a normalized version
        # of it, as PostgreSQL does. So we capture the query, and hope it works for now.
        elsif ($line =~/^(create\s*view)/i)
        {
            my $viewname;
            my $schemaname;
            my $supplement;
            # Either we have the create view and the object name with it, or it is on next non-empty line
            if ( $line =~ /^\s*(create\s*view)\s*(?:\[(\S+)\]\.)?\[(.*?)\]\s*(.*)$/i)
            {
                $viewname = $3;
                if (defined $2)
                {
                    $schemaname = $2;
                }
                else
                {
                    $schemaname = 'dbo';
                }
                $supplement=$4;
            }
            else
            {
                # Find the line containing the view name. For now, it's the next line. If not, well, correct your dump by yourself, sorry :)
                my $line_name = read_and_clean($file);
                $line_name=~ /^\s*(?:\[(\S+)\]\.)?\[(.*?)\]\s*(.*)$/ or croak "This line $line_name doesn't contain a view name";
                $viewname = $2;
                if (defined $1)
                {
                    $schemaname = $1;
                }
                else
                {
                    $schemaname = 'dbo';
                }
                $supplement=$3;
            }
            $schemaname = relabel_schemas($schemaname);

	    my $sql = $supplement;

	    while (my $line_cont = read_and_clean($file))
            {
                if ($line_cont =~ /^\s*'\s*$|^GO$/
                    ) # We may have a quote if the view is 'quoted', or a real sql query
                {
                    # The view definition is complete.
                    # We get rid of dbo. schemas
                    $sql =~ s/(dbo)\./relabel_schemas($1) . '.'/eg
                        ;    # We put this in the replacement schema
		    # parse the query view
		    if ( $sql =~ m/^\s*\(([^\)]+)\)\s*AS\s+SELECT\s+(.*)\s+FROM\s+(.*)$/is) {
		       my $view_columns = $1;
		       my $query_columns = $2;
		       my $query_end = $3;
		       my @rebuilt_view_columns = ();
		       my @rebuilt_query_columns = ();
		       my @string_column = ();

		       # format columns names
		       foreach my $view_col (split (',',$view_columns)) {
			  $view_col =~ s/^\s+|\s+$//g;
			  push @rebuilt_view_columns, format_identifier($view_col);
		       }
		       $objects->{SCHEMAS}->{$schemaname}->{VIEWS}->{$viewname}->{COLS} =
			  join(',', @rebuilt_view_columns);

		       # format view query columns
		       foreach my $view_query_col (split (',',$query_columns)) {
			  if ($view_query_col
				 =~ /^.*\+\s*N?'.*'\s*|\s*N?'.*'\s*\+.*|.*\+\s*N?'.*'\s*\+.*$/i) {
			     # PG use '||' to concatenate strings, change '+' to '||'
			     @string_column = ();
			     my $lhs;
			     while ($view_query_col =~ /^\s*(N?'.*?'|[^']+?)\s*\+\s*(.*)$/i) {
				$lhs = $1;
				$view_query_col = $2;
				$lhs = $1 if ($lhs =~ /N('.*?')/);
				push @string_column, $lhs;
			     }
			     $view_query_col = $1 if ($view_query_col =~ /N('.*?')/);
			     push @string_column, $view_query_col;
			     push @rebuilt_query_columns, join('||', @string_column);
			  }
			  else {
			     push @rebuilt_query_columns, $view_query_col;
			  }
		       }
		       $objects->{SCHEMAS}->{$schemaname}->{VIEWS}->{$viewname}->{QUERYCOLS} =
			  convert_transact_function(join(',', @rebuilt_query_columns));

		       $objects->{SCHEMAS}->{$schemaname}->{VIEWS}->{$viewname}->{QUERY} =
			  convert_transact_function($query_end);
		    }
		    else {
		       $objects->{SCHEMAS}->{$schemaname}->{VIEWS}->{$viewname}->{SQL} =
			  $sql;
		    }

                    # Views will be stored without the full schema in them. We will
                    # have to generate the schema in the output file
                    my @view_array=($schemaname,$viewname);
                    push @view_list,(\@view_array); # adds another schema/view to the list
                    next MAIN;
                }
                $sql .= $line_cont;
            }
        }
        # These are domains with PostgreSQL
        elsif ($line =~
            /^CREATE TYPE \[(.*?)\]\.\[(.*?)\] FROM \[(.*?)](?:\((\d+(?:,\s*\d+)?)?\))?/
            )
        {
            # Dependency between types is not done for now. If the problem arises, it may be added
            my ($schema, $type, $origtype, $quals) = ($1, $2, $3, $4);
            $schema=relabel_schemas($schema);
            my $newtype =
                convert_type($origtype, $quals, undef, undef, $type, $schema);
            $objects->{SCHEMAS}->{$schema}->{DOMAINS}->{$type} = $newtype;

            # We add them to known data types, as they probably will be used in table definitions
            # but they point to themselves, with the schema corrected: we want them substituted by themselves
            $types{$schema . '.' . $type} = format_identifier($schema) . '.'
                . format_identifier($type);    # We store the schema with it. And we do the case conversion, the quoting, etc right now
        }
        # These are like arrays of composite (with added functionnality, but we'll skip these
        # This will look like a table, but we'll ignore anything that isn't a column definition
        # If any of the type isn't a base type, this will die. But anyway, we wouldn't be able to convert properly
        elsif ($line =~ /^CREATE TYPE \[(.*)\]\.\[(.*)\] AS TABLE\(/)
        {
            my $schema=relabel_schemas($1);
            my $typename=$2;
            my $newbasetype='';
            my @cols_newbasetype;
            my $colname;
            my $type;
            my $typequal;
            my $newtype;
            TYPE: while (my $typeline= read_and_clean($file))
            {
                if ($typeline =~ /^\t\[(.*)\] \[(.+?)\](?:\s*?\((\d+|max(?:,\d+)?)\))?(?:\s+?(?:NOT\s+?)?NULL),?$/)
                {
                    # This is another column for this type
                    $colname=$1;
                    $type=$2;
                    $typequal=$3;
                    if (defined $typequal and $typequal eq 'max') {
                       # max in SqlServer is the same as no typequal in pg
                       $typequal = undef;
                    }
                    $newtype =
                       convert_type($type, $typequal, undef, undef, undef, undef);
                    push @cols_newbasetype,(format_identifier($colname) . ' ' . $newtype);
                }
                elsif ( $typeline =~ /PRIMARY KEY/)
                {
                    print STDERR "Warning: TABLE type in SQL Server, input line $., ignored a primary key constraint\n";
                    # Let's skip everything till next parenthesis (probably the end)
                    while (my $to_skip= read_and_clean($file))
                    {
                        next TYPE if ($to_skip =~ /\)/);
                    }
                }
                elsif ($typeline =~ /^\)$/) # We reached the end of the type def
                {
                    next;
                }
                elsif ($typeline =~ /^GO$/)
                {
                    # We reached the end. We add this new type
                    # create the new type declaration
                    $newbasetype=join(",\n",@cols_newbasetype);
                    $objects->{SCHEMAS}->{$schema}->{TABLE_TYPES}->{$typename}=$newbasetype;
                    # We add this to known data types, it will be used in table definitions
                    $types{$schema . '.' . $typename} = format_identifier($schema) . '.'
                        . format_identifier($typename);  # We store the schema with it. And we do the case conversion, the quoting, etc right now
                    next MAIN;
                }
                else
                {
                    croak "Cannot understand $typeline\n";
                }
            }
        }

        elsif ($line =~
            /^\s*CREATE\s*(UNIQUE )?\s*(NONCLUSTERED|CLUSTERED)?\s*INDEX \[(.*?)\] ON \[(.*?)\]\.\[(.*?)\](\(\[.*?\]\))?/
            )
        {
            # Index creation. Index are namespaced per table in SQL Server, not in PostgreSQL
            # In PostgreSQL they are in the same namespace as the tables, and in the same
            # schema as the table they are attached to
            # So we store them in $objects, attached to the table
            # Conflicts will be sorted by resolve_name_conflicts() later
            my $isunique    = $1;
            my $isclustered = $2;
            my $idxname     = $3;
            my $schemaname  = relabel_schemas($4);
            my $tablename   = $5;
            my $maybecols   = $6; # Some versions of sql server put column definitions on the first line
            if ($isunique)
            {
                $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}
                    ->{$idxname}->{UNIQUE} = 1;
            }
            else
            {
                $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}
                    ->{$idxname}->{UNIQUE} = 0;
            }
            if (defined $maybecols)
            {
	       my @maybecols = split (',',$maybecols);
	       foreach my $coldef(@maybecols)
	       {
		  $coldef=~/\[(.*)\](?: (ASC|DESC))?/ or die "Cannot understand coldef $coldef in index";
		  if (defined $2)
		  {
		     push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
			       ->{INDEXES}->{$idxname}->{COLS}}, ("$1 $2");
		  }
		  else
		  {
		     push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
			       ->{INDEXES}->{$idxname}->{COLS}}, ("$1");
		  }
	       }
            }
            while (my $idx = read_and_clean($file))
            {

                # Exit when read a line with a GO. The index is complete
                if ($idx =~ /^GO/)
                {
                    next MAIN;
                }
                next
                   if ($idx =~ /^\(|^\)/)
                   ;    # Begin/end of the columns declaration
                if ($idx =~ /\t\[(.*)\] (ASC|DESC)(,)?/) {
                   if (defined $2) {
                      push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                                ->{INDEXES}->{$idxname}->{COLS}}, ("$1 $2");
                   }
                   else {
                      push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                                ->{INDEXES}->{$idxname}->{COLS}}, ("$1");
                   }
                }
                if ($idx =~ /^INCLUDE\s*\(\s*\[(.*?)\](.*)/) {
                   # INCLUDE coluns in indexes are available on PG11 onward
                   # if multiple included columns, there are declared one per line
                   push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                             ->{INDEXES}->{$idxname}->{INCLUDE}}, ($1);
                   if (index($2, ')') == -1) {
                      while (my $incl_line = read_and_clean($file)) {
                         if ($incl_line =~ /^\s*\[(.*?)\](.*)/) {
                            push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                                      ->{INDEXES}->{$idxname}->{INCLUDE}}, ($1);
                            last if (index($2, ')') != -1);
                         }
                      }
                   }
                }
                if ($idx =~ /^WHERE\s*\((.*)\)$/) {
                   # This is a where clause. PostgreSQL has them too. But we
                   # cannot be sure this will be exactly the same. So if an
                   # index as a WHERE clause, it has to go to unsure
                   my $filter=$1;
                   $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                      ->{INDEXES}->{$idxname}->{WHERE}="(".$filter.")";
                }
             }
         }

				# we do not take migrate spatial indexes
        elsif ($line =~ /^CREATE SPATIAL INDEX/)
        {
            my $def=$line;
            while (my $idx = read_and_clean($file))
            {
              $def.=$idx;
            }
            print STDERR "This spatial index won't be migrated:\n$def\n";
        }

        elsif ($line =~ /^ALTER INDEX \[(.*)\] ON \[(.*)\]\.\[(.*)\] DISABLE$/)
        {
            my $idxname     = $1;
            my $schemaname  = relabel_schemas($2);
            my $tablename   = $3;

            $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{INDEXES}
                    ->{$idxname}->{DISABLE} = 1;
	 }

        # Added table columns… this seems to appear in SQL Server when some columns have ANSI padding, and some not.
        # PG follows ANSI, that is not an option. The end of the regexp is pasted from the create table
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD \[(.*)\] (?:\[(.*)\]\.)?\[(.*)\](\(.+?\))?( IDENTITY\(-?\d+,\s*-?\d+\))? (NOT NULL|NULL)(?: CONSTRAINT \[.*\] )?(?: DEFAULT \(.*\))?$/
            )
        {
            my $schemaname=relabel_schemas($1);
            my $tablename=$2;
            my $colname=$3;
            my $coltypeschema=$4;
            my $coltype=$5;
            my $colqual=$6;
            my $isidentity=$7;
            my $colisnull=$8;
            my $default=$9;
            add_column_to_table($schemaname,$tablename,$colname,$coltypeschema,$coltype,$colqual,$isidentity,$colisnull);
            if (defined $default)
            {
	       store_default_value($schemaname,$tablename,$colname,$default,$line);
            }
        }

        # Table constraints
        # Primary key. Multiline
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\]\s+(?:WITH (?:NO)?CHECK )?ADD\s*(?:CONSTRAINT \[(.*)\])? PRIMARY KEY (?:CLUSTERED|NONCLUSTERED)?/
            )
        {
            my $schemaname=relabel_schemas($1);
            my $tablename=$2;
            my $constraint;
            $constraint->{TYPE}='PK';
            if (defined $3)
            {
                $constraint->{NAME} = $3;
	     }

            CONS: while (my $consline= read_and_clean($file))
            {
                next if ($consline =~ /^\($/);
                if ($consline =~ /^\t\[(.*)\]\s+(?:ASC)?,?$/)
                {
                    push @{$constraint->{COLS}}, ($1);
                }
                elsif ($consline =~ /^\).*$/)
                {
                    push @{$objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}
                            ->{CONSTRAINTS}}, ($constraint);

                    # We also directly put the constraint reference in a direct path (for ease of use in generate_kettle)
                    $objects->{SCHEMAS}->{$schemaname}->{TABLES}->{$tablename}->{PK} = $constraint;
                    # We are done here
                    next MAIN;
                }
                else
                {
                    croak "Cannot understand $consline.";
                }
            }
        }
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[(.*)\])? UNIQUE (?:CLUSTERED|NONCLUSTERED)?/
            )
        {
            my $schemaname=relabel_schemas($1);
            my $tablename=$2;
            my $constraint;
            $constraint->{TYPE}='UNIQUE';
            if (defined $3)
            {
                $constraint->{NAME}=$3;
            }
            while (my $uk = read_and_clean($file))
            {

                # Exit when read a line beginning with ). The constraint is complete
                if ($uk =~ /^\)/)
                {
                    push @{$objects->{SCHEMAS}->{$schemaname}->{'TABLES'}->{$tablename}
                            ->{CONSTRAINTS}}, ($constraint);
                    next MAIN;
                }
                if ($uk =~ /^\t\[(.*)\] (ASC|DESC)(,?)/)
                {
                    push @{$constraint->{COLS}}, ($1);
                }
            }

        }

        # Default values. numeric, then text. These are 100% sure, they will parse in PG
	# Sometimes there is a second pair of parenthesis. I don't even want to know why...
	# Bit just need a little bit of work to be converted to 'true'/'false'
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \((\(?(?:-)?\d+(?:\.\d+)?\))?\) FOR \[(.*)\]/
            )
        {
	   store_default_value(relabel_schemas($1),$2,$4,$3,$line); # schema,table,col,value
        }
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \(('.*')\) FOR \[(.*)\]/
            )
        {
	   store_default_value(relabel_schemas($1),$2,$4,$3,$line); # schema,table,col,value
        }

        # Yes, we also get default NULL (what for ? :) ), and sometimes with a different case
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \(((?i)NULL)\) FOR \[(.*)\]/
            )
        {
	   store_default_value(relabel_schemas($1),$2,$4,$3,$line); # schema,table,col,value
        }

        # And there are also constraints with functions and other strange code in them. Put them as unsure
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\] ADD\s*(?:CONSTRAINT \[.*\])?\s*DEFAULT \(\(?(.*)\)?\) FOR \[(.*)\]/
            )
        {
	   store_default_value(relabel_schemas($1),$2,$4,$3,$line); # schema,table,col,value
        }

        # FK constraint. It's multi line, we have to look for references, and what to do on update, delete, etc (I have only seen delete cascade for now)
        # Constraint name is optionnal
        elsif ($line =~
            /^ALTER TABLE \[(.*)\]\.\[(.*)\]\s+WITH (?:NO)?CHECK(?: NOT FOR REPLICATION)?\s+ADD(?:\s+CONSTRAINT \[(.*)\])? FOREIGN KEY\((.*?)\)/
            )
        {
            # This is a FK definition. We have the foreign table definition in next line.
            my $constraint;
            my $table  = $2;
            my $schema = relabel_schemas($1);
            my $consname= $3;
            $constraint->{TYPE}        = 'FK';
            my @local_cols = split (/\s*,\s*/,$4); # Split around the comma. There may be whitespaces
            @local_cols=map{s/^\[//;s/]$//;$_;} @local_cols; # Remove the brackets around the columns
            $constraint->{LOCAL_COLS}=\@local_cols;
            $constraint->{LOCAL_TABLE} = $2;
            if (defined $consname)
            {
                $constraint->{NAME}=$consname;
            }

            while (my $fk = read_and_clean($file))
            {
                if ($fk =~ /^GO/)
                {
                    push @{$objects->{SCHEMAS}->{$schema}->{'TABLES'}->{$table}
                            ->{CONSTRAINTS}}, ($constraint);
                    next MAIN;
                }
                elsif ($fk =~ /^REFERENCES \[(.*)\]\.\[(.*)\] \((.*?)\)/)
                {

                    my @remote_cols = split (/\s*,\s*/,$3); # Split around the comma. There may be whitespaces
                    @remote_cols=map{s/^\[//;s/]$//;$_;} @remote_cols; # Remove the brackets around the columns
                    $constraint->{REMOTE_COLS}=\@remote_cols;
                    $constraint->{REMOTE_TABLE}  = $2;
                    $constraint->{REMOTE_SCHEMA} = relabel_schemas($1);
                    $constraint->{REMOTE_COLS} =~
                        s/\[|\]//g;    # Get rid of square brackets
                }
                elsif ($fk =~ /^ON DELETE CASCADE\s*$/)
                {
                    $constraint->{ON_DEL_CASC} = 1;
                }
                elsif ($fk =~ /^ON DELETE SET NULL\s*$/)
                {
                    $constraint->{ON_DEL_SET_NULL} = 1;
                }
                elsif ($fk =~ /^ON UPDATE CASCADE\s*$/)
                {
                    $constraint->{ON_UPD_CASC} = 1;
                }
                elsif ($fk =~ /^NOT FOR REPLICATION\s*$/)
                {
                  next; # We don't care for this, it has no meaning for PostgreSQL
                }
                else
                {
                    croak "Cannot parse $fk $., in a FK. This is a bug";
                }
            }
        }

        # Check constraint. As it can be arbitrary code, we just get this code, and hope it will work on PG (it will be stored in a special script file)
        elsif ($line =~
            /ALTER TABLE \[(.*)\]\.\[(.*)\]\s+(?:WITH? (?:NO)?CHECK? )?ADD(?:\s+CONSTRAINT (.*))?\s+CHECK(?: NOT FOR REPLICATION)?\s+\((\((.*)\)|(.*))\)/
            )
        {
            # Check constraint. We'll do what we can, syntax may be different.
            my $constraint;
            my $table   = $2;
            my $constxt = $4;
            my $schema  = relabel_schemas($1);
            $constraint->{TABLE} = $table;
            if (defined $3) {
	       my $constraint_name = $3;
	       $constraint_name = $1 if ($constraint_name =~ /\[(.*)\]/);
	       $constraint->{NAME}  = $constraint_name;
            }
            $constraint->{TYPE}  = 'CHECK';
            $constraint->{TEXT} = $constxt;
            push @{$objects->{SCHEMAS}->{$schema}->{'TABLES'}->{$table}->{CONSTRAINTS}},
                ($constraint);
        }

        # These are comments or extended attributes on objets. They can be multiline, so aggregate everything
        # Until a line that ends with a quote (but not two of them). We remove pair of quotes to make it simpler
        # If fact in can be a lot of things. So we have to ignore things like MS_DiagramPaneCount
        elsif ($line =~ /^EXEC sys.sp_addextendedproperty/)
        {
            $line =~ s/''//g;
            my $sqlproperty = $line;
            # If it ends with a single quote, and it is not the start (some people start their comments with a linefeed)
            unless ($line =~ /'$/ and $line !~ /=N'$/)
            {
                while (my $inline = read_and_clean($file))
                {
                    $inline =~ s/''//g;
                    $sqlproperty .= $inline;
                    # If it ends with a single quote, and it is not the start (some people start their comments with a linefeed)
                    last if ($inline =~ /'$/ and $inline !~ /=N'$/);
                }
            }

            # We have all the extended property. Let's parse it.

            # First step: what kind is it ? we are only interested in comments for now
            $sqlproperty =~ /\@name=N'(.*?)'/
                or croak
                "Cannot find a name for this extended property: $sqlproperty";
            my $propertyname = $1;
            if ($propertyname =~ /^(AggregateType|AllowZeroLength|AppendOnly|Attributes|CollatingOrder|ColumnHidden|ColumnOrder|ColumnWidth|DataUpdatable|DateCreated|DefaultValue|Description|Display Folder|Display Name|DisplayViewsOnSharePointSite|ETL Rules|Example Values|FilterOnLoad|GUID|HideNewField|LastUpdated|microsoft_database_tools_support|MS_DecimalPlaces|MS_DefaultView|MS_DiagramPane1|MS_DiagramPane2|MS_DiagramPaneCount|MS_DisplayControl|MS_Format|MS_Hyperlink|MS_IMEMode|MS_IMESentMode|MS_InputMask|MS_OrderByOn|MS_Orientation|Name|OrderByOnLoad|OrdinalPosition|RecordCount|Required|SCD  Type|ShowDatePicker|Size|Source Datatype|Source System|SourceField|SourceTable|Table Description|Table Type|TextAlign|TextFormat|TotalsRow|Type|UnicodeCompression|Updatable)$/)
            {
                # We don't dump these. They are graphical descriptions of the GUI
                next;
            }

            elsif ($propertyname =~ /^(MS_Description|MS_SSMA_SOURCE)$/)
            {

                # This is a comment. We parse it.
                # Spaces are mostly random it seems, in SQL Server's dump code. So \s* everywhere :(
                # There can be quotes inside a string. So (?<!')' matches only a ' not preceded by a '.
                # I hope it will be sufficient (won't be if someone decides to end a comment with a quote)

                unless ($sqlproperty =~
                    /^EXEC sys.sp_addextendedproperty \@name=N'(.*?)'\s*,\s*\@value=N'(.*)'\s*,\s*\@level0type=N'(.*?)'\s*,\s*\@level0name=N'(.*?)'\s*(?:,\s*\@level1type=N'(.*?)'\s*,\s*\@level1name=N'(.*?)')\s*?(?:,\s*\@level2type=N'(.*?)'\s*,\s*\@level2name=N'(.*?)')?/s)
                {
                    # Not parsing a comment should not stop
                    print STDERR "Could not parse <$sqlproperty>. Ignored.\n";
                    next MAIN;
                }
                my ($comment, $schema, $obj, $objname, $subobj, $subobjname)
                    = ($2, $4, $5, $6, $7, $8);
                $schema=relabel_schemas($schema);
                if ($obj eq 'TABLE' and not defined $subobj)
                {
                    $objects->{SCHEMAS}->{$schema}->{TABLES}->{$objname}->{COMMENT} =
                        $comment;
                }
                elsif ($obj eq 'VIEW' and not defined $subobj)
                {
                    $objects->{SCHEMAS}->{$schema}->{VIEWS}->{$objname}->{COMMENT} =
                        $comment;
                }
                elsif ($obj eq 'TABLE' and $subobj eq 'COLUMN')
                {
                    $objects->{SCHEMAS}->{$schema}->{TABLES}->{$objname}->{COLS}
                        ->{$subobjname}->{COMMENT} = $comment;
                }
                elsif ($obj eq 'TABLE' and $subobj eq 'CONSTRAINT')
                {
                    # It's a bit tedious: constraints are stored in an array for each table
                    # Find the one
                    foreach my $constraint (@{$objects->{SCHEMAS}->{$schema}->{TABLES}->{$objname}->{CONSTRAINTS}})
                    {
                        if (defined ($constraint->{NAME}) and $constraint->{NAME} eq $subobjname)
                        {
                            $constraint->{COMMENT}=$comment;
                        }
                    }
                 }
                elsif ($obj eq 'TABLE' and $subobj eq 'INDEX')
                {
                   $objects->{SCHEMAS}->{$schema}->{TABLES}->{$objname}->{INDEXES}
                      ->{$subobjname}->{COMMENT} = $comment;
                }
                else
                {
                    croak "Cannot understand this comment: $sqlproperty";
                }
            }
            elsif ($propertyname eq 'Dictionary')
            {
                # It seems to be another way to declare table comments. I hope this is right
                $sqlproperty =~
                    /^EXEC sys.sp_addextendedproperty \@name=N'(.*?)'\s*,\s*\@value=N'(.*?)(?<!')'\s*,\s*\@level0type=N'(.*?)'\s*,\s*\@level0name=N'(.*?)'\s*(?:,\s*\@level1type=N'(.*?)'\s*,\s*\@level1name=N'(.*?)')/s
                    or croak "Could not parse $sqlproperty. This is a bug.";
                my ($comment, $schema, $obj, $objname)
                    = ($2, $4, $5, $6);
                $schema=relabel_schemas($schema);
                if ($obj eq 'TABLE')
                {
                    $objects->{SCHEMAS}->{$schema}->{TABLES}->{$objname}->{COMMENT} =
                        $comment;
                }
                elsif ($obj eq 'SCHEMA')
                {
                    # Never met one for now. Die and ask to send me an example
                    croak "Schema comment : <$comment> not understood. Please send a bug report\n";
                }
            }
            else
            {
                croak
                    "Don't know what to do with this extendedproperty: $sqlproperty";
            }
        }

	# Save variable for future use
        elsif ($line =~ /^:setvar\s+(\S+)\s+"(.*)"/)
	{
	   my $varname = $1;
	   my $varvalue = $2;
	   $objects->{VARIABLES}->{$varname} = $varvalue;
	   next;
        }

        # Ignore USE, GO, and things that have no meaning for postgresql
        elsif ($line =~
            /^USE\s|^GO\s*$|\/\*\*\*\*|^SET ANSI_NULLS (ON|OFF)|^SET QUOTED_IDENTIFIER|^SET ANSI_PADDING|CHECK CONSTRAINT|^BEGIN|^END/
            )
        {
            next;
        }
        elsif ($line =~ /^--/)    # Comment
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

        # Ignore grant statements
        elsif ($line =~ /^GRANT ([^ ]+) ON (.+) TO \[[^ ]+\]/)
        {
            next;
        }
        elsif ($line =~ /^GRANT VIEW ([^ ]+) ON (.+) TO \[[^ ]+\]/)
        {
            next;
        }

        elsif ($line =~ /^ALTER (ROLE|USER)/)
        {
            next;
        }

        # Ignore xml schema collections since they are not supported in pg
        elsif ($line =~ /^CREATE XML SCHEMA COLLECTION/)
        {
            next;
        }

        elsif ($line =~ /^ALTER XML SCHEMA COLLECTION/)
        {
            next;
        }

        # Ignore existence tests… how could the object already exist anyway ? For now, only seen for views
        # Also ignore version tests
        elsif ($line =~ /^IF EXISTS|^IF \(\@\@microsoftversion/i)
        {
	   # just read until next go (or EOF)
	   while (defined $line and $line !~ /^GO$/)
	   {
	      $line =read_and_clean($file);
	   }
        }
        elsif ($line =~ /^IF NOT EXISTS/i)
        {
	   # Just ignore the line
	   next;
        }

        # Ignore CREATE DATABASE: we hope that we are given a single database as
	# an option. It is multiline.
        # Ignore everything until next GO
        # Ignore ALTER DATABASE for the same reason. The given parameters have no
	# meaning in PG anyway
	# Except for SET ARITHABORT OFF, for which we print a warning because it
	# probably means the database contents are weird (10/0 = null)
	elsif ($line =~
		  /^ALTER DATABASE.* SET ARITHABORT OFF/)
	{
	   print STDERR "WARNING: the source database is set as ARITHABORT OFF.\n";
	   print STDERR "         It means that for SQL Server, 10/0 = NULL.\n";
	   print STDERR "         You'll probably have problems porting that to PostgreSQL.\n";
	   while ($line !~ /^GO$/)
	   {
	      $line =read_and_clean($file);
	   }
	   # We read everything in the CREATE DATABASE. Back to work !
	   next;
	}
	# Sometimes, when there is a ALTER DATABASE SET ARITHABORT OFF, there are SET ARITHABORT ON. Just ignore them
	elsif ($line =~ /^SET ARITHABORT ON/)
	{
	   next;
	}
	# Sometimes we meet this: SET CONCAT_NULL_YIELDS_NULL ON. That's the normal behaviour for a SQL database. Just ignore
	elsif ($line =~ /^SET CONCAT_NULL_YIELDS_NULL ON/)
	{
	   next;
	}
	# Same more or less
	elsif ($line =~ /^SET ANSI_WARNINGS ON/)
	{
	   next;
	}
	# What the hell does this do in a dump ???
	elsif ($line =~ /^SET NUMERIC_ROUNDABORT OFF/)
	{
	   next;
	}

        # Same for tests about full text search.
        elsif ($line =~
               /^(CREATE|ALTER) DATABASE|^IF \(1 = FULLTEXTSERVICEPROPERTY/)
        {
            while ($line !~ /^GO$/)
            {
                $line = read_and_clean($file);
            }

            # We read everything in the CREATE DATABASE. Back to work !
            next;
        }

        # Ignore CREATE and ALTER statements for full text search objects, such as CATALOG, INDEX or STOPLIST.
        elsif ($line =~ /^(CREATE|ALTER) FULLTEXT/)
        {
          while ($line !~ /^GO$/)
          {
            $line =read_and_clean($file);
          }

          next;
        }

        # Ignore EXEC dbo.sp_executesql, for now only seen for a create view. Views sql command aren't executed directly, don't know why
        elsif ($line =~ /^EXEC dbo.sp_executesql/)
        {
            next;
        }
        # Ignore EXEC sys.sp_db_vardecimal_storage_format, enabling for vardecimal storage format was only needed in SQL Server 2005 and means nothing for PG.
        elsif ($line =~ /^EXEC sys\.sp_db_vardecimal_storage_format/)
        {
            next;
        }

        # Still on views: there are empty lines, and C-style comments
        elsif ($line =~ /^\s*$/)
        {
            next;
        }
        else
        {
            die "Line <$line> ($.) not understood. This is a bug";
        }
    }
    close $file;
}

# Creates the SQL scripts from $object
# We generate alphabetically, to make things less random (this data comes from a hash)
sub generate_schema
{
    my ($before_file, $after_file, $unsure_file) = @_;

    # Open the output files (except kettle, we'll do that at the end)
    open BEFORE, ">:utf8", $before_file or die "Cannot open $before_file, $!";
    open AFTER,  ">:utf8", $after_file  or die "Cannot open $after_file, $!";
    open UNSURE, ">:utf8", $unsure_file or die "Cannot open $unsure_file, $!";
    print BEFORE "\\set ON_ERROR_STOP\n";
    print BEFORE "\\set ECHO all\n";
    print BEFORE "BEGIN;\n";
    print AFTER "\\set ON_ERROR_STOP\n";
    print AFTER "\\set ECHO all\n";
    print AFTER "BEGIN;\n";
    print UNSURE "\\set ON_ERROR_STOP\n";
    print AFTER "\\set ECHO all\n";
    print UNSURE "BEGIN;\n";

    # Are we case insensitive ? We have to install citext then
    # Won't work on pre-9.1 database. But as this is a migration tool
    # if someone wants to start with an older version, it's their problem :)
    if ($case_insensitive)
    {
        print BEFORE "CREATE EXTENSION IF NOT EXISTS citext;\n";
    }

    # Do we require PostGIS ?
    if ($requires_postgis)
    {
        print BEFORE "CREATE EXTENSION IF NOT EXISTS postgis;\n";
        print BEFORE "CREATE EXTENSION IF NOT EXISTS postgis_topology;\n";
    }

    # Ok, we have parsed everything, and definitions are in $objects
    # We will put in the BEFORE file only table and columns definitions.
    # The rest will go in the AFTER script (check constraints, put default values, etc...)

    # The schemas. don't create empty schema, sql server creates a schema per user, even if it ends empty
    foreach my $schema (sort keys %{$objects->{SCHEMAS}})
    {
        unless ($schema eq 'public'
                or not defined $objects->{SCHEMAS}->{$schema})
        {
            # Not compatible before 9.3. This is the logical target for this tool anyway
            print BEFORE "CREATE SCHEMA IF NOT EXISTS ",format_identifier($schema),";\n";
        }
    }

    # Set psql variables in UNSURE
    foreach my $varname (sort keys %{$objects->{VARIABLES}})
    {
       print UNSURE "\\set $varname '$objects->{VARIABLES}->{$varname}'\n";
    }

    # For the rest, we iterate over schemas, except for array types (no point in complicating this)
    # The tables, columns, etc... will be created in the before script, so there is no dependancy
    # problem with constraints, that will be in the after script, except foreign keys which depend on unique indexes
    # We have to do all domains and types before all tables
    # Don't care for dependancy
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # The user-defined types (domains, etc)
        foreach my $tabletype (sort keys %{$refschema->{TABLE_TYPES}})
        {
            print BEFORE "CREATE TYPE " . format_identifier($schema) . '.' . format_identifier($tabletype) . " AS (\n"
                . $refschema->{TABLE_TYPES}->{$tabletype} . "\n);\n";
        }

        print BEFORE "\n";    # We change sections in the dump file
    }
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # The user-defined types (domains, etc)
        foreach my $domain (sort keys %{$refschema->{DOMAINS}})
        {
            print BEFORE "CREATE DOMAIN " . format_identifier($schema) . '.' . format_identifier($domain) . ' '
                . $refschema->{DOMAINS}->{$domain} . ";\n";
        }

        print BEFORE "\n";    # We change sections in the dump file
    }
    # Tables and columns
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {

        # The tables
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            my @colsdef;
            foreach my $col (
                sort {
                    $refschema->{TABLES}->{$table}->{COLS}->{$a}->{POS}
                        <=> $refschema->{TABLES}->{$table}->{COLS}->{$b}
                        ->{POS}
                } (keys %{$refschema->{TABLES}->{$table}->{COLS}}))

            {
                my $colref = $refschema->{TABLES}->{$table}->{COLS}->{$col};
                my $coldef = format_identifier($col) . " " . $colref->{TYPE};
                if ($colref->{NOT_NULL})
                {
                    $coldef .= ' NOT NULL';
                }
                push @colsdef, ($coldef);
            }
            print BEFORE "CREATE TABLE " . format_identifier($schema) . '.' . format_identifier($table) . "( \n\t"
                . join(",\n\t", @colsdef)
                . ");\n\n";
        }
    }
    # Sequences, PKs, Indexes
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
            # We now add all "AFTER" objects
            # We start with SEQUENCES, PKs and INDEXES (will be needed for FK)

        foreach my $sequence (sort keys %{$refschema->{SEQUENCES}})
        {
            my $seqref = $refschema->{SEQUENCES}->{$sequence};
            
            if ($use_identity_column and defined $seqref->{OWNERTABLE})
            {
                # Add a statement of the form
                # ALTER TABLE "schema"."table_name" ALTER COLUMN "column_name" ADD GENERATED ALWAYS AS IDENTITY (start 1000);

                print AFTER "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($seqref->{OWNERTABLE}) . " ";
                print AFTER "ALTER COLUMN " . format_identifier($seqref->{OWNERCOL}) . " ADD GENERATED ALWAYS AS IDENTITY";
                
                if (defined $seqref->{START} or defined $seqref->{STEP})
                {
                    print AFTER " (";
                    if (defined $seqref->{START})
            	    {
            	       print AFTER " START WITH ",$seqref->{START};
            	    }
            	    
            	    if (defined $seqref->{STEP})
            	    {
            	       print AFTER " INCREMENT BY ",$seqref->{STEP};
            	    }          	    
                    print AFTER ")";
        	    }        	    
            }
            else 
            {
                print AFTER "CREATE SEQUENCE " . format_identifier($schema) . '.' . format_identifier($sequence);
        	    if (defined $seqref->{STEP})
        	    {
        	       print AFTER " INCREMENT BY ",$seqref->{STEP};
        	    }
        	    if (defined $seqref->{MIN})
        	    {
        	       print AFTER " MINVALUE ",$seqref->{MIN};
        	    }
        	    if (defined $seqref->{MAX})
        	    {
        	       print AFTER " MAXVALUE ",$seqref->{MAX};
        	    }
        	    if (defined $seqref->{START})
        	    {
        	       print AFTER " START WITH ",$seqref->{START};
        	    }
        	    if (defined $seqref->{CACHE})
        	    {
        	       print AFTER " CACHE ",$seqref->{CACHE};
        	    }
        	    if (defined $seqref->{OWNERTABLE})
        	    {
        	       print AFTER " OWNED BY ",format_identifier($seqref->{OWNERSCHEMA}),
            		  '.',format_identifier($seqref->{OWNERTABLE}),
            		  '.',format_identifier($seqref->{OWNERCOL});
        	    }
        	}
        	
    	    print AFTER ";\n";
    	 }

        # Now PK. We have to go through all tables
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            my $refpk = $refschema->{TABLES}->{$table}->{PK};

            # Warn if no PK!
            if (not defined $refpk)
            {

                # Don't know if it should be displayed
                #print STDERR "Warning: $table has no primary key.\n";
                next;
            }
            my $pkdef = "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " ADD";
            if (defined $refpk->{NAME})
            {
                $pkdef .= " CONSTRAINT " . format_identifier($refpk->{NAME});
            }
            # Create a list of formatted columns
            my @collist=map{format_identifier($_)} @{$refpk->{COLS}};
            $pkdef .=
                " PRIMARY KEY (" . join(',', @collist) . ");\n";
            print AFTER $pkdef;
        }
    }
    # Unique
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # Now The UNIQUE constraints. They may be used for FK (if columns are not null)
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach my $constraint (
              @{$refschema->{TABLES}->{$table}->{CONSTRAINTS}})
            {
                next unless ($constraint->{TYPE} eq 'UNIQUE');
                my $consdef = "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " ADD";
                if (defined $constraint->{NAME})
                {
                    $consdef .= " CONSTRAINT " . format_identifier($constraint->{NAME});
                }
                my @collist=map{format_identifier($_)} @{$constraint->{COLS}};
                $consdef .=
                    " UNIQUE (" . join(",", @collist) . ");\n";
                print AFTER $consdef;
            }
        }
    }
    # Indexes. Unique indexes are needed before foreign key constraints
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # Indexes
        # They don't have a schema qualifier. But their table has, and they are in the same schema as their table
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach
                my $index (
                   sort keys %{$refschema->{TABLES}->{$table}->{INDEXES}})
            {
                my $index_created = 0;
                my $idxref =
                    $refschema->{TABLES}->{$table}->{INDEXES}->{$index};
                my $idxdef .= "";
                if ($idxref->{DISABLE})
                {
                    $idxdef .= "-- ";
                }
                $idxdef .= "CREATE";
                if ($idxref->{UNIQUE})
                {
                    $idxdef .= " UNIQUE";
                }
                if (defined $idxref->{COLS})
                {
                   $idxdef .= " INDEX " . format_identifier($index) . " ON " . format_identifier($schema) . '.' . format_identifier($table) . " ("
                     . join(",", map{format_identifier_cols_index($_)} @{$idxref->{COLS}}) . ")";

                   if (defined $idxref->{INCLUDE}) {
                      $idxdef .= " INCLUDE (" .
                         join(",", map{format_identifier_cols_index($_)} @{$idxref->{INCLUDE}})
                         . ")";
                   }

                   if (not defined $idxref->{WHERE} and not defined $idxref->{DISABLE}) {
                      $idxdef .= ";\n";
                      print AFTER $idxdef;
                      # the possible comment would go to after file
                      $index_created = 1;
                   }
                   else {

                      # this is either a disabled index or an index with a where declaration
                      if (defined $idxref->{WHERE}) {
                         print STDERR "Warning: index $schema.$index contains a where clause. It goes to unsure file\n";
                         if ($idxref->{DISABLE}) {
                            # if disabled, will be on the same line
                            $idxdef .= " ";
                         } else {
                            # otherwise, write condition on a new line
                            $idxdef .= "\n";
                         }
                         $idxdef .= "WHERE (" . convert_transactsql_code($idxref->{WHERE}) . ")";
                      }
                      $idxdef .= ";\n";
                      print UNSURE $idxdef;
                      # the possible comment would go to unsure file
                      $index_created = 2;
                   }

                   # Produce the comments for indexes
                   if (defined $idxref->{COMMENT}) {
                      my $idxcomment = "COMMENT ON INDEX ". format_identifier($schema) . '.' . format_identifier($index) . " IS '" . $idxref->{COMMENT} . "';\n";
                      if ($index_created == 1) {
                         print AFTER $idxcomment;
                      } elsif ($index_created == 2) {
                         print UNSURE $idxcomment;
                      }
                   }
                }
             }
         }
     }
    # Other constraints
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {

        # We have all we need for FKs now. We can put all other constraints (except PK of course)
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach my $constraint (
                             @{$refschema->{TABLES}->{$table}->{CONSTRAINTS}})
            {
                next if ($constraint->{TYPE} =~ /^UNIQUE|PK$/);
                my $consdef = "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " ADD";
                if (defined $constraint->{NAME})
                {
                    $consdef .= " CONSTRAINT " . format_identifier($constraint->{NAME});
                }
                if ($constraint->{TYPE} eq
                    'FK')    # COLS are already a comma separated list
                {
                    # We need to convert the column list to protected names
                    my @localcollist=map{format_identifier($_)} @{$constraint->{LOCAL_COLS}};
                    my @remotecollist=map{format_identifier($_)} @{$constraint->{REMOTE_COLS}};
                    $consdef .=
                          " FOREIGN KEY ("
                        . join(',',@localcollist) . ")"
                        . " REFERENCES "
                        . format_identifier($constraint->{REMOTE_SCHEMA}) . '.'
                        . format_identifier($constraint->{REMOTE_TABLE}) . " ( "
                        . join(',',@remotecollist) . ")";
                    if (defined $constraint->{ON_DEL_CASC}
                        and $constraint->{ON_DEL_CASC})
                    {
                        $consdef .= " ON DELETE CASCADE";
                    }
                    if (defined $constraint->{ON_DEL_SET_NULL}
                        and $constraint->{ON_DEL_SET_NULL})
                    {
                        $consdef .= " ON DELETE SET NULL";
                    }
                    if (defined $constraint->{ON_UPD_CASC}
                        and $constraint->{ON_UPD_CASC})
                    {
                        $consdef .= " ON UPDATE CASCADE";
                    }
                    # We need a name on the constraint to be able to validate it later. Maybe it would be better to generate one
                    # FIXME: we'll see later if a generator is needed (probably)
                    if ($constraint->{TYPE} eq 'FK' and ($validate_constraints =~ /^after|no$/) and defined($constraint->{NAME}))
                    {
                        $consdef .= " NOT VALID";
                    }
                    $consdef .= ";\n";
                    print AFTER $consdef;
                    if ($constraint->{TYPE} eq 'FK' and $validate_constraints eq 'after' and defined $constraint->{NAME})
                    {
                        print UNSURE "ALTER TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " VALIDATE CONSTRAINT " . format_identifier($constraint->{NAME}) . ";\n";
                    }
                }
                elsif ($constraint->{TYPE} eq 'CHECK')
		{
		   $consdef .= " CHECK (" . convert_transactsql_code($constraint->{TEXT}) . ");\n";
		   print UNSURE $consdef
		      ;    # Check constraints are SQL, so cannot be sure
		}
                elsif ($constraint->{TYPE} eq 'CHECK_CITEXT')
                {
                    # These have been generated here, for citext mostly. So we know their syntax is ok
                    $consdef .= " CHECK (" . $constraint->{TEXT} . ");\n";
                    print BEFORE $consdef
                        ; # These are for citext. So they should be checked asap
                }
                elsif ($constraint->{TYPE} eq 'CHECK_BINARY_LENGTH')
                {
                    # These have been generated here. Their syntax are ok.
                    $consdef .= " CHECK (" . $constraint->{TEXT} . ");\n";
                    print BEFORE $consdef
                        ; # These are for bytea length, checked them asap
                }
                else
                {
                    # Shouldn't get there. it would mean I have forgotten a type of constraint
                    croak "I couldn't translate a constraint. This is a bug";
                }
            }
        }
    }
    # Another pass at constraints. This time we want to produce the comments
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {

        # We have all we need for FKs now. We can put all other constraints (except PK of course)
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach my $constraint (
                             @{$refschema->{TABLES}->{$table}->{CONSTRAINTS}})
            {
	       next unless defined ($constraint->{COMMENT});
	       print UNSURE "COMMENT ON CONSTRAINT "
		  . format_identifier($constraint->{NAME}) . " ON "
		  . format_identifier($schema) . '.' . format_identifier($table)
		  . " IS '" . $constraint->{COMMENT} . "';\n";
	    }
	}
    }

    # Default values
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # Default values
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach
                my $col (sort keys %{$refschema->{TABLES}->{$table}->{COLS}})
            {
                my $colref = $refschema->{TABLES}->{$table}->{COLS}->{$col};
                next unless (defined $colref->{DEFAULT});
		my $default_value = $colref->{DEFAULT}->{VALUE};
		if ($default_value =~ /\(\$\((\S+)\)\)/)
		{
		   $default_value = ":$1";
		}
                my $definition =
		   "ALTER TABLE " . format_identifier($schema) . '.'
		   . format_identifier($table)
		   . " ALTER COLUMN " . format_identifier($col)
		   . " SET DEFAULT " . $default_value . ";\n";
                if ($colref->{DEFAULT}->{UNSURE})
		        {
                    print UNSURE $definition;
                }
                else
                {
                    if ($use_identity_column and ($definition =~ /nextval.+_seq/i))
                    {
                        # Skip this set default item
                    }
                    else 
                    {
                        print AFTER $definition;
                    }
                        
                }
            }
        }
    }

    # Current values for sequences: autodetect the current max in the table, now that we probably have the indexes
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        foreach my $sequence (sort keys %{$refschema->{SEQUENCES}})
        {
	   my $seqref = $refschema->{SEQUENCES}->{$sequence};
	   # This may not be an identity. Skip it then
	   next unless defined ($seqref->{OWNERCOL});
	   next if defined ($use_identity_column);
	   print AFTER "select setval('" . format_identifier($schema) . '.'
	      . format_identifier($sequence) . "',(select " . ($seqref->{STEP} > 0 ? "max" : "min") . "("
	      . format_identifier($seqref->{OWNERCOL}) .") from "
	      . format_identifier($seqref->{OWNERSCHEMA}) . '.'
	      . format_identifier($seqref->{OWNERTABLE}) . ")::bigint);\n";
        }
    }

    # Comments on tables and columns
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # Comments on tables
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            if (defined($refschema->{TABLES}->{$table}->{COMMENT}))
            {
                print AFTER "COMMENT ON TABLE " . format_identifier($schema) . '.' . format_identifier($table) . " IS '"
                    . $refschema->{TABLES}->{$table}->{COMMENT} . "';\n";
            }
            foreach
                my $col (sort keys %{$refschema->{TABLES}->{$table}->{COLS}})
            {
                my $colref = $refschema->{TABLES}->{$table}->{COLS}->{$col};
                if (defined($colref->{COMMENT}))
                {
		   print AFTER "COMMENT ON COLUMN " . format_identifier($schema)
		      . '.' . format_identifier($table) . '.'
		      . format_identifier($col) . " IS '"
		      . $colref->{COMMENT} . "';\n";
                }
            }
        }
    }
    # Views, and their comments
    # This is different from other objets: we keep the views ordering
    foreach my $viewref(@view_list)
    {
        my ($schema,$view)=@$viewref;
        my $refschema=$objects->{SCHEMAS}->{$schema};
	print UNSURE "CREATE VIEW "
	   . format_identifier($schema) . '.' . format_identifier($view) . " ";
	if (not defined $refschema->{VIEWS}->{$view}->{SQL}) {
	   my $view_columns = $refschema->{VIEWS}->{$view}->{COLS};
	   my $query_columns = $refschema->{VIEWS}->{$view}->{QUERYCOLS};
	   my $query = $refschema->{VIEWS}->{$view}->{QUERY};
	   print UNSURE "($view_columns) AS\n\tSELECT\n\t\t"
	      . $query_columns . "\n\t" . "FROM $query;\n\n";
	}
	else {
	   print UNSURE $refschema->{VIEWS}->{$view}->{SQL} . ";\n\n";
	}
        if (defined $refschema->{VIEWS}->{$view}->{COMMENT})
        {
	   print UNSURE "COMMENT ON VIEW $schema.$view IS '"
	      . $refschema->{VIEWS}->{$view}->{COMMENT} . "';\n";
        }
    }
    # Trigger functions
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # The trigger functions
        foreach my $triggerfunc (sort keys %{$refschema->{TRIG_FUNCTIONS}})
        {
            my $code = $refschema->{TRIG_FUNCTIONS}->{$triggerfunc}->{DEF};
	    my $language = $refschema->{TRIG_FUNCTIONS}->{$triggerfunc}->{LANG};
            print UNSURE
                "CREATE FUNCTION " . format_identifier($schema) . '.' . $triggerfunc . "() RETURNS trigger LANGUAGE $language AS \$def\$\n";
            print UNSURE $code;
            print UNSURE "\$def\$;\n";
        }
    }
    # Triggers
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        # triggers on tables, as these functions are declared now
        foreach my $table (sort keys %{$refschema->{TABLES}})
        {
            foreach
                my $reftrigger (@{$refschema->{TABLES}->{$table}->{TRIGGERS}})
            {
                print UNSURE "CREATE TRIGGER ";
		print UNSURE $reftrigger->{NAME};
	        print UNSURE ' ';
                print UNSURE $reftrigger->{EVENTS};
		print UNSURE ' ON ';
                print UNSURE$schema;
                print UNSURE '.';
		print UNSURE $table;
                print UNSURE ' ';
                print UNSURE  $reftrigger->{WHEN};
                print UNSURE  ' execute procedure ';
                print UNSURE  $schema;
                print UNSURE  '.';
                print UNSURE  $reftrigger->{FUNCTION};
		print UNSURE  "();\n";
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
    while (my ($schema, $refschema) = each %{$objects->{SCHEMAS}})
    {
        my %known_names;

        # Store all known names
        foreach my $table (keys %{$refschema->{TABLES}})
        {
            $known_names{format_identifier($table)} = 1;
        }

        # We scan all types. For now, this tool only generates domains, so we scan domains
        foreach my $domain (keys %{$refschema->{DOMAINS}})
        {
            if (not defined($known_names{format_identifier($domain)}))
            {

                # Great. Just skip to the next and remember this name
                $known_names{format_identifier($domain)} = 1;
            }
            else
            {
                # We rename
                $refschema->{DOMAINS}->{$domain . "2pgd"} =
                    $refschema->{DOMAINS}->{$domain};
                delete $refschema->{DOMAINS}->{$domain};
                print STDERR
                    "Warning: I had to rename domain $domain to ${domain}2pgd because of naming conflicts between a table and a domain, in source schema $schema\n";

                # I also have to check all cols type to rename this
                while ( my ($tablename,$table) = each %{$refschema->{TABLES}})
                {
                    while (my ($colname,$col) =each  %{$table->{COLS}})
                    {

                        # If a column has a custom type, it will be prefixed by schema
                        # The schema will be the destination schema: dbo may have been replaced by public
                        # Be careful that they are stored formatted through format_identifier
                        if ($col->{TYPE} eq
                            (format_identifier($schema) . '.' . format_identifier($domain)))
                        {
                            $col->{TYPE} =
                                format_identifier($schema) . '.' . format_identifier($domain . "2pgd");
                        }
                    }
                }
                $known_names{format_identifier($domain."2pgd")}=1;
            }

        }

        # Then we scan all indexes
        foreach my $table (keys %{$refschema->{TABLES}})
        {
            foreach
                my $idx (keys %{$refschema->{TABLES}->{$table}->{INDEXES}})
            {
                if (not defined($known_names{format_identifier($idx)}))
                {

                    # Great. Just skip to the next and remember this name
                    $known_names{format_identifier($idx)} = 1;
                }
                else
                {
                    my $i = 0;
                    my $postfix = "2pgi";
                    while (defined($known_names{format_identifier("${idx}2pgi${i}")}))
                    {
                        $i++;
                    }
                    $postfix .= $i;

                    # We have to rename :/
                    # Postfix with a 2pgi followed by number
                    # We have to update the name in the $refschema hash
                    $refschema->{TABLES}->{$table}->{INDEXES}
                        ->{"${idx}${postfix}"} =
                        $refschema->{TABLES}->{$table}->{INDEXES}->{$idx};
                    delete $refschema->{TABLES}->{$table}->{INDEXES}->{$idx};
                    print STDERR
                        "Warning: I had to rename index $table.$idx to ${idx}${postfix} because of naming conflicts in source schema $schema\n";
                    $known_names{format_identifier("${idx}${postfix}")} = 1;
                }
            }
        }
    }
}

# Main

# Parse command line
my $help = 0;

my $options = GetOptions(
	 "k=s"    => \$kettle,
	 "pi=i"   => \$parallelism_in,
	 "po=i"   => \$parallelism_out,
	 "b=s"    => \$before_file,
	 "a=s"    => \$after_file,
	 "u=s"    => \$unsure_file,
	 "h"      => \$help,
	 "conf=s" => \$conf_file,
	 "sd=s"   => \$sd,
	 "sh=s"   => \$sh,
	 "si=s"   => \$si,
	 "sp=s"   => \$sp,
	 "su=s"   => \$su,
	 "sw=s"   => \$sw,
	 "pd=s"   => \$pd,
	 "ph=s"   => \$ph,
	 "pp=s"   => \$pp,
	 "pu=s"   => \$pu,
	 "pw=s"   => \$pw,
	 "f=s"    => \$filename,
	 "i"      => \$case_insensitive,
	 "nr"     => \$norelabel_dbo,
	 "num"    => \$convert_numeric_to_int,
	 "drop_rowversion"          => \$drop_rowversion,
	 "relabel_schemas=s"        => \$relabel_schemas,
	 "keep_identifier_case"     => \$keep_identifier_case,
	 "camel_to_snake"           => \$camel_to_snake,
	 "validate_constraints=s"   => \$validate_constraints,
	 "sort_size=i"              => \$sort_size,
	 "use_pk_if_possible=s"     => \$use_pk_if_possible,
	 "ignore_errors"            => \$ignore_errors,
	 "pforce_ssl"	            => \$pforce_ssl,
	 "stringtype_unspecified"   => \$stringtype_unspecified,
	 "skip_citext_length_check" => \$skip_citext_length_check,
	 "use_identity_column"      => \$use_identity_column
);

# We don't understand command line or have been asked for usage
if (not $options or $help)
{
    usage();
    exit 1;
}

# We have a configuration file. We load it, and set
# all we can find in it
if ($conf_file)
{
    parse_conf_file();
}

# Set default values for anything not set yet
set_default_conf_values();

# We have no before, after, or unsure
if (   not $before_file
    or not $after_file
    or not $unsure_file
    or not $filename)
{
    usage();
    exit 1;
}

if ($validate_constraints !~ '^(yes|after|no)$')
{
    croak "validate_constraints should be yes, after or no (default yes)\n";
}

# We have been asked for kettle, but the compulsory parameters are not there
if ($kettle
    and (   not $sd
         or not $sh
         or not $sp
         or not $su
         or not defined($sw) # password can be empty, it just has to be defined
         or not $pd
         or not $ph
         or not $pp
         or not $pu
         or not defined($pw) # password can be empty, it just has to be defined
	)
)
{
    usage();
    print
        "You have to provide all connection information, if using -k or kettle directory set in configuration file\n";
    exit 1;
}

# We need to build %relabel_schemas from $relabel_schemas
build_relabel_schemas();


# Read SQL Server's dump file
parse_dump();

# Debug, uncomment:
#print Dumper($objects);

# Rename indexes if they conflict
resolve_name_conflicts();

# Create the 3 schema files for PostgreSQL
generate_schema($before_file, $after_file, $unsure_file);

# If asked, create the kettle job
if ($kettle and (defined $ENV{'HOME'} or defined $ENV{'USERPROFILE'}))
{
    check_kettle_properties();
}

generate_kettle($kettle) if ($kettle);

#####################################################################################################################################

# Begin block to load ugly template variables
BEGIN
{
    $template = <<EOF;
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
    <size_rowset>200</size_rowset>
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
      <attribute><code>EXTRA_OPTION_MSSQL.instance</code><attribute>__sqlserver_instance__</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
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
      <attribute><code>EXTRA_OPTION_POSTGRESQL.reWriteBatchedInserts</code><attribute>true</attribute></attribute>
      __pforce_ssl__
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
      <attribute><code>SQL_CONNECT</code><attribute>set synchronous_commit to off&#x3b;</attribute></attribute>
      <attribute><code>PRESERVE_RESERVED_WORD_CASE</code><attribute>Y</attribute></attribute>
      __stringtype_unspecified__
    </attributes>
  </connection>
  <order>
    <hop>
      <from>User Defined Java Class</from>
      <to>Table output</to>
      <enabled>Y</enabled>
    </hop>
    <hop>
      <from>Table input</from>
      <to>Block this step until steps finish</to>
      <enabled>Y</enabled>
    </hop>
    <hop>
      <from>Block this step until steps finish</from>
      <to>User Defined Java Class</to>
      <enabled>Y</enabled>
    </hop>
  </order>
  <step>
    <name>Execute SQL script</name>
    <type>ExecSQL</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
    <partitioning>
      <method>none</method>
      <schema_name/>
    </partitioning>
    <connection>__postgres_db__</connection>
    <execute_each_row>N</execute_each_row>
    <single_statement>N</single_statement>
    <replace_variables>N</replace_variables>
    <quoteString>N</quoteString>
    <sql>truncate table __postgres_schema_name__.__postgres_table_name__</sql>
    <set_params>N</set_params>
    <insert_field/>
    <update_field/>
    <delete_field/>
    <read_field/>
    <arguments>
    </arguments>
    <cluster_schema/>
    <remotesteps>
      <input>
      </input>
      <output>
      </output>
    </remotesteps>
    <GUI>
      <xloc>64</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
    </GUI>
    </step>
  <step>
    <name>Block this step until steps finish</name>
    <type>BlockUntilStepsFinish</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
    <partitioning>
      <method>none</method>
      <schema_name/>
    </partitioning>
    <steps>
      <step>
        <name>Execute SQL script</name>
        <CopyNr>0</CopyNr>
        </step>
      </steps>
    <cluster_schema/>
    <remotesteps>
      <input>
      </input>
      <output>
      </output>
    </remotesteps>
    <GUI>
      <xloc>240</xloc>
      <yloc>240</yloc>
      <draw>Y</draw>
    </GUI>
    </step>
  <step>
    <name>User Defined Java Class</name>
    <type>UserDefinedJavaClass</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>

    <definitions>
        <definition>
        <class_type>TRANSFORM_CLASS</class_type>

        <class_name>Processor</class_name>

        <class_source><![CDATA[import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.Arrays;

String[] fieldNames;
long numFields;
Pattern pattern = Pattern.compile("\\00");
RowMetaInterface inputRowMeta;

public boolean processRow(StepMetaInterface smi, StepDataInterface sdi) throws KettleException
{

    // First, get a row from the default input hop
        //
        Object[] r = getRow();

    // If the row object is null, we are done processing.
        //
        if (r == null) {
                setOutputDone();
                return false;
        }

        // Let's look up parameters only once for performance reason.
        // Let's also get field types and names
        if (first) {
        inputRowMeta = getInputRowMeta();
        fieldNames = inputRowMeta.getFieldNames();
        numFields = fieldNames.length;
        int fieldnum;
        for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
            if(inputRowMeta.getValueMeta(fieldnum).getType()!= ValueMetaInterface.TYPE_STRING) {
                fieldNames[fieldnum]="-1";
            }
        }
            first=false;
        }

    Object[] outputRow = createOutputRow(r, data.outputRowMeta.size());
//    Object[] outputRow = RowDataUtil.createResizedCopy(r, data.outputRowMeta.size());
    int fieldnum;
    for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
        if (!(fieldNames[fieldnum].equals("-1"))){
            String inputStr = get(Fields.In,fieldNames[fieldnum]).getString(r);
            if (inputStr != null) { // else null pointer execption in regexp
                Matcher matcher = pattern.matcher(inputStr);
                String newfield = matcher.replaceAll("");
                get(Fields.Out,fieldNames[fieldnum]).setValue(outputRow,newfield);
            }
        }
    }

    // putRow will send the row on to the default output hop.
        //
    putRow(data.outputRowMeta, outputRow);

        return true;
}]]></class_source>
        </definition>
    </definitions>
   <fields>
    </fields><clear_result_fields>N</clear_result_fields>
<info_steps></info_steps><target_steps></target_steps><usage_parameters></usage_parameters>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>280</xloc>
      <yloc>332</yloc>
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
    <sql>SELECT __sqlserver_table_cols__ FROM __sqlserver_table_name__ WITH(NOLOCK)</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>182</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table output</name>
    <type>TableOutput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <schema>__postgres_schema_name__</schema>
    <table>__postgres_table_name__</table>
    <commit>100</commit>
    <truncate>N</truncate>
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
    $template_lob = <<EOF;
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
    <size_rowset>10</size_rowset>
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
      <attribute><code>EXTRA_OPTION_MSSQL.instance</code><attribute>__sqlserver_instance__</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
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
      <attribute><code>EXTRA_OPTION_POSTGRESQL.reWriteBatchedInserts</code><attribute>true</attribute></attribute>
      __pforce_ssl__
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
      <attribute><code>SQL_CONNECT</code><attribute>set synchronous_commit to off&#x3b;</attribute></attribute>
      <attribute><code>PRESERVE_RESERVED_WORD_CASE</code><attribute>Y</attribute></attribute>
      __stringtype_unspecified__
    </attributes>
  </connection>
  <order>
    <hop>
      <from>User Defined Java Class</from>
      <to>Table output</to>
      <enabled>Y</enabled>
    </hop>
    <hop>
      <from>Table input</from>
      <to>Block this step until steps finish</to>
      <enabled>Y</enabled>
    </hop>
    <hop>
      <from>Block this step until steps finish</from>
      <to>User Defined Java Class</to>
      <enabled>Y</enabled>
    </hop>
  </order>
  <step>
    <name>Execute SQL script</name>
    <type>ExecSQL</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
    <partitioning>
      <method>none</method>
      <schema_name/>
    </partitioning>
    <connection>__postgres_db__</connection>
    <execute_each_row>N</execute_each_row>
    <single_statement>N</single_statement>
    <replace_variables>N</replace_variables>
    <quoteString>N</quoteString>
    <sql>truncate table __postgres_schema_name__.__postgres_table_name__</sql>
    <set_params>N</set_params>
    <insert_field/>
    <update_field/>
    <delete_field/>
    <read_field/>
    <arguments>
    </arguments>
    <cluster_schema/>
    <remotesteps>
      <input>
      </input>
      <output>
      </output>
    </remotesteps>
    <GUI>
      <xloc>64</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
    </GUI>
    </step>
  <step>
    <name>Block this step until steps finish</name>
    <type>BlockUntilStepsFinish</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
    <partitioning>
      <method>none</method>
      <schema_name/>
    </partitioning>
    <steps>
      <step>
        <name>Execute SQL script</name>
        <CopyNr>0</CopyNr>
        </step>
      </steps>
    <cluster_schema/>
    <remotesteps>
      <input>
      </input>
      <output>
      </output>
    </remotesteps>
    <GUI>
      <xloc>240</xloc>
      <yloc>240</yloc>
      <draw>Y</draw>
    </GUI>
    </step>
  <step>
    <name>User Defined Java Class</name>
    <type>UserDefinedJavaClass</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>

    <definitions>
        <definition>
        <class_type>TRANSFORM_CLASS</class_type>

        <class_name>Processor</class_name>

        <class_source><![CDATA[import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.Arrays;

String[] fieldNames;
long numFields;
Pattern pattern = Pattern.compile("\\00");
RowMetaInterface inputRowMeta;

public boolean processRow(StepMetaInterface smi, StepDataInterface sdi) throws KettleException
{

    // First, get a row from the default input hop
        //
        Object[] r = getRow();

    // If the row object is null, we are done processing.
        //
        if (r == null) {
                setOutputDone();
                return false;
        }

        // Let's look up parameters only once for performance reason.
       // Let's also get field types and names
        if (first) {
        inputRowMeta = getInputRowMeta();
        fieldNames = inputRowMeta.getFieldNames();
        numFields = fieldNames.length;
        int fieldnum;
        for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
            if(inputRowMeta.getValueMeta(fieldnum).getType()!= ValueMetaInterface.TYPE_STRING) {
                fieldNames[fieldnum]="-1";
            }
        }
            first=false;
        }

    Object[] outputRow = createOutputRow(r, data.outputRowMeta.size());
//    Object[] outputRow = RowDataUtil.createResizedCopy(r, data.outputRowMeta.size());
    int fieldnum;
    for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
        if (!(fieldNames[fieldnum].equals("-1"))){
            String inputStr = get(Fields.In,fieldNames[fieldnum]).getString(r);
            if (inputStr != null) { // else null pointer execption in regexp
                Matcher matcher = pattern.matcher(inputStr);
                String newfield = matcher.replaceAll("");
                get(Fields.Out,fieldNames[fieldnum]).setValue(outputRow,newfield);
            }
        }
    }

    // putRow will send the row on to the default output hop.
        //
    putRow(data.outputRowMeta, outputRow);

        return true;
}]]></class_source>
        </definition>
    </definitions>
    <fields>
    </fields><clear_result_fields>N</clear_result_fields>
<info_steps></info_steps><target_steps></target_steps><usage_parameters></usage_parameters>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>280</xloc>
      <yloc>332</yloc>
      <draw>Y</draw>
      </GUI>
    </step>
  <step>
    <name>Table input</name>
    <type>TableInput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_IN__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__sqlserver_db__</connection>
    <sql>SELECT __sqlserver_table_cols__ FROM __sqlserver_table_name__ WITH(NOLOCK) __sqlserver_where_filter__</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>182</xloc>
      <yloc>160</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Table output</name>
    <type>TableOutput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <schema>__postgres_schema_name__</schema>
    <table>__postgres_table_name__</table>
    <commit>100</commit>
    <truncate>N</truncate>
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

    $job_header = <<EOF;
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
      <attribute><code>EXTRA_OPTION_POSTGRESQL.reWriteBatchedInserts</code><attribute>true</attribute></attribute>
      __pforce_ssl__
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
      <attribute><code>SQL_CONNECT</code><attribute>set synchronous_commit to off&#x3b;</attribute></attribute>
      <attribute><code>PRESERVE_RESERVED_WORD_CASE</code><attribute>Y</attribute></attribute>
      __stringtype_unspecified__
    </attributes>
  </connection>
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
    <entry>
      <name>SQL SCRIPT START</name>
      <description/>
      <type>SQL</type>
      <sql>__SQL_SCRIPT_INIT__</sql>
      <useVariableSubstitution>F</useVariableSubstitution>
      <sqlfromfile>F</sqlfromfile>
      <sqlfilename/>
      <sendOneStatement>F</sendOneStatement>
      <connection>__postgres_db__</connection>
      <parallel>N</parallel>
      <draw>Y</draw>
      <nr>0</nr>
      <xloc>38</xloc>
      <yloc>140</yloc>
      </entry>
    <entry>
      <name>SQL SCRIPT END</name>
      <description/>
      <type>SQL</type>
      <sql>__SQL_SCRIPT_END__</sql>
      <useVariableSubstitution>F</useVariableSubstitution>
      <sqlfromfile>F</sqlfromfile>
      <sqlfilename/>
      <sendOneStatement>F</sendOneStatement>
      <connection>__postgres_db__</connection>
      <parallel>N</parallel>
      <draw>Y</draw>
      <nr>0</nr>
      <xloc>38</xloc>
      <yloc>200</yloc>
      </entry>
EOF
####################################################################################

    $job_middle = <<EOF;
  </entries>
  <hops>
EOF
####################################################################################

    $job_footer = <<EOF;
  </hops>
  <notepads>
  </notepads>
</job>
EOF
####################################################################################

    $job_entry = <<EOF;
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

    $job_hop = <<EOF;
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

    $incremental_template= <<EOF;
<transformation>
  <info>
    <name>migration__sqlserver_table_name__</name>
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
    <size_rowset>200</size_rowset>
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
  <modified_date>2014&#47;08&#47;26 15:16:59.019</modified_date>
  </info>
  <notepads>
  </notepads>
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
      <attribute><code>EXTRA_OPTION_POSTGRESQL.reWriteBatchedInserts</code><attribute>true</attribute></attribute>
      __pforce_ssl__
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SQL_CONNECT</code><attribute>set synchronous_commit to off&#x3b;</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
      __stringtype_unspecified__
    </attributes>
  </connection>
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
      <attribute><code>EXTRA_OPTION_MSSQL.instance</code><attribute>__sqlserver_instance__</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>N</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>

  <order>
  <hop> <from>Table input 2</from><to>User Defined Java Class</to><enabled>Y</enabled> </hop>  <hop> <from>User Defined Java Class</from><to>Sort rows 2</to><enabled>Y</enabled> </hop> <hop> <from>Sort rows 2</from><to>Sorted Merge 2</to><enabled>Y</enabled> </hop> <hop> <from>Table input</from><to>Sort rows</to><enabled>Y</enabled> </hop> <hop> <from>Sort rows</from><to>Sorted Merge</to><enabled>Y</enabled> </hop>  <hop> <from>Sorted Merge</from><to>Merge Rows (diff)</to><enabled>Y</enabled> </hop>  <hop> <from>Sorted Merge 2</from><to>Merge Rows (diff)</to><enabled>Y</enabled> </hop>  <hop> <from>Merge Rows (diff)</from><to>Synchronize after merge</to><enabled>Y</enabled> </hop>  </order>
  <step>
    <name>Table input 2</name>
    <type>TableInput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__sqlserver_db__</connection>
    <sql>SELECT __sqlserver_table_cols__ FROM __sqlserver_table_name__ WITH(NOLOCK)</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>250</yloc>
      <draw>Y</draw>
      </GUI>
    </step>


  <step>
    <name>User Defined Java Class</name>
    <type>UserDefinedJavaClass</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>

    <definitions>
        <definition>
        <class_type>TRANSFORM_CLASS</class_type>

        <class_name>Processor</class_name>

        <class_source><![CDATA[import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.Arrays;

String[] fieldNames;
long numFields;
Pattern pattern = Pattern.compile("\\00");
RowMetaInterface inputRowMeta;

public boolean processRow(StepMetaInterface smi, StepDataInterface sdi) throws KettleException
{

    // First, get a row from the default input hop
        //
        Object[] r = getRow();

    // If the row object is null, we are done processing.
        //
        if (r == null) {
                setOutputDone();
                return false;
        }

        // Let's look up parameters only once for performance reason.
        // Let's also get field types and names
        if (first) {
        inputRowMeta = getInputRowMeta();
        fieldNames = inputRowMeta.getFieldNames();
        numFields = fieldNames.length;
        int fieldnum;
        for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
            if(inputRowMeta.getValueMeta(fieldnum).getType()!= ValueMetaInterface.TYPE_STRING) {
                fieldNames[fieldnum]="-1";
            }
        }
            first=false;
        }

    Object[] outputRow = createOutputRow(r, data.outputRowMeta.size());
//    Object[] outputRow = RowDataUtil.createResizedCopy(r, data.outputRowMeta.size());
    int fieldnum;
    for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
        if (!(fieldNames[fieldnum].equals("-1"))){
            String inputStr = get(Fields.In,fieldNames[fieldnum]).getString(r);
            if (inputStr != null) { // else null pointer execption in regexp
                Matcher matcher = pattern.matcher(inputStr);
                String newfield = matcher.replaceAll("");
                get(Fields.Out,fieldNames[fieldnum]).setValue(outputRow,newfield);
            }
        }
    }

    // putRow will send the row on to the default output hop.
        //
    putRow(data.outputRowMeta, outputRow);

        return true;
}]]></class_source>
        </definition>
    </definitions>
   <fields>
    </fields><clear_result_fields>N</clear_result_fields>
<info_steps></info_steps><target_steps></target_steps><usage_parameters></usage_parameters>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>280</xloc>
      <yloc>332</yloc>
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
    <connection>__postgres_db__</connection>
    <sql>SELECT __postgres_table_cols__ FROM __postgres_schema_name__.__postgres_table_name__</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>N</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>150</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Sort rows</name>
    <type>SortRows</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
      <directory>%%java.io.tmpdir%%</directory>
      <prefix>out</prefix>
      <sort_size>__sort_size__</sort_size>
      <free_memory></free_memory>
      <compress>N</compress>
      <compress_variable/>
      <unique_rows>N</unique_rows>
    <fields>
__SORT_KEYS_PG__
    </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>351</xloc>
      <yloc>161</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Sort rows 2</name>
    <type>SortRows</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
      <directory>%%java.io.tmpdir%%</directory>
      <prefix>out</prefix>
      <sort_size>__sort_size__</sort_size>
      <free_memory></free_memory>
      <compress>N</compress>
      <compress_variable/>
      <unique_rows>N</unique_rows>
    <fields>
__SORT_KEYS_SQLSERVER__
    </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>352</xloc>
      <yloc>253</yloc>
      <draw>Y</draw>
      </GUI>
    </step>
  <step>
    <name>Sorted Merge</name>
    <type>SortedMerge</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <fields>
__SORT_KEYS_PG__
      </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>428</xloc>
      <yloc>161</yloc>
      <draw>Y</draw>
      </GUI>
    </step>
  <step>
    <name>Sorted Merge 2</name>
    <type>SortedMerge</type>
    <description/>
    <distribute>Y</distribute>
    <custom_distribution/>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <fields>
__SORT_KEYS_SQLSERVER__
      </fields>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>429</xloc>
      <yloc>245</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Synchronize after merge</name>
    <type>SynchronizeAfterMerge</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <commit>100</commit>
    <tablename_in_field>N</tablename_in_field>
    <tablename_field/>
    <use_batch>N</use_batch>
    <perform_lookup>N</perform_lookup>
    <operation_order_field>__changed__</operation_order_field>
    <order_insert>new</order_insert>
    <order_update>changed</order_update>
    <order_delete>deleted</order_delete>
    <lookup>
      <schema>__postgres_schema_name__</schema>
      <table>__postgres_table_name__</table>
      __KEYS_SYNC__
      __VALUES_SYNC__
    </lookup>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>700</xloc>
      <yloc>212</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Merge Rows (diff)</name>
    <type>MergeRows</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <keys>
      __KEYS_MERGE__
    </keys>
    <values>
      __VALUES_MERGE__
    </values>
<flag_field>__changed__</flag_field>
<reference>Sorted Merge</reference>
<compare>Sorted Merge 2</compare>
    <compare>
    </compare>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>506</xloc>
      <yloc>212</yloc>
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

    $incremental_template_sortable_pk= <<EOF;
<transformation>
  <info>
    <name>migration__sqlserver_table_name__</name>
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
    <size_rowset>200</size_rowset>
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
  <modified_date>2014&#47;08&#47;26 15:16:59.019</modified_date>
  </info>
  <notepads>
  </notepads>
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
      <attribute><code>EXTRA_OPTION_POSTGRESQL.reWriteBatchedInserts</code><attribute>true</attribute></attribute>
      __pforce_ssl__
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__postgres_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SQL_CONNECT</code><attribute>set synchronous_commit to off&#x3b;</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>Y</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
      __stringtype_unspecified__
    </attributes>
  </connection>
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
      <attribute><code>EXTRA_OPTION_MSSQL.instance</code><attribute>__sqlserver_instance__</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_LOWERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>FORCE_IDENTIFIERS_TO_UPPERCASE</code><attribute>N</attribute></attribute>
      <attribute><code>IS_CLUSTERED</code><attribute>N</attribute></attribute>
      <attribute><code>MSSQL_DOUBLE_DECIMAL_SEPARATOR</code><attribute>N</attribute></attribute>
      <attribute><code>PORT_NUMBER</code><attribute>__sqlserver_port__</attribute></attribute>
      <attribute><code>QUOTE_ALL_FIELDS</code><attribute>Y</attribute></attribute>
      <attribute><code>SUPPORTS_BOOLEAN_DATA_TYPE</code><attribute>N</attribute></attribute>
      <attribute><code>USE_POOLING</code><attribute>N</attribute></attribute>
    </attributes>
  </connection>

  <order>
  <hop> <from>Table input 2</from><to>User Defined Java Class</to><enabled>Y</enabled> </hop>  <hop> <from>User Defined Java Class</from><to>Merge Rows (diff)</to><enabled>Y</enabled> </hop> <hop> <from>Table input</from><to>Merge Rows (diff)</to><enabled>Y</enabled> </hop> <hop> <from>Merge Rows (diff)</from><to>Synchronize after merge</to><enabled>Y</enabled> </hop>  </order>
  <step>
    <name>Table input 2</name>
    <type>TableInput</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__sqlserver_db__</connection>
    <sql>SELECT __sqlserver_table_cols__ FROM __sqlserver_table_name__ WITH(NOLOCK) ORDER BY __sqlserver_pk_condition__</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>Y</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>250</yloc>
      <draw>Y</draw>
      </GUI>
    </step>


  <step>
    <name>User Defined Java Class</name>
    <type>UserDefinedJavaClass</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>

    <definitions>
        <definition>
        <class_type>TRANSFORM_CLASS</class_type>

        <class_name>Processor</class_name>

        <class_source><![CDATA[import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.Arrays;

String[] fieldNames;
long numFields;
Pattern pattern = Pattern.compile("\\00");
RowMetaInterface inputRowMeta;

public boolean processRow(StepMetaInterface smi, StepDataInterface sdi) throws KettleException
{

    // First, get a row from the default input hop
        //
        Object[] r = getRow();

    // If the row object is null, we are done processing.
        //
        if (r == null) {
                setOutputDone();
                return false;
        }

        // Let's look up parameters only once for performance reason.
        // Let's also get field types and names
        if (first) {
        inputRowMeta = getInputRowMeta();
        fieldNames = inputRowMeta.getFieldNames();
        numFields = fieldNames.length;
        int fieldnum;
        for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
            if(inputRowMeta.getValueMeta(fieldnum).getType()!= ValueMetaInterface.TYPE_STRING) {
                fieldNames[fieldnum]="-1";
            }
        }
            first=false;
        }

    Object[] outputRow = createOutputRow(r, data.outputRowMeta.size());
//    Object[] outputRow = RowDataUtil.createResizedCopy(r, data.outputRowMeta.size());
    int fieldnum;
    for (fieldnum = 0; fieldnum < numFields; fieldnum++) {
        if (!(fieldNames[fieldnum].equals("-1"))){
            String inputStr = get(Fields.In,fieldNames[fieldnum]).getString(r);
            if (inputStr != null) { // else null pointer execption in regexp
                Matcher matcher = pattern.matcher(inputStr);
                String newfield = matcher.replaceAll("");
                get(Fields.Out,fieldNames[fieldnum]).setValue(outputRow,newfield);
            }
        }
    }

    // putRow will send the row on to the default output hop.
        //
    putRow(data.outputRowMeta, outputRow);

        return true;
}]]></class_source>
        </definition>
    </definitions>
   <fields>
    </fields><clear_result_fields>N</clear_result_fields>
<info_steps></info_steps><target_steps></target_steps><usage_parameters></usage_parameters>     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>280</xloc>
      <yloc>332</yloc>
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
    <connection>__postgres_db__</connection>
    <sql>SELECT __postgres_table_cols__ FROM __postgres_schema_name__.__postgres_table_name__ ORDER BY __pg_pk_condition__</sql>
    <limit>0</limit>
    <lookup/>
    <execute_each_row>N</execute_each_row>
    <variables_active>N</variables_active>
    <lazy_conversion_active>N</lazy_conversion_active>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>122</xloc>
      <yloc>150</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Synchronize after merge</name>
    <type>SynchronizeAfterMerge</type>
    <description/>
    <distribute>Y</distribute>
    <copies>__PARALLELISM_OUT__</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <connection>__postgres_db__</connection>
    <commit>100</commit>
    <tablename_in_field>N</tablename_in_field>
    <tablename_field/>
    <use_batch>N</use_batch>
    <perform_lookup>N</perform_lookup>
    <operation_order_field>__changed__</operation_order_field>
    <order_insert>new</order_insert>
    <order_update>changed</order_update>
    <order_delete>deleted</order_delete>
    <lookup>
      <schema>__postgres_schema_name__</schema>
      <table>__postgres_table_name__</table>
      __KEYS_SYNC__
      __VALUES_SYNC__
    </lookup>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>700</xloc>
      <yloc>212</yloc>
      <draw>Y</draw>
      </GUI>
    </step>

  <step>
    <name>Merge Rows (diff)</name>
    <type>MergeRows</type>
    <description/>
    <distribute>Y</distribute>
    <copies>1</copies>
         <partitioning>
           <method>none</method>
           <schema_name/>
           </partitioning>
    <keys>
      __KEYS_MERGE__
    </keys>
    <values>
      __VALUES_MERGE__
    </values>
<flag_field>__changed__</flag_field>
<reference>Table input</reference>
<compare>User Defined Java Class</compare>
    <compare>
    </compare>
     <cluster_schema/>
 <remotesteps>   <input>   </input>   <output>   </output> </remotesteps>    <GUI>
      <xloc>506</xloc>
      <yloc>212</yloc>
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

}
