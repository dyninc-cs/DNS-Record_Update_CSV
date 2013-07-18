#!/usr/bin/env perl

#This script works off the DynECT API to do one of two primary actions:
#1. Generate a two column CSV file where column 1 is a series of nodes withing a
#zone and column 2 is the A Record located at that node
#2. Update a zone by reading a 3 column zone extended from 1. whereas column 3 is
#the new A record to replace the record listed to the left
#-If column 1 is 'ADD' the script will add the record at that node
#-If column 2 is 'DEL' the script will delete that a record
#OPTIONS:
#-h/--help	Displays this help message
#-f/--file	File to be read for updated record information
#-z/--zone	Name of zone to be updated EG. example.com
#-g/--gen	Set this option to generate a CSV file
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
use LWP::UserAgent;
use JSON;
use Text::CSV_XS;
use Data::Dumper;

#Import DynECT handler
use FindBin;
use lib "$FindBin::Bin/DynectDNS";  # use the parent directory
use DynECTDNS;


#Get Options
my $opt_file;
my $opt_gen;
my $opt_zone;
my $opt_help;

#Read in options (long or short) from invocation
GetOptions( 
	'file=s' 	=> 	\$opt_file,
	'zone=s' 	=> 	\$opt_zone,
	'generate'	=> 	\$opt_gen,
	'help'		=>	\$opt_help,
);

#help
if ( $opt_help) {
	print "This script works off the DynECT API to generate and process CSV files\nto update A records within an account\n";
	print "\nOPTIONS:\n";
	print "-h/--help\tDisplays this help message\n";
	print "-f/--file\tFile to be read for updated record information\n";
	print "-z/--zone\tName of zone to be updated EG. example.com\n";
	print "-g/--gen\tSet this option to generate a CSV file\n";
	print "\t\tWith this option set -f will be used as the file to be written\n";
	print "\t\tWith this option set -z will be used as the zone to be read\n";
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


my $dynect = DynECTDNS->new();
$dynect->login( $apicn, $apiun, $apipw)
	or die $dynect->message;

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
		next unless $csvrow->[2];
		push ( @{ $nodes{ $csvrow->[0] }} , [ $csvrow->[1], $csvrow->[2]]);
	}
	close $fhan;

	#Call REST/AllRecord on the zone
	$dynect->request( "/REST/AllRecord/$opt_zone", 'GET')
		or die $dynect->message;

	my $keep_result = $dynect->result;


	foreach my $uri ( @{ $keep_result->{'data'} }) {
		#Skip any non-a records
		next unless $uri =~ /\/REST\/ARecord\//;
		#Process all possible matching changes
		foreach my $node ( keys %nodes ) {
			#Check to see if zone node matches
			my $regex = '\/REST\/ARecord\/' . $opt_zone . '\/([^/]+)/';
			$uri =~ /$regex/;
			next unless ( $1 eq $node);

			#Check rdata behind that URI
			$dynect->request( $uri, 'GET') or die $dynect->message;
			my $rdata = $dynect->result; 

			#Check all updates at that node for matches			
			foreach my $set ( @{ $nodes{ $node } } ) {
				next unless $rdata->{'data'}{'rdata'}{'address'} eq $set->[0];
				if ( uc($set->[1]) eq 'DEL') {
					print "Delete - $node - $set->[0]\n";
					$dynect->request( $uri, 'DELETE');  
				}
				else {
					#If so, update node
					print "Update - $node - $set->[0] => $set->[1]\n";
					my %api_param = ( rdata => { 'address' => $set->[1] });
					$dynect->request( $uri, 'put', \%api_param) or die $dynect->message; 
				}
			}
		}
	}
	
	#Check for any added records
	foreach my $node ( keys %nodes ) {
		foreach my $set ( @{ $nodes{ $node } } ) {
			next unless ( uc($set->[0]) eq 'ADD');
			#Add record
			print "Add   - $node - $set->[1]\n";
			my %api_param = ( rdata => { 'address' => $set->[1] });
			$dynect->request( "/REST/ARecord/$opt_zone/$node/", 'POST', \%api_param) or die $dynect->message;
		}
	}

	#Done making changes, publish zone
	my %api_param = ( publish => 'True' );
	$dynect->request( "/REST/Zone/$opt_zone", 'PUT', \%api_param) or die $dynect->message;
}

else {
	#Generating file for CSV
	print "Generating CSV file $opt_file for zone $opt_zone\n";

	#Get all records on zone
	$dynect->request( "/REST/AllRecord/$opt_zone", 'GET');
	my $allrec = $dynect->result;

	#Initialize CSV writer
	my $csv_write = Text::CSV_XS->new  ( { binary => 1 } ) 
		or die "Cannot use CSV: ".Text::CSV_XS->error_diag ();
	open (my $fhan,'>', $opt_file)
		or die "Unable to oepn $opt_file for writing\n";

	#iterate over all recrod URI looking for type ARecord	
	foreach my $rec_uri ( @{$allrec->{'data'}} ) {
		if ($rec_uri =~ /\/REST\/ARecord\//) {
			#if found, get RDATA from ARecord URI
			$dynect->request($rec_uri, 'GET') or die $dynect->message;
			#create array with FQDN and RDATA
			my @out_arr = ( $dynect->result->{'data'}{'fqdn'}, $dynect->result->{'data'}{'rdata'}{'address'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
	}
	close $fhan;
}

$dynect->logout;
	
