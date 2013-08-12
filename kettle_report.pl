#!/usr/bin/perl -w
use Data::Dumper;
# Reads a kettle output and returns the throughput per table
use Time::Local;

sub to_time_without_year
{
	my ($sec,$min,$hour,$day,$month)=@_;
	my $year= (localtime())[5];
	$day=$day-1; # localtime oddities
	return timelocal($sec,$min,$hour,$day,$month,$year);
}

my $start_time=0;
my $processed_rows=0;
my $current_table='';
my $current_time;
my @stats;
while (my $line = <>)
{
	# Find these lines:
	#INFO  11-04 10:15:52,092 - AgentStatEvent - Dispatching started for transformation [AgentStatEvent]
	#INFO  11-04 10:15:58,214 - Table output - Finished processing (I=0, O=68768, R=68768, W=68768, U=0, E=0)
	# The first one is the start of the job
	# The last one is the end of the output (there can be several of them)
	if (my @result=($line =~ /^INFO\s+(\d+)\-(\d+)\s+(\d+):(\d+):(\d+),(\d+).*Dispatching started.*\[(.*?)\]$/))
	{
		my ($day,$month,$hour,$min,$sec,$ms,$table)=@result;
		my $new_start_time=to_time_without_year($sec,$min,$hour,$day,$month)*1000+$ms;
		if ($current_table)
		{
			# We push the stats of the previous table
			my @data=($current_table,$new_start_time-$start_time,$processed_rows);
			push @stats,(\@data);
		}
		$start_time= $new_start_time;
		$current_table=$table;
		$processed_rows=0;

	}
	elsif (@result=($line =~ /^INFO\s+(\d+)\-(\d+)\s+(\d+):(\d+):(\d+),(\d+) - Table output - Finished processing.*O=(\d+)/))
	{
		my ($day,$month,$hour,$min,$sec,$ms,$nb_records)=@result;
		$processed_rows+=$nb_records;
		$current_time=to_time_without_year($sec,$min,$hour,$day,$month)*1000+$ms;;
	}
	else
	{
		# Just get the time
		my @result=($line =~ /^INFO\s+(\d+)\-(\d+)\s+(\d+):(\d+):(\d+),(\d+)/);
		next unless (@result);
		my ($day,$month,$hour,$min,$sec,$ms)=@result;
		$current_time=to_time_without_year($sec,$min,$hour,$day,$month)*1000+$ms;;
	}
}
# store last result
my @data=($current_table,$current_time-$start_time,$processed_rows);
push @stats,(\@data);

#print Dumper(\@stats);

# Produce output, sorted by duration
foreach my $record (sort {$b->[1] <=> $a->[1]} @stats )
{
	my ($table,$duration,$records)=@$record;
	printf "%-30s -> Duration=%-15s, Throughput=%.02f\n",$table,$duration/1000,$records/($duration/1000);
}
