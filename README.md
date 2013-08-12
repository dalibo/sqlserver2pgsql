mssql2pgsql
===========

Migration tool to convert a Microsoft SQL Server Database into a PostgreSQL database, as automatically as possible
This Perl script provides a method to migrate a database from SQL Server to PostgreSQL

It does two things:

  * convert a SQL Server schema to a PostgreSQL schema

  * produce a Pentaho Data Integrator (Kettle) job to migrate
all the data from SQL Server to PostgreSQL. This part is optionnal


Notes, warnings:
==========================
This tool will never be completely finished. For now, it works with all the SQL Server
databases I had to migrate. If it doesn't work with yours, feel free to modify this,
send me patches, or at least the SQL dump from your SQL Server Database, with the
problem you are facing.
I only tested this script under Linux. It should almost work on Windows. Will do if
someone needs it.

Installation:
==========================
Nothing to do on this part, as long as you don't want to use the data migration part.

Just run the script with your perl interpreter.

If you want to migrate the data, you'll need Kettle. Get the latest version from here:
http://kettle.pentaho.com/

As Kettle is in Java, you'll also need a JVM.

==========================

Ok, I have installed Kettle and Java, I have mssql2pg.pl, what do I do now ?

You'll need several things:

  * The connection parameters to the SQL Server database
  * Access to an empty PostgreSQL database (where you obviously will put your data)
  * A text file containing a SQL dump of the SQL Server database

To get this SQL Dump, follow this procedure:
  Under SQL Server Management Studio, Right click on the database you want to export
  Select Tasks/Generate Scripts
  Next on the welcome screen (if it hasn't already been desactivated)
  Select your database
  In the long list, just change Script Indexes from False to True, then Next
  Select Tables and Next
  Select the tables you want to export (or select all), then Next
  Script to file, choose a filename, Next
  Select unicode encoding (who knows…)
  Finish

You'll get a file containing a SQL script. Get it on the server you'll want to
run mssql2pg.pl from.

If you just want to convert this schema, run:

mssql2pg -f my_sqlserver_script.txt -b name_of_before_script -a name_of_after_script

The before script contains what is needed to import data.
The after script contains the rest (indexes, constraints), that should be restored
after data is imported.

If you want to also import data:

./mssql2pgsql.pl -b before.sql -a after.sql -k kettledir \ 
  -sd source -sh 192.168.0.2 -sp 1433 -su dalibo -sw mysqlpass \
  -pd dest -ph localhost -pp 5432 -pu dalibo -pw mypgpass -f ../schema_sql_server.sql

-k is the directory where you want to store the kettle xml files (there will be
one for each table to copy, plus the one for the job)
You'll also need to specify these, they will be stored inside the kettle files (in
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

# Run the before script (creates the tables)
> psql -U mypguser mypgdatabase -f name_of_before_script
# Run the kettle job:
cd my_kettle_installation_directory
./kitchen.sh -file=full_path_to_kettle_job_dir/migration.kjb -level=detailed
# Run the after script (creates the indexes, constraints...)
psql -U mypguser mypgdatabase -f name_of_after_script

If you want to dig deeper into the kettle job, you can use kettle_report.pl to display the individual table's performance. Then if needed you'll be able to modify the Kettle job to optimize it.
