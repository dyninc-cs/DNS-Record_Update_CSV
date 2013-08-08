#!/usr/bin/env perl

#Version 1.01.01

package DynECT::DNS_REST;

use strict;
use warnings;
use LWP::UserAgent;
use JSON;

#TODO: Write documentation with POD
#TODO: Add support for API version declaration and use
#Constructor
sub new {	
	#reference to self if first argument passed in
	my $classid = shift;
	
	my $self = {
		#LWP User agent instance
		lwp => '',		
		apitoken => '',
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
	my ($classid, $custn, $usern, $pass) = @_;

	#API login
	my $session_uri = 'https://api.dynect.net/REST/Session';
	my %api_param = (
		'customer_name' => $custn,
		'user_name' => $usern,
		'password' => $pass,
	);

	my $api_request = HTTP::Request->new('POST','https://api.dynect.net/REST/Session');
	$api_request->header ( 'Content-Type' => 'application/json' );
	$api_request->content( to_json( \%api_param ) );

	$classid->{'lwp'} = LWP::UserAgent->new;
	#diable redirect following as that is a special case with DynECT
	$classid->{'lwp'}->max_redirect( '0' );

	my $api_result = $classid->{'lwp'}->request( $api_request );

	#check if call succeeded
	my $res = $classid->check_res( $api_result );
	if ( $res ) {
		#Grab API key
		$classid->{'apitoken'} = $classid->{'resultref'}->{'data'}->{'token'};
		$classid->{'message'} = "Login successful";
		return 1;
	}

	return $res;

}

sub logout {
	#get self id
	my $classid = shift;
	#TODO: Set message if API token not set
	#existance of the API key means we are logged in
	if ( $classid->{'apitoken'} ) {
		#Logout of the API, to be nice
		my $api_request = HTTP::Request->new('DELETE','https://api.dynect.net/REST/Session');
		$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apitoken'} );
		my $api_result = $classid->{'lwp'}->request( $api_request );
		my $res =  $classid->check_res( $api_result );
		if ( $res ) {
			undef $classid->{'apitoken'};
			$classid->{'message'} = "Logout successful";
		}
		
		return $res;
	}
}

sub request {
	my ($classid, $uri, $method, $paramref) = @_;
	if (defined $paramref) {
		#weak check for correct paramater type
		unless ( ref($paramref) eq 'HASH' ) {
			$classid->{'message'} = "Invalid paramater type.  Please utilize a hash reference";
			return 0;
		}
	}
	#TODO: Check for keepalive
	if ( $uri =~ /\/REST\/Session/ ) {
		$classid->{'message'} = "Please use the ->login or ->logout for managing sessions";
		return 0;
	}

	#weak check for valid URI
	#TODO: Set this to detect start of string
	#TODO: Clean up this logic
	if ( !($uri =~ /\/REST\// ) ) {
		$classid->{'message'} = "Invalid REST URI.  Correctly formatted URIs start with '/REST/";
		return 0;
	}

	my $api_request = HTTP::Request->new(uc($method), "https://api.dynect.net$uri");
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apitoken'} );
	if (defined $paramref) {
		$api_request->content( to_json( $paramref ) );
	}

	my $api_result = $classid->{'lwp'}->request( $api_request );
	#check if call succeeded
	my $res =  $classid->check_res( $api_result );

	# If $res, set the message
	$classid->{'message'} = "Request ( $uri, $method) successful" if $res;
	
	return $res;
}


sub check_res {
	#grab self reference
	my ($classid, $api_result)  = @_;
	
	#Fail out if there is no content in the response
	unless ($api_result->content) { 
		$classid->{'message'} = "Unable to connect to API.\n Status message -\n\t" . $api_result->status_line;
		return 0;
	}

	#on initial redirect the result->code is the URI to the Job ID
	#Calling the /REST/Job will return JSON in the content of status 
	if ($api_result->code == 307) {
		sleep 2;
		my $api_request = HTTP::Request->new('GET', "https://api.dynect.net" . $api_result->content);
		$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $classid->{'apitoken'} );
		$api_result = $classid->{'lwp'}->request( $api_request );
		unless ( $api_result->content ) { 
			$classid->{'message'} = "Unable to connect to API.\n Status message -\n\t" . $api_result->status_line;
			return 0;
		}
	}

	#now safe to decode JSON
	$classid->{'resultref'} = decode_json ( $api_result->content );

	#loop until the job id comes back as success or program dies
	while ( $$classid{'resultref'}{'status'} ne 'success' ) {
		if ( $$classid{'resultref'}{'status'} ne 'incomplete' ) {
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
			#status incomplete, wait 2 seconds and check again
			sleep 2;
			my $job_uri = "https://api.dynect.net/REST/Job/$$classid{'resultref'}{'job_id'}/";
			my $api_request = HTTP::Request->new('GET',$job_uri);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$classid{'apitoken'} );
			my $api_result = $$classid{'lwp'}->request( $api_request );
			unless ( $api_result->content ) { 
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
	#call logout on destroy
	$_[0]->logout();
}


1;
