#!/usr/bin/perl

# This script is used to sync local bind zones and records to a NicTool Server
# using the API based on the serial in the zone.
# If the serial matches the zone and all records are pulled updated on the 
# NicTool server.
# As of now, if a zone serial changes we remove all records for that zone and
# then go through and add them again. In the future I hope to have the scrip
# compare records and update them, rather than remove and add again.
#
# Written By Shaun Reitan <shaun.reitan@ndchost.com> ( www.NDCHost.com )
#

use strict;
use warnings;

use NicToolServerAPI;
use Net::DNS::ZoneFile;
use DNS::ZoneParse;
use Sys::Hostname;
use Unix::PID;
use Getopt::Long;

use Data::Dumper;

# Set Config Defaults
my %config = (
    server => 'localhost',
    port => '8082',
    transfer_protocol => 'http',
    username => 'nictool',
    password => 'nictool',
    bind_zones_path => '/var/named',
    remove_nonexistant_zones => 0,
    force_update => 0,
	group_zones_limit => 254,
	zone_records_limit => 254,
	verbose => 0,
	pid_file => '/var/run/bind2nictool.pid',
	debug_soap_setup => 0,
	debug_soap_response => 0
);

my $config_file;
my $verbose;
my $force_update;
my $domain;

GetOptions(
    "configfile=s" => \$config_file,
    "verbose+" => \$verbose,
    "force" => \$force_update,
    "domain=s" => \$domain,
    );

$config_file = '/etc/bind2nictool.conf' unless $config_file;
    if (! -f $config_file) {
	print STDERR "Config file $config_file does not exist or is not accessible\n";
	exit(1);
}

# Read Config
print "Using config file at $config_file\n" if $verbose > 1;
open FH, "<$config_file" or die "Failed to open /etc/$config_file for reading: $!";
while(<FH>) {
	tr/\n\r//d;
    # Skip lines that start with # (comments)
    next if /^#/;
    # Skip empty lines
    next if /^$/;

	my ($k, $v) = split /=/, $_, 2;
    unless(exists $config{$k}) {
        print STDERR "Unknown config option $k in config file located at $config_file\n";
        next;
    }
	$config{$k} = $v;
}
$verbose = $config{verbose} unless $verbose;
$force_update = $config{force_update} unless $force_update;
close FH;

# Override config verbose level if verbose opts where used.
$verbose = $config{verbose} unless $verbose;

# Init PID to prevent duplicate runnings of this script.
my $pid = Unix::PID->new({ ps_path => $config{'pid_file'} }) or die "Cound not create PID file at $config{'pid_file'}";

# Init NicToolServerAPI
my $nt = new NicToolServerAPI();
$NicToolServerAPI::data_protocol = "soap";
$NicToolServerAPI::server_host = $config{server};
$NicToolServerAPI::server_port = $config{port};
$NicToolServerAPI::transfer_protocol = $config{transfer_protocol};
$NicToolServerAPI::debug_soap_setup = $config{debug_soap_setup};
$NicToolServerAPI::debug_soap_response = $config{debug_soap_response};

# Authenticate with NicTool
my $nt_user = $nt->send_request(
	action	=> 'login',
	username => $config{username},
	password => $config{password}
);
unless ($nt_user->{nt_user_session}) {
	print STDERR "Error: $nt_user->{error_msg} ( $nt_user->{error_code} )\n";
	exit(1);
}

# Get list of remote zones from NicTool
my %remote_zones;
my $page=0;
my $total_pages=0;
do {
	$page++;
	my $nt_group_zones = $nt->send_request(
		action => 'get_group_zones',
		nt_user_session	=> $nt_user->{nt_user_session},
		nt_group_id => $nt_user->{nt_group_id},
		limit => $config{group_zones_limit},
		page => $page,
	);
	if ($nt_group_zones->{error_msg} ne 'OK') {
	    print STDERR "Error: $nt_group_zones->{error_msg} ( $nt_group_zones->{error_code}\n";
		exit(1);
	}
	$total_pages = $nt_group_zones->{total_pages};

	if ($nt_group_zones->{total} > 0) {
		my @zone_ids;
		for my $nt_group_zone (@{$nt_group_zones->{zones}}) {
			push @zone_ids, $nt_group_zone->{nt_zone_id};
		}

		my $nt_zone_list = $nt->send_request(
			action => 'get_zone_list',
			nt_user_session	=>	$nt_user->{nt_user_session},
			zone_list => join(',', @zone_ids)
		);
		if ($nt_zone_list->{error_msg} ne 'OK') {
			print STDERR "Error: $nt_zone_list->{error_msg} ( $nt_zone_list->{error_code} )\n";
			exit(1);
		}
	
		for my $nt_zone (@{$nt_zone_list->{zones}}) {
			$remote_zones{$nt_zone->{'zone'}} = $nt_zone;
		}
	} else {
		print "No zones on nictool server\n";
	}
} while($page < $total_pages);

# Remove old zones from NicTool
if ($config{remove_nonexistant_zones}) {
	for my $remote_zone (keys %remote_zones) {
        next if $domain && $remote_zone ne $domain;

		unless (-f "$config{bind_zones_path}/$remote_zone.db") {
			print "Deleting old zone $remote_zone\n" if $verbose;
			my $nt_delete_zones = $nt->send_request(
				action => 'delete_zones',
				nt_user_session	=> $nt_user->{nt_user_session},
				zone_list => $remote_zones{ $remote_zone}->{nt_zone_id}
			);
			if ($nt_delete_zones->{error_msg} ne 'OK') {
				print STDERR "Failed to remove zone $remote_zone : $nt_delete_zones->{error_msg} ( $nt_delete_zones->{error_code} )\n";
			}
		}
	}
}

# Add any new zones and records to NicTool
opendir (my $dh, "$config{bind_zones_path}") || die "Can't opendir $config{'bind_zones_path'}: $!";
my @local_zones = grep { /\.db$/ && -f "$config{bind_zones_path}/$_" } readdir($dh);
closedir $dh;
foreach my $local_zone (@local_zones) {
	my $origin = $local_zone;
	$origin =~ s/\.db$//g;

    # Skip if domain argument was passed and zone is not that domain
    next if $domain && $origin ne $domain;

	my $nt_zone_id;

    my $zonefile = Net::DNS::ZoneFile->new("$config{bind_zones_path}/$local_zone", $origin);

    if (!$zonefile) {
		print STDERR "Failed to parse zone $config{bind_zones_path}/$local_zone\n";
		next;
	}

    # First record returned should be the SOA
    my $rr = $zonefile->read;
    if ($rr->type ne 'SOA') {
        print STDERR "Error retreiving SOA record\n";
        next;
    }

    # Build our own SOA hash so we can make any needed changes.
    my %soa = (
        ttl => $rr->ttl,
        serial => $rr->serial,
        mailaddr => $rr->rname,
        refresh => $rr->refresh,
        retry => $rr->retry,
        expire => $rr->expire,
        minimum => $rr->minimum,
    );

    # Replace @ with . for mailaddr
    $soa{mailaddr} =~ s/@/./;
    # Append . to the end
    $soa{mailaddr} .= '.';


	# If remote zone does not exist, create it.
	if (!$remote_zones{$origin}) {
        print "Creating new zone $origin\n" if $verbose;
		my $nt_new_zone = $nt->send_request(
			action => 'new_zone',
			nt_user_session => $nt_user->{nt_user_session},
			nt_group_id => $nt_user->{nt_group_id},
			zone => $origin,
			ttl => $soa{ttl},
			serial => $soa{serial},
			nameservers => $nt_user->{usable_ns},
			mailaddr => $soa{mailaddr},
			description => 'Created by ' . hostname,
			refresh => $soa{refresh},
			retry => $soa{retry},
			expire => $soa{expire},
			minimum => $soa{minimum}
		);
		unless ($nt_new_zone->{nt_zone_id}) {
		    print STDERR "Failed to create zone $origin: $nt_new_zone->{error_msg}\n";
		    next;
		}
		
        # Get the zone we just created
		my $nt_zone = $nt->send_request(
			action => 'get_zone',
			nt_user_session => $nt_user->{nt_user_session},
			nt_zone_id => $nt_new_zone->{nt_zone_id}
		);
		unless ($nt_zone->{nt_zone_id}) {
			print STDERR "Failed to retreive newly created zone $origin\n";
			next;
		}
		$remote_zones{$nt_zone->{zone}} = $nt_zone;
	} else {
		# If serial matches and force_update is not set, then skip.
		if ($soa{serial} eq $remote_zones{$origin}->{serial} && !$force_update) {
            print "$origin serials match no update needed\n" if $verbose > 1;
            next;
        } elsif ($force_update) {
            print "$origin serials match, forcing a update\n" if $verbose > 1;
        } else {
            print "$origin serials do not match update needed\n" if $verbose > 1;
        }
    }
    # Ideally we should compare records and make the changes but that's a bit of work and since the serial changed, we know something has changed.  So we'll just delete all the existing records and re-add them.
	while(1) {
        print "$origin - getting records\n" if $verbose > 1;
	    my $nt_zone_records = $nt->send_request(
		    action => 'get_zone_records',
			nt_user_session => $nt_user->{'nt_user_session'},
			nt_zone_id => $remote_zones{$origin}->{'nt_zone_id'},
			limit => $config{'zone_records_limit'},
			page => 1
		);
		if ($nt_zone_records->{'error_msg'} ne 'OK') {
			print STDERR "Error: $nt_zone_records->{'error_msg'} ( $nt_zone_records->{'error_code'} )\n";
		}

		for my $nt_zone_record (@{$nt_zone_records->{'records'}}) {
			print 'Removing record id: ' . $nt_zone_record->{'nt_zone_record_id'} . ' from zone id: ' . $remote_zones{$origin}->{'nt_zone_id'} ."\n" if $verbose;
			$nt->send_request(
			    action => 'delete_zone_record',
				nt_user_session => $nt_user->{'nt_user_session'},
				nt_zone_record_id => $nt_zone_record->{'nt_zone_record_id'}
			);
		}
		last if $nt_zone_records->{'total'} < 1;
    }
	
	# Add Records
    while (my $rr = $zonefile->read) {
        # Defaults for all record types
        my %api_params = (
            action => 'new_zone_record',
            nt_user_session => $nt_user->{'nt_user_session'},
            nt_zone_record_id => '',
            nt_zone_id => $remote_zones{$origin}->{'nt_zone_id'},
            name => $rr->name . '.',
            ttl => $rr->ttl,
            type => lc($rr->type),
        );

        # TXT Records
        if ($rr->type eq 'TXT') {
            $api_params{address} = $rr->txtdata;

        # MX Records
        } elsif($rr->type eq 'MX') {
            $api_params{address} = $rr->exchange . '.';
            $api_params{weight} = $rr->preference;
        # SRV Records
        } elsif ($rr->type eq 'SRV') {
            $api_params{address} = $rr->target . '.';
            $api_params{priority} = $rr->priority;
            $api_params{weight} = $rr->weight;
            $api_params{other} = $rr->port;
        # A Records
        } elsif ($rr->type eq 'A') {
            $api_params{address} = $rr->address;
        # CNAME Records
        } elsif ($rr->type eq 'CNAME') {
            $api_params{address} = $rr->cname . '.';
        # NS Records, we skip these because NicTool doesn't allow setting NS records for nameservers the user doesn't have access too.
        } elsif($rr->type eq 'NS') {
            next;
        # Show an error, and skip unknown record types.
        } else {
            print STDERR "Unknown record type of " . $rr->type . "\n";
            next;
        }
    
		# Create Record
		my $nt_new_zone_record = $nt->send_request(%api_params);
		unless ($nt_new_zone_record->{'nt_zone_record_id'}) {
            print STDERR 'Error creating zone record line #' . $zonefile->line . ' from zone ' . $origin . "\n";
            print STDERR $nt_new_zone_record->{'error_desc'} . ', ' . $nt_new_zone_record->{'error_msg'} . "\n";
		}
	}

	# Edit zone, at the very least we need to set the serial because when we added all the records
	# NicTool auto increments the serial meaning when this script runs again the serial wont match.
	#
#	my $serial = $soa{serial};
	my $nt_edit_zone = $nt->send_request(
		action => 'edit_zone',
		nt_user_session => $nt_user->{'nt_user_session'},
		nt_zone_id => $remote_zones{$origin}->{'nt_zone_id'},
		nt_group_id => $nt_user->{'nt_group_id'},
		zone => $origin,
		ttl => $soa{ttl},
		serial => $soa{serial},
		nameservers => $nt_user->{'usable_ns'},
		mailaddr => $soa{mailaddr},
		description => 'Updated by ' . hostname, 
		refresh => $soa{refresh},
		retry => $soa{retry},
		expire => $soa{expire},
		minimum => $soa{minimum},
	);
	unless ($nt_edit_zone->{'nt_zone_id'}) {
		print STDERR "Failed to edit zone $origin: $nt_edit_zone->{'error_desc'} ( $nt_edit_zone->{'error_msg'} )\n";
		next;
	}
}
