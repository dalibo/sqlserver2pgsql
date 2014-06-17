Installation:
==========================
Nothing to do on this part, as long as you don't want to use the data migration part: the script
has no dependancy on fancy Perl modules, it only uses modules from the base perl distribution.

Just run the script with your perl interpreter, providing it with the requested options (--help
will tell you what to do).

If you want to migrate the data, you'll need "Kettle", an Open Source ETL. Get the latest version
from here: http://kettle.pentaho.com/ .
You'll also need a SQL Server account with the permission to SELECT from the tables you want to migrate.

As Kettle is a Java program, you'll also need a recent JVM (Java 6 or 7 should do the trick).
