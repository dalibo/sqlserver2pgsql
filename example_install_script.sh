#!/bin/sh

# note this script does not install spoon dependencies
# ignore libwebkitgtk-1.0 errors when running kitchen.
# libwebkitgtk-1.0 is not available for RedHat/CentOS 7 or debian buster and is
# not needed for kitchen to run correctly

# on RedHat 7 / CentOS 7
# yum -y install wget unzip perl perl-MLDBM java-1.8.0-openjdk

# on debian stretch
# apt install -y wget unzip perl libmldbm-perl openjdk-8-jdk
# (on debian buster you need to install openjdk-8-jdk from sid)

MIGRATIONDIR=/opt/data_migration
mkdir -p $MIGRATIONDIR/kettlejobs

# install sqlserver2pgsql
if [ ! -f "$MIGRATIONDIR/sqlserver2pgsql.pl" ]; then
    wget https://raw.githubusercontent.com/dalibo/sqlserver2pgsql/master/sqlserver2pgsql.pl -P $MIGRATIONDIR
    # make executable
    chmod u+x,g+x,a+x $MIGRATIONDIR/sqlserver2pgsql.pl
fi

# install kettle
if [ ! -f "$MIGRATIONDIR/data-integration/kitchen.sh" ]; then
    wget https://sourceforge.net/projects/pentaho/files/latest/download?source=files -O /tmp/kettle.zip
    unzip /tmp/kettle.zip -d /tmp/kettle
    cp -R /tmp/kettle/data-integration $MIGRATIONDIR
    rm -Rf /tmp/kettle;rm -f /tmp/kettle.zip
    # make all shell scripts executable
    chmod -R u+x,g+x,a+x $MIGRATIONDIR/data-integration/*.sh
fi

# install JDBC driver (JTDS version works fine with MSSQL)
set -- $MIGRATIONDIR/data-integration/lib/jtds*
if [ ! -f "$1" ]; then
    wget https://sourceforge.net/projects/jtds/files/latest/download?source=files -O /tmp/jtds.zip
    unzip /tmp/jtds.zip -d /tmp/jtds
    # copy to kettle lib directory
    cp /tmp/jtds/jtds-*.jar $MIGRATIONDIR/data-integration/lib/
    rm -Rf /tmp/jtds;rm -f /tmp/jtds.zip
fi


