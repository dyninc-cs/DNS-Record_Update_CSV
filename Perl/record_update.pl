#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use LWP::UserAgent;
use JSON;
use Text::CSV_XS;

#Get Options
my $opt_file;
my $opt_gen;
my $opt_zone;
my $opt_help;

GetOptions( 
	'file=s' 	=> 	\$opt_file,
	'zone=s' 	=> 	\$opt_zone,
	'generate'	=> 	\$opt_gen,
	'help'		=>	\$opt_help,
);


if ( $opt_help) {
#TODO: HELP TEXT HERE!!!!
	print "SAMPLE HELP TEXT\n";
	exit;
}
elsif (!$opt_zone) {
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

if ( ($apicn eq 'CUSOTMER') || ($apiun eq 'USER_NAME') || ($apipw eq 'PASSWORD')) {
	print "Please change the default values in config.cfg for API login credentials\n";
	exit;
}

#API login
my $session_uri = 'https://api2.dynect.net/REST/Session';
my %api_param = ( 
	'customer_name' => $apicn,
	'user_name' => $apiun,
	'password' => $apipw,
	);

my $api_request = HTTP::Request->new('POST',$session_uri);
$api_request->header ( 'Content-Type' => 'application/json' );
$api_request->content( to_json( \%api_param ) );

my $api_lwp = LWP::UserAgent->new;
my $api_result = $api_lwp->request( $api_request );

my $api_decode = decode_json ( $api_result->content ) ;
my $api_key = $api_decode->{'data'}->{'token'};

if ( !$opt_gen ) {
	my $csv_read = Text::CSV_XS->new  ( { binary => 1 } )
		or die "Cannot use CSV: ".Text::CSV_XS->error_diag ();
	open (my $fhan, '<', $opt_file) 
		or die "Unable to open file $opt_file";
	
	#Hash to store all nodes that need updating to avoid processing the same node more than once
	my %nodes;
	while ( my $csvrow = $csv_read->getline( $fhan )) {
		next unless $csvrow->[2];
		push ( @{ $nodes{ $csvrow->[0] }} , [ $csvrow->[1], $csvrow->[2]]);
	}
	close $fhan;

	my $allrec_uri = "https://api2.dynect.net/REST/AllRecord/$opt_zone";
	$api_request = HTTP::Request->new('GET',$allrec_uri);
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
	$api_request->content();
	$api_result = $api_lwp->request($api_request);
	$api_decode = decode_json( $api_result->content);
	$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');
	my $keep_decode = $api_decode;


	foreach my $uri ( @{ $keep_decode->{'data'} }) {
		next unless $uri =~ /\/REST\/ARecord\//;
		foreach my $node ( keys %nodes ) {
			my $regex = '\/REST\/ARecord\/' . $opt_zone . '\/([^/]+)/';
			$uri =~ /$regex/;
			next unless ( $1 eq $node);

			my $arec_uri = "https://api2.dynect.net$uri";
			$api_request = HTTP::Request->new('GET',$arec_uri);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
			$api_request->content();
			$api_result = $api_lwp->request($api_request);
			$api_decode = decode_json( $api_result->content);
			$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');
			
			foreach my $set ( @{ $nodes{ $node } } ) {
				next unless $api_decode->{'data'}{'rdata'}{'address'} eq $set->[0];
					print "Updating $node from $set->[0] => $set->[1]\n";
					$api_request = HTTP::Request->new('PUT',$arec_uri);
					$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
					%api_param = ( rdata => { 'address' => $set->[1] });
					$api_request->content( to_json( \%api_param ) );
					$api_result = $api_lwp->request($api_request);
					$api_decode = decode_json( $api_result->content);
					$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');
			}
		}
	}

	print "Publishing updates to zone $opt_zone\n";
	my $zone_uri = "https://api2.dynect.net/REST/Zone/$opt_zone";
	$api_request = HTTP::Request->new('PUT',$zone_uri);
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
	%api_param = ( publish => 'True' );
	$api_request->content( to_json( \%api_param ));
	$api_result = $api_lwp->request($api_request);
	$api_decode = decode_json( $api_result->content);
	$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');
}

else {
	#Generating file for CSV
	print "Generating CSV file $opt_file for zone $opt_zone\n";

	my $allrec_uri = "https://api2.dynect.net/REST/AllRecord/$opt_zone";
	$api_request = HTTP::Request->new('GET',$allrec_uri);
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
	$api_request->content();
	$api_result = $api_lwp->request($api_request);
	$api_decode = decode_json( $api_result->content);
	$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');

	my $csv_write = Text::CSV_XS->new  ( { binary => 1 } ) 
		or die "Cannot use CSV: ".Text::CSV_XS->error_diag ();
	open (my $fhan,'>', $opt_file)
		or die "Unable to oepn $opt_file for writing\n";

	#iterate over all recrod URI looking for type ARecord	
	foreach my $rec_uri ( @{$api_decode->{'data'}} ) {
		if ($rec_uri =~ /\/REST\/ARecord\//) {
			#if found, get RDATA from ARecord URI
			$api_request = HTTP::Request->new('GET',"https://api2.dynect.net$rec_uri");
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
			$api_request->content();
			$api_result = $api_lwp->request($api_request);
			$api_decode = decode_json( $api_result->content);
			$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');
			#create array with FQDN and RDATA
			my @out_arr = ( $api_decode->{'data'}{'fqdn'}, $api_decode->{'data'}{'rdata'}{'address'});
			#attempt to combine the FQDN and the RDATA into a CSV string and if success print to file
			if ( $csv_write->combine(@out_arr) ) {
				print $fhan ($csv_write->string() . "\n");
			}
		}
	}
	close $fhan;
}
	

#api logout
$api_request = HTTP::Request->new('DELETE',$session_uri);
$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
$api_result = $api_lwp->request( $api_request );
$api_decode = decode_json ( $api_result->content);

#Expects 2 variable, first a reference to the API key and second a reference to the decoded JSON response
sub api_fail {
	my ($api_keyref, $api_jsonref) = @_;
	#set up variable that can be used in either logic branch
	my $api_request;
	my $api_result;
	my $api_decode;
	my $api_lwp = LWP::UserAgent->new;
	my $count = 0;
	#loop until the job id comes back as success or program dies
	while ( $api_jsonref->{'status'} ne 'success' ) {
		if ($api_jsonref->{'status'} ne 'incomplete') {
			foreach my $msgref ( @{$api_jsonref->{'msgs'}} ) {
				print "API Error:\n";
				print "\tInfo: $msgref->{'INFO'}\n" if $msgref->{'INFO'};
				print "\tLevel: $msgref->{'LVL'}\n" if $msgref->{'LVL'};
				print "\tError Code: $msgref->{'ERR_CD'}\n" if $msgref->{'ERR_CD'};
				print "\tSource: $msgref->{'SOURCE'}\n" if $msgref->{'SOURCE'};
			};
			#api logout or fail
			$api_request = HTTP::Request->new('DELETE','https://api2.dynect.net/REST/Session');
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$api_keyref );
			$api_result = $api_lwp->request( $api_request );
			$api_decode = decode_json ( $api_result->content);
			exit;
		}
		else {
			sleep(5);
			my $job_uri = "https://api2.dynect.net/REST/Job/$api_jsonref->{'job_id'}/";
			$api_request = HTTP::Request->new('GET',$job_uri);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$api_keyref );
			$api_result = $api_lwp->request( $api_request );
			$api_jsonref = decode_json( $api_result->content );
		}
	}
	$api_jsonref;
}
