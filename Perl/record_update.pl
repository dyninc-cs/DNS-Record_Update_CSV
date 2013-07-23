#!/usr/bin/env perl

#This script works off the DynECT API to do one of two primary actions:
#1. Generate a CSV file with the followiing format:
#fqdn, rtype, rdata, ttl
#2. Update a zone by reading the csv whereas column 5-7 are in this format
#newrtype, newrdata, ttl
#-If column 2 is 'ADD' the script will add the record at that node
#-If column 5 is 'DEL' the script will delete that a record
#OPTIONS:
#-h/--help		Displays this help message
#-f/--file		File to be read for updated record information
#-z/--zone		Name of zone to be updated EG. example.com
#-g/--gen		Set this option to generate a CSV file
#-d/--dryrun 	Set this run to interpret the CSV file and exit
#				withouth publishing changes
#-c/--confirm	Require confrimation before publishing changes
#--noconfirm	Automatically publish changes without confrimaiton
#With this option set -f will be used as the file to be written
#With this option set -z will be used as the zone to be read
#
#EXAMPLE USGAGE:
#perl record_update.pl -f ips.csv -z example.com
#-Read udpates from ips.csv and apply them to example.com
#
#perl record_updates.pl -f gen.csv -z example.com --gen
#-Read example.com and generate a CSV file from its current A records


use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use Text::CSV_XS;

#Import DynECT handler
use FindBin;
use lib "$FindBin::Bin/DynECT";  # use the parent directory
require DynECT::DNS_REST;

#Get Options
my $opt_file;
my $opt_gen;
my $opt_zone;
my $opt_help;
my $opt_confirm=2;
my $opt_dryrun;

#Read in options (long or short) from invocation
GetOptions( 
	'file=s' 	=> 	\$opt_file,
	'zone=s' 	=> 	\$opt_zone,
	'generate'	=> 	\$opt_gen,
	'help'		=>	\$opt_help,
	'confirm!'	=>	\$opt_confirm,
	'dryrun'	=>	\$opt_dryrun,
);


#help
if ( $opt_help) {
	print "This script works off the DynECT API to generate and process CSV files\nto update A records within an account\n";
	print "\nOPTIONS:\n";
	print "-h/--help\t\tDisplays this help message\n";
	print "-f/--file\t\tFile to be read for updated record information\n";
	print "-g/--gen\t\tSet this option to generate a CSV file\n";
	print "-d/--dryrun\t\tSet this run to interpret the CSV file and exit\n\t\t\twithouth publishing changes\n";
	print "-c/--confirm\t\tRequire confrimation before publishing changes\n";
	print "--noconfirm\t\tAutomatically publish changes without confrimaiton\n";
	print "-z/--zone\t\tName of zone to be updated EG. example.com\n";
	print "\t\t\tWith this option set -f will be used as the file to be written\n";
	print "\t\t\tWith this option set -z will be used as the zone to be read\n";
	print "\nEXAMPLE USGAGE:\n";
	print "perl record_update.pl -f ips.csv -z example.com\n";
	print "-Read udpates from ips.csv and apply them to example.com\n\n";
	print "perl record_updates.pl -f gen.csv -z example.com --gen\n";
	print "-Read example.com and generate a CSV file from its current A records\n\n";
	exit;
}
if (!$opt_zone) {
	print "-z or --zone option required\n";
	exit;
}
elsif (!$opt_file) {
	print "-f or --file option required\n";
	exit;
}

#Create config reader
my $cfg = new Config::Simple();

# read configuration file (can fail)
$cfg->read('config.cfg') or die $cfg->error();

#dump config variables into hash for later use
my %configopt = $cfg->vars();
my $apicn = $configopt{'cn'} or do {
	print "Customer Name required in config.cfg for API login\n";
	exit;
};

my $apiun = $configopt{'un'} or do {
	print "User Name required in config.cfg for API login\n";
	exit;
};

my $apipw = $configopt{'pw'} or do {
	print "User password required in config.cfg for API login\n";
	exit;
};

#The github version comes with example values that should be changed
if ( ($apicn eq 'CUSOTMER') || ($apiun eq 'USER_NAME') || ($apipw eq 'PASSWORD')) {
	print "Please change the default values in config.cfg for API login credentials\n";
	exit;
}

#check usage options for record types
my ($use_arec, $use_aaaa, $use_cname, $use_txt);
$use_arec = $use_aaaa = $use_cname = $use_txt = 1;
$use_arec = 0 if (uc($configopt{'AREC'}) ne 'ON');
$use_aaaa = 0 if (uc($configopt{'AAAA'}) ne 'ON');
$use_cname = 0 if (uc($configopt{'CNAME'}) ne 'ON');
$use_txt = 0 if (uc($configopt{'TXT'}) ne 'ON');


#confmode: 0= No confirm 1= Confirm
my $confmode = 0;
if ( $opt_confirm == 2 ) { #default from command line
	$confmode = 1 if (uc($configopt{'CONFIRM_MODE'}) ne 'OFF')
}
else {
	$confmode = $opt_confirm;
}


#create a DynECT API object and login
my $dynect = DynECT::DNS_REST->new();
$dynect->login( $apicn, $apiun, $apipw)
	or die $dynect->message . ":$!";

if ( !$opt_gen ) { 
	#Create CSV reader 
	my $csv_read = Text::CSV_XS->new  ( { binary => 1 } )
		or die "Cannot use CSV: ".Text::CSV_XS->error_diag ();
	open (my $fhan, '<', $opt_file) 
		or die "Unable to open file $opt_file";
	
	#Hash to store all nodes that need updating to avoid processing the same node more than once
	my %nodes;
	#Read in all changes
	while ( my $csvrow = $csv_read->getline( $fhan )) {
		next unless $csvrow->[4];
		foreach ( @$csvrow ) {
			#Eliminate all leading and trailing whitepace
			$_ =~ s/^\s+//;
			$_ =~ s/\s+$//;
		}
		push ( @{ $nodes{ shift @$csvrow }} , [@$csvrow]);
	}
	close $fhan;
	
	#storage by node name for updates
	my %summary;

	$dynect->request("/REST/AllRecord/$opt_zone/",'GET')
		or die $dynect->message . ":$!";
	#precompile a regex to capture the FQDN from the record URI
	my $regex = qr/\/REST\/([^\/]+)\/$opt_zone\/([^\/]+)\//;

	foreach my $uri ( @{$dynect->result->{'data'}}) {
		#run capture
		$uri =~ $regex;
		my $rtype = $1;
		my $node = $2;
		if ( exists $nodes{$node} ) {
			next if ( $rtype eq 'ARecord' && !$use_arec);
			next if ( $rtype eq 'AAAARecord' && !$use_aaaa);
			next if ( $rtype eq 'TXTRecord' && !$use_txt);
			next if ( $rtype eq 'CNAMERecord' && !$use_cname);
			$dynect->request($uri, 'GET') 
				or die $dynect->message . ":$!";
			#get the rdata regardless of type by dynamically generating the keys for the rdata hash
			my $rclass = (keys $dynect->result->{'data'}->{'rdata'})[0];
			my $rdata = $dynect->result->{'data'}->{'rdata'}->{$rclass};
			
			#This foreach loop is broken by last call  in record -> cname handling
			foreach my $update ( @{$nodes{$node}} ) {
				#skip unless this is the record we want to update
				next unless $rdata eq $update->[1];
				#Check for same record types
				if ($update->[0] eq $update->[3]) {
					$summary{$node} .= "UPDATE\t$update->[3]\t$rdata -> $update->[4]\n";
					my %api_param = (
						rdata => {
							$rclass => $update->[4]
						}
					);
					#set new TTL if new TTL is defined
					$api_param{'ttl'} = $update->[5] if $update->[5];
					$dynect->request($uri,'PUT',\%api_param) or die $dynect->message . ":$!";
				}
				elsif ( (uc($update->[3]) eq 'A') || (uc($update->[3]) eq 'AAAA') || (uc($update->[3]) eq 'CNAME') || (uc($update->[3]) eq 'TXT') ) {
					my $newrclass;
					$newrclass = 'address' if (uc($update->[3]) eq 'A'); 
					$newrclass = 'address' if (uc($update->[3]) eq 'AAAA'); 
					$newrclass = 'txtdata' if (uc($update->[3]) eq 'TXT'); 
					$newrclass = 'cname' if (uc($update->[3]) eq 'CNAME'); 
					my $newrtype = uc($update->[3]) . 'Record';
					if ( uc($update->[3]) ne 'CNAME') {
						$summary{$node} .= "DELETE\t$update->[0]\t$rdata\n";
						$summary{$node} .= "ADD\t$update->[3]\t$update->[4]\n";
						#safe to delete current record and put in new one
						$dynect->request($uri,'DELETE') or die $dynect->message . ":$!";
						my %api_param = (
							rdata => {
								$newrclass => $update->[4]
							}
						);
						#set new TTL if new TTL is defined
						$api_param{'ttl'} = $update->[5] if $update->[5];
						$dynect->request("/REST/$newrtype/$opt_zone/$node/",'POST',\%api_param) or die $dynect->message . ":$!";
					}
					else {
						$summary{$node} .= "PRUNE\tNODE\t$node\n";
						$summary{$node} .= "ADD\tCNAME\t$update->[4]\n";
						#need to prune all records at node to add CNAME
						$dynect->request("/REST/AllRecord/$opt_zone/$node/",'GET') or die $dynect->message . ":$!";
						foreach my $deluri ( @{$dynect->result->{'data'}} ) {
							$dynect->request($deluri,'DELETE') or die $dynect->message . ":$!";
						}
						my %api_param = (
							rdata => {
								$newrclass => $update->[4]
							}
						);
						#set new TTL if new TTL is defined
						$api_param{'ttl'} = $update->[5] if $update->[5];
						$dynect->request("/REST/$newrtype/$opt_zone/$node/",'POST',\%api_param) or die $dynect->message . ":$!";
						#Prevent any additional updates agains that node
						delete $nodes{$node};
						last;
					}
				}
				#everything else SHOULD  be a DELETE
				elsif ( uc($update->[3]) eq 'DEL' ) {
					$summary{$node} .= "DELETE\t$update->[0]\t$rdata\n";
					$dynect->request($uri,'DELETE') or die $dynect->message . ":$!";
				}
				else {
					print "Invalid command: $node, ";
					foreach ( @$update ) {
						print "$_, " if $_;
					}
					print "\n";
				}
					
			}
		}
	}
	#do all record adds
	foreach my $node ( keys %nodes ) {
	   foreach my $update ( @{ $nodes{ $node } } ){
			next unless ( uc($update->[0]) eq 'ADD' );
			my $newrclass;
			$newrclass = 'address' if (uc($update->[3]) eq 'A'); 
			$newrclass = 'address' if (uc($update->[3]) eq 'AAAA'); 
			$newrclass = 'txtdata' if (uc($update->[3]) eq 'TXT'); 
			$newrclass = 'cname' if (uc($update->[3]) eq 'CNAME'); 
			my $newrtype = uc($update->[3]) . 'Record';
			$summary{$node} .= "ADD\t$update->[3]\t$update->[4]\n";
			my %api_param = (
				rdata => {
					$newrclass => $update->[4]
				}
			);
			#set new TTL if new TTL is defined
			$api_param{'ttl'} = $update->[5] if $update->[5];
			$dynect->request("/REST/$newrtype/$opt_zone/$node/",'POST',\%api_param) or die $dynect->message . ":$!";
		}
	}
	#this code block could display pending changes, but no was to determine deletes from creates
	if ( 1 == 0) {
		$dynect->request("/REST/ZoneChanges/$opt_zone/",'GET');
		my %changes;
		foreach my $change ( @{$dynect->result->{'data'}} ) {
			my $rtype = $change->{'rdata_type'};
			my $rdkey = 'rdata_' . lc($rtype);
			$changes{ $change->{'fqdn'} } .= "\n\tRType: $change->{'rdata_type'}\n\tRData: ";
			foreach my $rdata (keys $change->{'rdata'}->{$rdkey }) {
				$changes{ $change->{'fqdn'} } .= $change->{'rdata'}->{$rdkey}->{$rdata};
			}
		}
		print "Pending Changset:\n";
		foreach my $node ( sort keys %changes ) {
			print "\nNode: $node $changes{$node}\n";
		}
	}

	#print pending changes;
	my $printsum;
	foreach my $node ( keys %summary ) {
		$printsum .= "Node: $node\n" . $summary{$node} . "\n";
	}
	print "Pending Changes:\n\n$printsum";
	
	#check if the user wants to make changes
	exit if $opt_dryrun;
	if ( $confmode) {
		print "Please confirm changes by typing 'CONFIRM'\n:";

		while (<STDIN>) {
			my $input = $_;
			chomp $input;
			exit if (uc($input) eq 'EXIT');
			last if ( $input eq 'CONFIRM');
			if ( uc($input) eq 'CHANGES' ) {
				print "Pending Changes:\n\n$printsum";
				next;
			}
			print "Invalid input: $input.  Options:\n\tCONFIRM\tConfirm changes and continue\n\tEXIT  \tCancel and exit program\n";
			print "\tCHANGES\tPrint pending changes\n:";
		}
	}

	print "publishing zone $opt_zone in 10 seconds ...\n";
	sleep(10);
	print "Publishing zone $opt_zone\n";
	my %publish_param = ( 'publish' => 'true' );
	$dynect->request( "/REST/Zone/$opt_zone/",'PUT',\%publish_param) or die $dynect->message . ":$!";

}

else {
	#Generating file for CSV
	print "Generating CSV file $opt_file for zone $opt_zone.\nPlease wait, this may take a few moments\n";

	#Get all records on zone
	$dynect->request( "/REST/AllRecord/$opt_zone", 'GET');
	my $allrec = $dynect->result;

	#Initialize CSV writer
	my $csv_write = Text::CSV_XS->new  ( { binary => 1 } ) 
		or die "Cannot use CSV: ".Text::CSV_XS->error_diag ();
	open (my $fhan,'>', $opt_file)
		or die "Unable to oepn $opt_file for writing\n";


	#iterate over all recrod URI looking for each record type	
	foreach my $rec_uri ( @{$allrec->{'data'}} ) {
		if ($rec_uri =~ /\/REST\/ARecord\//) {
			#move on if rtype is turned off
			next unless $use_arec;
			#if found, get RDATA from URI
			$dynect->request($rec_uri, 'GET') or die $dynect->message . ":$!";
			#create array with FQDN , RTYPE, RDATA, TTL
			my @out_arr = ( $dynect->result->{'data'}{'fqdn'},$dynect->result->{'data'}{'record_type'}, 
				$dynect->result->{'data'}{'rdata'}{'address'},$dynect->result->{'data'}{'ttl'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
		elsif ($rec_uri =~ /\/REST\/AAAARecord\//) {
			#move on if rtype is turned off
			next unless $use_aaaa;
			#if found, get RDATA from URI
			$dynect->request($rec_uri, 'GET') or die $dynect->message . ":$!";
			#create array with FQDN , RTYPE, RDATA, TTL
			my @out_arr = ( $dynect->result->{'data'}{'fqdn'},$dynect->result->{'data'}{'record_type'}, 
				$dynect->result->{'data'}{'rdata'}{'address'},$dynect->result->{'data'}{'ttl'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
		elsif ($rec_uri =~ /\/REST\/TXTRecord\//) {
			#move on if rtype is turned off
			next unless $use_txt;
			#if found, get RDATA from URI
			$dynect->request($rec_uri, 'GET') or die $dynect->message . ":$!";
			#create array with FQDN , RTYPE, RDATA, TTL
			my @out_arr = ( $dynect->result->{'data'}{'fqdn'},$dynect->result->{'data'}{'record_type'}, 
				$dynect->result->{'data'}{'rdata'}{'txtdata'},$dynect->result->{'data'}{'ttl'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
		elsif ($rec_uri =~ /\/REST\/CNAMERecord\//) {
			#move on if rtype is turned off
			next unless $use_cname;
			#if found, get RDATA from URI
			$dynect->request($rec_uri, 'GET') or die $dynect->message . ":$!";
			#create array with FQDN , RTYPE, RDATA, TTL
			my @out_arr = ( $dynect->result->{'data'}{'fqdn'},$dynect->result->{'data'}{'record_type'}, 
				$dynect->result->{'data'}{'rdata'}{'cname'},$dynect->result->{'data'}{'ttl'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
	}
	close $fhan;
}

#logout of the API
$dynect->logout;
	
