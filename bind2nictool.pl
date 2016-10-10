#!/usr/bin/perl

# Script to sync local bind zones and records with NicTool based on serial.
#
# Version 1.0
# 
# Written By Shaun Reitan <shaun.reitan@ndchost.com> ( www.NDCHost.com )

use strict;
use warnings;

use NicToolServerAPI;
use DNS::ZoneParse;
use Sys::Hostname;
use Unix::PID;
use Getopt::Long;

# Set Config Defaults
my %config = (
	server 							=> 'localhost',
	port								=> '8082',
	transfer_protocol				=> 'http',
	username							=> 'nictool',
	passowrd 						=> 'nictool',
	bind_zones_path				=> '/var/named',
	remove_nonexistant_zones 	=> 0,
	force_update					=> 0,
	group_zones_limit				=> 254,
	zone_records_limit			=> 254,
	verbose							=> 0,
	pid_file							=> '/var/run/bind2nictool.pid',
	debug_soap_setup				=> 0,
	debug_soap_response			=> 0
);

my $config_file = '/etc/bind2nictool.conf';
GetOptions("configfile=s" => \$config_file);

if (! -f $config_file) {
	print STDERR "Config file $config_file does not exist or is not accessible\n";
	exit(1);
}

# Read Config
open FH, "<$config_file" or die "Failed to open /etc/$config_file for reading: $!";
while(<FH>) {
	tr/\n\r//d;
	my ($k, $v) = split /=/, $_, 2;
	$config{$k} = $v if $k && $v;
}
close FH;

# Init PID to prevent duplicate runnings of this script.
my $pid = Unix::PID->new({ ps_path => $config{'pid_file'} }) or die "Cound not create PID file at $config{'pid_file'}";

# Init NicToolServerAPI
my $nt = new NicToolServerAPI();
$NicToolServerAPI::data_protocol = "soap";
$NicToolServerAPI::server_host = $config{'server'};
$NicToolServerAPI::server_port = $config{'port'};
$NicToolServerAPI::transfer_protocol = $config{'transfer_protocol'};
$NicToolServerAPI::debug_soap_setup = $config{'debug_soap_setup'};
$NicToolServerAPI::debug_soap_response = $config{'debug_soap_response'};

# Authenticate with NicTool
my $nt_user = $nt->send_request(
	action	=> 'login',
	username => $config{'username'},
	password => $config{'password'}
);
if (!$nt_user->{'nt_user_session'}) {
	print STDERR "Error: $nt_user->{'error_msg'} ( $nt_user->{'error_code'} )\n";
	exit(1);
}

# Get list of remote zones from NicTool
my %remote_zones;
my $page=0;
my $total_pages=0;
do {
	$page++;
	my $nt_group_zones = $nt->send_request(
		action				=> 'get_group_zones',
		nt_user_session	=> $nt_user->{'nt_user_session'},
		nt_group_id			=> $nt_user->{'nt_group_id'},
		limit					=> $config{'group_zones_limit'},
		page					=> $page,
	);
	if ($nt_group_zones->{'error_msg'} ne 'OK') {
		print STDERR "Error: $nt_group_zones->{'error_msg'} ( $nt_group_zones->{'error_code'} )\n";
		exit(1);
	}
	$total_pages = $nt_group_zones->{'total_pages'};

	my @zone_ids;
	for my $nt_group_zone (@{$nt_group_zones->{'zones'}}) {
		push @zone_ids, $nt_group_zone->{'nt_zone_id'};
	}

	my $nt_zone_list = $nt->send_request(
		action				=> 'get_zone_list',
		nt_user_session	=>	$nt_user->{'nt_user_session'},
		zone_list			=> join(",", @zone_ids)
	);
	if ($nt_zone_list->{'error_msg'} ne 'OK') {
		print STDERR "Error: $nt_zone_list->{'error_msg'} ( $nt_zone_list->{'error_code'} )\n";
		exit(1);
	}

	for my $nt_zone (@{$nt_zone_list->{'zones'}}) {
		$remote_zones{$nt_zone->{'zone'}} = $nt_zone;
	}
} while($page < $total_pages);

# Remove old zones from NicTool
if ($config{'remove_nonexistant_zones'}) {
	for my $remote_zone (keys %remote_zones) {
		unless (-f $config{'bind_zones_path'} . "/" . $remote_zone . ".db") {
			print "Removing old zone from NicTool for " . $remote_zone . "\n";
			my $nt_delete_zones = $nt->send_request(
				action				=> 'delete_zones',
				nt_user_session	=> $nt_user->{'nt_user_session'},
				zone_list			=> $remote_zones{$remote_zone}->{'nt_zone_id'}
			);
			if ($nt_delete_zones->{'error_msg'} ne 'OK') {
				print STDERR "Failed to remove zone for " . $remote_zone . ": " . $nt_delete_zones->{'error_msg'} . "( " . $nt_delete_zones->{'error_code'} . " )\n";
			} else {
				print "Successfuly removed zone for " . $remote_zone . "\n";
			}
		}
	}
}

# Add new zones and records to NicTool
opendir (my $dh, "$config{'bind_zones_path'}") || die "Can't opendir $config{'bind_zones_path'}: $!";
my @local_zones = grep { /\.db$/ && -f "$config{'bind_zones_path'}/$_" } readdir($dh);
closedir $dh;

foreach my $local_zone (@local_zones) {
	my $origin = $local_zone;
	$origin =~ s/\.db$//g;

	my $nt_zone_id;

	my $zoneparse = DNS::ZoneParse->new("$config{'bind_zones_path'}/$local_zone", $origin);
	if (!$zoneparse) {
		print STDERR "Failed to parse zone $config{'bind_zones_path'}/$local_zone\n";
		next;
	}

	my $soa = $zoneparse->soa();
	if (!$soa) {
		print STDERR "Failed to get SOA information for $config{'bind_zones_path'}/$local_zone\n";
		next;
	}

	# If remote zone does not exist, create it.
	if (!$remote_zones{$origin}) {
		my $nt_new_zone = $nt->send_request(
			action				=> 'new_zone',
			nt_user_session	=> $nt_user->{'nt_user_session'},
			nt_group_id			=> $nt_user->{'nt_group_id'},
			zone					=> $origin,
			ttl					=> $soa->{'ttl'},
			serial				=> $soa->{'serial'},
			nameservers			=> $nt_user->{'usable_ns'},
			mailaddr				=> $soa->{'email'},
			description			=> 'Created by ' . hostname, 
			refresh				=> $soa->{'refresh'},
			retry					=> $soa->{'retry'},
			expire				=> $soa->{'expire'},
			minimum				=> $soa->{'minimumTTL'}
		);
		unless ($nt_new_zone->{'nt_zone_id'}) {
			print STDERR "Failed to create new zone $origin\n";
			next;
		}
		$nt_zone_id = $nt_new_zone->{'nt_zone_id'};
	} else {
		$nt_zone_id = $remote_zones{$origin}->{'nt_zone_id'};

		# If serial matches and force_update is not set, then skip.
		if ($soa->{'serial'} eq $remote_zones{$origin}->{'serial'} && !$config{'force_update'}) {
			next;
		}
		print "$origin local serial does not match remote serial: $soa->{'serial'} $remote_zones{$origin}->{'serial'}\n" if $config{'verbose'};
	}

	# It's too difficult to compare records so for now lets just remove all records and re-add them.
	while(1) {
		my $nt_zone_records = $nt->send_request(
			action				=> 'get_zone_records',
			nt_user_session	=> $nt_user->{'nt_user_session'},
			nt_zone_id			=> $nt_zone_id,
			limit					=> $config{'zone_records_limit'},
			page					=> 1
		);
		if ($nt_zone_records->{'error_msg'} ne 'OK') {
			print STDERR "Error: $nt_zone_records->{'error_msg'} ( $nt_zone_records->{'error_code'} )\n";
		}

		for my $nt_zone_record (@{$nt_zone_records->{'records'}}) {
			print "Removing record id: $nt_zone_record->{'nt_zone_record_id'} for $origin\n" if $config{'verbose'};
			$nt->send_request(
				action					=> 'delete_zone_record',
				nt_user_session		=> $nt_user->{'nt_user_session'},
				nt_zone_record_id		=> $nt_zone_record->{'nt_zone_record_id'}
			);
		}
		last if $nt_zone_records->{'total'} < 1;
	}
	
	# Add Records
	my @record_types = ('a', 'cname', 'mx', 'ptr', 'txt');
	foreach my $record_type (@record_types) {
		foreach my $record (@{$zoneparse->$record_type()}) {
			# Default params for all record types
			my %api_params = (
				action					=> 'new_zone_record',
				nt_user_session		=> $nt_user->{'nt_user_session'},
				nt_zone_record_id		=> '',
				nt_zone_id				=> $nt_zone_id,
				name						=> $record->{'name'},
				ttl						=> $record->{'ttl'},
				type						=> $record_type
			);

			# Record specific params
			if ($record_type eq 'txt') {
				$api_params{address} = $record->{'text'};
			} elsif($record_type eq 'mx') {
				$api_params{address} = $record->{'host'};
				$api_params{weight}  = $record->{'priority'};
			} else {
				$api_params{address} = $record->{'host'};
			}
		
			# Create Record
			my $nt_new_zone_record = $nt->send_request(%api_params);
			unless ($nt_new_zone_record->{'nt_zone_record_id'}) {
				print STDERR "Failed to create new zone record for $origin: $nt_new_zone_record->{'error_desc'} $nt_new_zone_record->{'msg'}\n";
			}
		}
	}

	# Edit zone, at the very least we need to set the serial because when we added all the records
	# NicTool auto increments the serial meaning when this script runs again the serial wont match.
	my $nt_edit_zone = $nt->send_request(
		action				=> 'edit_zone',
		nt_user_session	=> $nt_user->{'nt_user_session'},
		nt_zone_id			=> $remote_zones{$origin}->{'nt_zone_id'},
		nt_group_id			=> $nt_user->{'nt_group_id'},
		zone					=> $origin,
		ttl					=> $soa->{'ttl'},
		serial				=> $soa->{'serial'},
		nameservers			=> $nt_user->{'usable_ns'},
		mailaddr				=> $soa->{'email'},
		description			=> 'Updated by ' . hostname, 
		refresh				=> $soa->{'refresh'},
		retry					=> $soa->{'retry'},
		expire				=> $soa->{'expire'},
		minimum				=> $soa->{'minimumTTL'}
	);
	unless ($nt_edit_zone->{'nt_zone_id'}) {
		print STDERR "Failed to edit zone $origin\n";
		next;
	}
}
