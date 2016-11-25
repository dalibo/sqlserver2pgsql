sqlserver2pgsql
===========

This is a migration tool to convert a Microsoft SQL Server Database into a PostgreSQL database, as automatically as possible.

It is written in Perl and has received a fair amount of testing.

It does three things:

  * convert a SQL Server schema to a PostgreSQL schema
  * produce a Pentaho Data Integrator (Kettle) job to migrate 
    all the data from SQL Server to PostgreSQL (optional)
  * produce an incremental version of this job to migrate what has changed in the database from the previous run. This is created when the migration job is also created.

Please drop me a word (on github) if you use this tool, feedback is great. I also like pull requests :)

Notes, warnings:
==========================
This tool will never be completely finished. For now, it works with all the SQL Server
databases I and anyone asking for help in an issue had to migrate. If it doesn't work with yours, feel free to modify this,
send me patches, or the SQL dump from your SQL Server Database, with the
problem you are facing. I'll try to improve the code, but I need this SQL dump. Create an issue in github !

It won't migrate PL procedures, the languages are too different.

I usually only test this script under Linux. It works on Windows, as I had to do it once
with Windows, and on any Unix system.


You'll need to install a few things to make it work. See INSTALL.md

Install
==========================

See https://github.com/dalibo/sqlserver2pgsql/blob/master/INSTALL.md


Usage
=============================
Ok, I have installed Kettle and Java, I have sqlserver2pgsql.pl, what do I do now ?

You'll need several things:

  * The connection parameters to the SQL Server database:
    IP address, port, username, password, database name, instance name if not default
  * Access to an empty PostgreSQL database (where you want your migrated data)
  * A text file containing a SQL dump of the SQL Server database

To get this SQL Dump, follow this procedure, in SQL Server's management interface:
  * Under SQL Server Management Studio, Right click on the database you want to export
  * Select Tasks/Generate Scripts
  * Click "Next" on the welcome screen (if it hasn't already been desactivated)
  * Select your database
  * In the list of things you can export, just change "Script Indexes" from False to True, then "Next"
  * Select Tables then "Next"
  * Select the tables you want to export (or select all), then "Next"
  * Script to file, choose a filename, then "Next"
  * Select unicode encoding (who knows…, maybe someone has put accents in objects names, or in comments)
  * Finish

You'll get a file containing a SQL script. Get it on the server you'll want to
run sqlserver2pgsql.pl from.

If you just want to convert this schema, run:

```
./sqlserver2pgsql.pl -f input_sql_dump \
                   -b output_before_script\
                   -a output_after_script\
                   -u output_unsure_script
```

The sqlserver2pgsql Perl script processes your SQL raw dump "input_sql_dump" and produces these three scripts:

- output_before_script: contains what is needed to import data (types, tables and columns)

- output_after_script: contains the rest (indexes, constraints)

- output_unsure_script: contains objects where we attempt to migrate, but cannot guarantee, such as views

-conf uses a conf file. All options below can also be set there. Command line options will overwrite conf options.
There is an example of such a conf file (example_conf_file)

You can also use the -i, -num and/or -nr options:

-i  : Generate an "ignore case" schema, using citext, to emulate MSSQL's case insensitive collation.
      It will create citext fields, with check constraints. This type is slower on string comparison operations.

-nr : Don't convert the dbo schema to public. By default, this conversion is done, as it converts MSSQL's default
schema (dbo) to PostgreSQL's default schema (public)

-relabel_schemas is a list of schemas to remap. The syntax is : 'source1=>dest1;source2=>dest2'. Don't forget to quote this option or the shell might alter it
there is a default dbo=>public remapping, that can be cancelled with -nr. Use double quotes instead of simple quotes on Windows.

-num : Converts numeric (xxx,0) to the appropriate smallint, integer or bigint. It won't keep the constraint on
the size of the scale of the numeric. But smallint, integer and bigint types are faster than numeric.

-keep_identifier_case: don't convert the dump to all lower case. This is not recommended, as you'll have to put every identifier (column, table…) in double quotes…

-validate_constraints=yes/after/no: for foreign keys, if yes: foreign keys are created as valid in the after script (default)
                                                      if no: they are created as not valid (enforced only for new rows)
                                                      if after: they are created as not valid, but the statements to validate them are put in the unsure file


If you want to also import data:

```
./sqlserver2pgsql.pl -b before.sql -a after.sql -u unsure.sql -k kettledir \ 
    -sd source -sh 192.168.0.2 -sp 1433 -su dalibo -sw mysqlpass \
    -pd dest -ph localhost -pp 5432 -pu dalibo -pw mypgpass -f sql_server_schema.sql
```

-k is the directory where you want to store the kettle xml files (there will be
one for each table to copy, plus the one for the job)

You'll also need to specify the connection parameters. They will be stored inside the kettle files (in
cleartext, so don't make this directory public):
-sd : sql server database
-sh : sql server host
-si : sql server host instance
-sp : sql server port (usually 1433)
-su : sql server username
-sw : sql server password
-pd : postgresql database
-ph : postgresql host
-pp : postgresql port
-pu : postgresql username
-pw : postgresql password
-f  : the SQL Server structure dump file


-p  : The parallelism used in kettle jobs: there will be this amount of sessions used to insert into PostgreSQL. Default to 8
-sort_size=100000: sort size to use for incremental jobs. Default is 10000, to try to be on the safe side (see below).

We don't sort in databases for two reasons: the sort order (collation for strings for example) can be different between SQL Server
and PostgreSQL, and we don't want to stress the servers more than needed anyway. But sorting a lot of data in Java can generate a Java Out of Heap Memory error.
If you get Out of Memory errors, raise the Java Heap memory (in the kitchen script) as much as you can. If you still have the problem, reduce
this sort size. You can also try reducing parallelism, having one or two sorts instead of 8 will of course consume less memory. The last problem is that
if the sort_size is small, kettle is going to generate a very large amount of temporary files, and then read them back sorted. So you may hit the
"too many open files" limit of your system (default 1024 on linux for instance). So you'll have to do some tuning here:

  - First, use as much Java memory as you can: set the JAVAXMEM environment variable to 4096 (megabytes) or more if you can afford it. The more the better.
  - If you still get Out Of Memory errors, put a smaller sort size, until you can do the sorts (decrease it tenfold each time for example). You'll obviously lose some performance
  - If then you get the too many open files error, raise the maximum number of open files. In most Linux distributions, this is editing /etc/security/limits.conf and putting
```
@userName soft nofile 65535
@userName hard nofile 65535
```

(replace userName with your user name). Log in again, and verify with "ulimit -n" that you are now allowed to open 65535 files.
You may also have to raise the maximum number of open files on the system: echo the new value to /proc/sys/fs/file-max.

You'll need a lot of temporary space on disk to do these sorts...

You can also edit only the offending transformation with Spoon (Kettle's GUI), so that only this one is slowed down.

When Kettle crashed on one of these problems, the temporary files aren't removed. They are usually in /tmp (or in your temp directory in Windows), and start with out_. Don't forget to remove them.

-use_pk_if_possible=0/1/public.table1,myschema.table2: enable the generation of jobs doing sorts in the databases (order by in the select part of Kettle's table inputs).

1 will ask to try for all tables, or you can give a list of tables (if for example, you cannot make these tables work with a reasonable sort size). Anyway, sqlserver2pgsql will only accept
to do sorts in the database if the primary key can be guaranteed to be sorted the same way in PostgreSQL and SQL Server. That means that it only accepts if the key is made only of numeric
and date/timestamp types. If not, the standard, kettle-sorting incremental job will be generated.


Now you've generated everything. Let's do the import:

```
  # Run the before script (creates the tables)
  psql -U mypguser mypgdatabase -f name_of_before_script
  # Run the kettle job:
  cd my_kettle_installation_directory
  ./kitchen.sh -file=full_path_to_kettle_job_dir/migration.kjb -level=detailed
  # Run the after script (creates the indexes, constraints...)
  psql -U mypguser mypgdatabase -f name_of_after_script
```

If you want to dig deeper into the kettle job, you can use kettle_report.pl to display the individual table's transfer performance. Then, if needed, you'll be able to modify the Kettle job to optimize it, using Spoon, Kettle's GUI


You can also give a try to the incremental job:
```
./kitchen.sh -file=full_path_to_kettle_job_dir/incremental.kjb -level=detailed
```

This one is highly experimental. I need your feedback ! :). You should only run an incremental job on an already loaded database.

It may fail for a variety of reasons, mainly out of memory errors. If you have other unique constraints beyond the primary key, the series of queries generated by sqlserver2pgsql may generate conflicting updates. So test it several times before the migration day, if you really want to try this method. The "normal" method is safer, but of course, you'll start from scratch, and have those long indexes builds at the end.

By the way, to be able to insert data into all tables, it deactivates triggers at the beginning and activates them back at the end of the job. So, if the job fails, those triggers won't be reactivated.


You can also use a configuration file if you like:

```
./sqlserver2pgsql.pl -conf example_conf_file -f mydatabase_dump.sql
```

There is an example configuration file provided. You can also mix the configuration file with command line options. Command line options have the priority over values set in the configuration file.

FAQ
================================

See https://github.com/dalibo/sqlserver2pgsql/blob/master/FAQ.md


Licence
================================

GPL v3 : http://www.gnu.org/licenses/gpl.html
