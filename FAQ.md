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
