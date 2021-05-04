#!/usr/bin/perl -w

# Basic regression testing. Better than nothing.
# Sorry, I cannot share the files, some of them are customers files...
use strict;
use Data::Dumper;

foreach my $file (<*.sql>)
{
	my @options_to_try=('-i','-nr','-num', '-keep_identifier_case', '-validate_constraints=after', '-use_identity_column=0');
	my @all_combinations=('');
	foreach my $option (@options_to_try)
	{
		my @new;
		foreach my $known(@all_combinations)
		{
			push @new,($known . ' ' . ' ');
			push @new,($known . ' ' . $option);
		}
		@all_combinations=@new;
	}

	foreach my $options (@all_combinations)
	{	
		print "Running test with options = <$options>, source file $file\n";
		print "======================================\n";
		system("dropdb reg");
		system("createdb reg");
                my $command=".././sqlserver2pgsql.pl -f $file -b /tmp/before -a /tmp/after -u /tmp/unsure -k /tmp/kettle -sd 1 -sh 1 -sp 1 -su 1 -sw 1 -pd 1 -ph 1 -pp 1 -pu 1 -pw 2 $options";
                print $command,"\n";
		system($command);
		if ($? >>8)
		{
			die "Could not generate files for $file\n";
		}
		system("psql reg < /tmp/before > /tmp/before.log 2>&1");
		if ($? >>8)
		{
			die "Before script failed for $file, with options $options\n";
		}
		system("psql reg < /tmp/after > /tmp/after.log 2>&1");
		if ($? >>8)
		{
			open LOG,'/tmp/after.log';
			while (<LOG>)
			{
				print;
			}
			die "After script failed for $file, with options $options\n";
		}
		print "OK!\n";
	}
}
