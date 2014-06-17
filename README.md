sqlserver2pgsql
===========

This is a migration tool to convert a Microsoft SQL Server Database into a PostgreSQL database, as automatically as possible.

It is written in Perl.


It does two things:

  * convert a SQL Server schema to a PostgreSQL schema
  * produce a Pentaho Data Integrator (Kettle) job to migrate 
    all the data from SQL Server to PostgreSQL. This second part is optionnal


Notes, warnings:
==========================
This tool will never be completely finished. For now, it works with all the SQL Server
databases I had to migrate. If it doesn't work with yours, feel free to modify this,
send me patches, or the SQL dump from your SQL Server Database, with the
problem you are facing. I'll try to improve the code, but I need this SQL dump.

It won't migrate PL procedures, the languages are too different.

I usually only test this script under Linux. It should work on Windows, as I had to do it once
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
    IP address, port, username, password, database name
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

  > sqlserver2pgsql.pl -f my_sqlserver_script.txt -b name_of_before_script -a name_of_after_script -u name_of_unsure_script

The before script contains what is needed to import data (types, tables and columns).
The after script contains the rest (indexes, constraints). It should be run
after data is imported. The unsure script contains objects where we attempt to migrate, but cannot guarantee,
such as views.

-conf uses a conf file. All options below can also be set there. Command line options will overwrite conf options.
There is an example of such a conf file (example_conf_file)

You can also use the -i, -num and/or -nr options:

-i  : Generate an "ignore case" schema, using citext, to emulate MSSQL's case insensitive collation.
      It will create citext fields, with check constraints.

-nr : Don't convert the dbo schema to public. By default, this conversion is done, as it converts MSSQL's default
schema to PostgreSQL's default schema

-relabel_schemas is a list of schemas to remap. The syntax is : 'source1=>dest1;source2=>dest2'. Don't forget to quote this option or the shell might alter it
there is a default dbo=>public remapping, that can be cancelled with -nr. Use double quotes instead of simple quotes on Windows.

-num : Converts numeric (xxx,0) to the appropriate smallint, integer or bigint. It won't keep the constraint on
the size of the scale of the numeric

-validate_constraints=yes/after/no: for foreign keys, if yes: foreign keys are created as valid in the after script (default)
                                                      if no: they are created as not valid (enforced only for new rows)
                                                      if after: they are created as not valid, but the statements to validate them are put in the unsure file

If you want to also import data:

  > ./sqlserver2pgsql.pl -b before.sql -a after.sql -u unsure.sql -k kettledir \ 
    -sd source -sh 192.168.0.2 -sp 1433 -su dalibo -sw mysqlpass \
    -pd dest -ph localhost -pp 5432 -pu dalibo -pw mypgpass -f sql_server_schema.sql

-k is the directory where you want to store the kettle xml files (there will be
one for each table to copy, plus the one for the job)

You'll also need to specify the connection parameters. They will be stored inside the kettle files (in
cleartext, so don't make this directory public):
-sd : sql server database
-sh : sql server host
-sp : sql server port (usually 1433)
-su : sql server username
-sw : sql server password
-pd : postgresql database
-ph : postgresql host
-pp : postgresql port
-pu : postgresql username
-pw : postgresql password
-f  : the SQL Server structure dump file

You've generated everything. Let's do the import:

```
  # Run the before script (creates the tables)
  > psql -U mypguser mypgdatabase -f name_of_before_script
  # Run the kettle job:
  > cd my_kettle_installation_directory
  > ./kitchen.sh -file=full_path_to_kettle_job_dir/migration.kjb -level=detailed
  # Run the after script (creates the indexes, constraints...)
  > psql -U mypguser mypgdatabase -f name_of_after_script
```

If you want to dig deeper into the kettle job, you can use kettle_report.pl to display the individual table's transfer performance. Then, if needed, you'll be able to modify the Kettle job to optimize it, using Spoon, Kettle's GUI

You can also use a configuration file if you like:

  > ./sqlserver2pgsql.pl -conf example_conf_file -f mydatabase_dump.sql

There is an example configuration file provided. You can also mix the configuration file with command line options. Command line options have the priority over values set in the configuration file.

FAQ
================================

See https://github.com/dalibo/sqlserver2pgsql/blob/master/FAQ.md


Licence
================================

GPL v3 : http://www.gnu.org/licenses/gpl.html
