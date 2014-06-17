================================
FAQ:

Why didn't you do everything in the Perl script ? I don't want to use Kettle.

Because I have once installed a Perl DBD driver for MS SQL's server, and I don't want to ever do it again... nor 
force you to do it :) You can either do it using ODBC, or using Sybase's driver. In both case, it will take you 
quite a while, and you'll suffer with large objects. With Kettle, on the other hand, you're using the JBDC driver, 
which is already one of Kettle's default drivers, along with PostgreSQL. So all the heavy lifting (converting 
LOBs and IMAGES and whatever to bytea) is directly done by both JDBC drivers, and should work with no efforts 
(except maybe adjust Java's memory parameters). If you get a memory error, try setting a JAVAMAXMEM environment 
variable to a higher value (4096) for 4GB for instance.



What is this IGNORE NULLS I have to change in kettle.properties ?

Because Kettle behaves by default the way Oracle behaves: for Oracle, a NULL and an empty string are the same. 
You don't want this here, because neither SQL Server nor PostgreSQL do this.
