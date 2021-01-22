FAQ:
================
Why didn't you do everything in the Perl script ? I don't want to use Kettle.
----------------------------------

Because I have once installed a Perl DBD driver for Microsoft SQL server, and I don't want to ever do it again... nor 
force you to do it :) You can either do it using ODBC, or using Sybase's driver. In both case, it will take you 
quite a while, and you'll suffer with large objects.

With Kettle, on the other hand, you're using the JBDC driver, 
which is already one of Kettle's default drivers, along with PostgreSQL. So all the heavy lifting (converting 
LOBs and IMAGES and whatever to bytea) is directly done by both JDBC drivers, and should work with no efforts 
(except maybe adjust Java's memory parameters). If you get a memory error, try setting a JAVAMAXMEM environment 
variable to a higher value (4096) for 4GB for instance.

There is another big advantage of using Kettle: you can tailor the scripts produced by sqlserver2pgsql to your needs, such as adding some conversions, schema changes. As Kettle is an ETL, it is a good tool for doing such conversions on the fly.


In which order should I run the operations?
----------------------------------

sqlserver2pgsql outputs several files: before, after and unsure SQL files, plus
the kettle jobs files.

If you load all the SQL files before the data migration, you can experience
problems. For example, you can have errors when the kettle job truncates the
table at the start of the process. If a foreign key constraint is enforced,
PostgreSQL cannot truncate a table referenced in a foreign key constraint and
the job would error out.

You should first check the unsure file, verify that the SQL is fine or correct
it if needed. Some SQL orders from the unsure files are to be run before the
data migration, for example, default column values, procedures or functions,
triggers. So move them to the before file.

You can then load the before file (`before.sql`). Then use the kettle jobs to
migrate the data (`migration.kjb`). When this is done, load the rest of the
unsure and the after file (`unsure.sql` and `after.sql`).

In case you are still using the original database, a specific kettle job is
created so that you can feed the change periodically to your PostgreSQL
database (`incremental.kjb`).


What is this IGNORE NULLS I have to change in kettle.properties ?
----------------------------------

Because Kettle behaves by default the way Oracle behaves: for Oracle, a NULL and an empty string are the same. 
You don't want this here, because neither SQL Server nor PostgreSQL do this.

What problems will I face after the migration ?
----------------------------------
Here are those I faced:
* It seems that there is no way (at least with certain SQL Server versions) to tell if a constraint is enforced 
on the whole table or only for new records. Anyway, this information isn't available in the SQL dump provided by 
SQL Sever. So you may have constraints that won't validate anyway
* Case sensivity is on a per-column basis in SQL Server (you choose the collation per column, and case 
sensitivity is part of the collation). In PostgreSQL, everything is case sensitive. I tried to emulate that 
with citext, but if you can avoid it, do it. You'll have casting between citext and varchar/text everywhere, 
bad plans, etc.
* Some columns may take into account trailing spaces, some won't (it must be ansi_padding). Anyway, this 
doesn't exist either in PG. So more constraints will fail.
* PLpgSQL is very different from T-SQL, so you'll have trouble with stored procedures. It may be worth to give https://bitbucket.org/openscg/pgtsql a try …

Can this tool migrate functions and stored procedures?
----------------------------------
No, Transact-SQL is very different from PostgreSQL's many PL languages. These would need a manual migration.

