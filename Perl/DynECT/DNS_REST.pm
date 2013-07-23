#!/usr/bin/env perl

package DynECT::DNS_REST;

use strict;
use warnings;
use LWP::UserAgent;
use JSON;

#Constructor
sub new {	
	#reference to self if first argument passed in
	my $classid = shift;
	
	my $self = {
		#LWP User agent instance
		lwp => '',		
		apikey => '',
		#Current status meesage
		message => '',
		#Reference to a hash for JSON decodes of most recent result
		resultref => '',
	};

	bless $self, $classid;

	return $self;
}

#API login an key generation
sub login {
	#get reference to self
	#get params from call
	my ( $classid, $custn, $usern, $pass) = @_;

	#API login
	my $session_uri = 'https://api2.dynect.net/REST/Session';
	my %api_param = (
		'customer_name' => $custn,
		'user_name' => $usern,
		'password' => $pass,
	);

	my $api_request = HTTP::Request->new('POST','https://api2.dynect.net/REST/Session');
	$api_request->header ( 'Content-Type' => 'application/json' );
	$api_request->content( to_json( \%api_param ) );

	$classid->{'lwp'} = LWP::UserAgent->new;
	my $api_result = $classid->{'lwp'}->request( $api_request );

	#check if call succeeded
	my $res = $classid->check_res( $api_result );
	if ( $res ) {
		#Grab API key
		$classid->{'apikey'} = $classid->{'resultref'}->{'data'}->{'token'};
		$classid->{'message'} = "Login successful";
		return 1;
	}
	else {
		return $res;
	}
}

sub logout {
	#get self id
	my $classid = shift;

	#existance of the API key means we are logged in
	if ( $classid->{'apikey'} ) {
		#Logout of the API, to be nice
		my $api_request = HTTP::Request->new('DELETE','https://api2.dynect.net/REST/Session');
		$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apikey'} );
		my $api_result = $classid->{'lwp'}->request( $api_request );
		my $res =  $classid->check_res( $api_result );
		if ( $res ) {
			undef $classid->{'apikey'};
			$classid->{'message'} = "Logout successful";
			return $res;
		}
		else {
			return $res;
		}
	}
}

sub request {
	my ($classid, $uri, $method) = @_;
	my $paramref = '';
	if (exists $_[3]) {
		$paramref = $_[3]; 
		#weak check for correct paramater type
		unless ( ref($paramref) eq 'HASH' ) {
			$classid->{'message'} = "Invalid paramater type.  Please utilize a hash reference";
			return 0;
		}
	}
#TODO: Set this to detect start of string
	if ( $uri =~ /\/REST\/Session/ ) {
		$classid->{'message'} = "Please use the ->login or ->logout for managing sessions";
		return 0;
		}

	#weak check for valid URI
	if ( !($uri =~ /\/REST\//) || ( uc($uri) =~ /HTTPS/ )  ) {
		$classid->{'message'} = "Invalid REST URI.  Correctly formatter URIs start with '/REST/";
		return 0;

	}

	my $api_request = HTTP::Request->new(uc($method), "https://api2.dynect.net$uri");
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apikey'} );
	if ($paramref) {
		$api_request->content( to_json( $paramref ) );
	}
	else {
		$api_request->content();
	}

	my $api_result = $classid->{'lwp'}->request( $api_request );
	#check if call succeeded
	my $res =  $classid->check_res( $api_result );
	if ( $res ) {
		$classid->{'message'} = "Request ( $uri, $method) successful";
		return $res;
	}
	else {
		return $res;
	}
}


sub check_res {
	#grab self reference
	my ($classid, $api_result)  = @_;
	
	#Fail out if there is no content in the response
	unless ($api_result->content) { 
		$classid->{'message'} = "Unable to connect to API.\n Status message -\n\t" . $api_result->status_line;
		return 0;
	}

	$classid->{'resultref'} = decode_json ( $api_result->content );

	#loop until the job id comes back as success or program dies
	while ( $classid->{'resultref'}->{'status'} ne 'success' ) {
		if ($classid->{'resultref'}->{'status'} ne 'incomplete') {
			#api stauts != sucess || incomplete would indicate an API failure
			foreach my $msgref ( @{$classid->{'resultref'}->{'msgs'}} ) {
				$classid->{'message'} = "API Error:\n";
				$classid->{'message'} .= "\tInfo: $msgref->{'INFO'}\n" if $msgref->{'INFO'};
				$classid->{'message'} .= "\tLevel: $msgref->{'LVL'}\n" if $msgref->{'LVL'};
				$classid->{'message'} .= "\tError Code: $msgref->{'ERR_CD'}\n" if $msgref->{'ERR_CD'};
				$classid->{'message'} .= "\tSource: $msgref->{'SOURCE'}\n" if $msgref->{'SOURCE'};
			};
			return 0;
		}
		else {
			#status incomplete, wait 5 seconds and check again
			sleep(5);
			my $job_uri = "https://api2.dynect.net/REST/Job/$classid->{'resultref'}->{'job_id'}/";
			my $api_request = HTTP::Request->new('GET',$job_uri);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apikey'} );
			my $api_result = $classid->{'lwp'}->request( $api_request );
			my $res = $classid->check_http( $api_result );
			#TODO: Change this check content rather than is_success
			unless ( $api_result->is_success ) { 
				$classid->{'message'} = "Unable to connect to API.\n Status message -\n\t" . $api_result->status_line;
				return 0;
			}
			$classid->{'resultref'} = decode_json( $api_result->content );
		}
	}
	return 1;
}


sub message {
	my $classid = shift; 
	return $classid->{'message'};
}

sub result {
	my $classid = shift;
	return $classid->{'resultref'};
}

sub DESTROY {
	#get self id
	my $classid = shift;
	#call logout on destroy
	$classid->logout();
}


1;
