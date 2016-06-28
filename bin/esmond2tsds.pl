#!/usr/bin/perl

use strict;
use warnings;

use FindBin;

# For esmond libs
use lib "$FindBin::Bin/../perfsonar-lib";

use DateTime;
use Data::Dumper;
use List::MoreUtils qw(natatime);

use JSON::XS qw(decode_json encode_json);
use LWP::Simple qw(get);

use perfSONAR_PS::Client::Esmond::ApiConnect;

use GRNOC::Config;
use GRNOC::WebService::Client;

use Getopt::Long;

use constant TSDS_TYPE_OWAMP => 'ps_owamp';
use constant TSDS_TYPE_BWCTL => 'ps_bwctl';

my $config_file = "/etc/grnoc/esmond2tsds/config.xml";
my $hours       = 1;

my $NOW = time();

GetOptions("configc|c=s" => \$config_file,   
	   "back|b=s"    => \$hours);

my $config = GRNOC::Config->new(config_file => $config_file, force_array => 0);

my $username = $config->get('/config/tsds/@user');
my $password = $config->get('/config/tsds/@password');
my $tsds_url = $config->get('/config/tsds/@url');
my $mesh_url = $config->get('/config/mesh/@url');

my $client = GRNOC::WebService::Client->new(usePost => 1,
					    uid     => $username,
					    passwd  => $password,
					    url     => $tsds_url);


my $mesh_json = get($mesh_url) or die "Can't download mesh: $mesh_url";
$mesh_json    = decode_json($mesh_json);

#
# Step 1 - parse out the host and test information from the 
# test mesh json
#

my @hosts;

my $organizations = $mesh_json->{'organizations'};
foreach my $org (@$organizations){
    my $sites = $org->{'sites'};

    foreach my $site (@$sites){
	my $hosts = $site->{'hosts'};
	
	foreach my $host (@$hosts){
	    # if we aren't using host specified measurement archives, use the
	    # the default mesh archives
	    if (! $host->{'measurement_archives'}){
		$host->{'measurement_archives'} = $mesh_json->{'measurement_archives'};
	    }

	    push(@hosts, $host);
	}
    }
}

my $tests = $mesh_json->{'tests'};


#
# Step 2 - for each test in the mesh, grab the data in Esmond so that
# we can reformat and send to TSDS
#
foreach my $test (@$tests){

    # This is very netsage specific
    if ($test->{'members'}{'type'} ne 'disjoint'){
	warn "Skipping netsage test because it's not a disjoint mesh";
	next;
    }

    my $a_members = $test->{'members'}{'a_members'};
    my $b_members = $test->{'members'}{'b_members'};

    my $interval;
    my $test_type = $test->{'parameters'}{'type'};

    if ($test_type =~ /bwctl/){
	$interval = $test->{'parameters'}{'interval'};
    }
    elsif ($test_type =~ /owamp/){
	$interval = $test->{'parameters'}{'sample_count'} * $test->{'parameters'}{'packet_interval'};
    }
    else {
	warn "Skipping unsupported test type: $test_type";
	next;
    }

    # Each a member tests to/from each b member
    foreach my $a_member (@$a_members){
	foreach my $b_member (@$b_members){

	    my $ma_url;
	    # find the MA URL. Because they're all disjoint meshes
	    # we can always use host A's MA
	    foreach my $host (@hosts){
		if (grep { $_ eq $a_member } @{$host->{'addresses'}}){
		    $ma_url = $host->{'measurement_archives'}[0]->{'read_url'};
		}
	    }

	    for (my $i = 0; $i < $hours; $i++){
		
		# get forward and reverse
		my $to_tsds_forward = get_data(from       => $a_member,
					       to         => $b_member,
					       ma_url     => $ma_url,
					       hours_back => $i,
					       interval   => $interval,
					       test_type  => $test_type);

		my $to_tsds_reverse = get_data(from       => $b_member,
					       to         => $a_member,
					       ma_url     => $ma_url,
					       hours_back => $i,
					       interval   => $interval,
					       test_type  => $test_type);
		
		#
		# Step 3
		# Send data collected for this source/dest pairing over 
		# into TSDS
		#
		my @combined = (@$to_tsds_forward, @$to_tsds_reverse);
		send_to_tsds(\@combined);
	    }
	}
    }

}

sub get_data {
    my %args = @_;
    my $a          = $args{'from'};
    my $b          = $args{'to'};
    my $url        = $args{'ma_url'};
    my $hours_back = $args{'hours_back'};
    my $interval   = $args{'interval'};
    my $test_type  = $args{'test_type'};

    my @to_tsds;

    my $end   = $NOW - ($hours_back * 3600);
    my $start = $end - 3600;

    warn "Getting from $a -> $b from $url ($start -> $end)";

    my $filters = new perfSONAR_PS::Client::Esmond::ApiFilters();
    $filters->source($a);
    $filters->destination($b);
    $filters->time_range(86400);

    my $client = new perfSONAR_PS::Client::Esmond::ApiConnect(
	url => $url,
	filters => $filters
	);
    
    my $metadata_results = $client->get_metadata();
    
    die $client->error if ($client->error); #check for errors

    foreach my $metadatum (@$metadata_results){

	my @event_types;

	if ($test_type =~ /bwctl/){
	    push(@event_types, 'throughput');
	}
	if ($test_type =~ /owamp/){
	    push(@event_types, 'packet-loss-rate');
	    push(@event_types, 'histogram-owdelay');
	}

	foreach my $event_type (@event_types){

	    warn "  $event_type\n";

	    # get data of a particular event type
	    my $et = $metadatum->get_event_type($event_type);
	    next if (! $et);

	    warn "Found $event_type";

	    $et->filters->time_start($start);
	    $et->filters->time_end($end);

	    my $data = $et->get_data();
	
	    die $et->error if ($et->error); #check for errors
	
	    # Go through and push data into TSDS format
	    foreach my $d (@$data){

		my $meta = {
		    "source"      => $a,
		    "destination" => $b
		};

		if ($event_type eq 'packet-loss-rate'){
		    push(@to_tsds, {
			"meta"     => $meta,
			"interval" => $interval,
			"type"     => TSDS_TYPE_OWAMP,
			"time"     => $d->ts,
			"values"   => {
			    "loss" => $d->val
			}
			 });
		}

		if ($event_type eq 'throughput'){
		    push(@to_tsds, {
			"meta"     => $meta,
			"interval" => $interval,
			"type"     => TSDS_TYPE_BWCTL,
			"time"     => $d->ts,
			"values"   => {
			    "throughput" => $d->val
			}
			 });
		}

		if ($event_type eq 'histogram-owdelay'){
		    my $min;
		    my $max;
		    my $sum;
		    my $count_total;
		    
		    foreach my $delay (keys %{$d->val}){
			my $count_delay = $d->val->{$delay};
			$count_total += $count_delay;
			$sum         += $delay * $count_delay;

			if (! defined $min || $delay < $min){
			    $min = $delay;
			}
			if (! defined $max || $delay > $max){
			    $max = $delay;
			}
		    }

		    push(@to_tsds, {
			"meta"     => $meta,
			"interval" => $interval,
			"type"     => TSDS_TYPE_OWAMP,
			"time"     => $d->ts,
			"values"   => {
			    "latency_min" => $min,
			    "latency_max" => $max,
			    "latency_avg" => ($sum / $count_total)
			}
			 });
		}

	    }
	}
    }

    return \@to_tsds;
}


sub send_to_tsds {
    my $data = shift;

    my $it = natatime(50, @$data);

    while (my @block = $it->()){
	my $res = $client->add_data(data => encode_json(\@block));

	if (! $res){
	    die "Error: " . $client->get_error();
	}
	
	warn Dumper($res);
    }
}
