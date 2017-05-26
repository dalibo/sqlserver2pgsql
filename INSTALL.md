Installation:
==========================
Nothing to do on this part, as long as you don't want to use the data migration part: the script
has no dependancy on fancy Perl modules, it only uses modules from the base perl distribution.

Just run the script with your perl interpreter, providing it with the requested options (--help
will tell you what to do).

If you are trying to run the script under Windows, you probably won't have a Perl interpreter. I recommand you use the latest Strawberry Perl (use either the installer or the portable version).

Kettle:
==========================
If you want to migrate the data, you'll need "Kettle", an Open Source ETL. Get the latest version
from here: http://kettle.pentaho.com/ .

On newest versions of Kettle, the SQL Server java driver isn't included. You'll need this one: http://jtds.sourceforge.net/. Just download the zip file (jtds-1.3.1-dist.zip at the time of this writing), extract the jar file (jtds-1.3.1.jar) and put this file in the lib directory of Kettle.

If you don't want to bother with installing a JVM system-wide for Kettle, just download Sun's JVM and put in in Kettle's directory, in a "java" subdirectory. Latest versions of Kettle require Java 8.

You'll also need a SQL Server account with the permission to SELECT from the tables you want to migrate.


