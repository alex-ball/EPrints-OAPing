
=head1 NAME

B<EPrints::Plugin::Event::OAPingEvent> - Event task to ping OpenAIRE

=head1 SYNOPSIS

Adapted from the official EPrints support package,
L<OAPiwik|https://github.com/openaire/EPrints-OAPiwik>.

Relies on the following configuration settings:

	# cfg.d/oaping.pl
	$c->{oaping}->{tracker} - tracker URL
	$c->{oaping}->{verbosity} - 0 or 1

	# cfg.d/x_oaping.pl
	$c->{oaping}->{idsite} - site identifier
	$c->{oaping}->{token_auth} - authorization token

=head1 DESCRIPTION

See L<EPrints::Plugin::Event> for standard methods.

There are two different jobs provided, corresponding to two phases of
operation.

With C<legacy_notify>, the job goes progresses through the entire table of
access events. A fake-but-likely request URL is generated for each one. With
each run of the job, a batch of up to 100 access events is sent to the tracker,
progress is recorded in a log for safety, and the job respawns to send the next
batch in 60 seconds. In the event of an error, the current batch is saved to a
folder, and the job respawns in 60 minutes. On the next run, the saved batch is
reloaded and and the request is retried. If the request does not succeed for 24
hours, the job stops respawning; however, after a successful retry, normal
operation resumes with the next batch. When spawning a new job, the status of
the last run is included as a parameter for the sake of visibility, but is not
otherwise used.

The C<notify> job is intended to be triggered each time a new access event is
added to the database. Normally a HEAD request is sent to the tracker with the
tracking information provided in the query string; on error, the access event is
saved to a folder. If the job is run while there are saved access events, the
saved ones are loaded and removed, the triggering event is added to them, and
they are sent as a batch. If there are more than 100 to send in this way, only
the first 100 are sent, and the rest are saved back to the folder.

If the C<notify> job detects a log file left behind by C<legacy_notify>, it will
load the access events between the last one sent by C<legacy_notify> and the
triggering event, and rename the log file. Then it will proceed in the same way
as for error recovery.

=cut

package EPrints::Plugin::Event::OAPingEvent;

use strict;
use v5.34;

our $VERSION = v1.0.0;
our @ISA     = qw( EPrints::Plugin::Event );

use File::Copy;
use File::Path qw(make_path);
use JSON;
use POSIX qw(strftime);
use URI;

use EPrints::Const
  qw(HTTP_OK HTTP_RESET_CONTENT HTTP_NOT_FOUND HTTP_LOCKED HTTP_INTERNAL_SERVER_ERROR);

=head1 CONSTANTS

=over

=item LEGACY_LOG

Relative path to record of last legacy ping.

=item RETRY_DIR

Relative path to folder of failed pings.

=item RETRY_LOG

Relative path to record of retry attempts.

=item INVESTG

Activity name for COUNTER Investigations.

=item REQUEST

Activity name for COUNTER Requests.

=back

=cut

use constant {
	LEGACY_LOG => '/oaping-legacy.json',
	REPLAY_DIR => '/oaping',
	ERROR_LOG  => '/oaping-error.yaml',
	INVESTG    => 'View',
	REQUEST    => 'Download',
};

=head1 METHODS

=head2 Constructor method

=over

=item $event = EPrints::Plugin::Event::OAPingEvent->new( %params )

The constructor has no special parameters of its own: all are passed to
the parent EPrints::Plugin::Event constructor.

=cut

sub new
{
	my ( $class, %params ) = @_;

	my $self = $class->SUPER::new(%params);

	$self->{actions} = [qw( enable disable )];

	$self->{package_name} = "OAPingEvent";

	return $self;
}

=back

=head2 High level public methods, corresponding to available job events

=over

=item $status = $self->legacy_notify( $self, $offset, [ $message ] )

Notifies the tracker of a batch of legacy access records, skipping the
chronologically first C<$offset> records. The C<$message> should be indicative
of how the last run went; this is a bit of a cheat, in order to make it clear
in the Indexer task screen when the legacy upload has finished.

(Internally C<$offset> is the 0-indexed number of the first record to include,
but this is the same as skipping the first C<$offset> records).

=cut

sub legacy_notify
{
	my ( $self, $offset, $message ) = @_;
	my $repo = $self->{repository};

	# Maximum number of events in one upload:
	my $size = 100;

	my $json    = JSON->new->allow_nonref(0)->canonical(1)->pretty(1);
	my $logfile = $repo->config('variables_path') . LEGACY_LOG;

	# Read log if exists
	my $log = { tries_since_last_success => 0 };
	if ( -f $logfile )
	{
		open( my $fh, "<", $logfile ) or do
		{
			$self->_log("legacy_notify: Could not open $logfile: $!");
			return HTTP_INTERNAL_SERVER_ERROR;
		};
		my $err = read( $fh, my $logcontent, -s $fh );
		if ( !defined $err )
		{
			$self->_log("legacy_notify: Could not read $logfile: $!");
			return HTTP_INTERNAL_SERVER_ERROR;
		}
		close($fh) or warn "Failed to close $logfile: $!";
		$log = eval { $json->decode($logcontent) } or do
		{
			$self->_log("legacy_notify: Could not parse $logfile: $@");
			return HTTP_INTERNAL_SERVER_ERROR;
		};

		# Offset should match logfile.
		if ( exists $log->{offset} && $log->{offset} != $offset )
		{
			$self->_log(
					"legacy_notify: Offset mismatch, $log->{offset} (log) "
				  . "!= $offset (call)" );
			return HTTP_INTERNAL_SERVER_ERROR;
		}
	}

	$log->{last_run} = EPrints::Time::iso_datetime();
	$log->{last_accessid} //= 0;

	my $up_to_date = "Up to date";

	# Process stashed records if they exist, otherwise look up new ones
	my @accesses = $self->_unstash();
	if (@accesses)
	{
		$log->{message} = $self->_bulk_ping( \@accesses, 1 );
	}
	else
	{
		# We can only register access events with a datestamp.
		# We only want to register access events with a referent ID.
		# Would be more robust to cache but probably too many results.
		my %params = (
			session       => $self->{repository},
			dataset       => $self->_ds_acc,
			search_fields => [
				{ meta_fields => ['datestamp'],   match => 'SET' },
				{ meta_fields => ['referent_id'], match => 'SET' },
			],
			custom_order => "datestamp/accessid",
		);
		my $search = EPrints::Search->new( %params, allow_blank => 1, );

		my $results = $search->perform_search;
		my $total   = $results->count;
		$log->{total} = $total;

		if ( $total > $offset )
		{
			for my $access ( $results->slice( $offset, $size ) )
			{
				$offset++;
				push @accesses, [$access];
				$log->{last_accessid} = $access->id
				  if ( $access->id > $log->{last_accessid} );
			}

			$log->{offset}  = $offset;
			$log->{message} = $self->_bulk_ping( \@accesses );
		}
		else
		{
			$log->{message} = $up_to_date;
		}
	}

	# How did it go?
	my $start_stamp = time();
	if ( $log->{message} =~ m/^Sent/ )
	{
		# Do next batch in one minute:
		$log->{tries_since_last_success} = 0;
		$start_stamp += 60;
	}
	elsif ( $log->{message} eq $up_to_date )
	{
		# Look again tomorrow:
		$start_stamp += ( 24 * 60 * 60 );
	}
	else
	{
		# Retry in an hour:
		$log->{tries_since_last_success}++;
		$start_stamp += ( 60 * 60 );
	}

	# Save log file
	open( my $fh, ">", $logfile ) or do
	{
		$self->_log("legacy_notify: Could not open $logfile: $!");
		return HTTP_INTERNAL_SERVER_ERROR;
	};
	print $fh $json->encode($log);
	close($fh) or warn "Failed to close $logfile: $!";

	if ( $log->{tries_since_last_success} > 24 )
	{
		# Hasn't worked for a day, give up:
		return HTTP_INTERNAL_SERVER_ERROR;
	}

	# Spawn new job
	EPrints::DataObj::EventQueue->create_unique(
		$self->{repository},
		{
			start_time => EPrints::Time::iso_datetime($start_stamp),
			pluginid   => $self->get_id,
			action     => "legacy_notify",
			params     => [ $offset, $log->{message} ]
		}
	);
	return HTTP_OK;
}

=item $status = $self->notify( $self, $access, $request_url )

Notifies the tracker about the given C<$access> event.

If there are no stashed events, this is done using a regular ping.

If there are stashed events, they will be unstashed and the given C<$access>
event will be added to them. The chronologically first 100 will be sent as a
bulk tracking request. If there are any left over, they are stashed again
ready for next time.

=cut

sub notify
{
	my ( $self, $access, $request_url ) = @_;
	my $repo = $self->{repository};

	my $logfile = $repo->config('variables_path') . LEGACY_LOG;

	# Maximum number of events in one upload:
	my $size = 100;

	my $msg;

	# Recovery from previous runs
	my @accesses;

	if ( -f $logfile )
	{
		# Transitioning from legacy_notify:
		open( my $fh, "<", $logfile ) or do
		{
			$msg = "Could not open $logfile: $!";
			$self->_err_log( $msg, stashed => [ [ $access, $request_url ] ] );
			$self->_log("notify: $msg");
			$self->_stash( $access, $request_url );
			return HTTP_INTERNAL_SERVER_ERROR;
		};
		my $err = read( $fh, my $logcontent, -s $fh );
		if ( !defined $err )
		{
			$msg = "Could not read $logfile: $!";
			$self->_err_log( $msg, stashed => [ [ $access, $request_url ] ] );
			$self->_log("notify: $msg");
			$self->_stash( $access, $request_url );
			return HTTP_INTERNAL_SERVER_ERROR;
		}
		close($fh) or warn "Failed to close $logfile: $!";
		my $json = JSON->new->allow_nonref(0)->canonical(1)->pretty(1);
		my $log  = eval { $json->decode($logcontent) } or do
		{
			$msg = "Could not parse $logfile: $@";
			$self->_err_log( $msg, stashed => [ [ $access, $request_url ] ] );
			$self->_log("notify: $msg");
			$self->_stash( $access, $request_url );
			return HTTP_INTERNAL_SERVER_ERROR;
		};
		if ( !$log->{last_accessid} )
		{
			$msg = "Last legacy accessid not found in $logfile";
			$self->_err_log( $msg, stashed => [ [ $access, $request_url ] ] );
			$self->_log("notify: $msg");
			$self->_stash( $access, $request_url );
			return HTTP_INTERNAL_SERVER_ERROR;
		}
		@accesses =
		  $self->_accesses_between( $log->{last_accessid}, $access->id );
		move( $logfile, "$logfile.bak" );
	}
	else
	{
		# Error recovery:
		@accesses = $self->_unstash();
	}

	if (@accesses)
	{
		push @accesses, [ $access, $request_url ];

		if ( @accesses > $size )
		{
			# Bulk ping will sort entries, but if choosing, need to choose
			# the earliest ones:
			my @sorted_accesses = sort {
				$a->[0]->value('datestamp') cmp $b->[0]->value('datestamp')
			} @accesses;
			my @batch = @sorted_accesses[ 0 .. ( $size - 1 ) ];
			$msg = $self->_bulk_ping( \@batch, 1 );
			$self->_log("notify call to _bulk_ping: $msg");

			# Stash the remainder:
			my @stashed;
			for my $tuple ( @sorted_accesses[ $size .. $#sorted_accesses ] )
			{
				push @stashed, $tuple;
				my ( $deferred_access, $deferred_request_url ) = @{$tuple};
				$self->_stash( $deferred_access, $deferred_request_url );
			}
			$self->_err_log(
				'Too many stashed access events, saving some for next time.',
				stashed => \@stashed );
		}
		else
		{
			$msg = $self->_bulk_ping( \@accesses, 1 );
			$self->_log("notify call to _bulk_ping: $msg");
		}

		if ( $msg =~ m/^Sent/ )
		{
			return HTTP_OK;
		}
		else
		{
			return HTTP_INTERNAL_SERVER_ERROR;
		}
	}

	# Simple ping:
	$msg = $self->_ping( $access, $request_url );
	if ( $msg =~ m/^Sent/ )
	{
		if ( $repo->config( 'oaping', 'verbosity' ) )
		{
			$self->_log("notify: $msg");
		}
		return HTTP_OK;
	}
	else
	{
		$self->_log("notify: $msg");
		return HTTP_INTERNAL_SERVER_ERROR;
	}
}

=back

=head2 Low level supporting methods used in the above

=over

=item @accesses = $self->_accesses_between( $last_accessid, $current_accessid )

Loads all relevant access records I<after> the C<$last_accessid> but I<before>
the C<$current_accessid> and returns them as an array of arrayrefs, where the
only element is an C<$access> object (compatible with L<_unstash>).

=cut

sub _accesses_between
{
	my ( $self, $last_accessid, $current_accessid ) = @_;

	my $range_start = $last_accessid + 1;
	my $range_stop  = $current_accessid - 1;

	my %params = (
		session       => $self->{repository},
		dataset       => $self->_ds_acc,
		search_fields => [
			{
				meta_fields => ['accessid'],
				value       => "$range_start-$range_stop",
				match       => 'EQ',
				merge       => 'ANY'
			},
			{ meta_fields => ['datestamp'],   match => 'SET' },
			{ meta_fields => ['referent_id'], match => 'SET' },
		],
		custom_order => "datestamp/accessid",
		allow_blank  => 1
	);
	my $search  = EPrints::Search->new(%params);
	my $results = $search->perform_search;
	my $total   = $results->count;
	$self->_log("_accesses_between: Loading $total access records.");

	my @accesses;
	foreach my $access ( $results->slice() )
	{
		push @accesses, [$access];
	}
	return @accesses;
}

=item ($id1, $id2) | $id2 = $self->_archive_id ( $any )

Takes Boolean. If true, returns an array containing both the v1 and v2
OAI identifiers for the current archive. Otherwise just returns the v2
one.

Reproduced from C<EPrints::OpenArchives::archive_id>.

=cut

sub _archive_id
{
	my ( $self, $any ) = @_;
	my $repo = $self->{repository};

	my $v1 = $repo->config( 'oai', 'archive_id' );
	my $v2 = $repo->config( 'oai', 'v2', 'archive_id' );

	$v1 ||= $repo->config('host');
	$v1 ||= $repo->config('securehost');
	$v2 ||= $v1;

	return $any ? ( $v1, $v2 ) : $v2;
}

=item %qf_params = $self->_to_form( $access, [ $request_url ] )

Convert an C<$access> object into a
L<Matomo Tracking HTTP API|https://developer.matomo.org/api-reference/tracking-api>
query form.

A request URL will be calculated if blank or undefined.

Does not insert the C<token_auth> as this is handled differently depending on
whether a singular or bulk call is made.

Returns empty if the C<$access> does not have reportable data.

=cut

sub _as_form
{
	my ( $self, $access, $request_url ) = @_;
	my $repo = $self->{repository};

	# Required parameters:
	my %qf_params = (
		idsite => $repo->config( 'oaping', 'idsite' ),
		rec    => '1',
	);

	# COUNTER classification
	my $is_request =
		 $access->is_set('service_type_id')
	  && $access->value('service_type_id') eq '?fulltext=yes'
	  ? 1
	  : 0;

	# Recommended parameters:
	# - action_name
	my $action_name = $is_request ? REQUEST : INVESTG;
	$qf_params{action_name} = $action_name;

	# - url
	if ( !$request_url )
	{
		if ( $is_request && $access->is_set('referent_docid') )
		{
			my $doc =
			  $self->_ds_doc->get_object( $repo,
				$access->value('referent_docid') );
			if ( defined $doc )
			{
				$request_url = $doc->get_url();
			}
			elsif ( $access->is_set('referent_id') )
			{
				# Should only get here if the document has since been deleted.
				# So long as the first bit of the URL identifies the dataset,
				# the last bit doesn't have to be accurate, so long as it's
				# consistent for a given file
				$request_url =
					$repo->config('base_url') . '/'
				  . $access->value('referent_id') . '/'
				  . $access->value('referent_docid');
			}
			else
			{
				# Should never get here.
				$request_url =
					$repo->config('base_url')
				  . '/id/document/'
				  . $access->value('referent_docid');
			}
		}
		elsif ( $access->is_set('referent_id') )
		{
			my $eprint =
			  $self->_ds_ep->get_object( $repo, $access->value('referent_id') );
			$request_url =
			  defined $eprint
			  ? $eprint->get_url()
			  : $repo->config('base_url') . '/' . $access->value('referent_id');
		}
		else
		{
			# If both eprint and document IDs are null, ignore.
			return;
		}
	}
	$qf_params{url} = $request_url;

	# - apiv
	$qf_params{apiv} = '1';

	# Optional User info:
	# - urlref
	if ( $access->is_set('referring_entity_id') )
	{
		my $referer = $access->value('referring_entity_id');
		$referer =~ s/^(.{1024}).*$/$1/s;    # stop it getting too long
		$qf_params{urlref} = $referer;
	}

	# - ua
	if ( $access->is_set('requester_user_agent') )
	{
		$qf_params{ua} = $access->value('requester_user_agent');
	}

	# Optional Action info:
	# - cvar (stringified JSON containing OAI PMH ID)
	if ( $access->is_set('referent_id') )
	{
		my $oai_id =
		  EPrints::OpenArchives::to_oai_identifier( $self->_archive_id(),
			$access->value('referent_id'),
		  );
		$qf_params{cvar} = '{"1":["oaipmhID","' . $oai_id . '"]}';
	}

	# - download
	if ($is_request)
	{
		$qf_params{download} = $request_url;
	}

	# Parameters requiring authentication:
	# - cip
	if ( $access->is_set('requester_id') )
	{
		$qf_params{cip} = $access->value('requester_id');
	}

	# - cdt
	if ( $access->is_set('datestamp') )
	{
		$qf_params{cdt} = $access->value('datestamp');
	}

	return %qf_params;
}

=item $message = $self->_bulk_ping( $accesses, [ $is_recovery ] )

Sends a POST request to the configured Matomo Tracking HTTP API, registering
multiple access events at once. The C<$accesses> argument must be an arrayref
containing arrayrefs, where the first item is an C<$access> object and the
optional second item is a request URL.

Bulk tracking is handled by the Matomo
L<BulkTracking|https://github.com/matomo-org/matomo/blob/5.x-dev/plugins/BulkTracking/>
plugin.

If C<$is_recovery> evaluates true, successfully sent access events will be
logged, so they can be compared against the lists of previously stashed ones.

Returns a log message indicating how it went.

=cut

sub _bulk_ping
{
	my ( $self, $accesses, $is_recovery ) = @_;
	my $repo = $self->{repository};

	my $tracker_url = URI->new( $repo->config( 'oaping', 'tracker' ) );
	my $token_auth  = $repo->config( 'oaping', 'token_auth' );

	# Filter out unusable events:
	my @events;
	foreach my $tuple ( @{$accesses} )
	{
		my ( $access, $request_url ) = @{$tuple};
		my %qf_params = $self->_as_form( $access, $request_url );
		if (%qf_params)
		{
			push @events,
			  {
				a => $access,
				u => $qf_params{url},
				p => \%qf_params,
			  };
		}
	}

	my $msg;

	# Can't continue if that leaves us with nothing:
	return 'No usable events' unless @events;

	# Can't continue if can't authenticate, so stash:
	if ( !defined $token_auth )
	{
		$msg = 'Missing authorization token';
		my @stashed;
		foreach my $event (@events)
		{
			push @stashed, [ $event->{a}, $event->{u} ];
			$self->_stash( $event->{a}, $event->{u} );
		}
		$self->_err_log( $msg, stashed => \@stashed );
		return $msg;
	}

	# Sort all events into chronological order
	# (they will already be ordered if from database search,
	# but not if rescued from the stash):
	my @sorted_events = sort { $a->{p}{cdt} cmp $b->{p}{cdt} } @events;

	# According to BulkTracking/Tracker/Requests.php, each member of
	# the requests array can be either be a URL string (in which case
	# the URL is parsed, then the query part is parsed again for
	# parameters), or a hash (in which case it is used directly): so
	# we may as well avoid the round trip and deliver hashes.
	my $payload = {
		requests   => [],
		token_auth => $token_auth,
	};
	foreach my $event (@sorted_events)
	{
		push @{ $payload->{requests} }, $event->{p};
	}

	# Turn into payload JSON string.
	my $json    = JSON->new->utf8->allow_nonref(0)->canonical(1)->pretty(0);
	my $content = $json->encode($payload);

	my $response = $self->_ua->post(
		$tracker_url,
		Content_Type => 'application/json',
		Accept       => 'application/json',
		Content      => $content,
	);

	my $error;
	my %err_details;
	my @sent   = @sorted_events;
	my @unsent = @sorted_events;

	if (   $response->header('Client-Warning')
		&& $response->header('Client-Warning') eq 'Internal response"' )
	{
		@sent  = ();
		$error = 'Failed to send request';
	}
	elsif ( $response->code > 399 )
	{
		$error =
		  'Tracker responded ' . $response->code . ' ' . $response->message;
		$err_details{response} = $response->decoded_content();
		my $report = eval { $json->decode( $response->content() ) }
		  or $error .= '. Could not parse content of response.';
		my $tracked = 0;
		if ( $report && exists $report->{tracked} )
		{
			$tracked = $report->{tracked};
		}
		@sent   = $tracked ? @sorted_events[ 0 .. ( $tracked - 1 ) ] : ();
		@unsent = @sorted_events[ $tracked .. $#sorted_events ];
	}
	else
	{
		@unsent = ();
	}

	foreach my $event (@unsent)
	{
		push @{ $err_details{stashed} }, [ $event->{a}, $event->{u} ];
		$self->_stash( $event->{a}, $event->{u} );
	}

	$msg = "Sent ${\scalar @sent} events to tracker";
	my $log_msg = $error ? $error : $msg;

	if ($is_recovery)
	{
		foreach my $event (@sent)
		{
			push @{ $err_details{sent} }, [ $event->{a}, $event->{u} ];
		}
		$self->_err_log( $log_msg, %err_details );
	}
	elsif ($error)
	{
		$self->_err_log( $log_msg, %err_details );
	}

	return $log_msg;
}

=item $ds = $self->_ds_acc

Returns access dataset.

=cut

sub _ds_acc
{
	my ($self) = @_;

	if ( !defined $self->{access_ds} )
	{
		$self->{access_ds} = $self->{repository}->dataset('access');
	}

	return $self->{access_ds};
}

=item $ds = $self->_ds_doc

Returns document dataset.

=cut

sub _ds_doc
{
	my ($self) = @_;

	if ( !defined $self->{document_ds} )
	{
		$self->{document_ds} = $self->{repository}->dataset('document');
	}

	return $self->{document_ds};
}

=item $ds = $self->_ds_ep

Returns eprints dataset.

=cut

sub _ds_ep
{
	my ($self) = @_;

	if ( !defined $self->{eprint_ds} )
	{
		$self->{eprint_ds} = $self->{repository}->dataset('eprint');
	}

	return $self->{eprint_ds};
}

=item $bool = $self->_ensure_path( $path )

Returns 1 if path already exists or has been successfully created.
Returns 0 if path still does not exist after best efforts.

=cut

sub _ensure_path
{
	my ( $self, $path ) = @_;

	if ( -d $path )
	{
		return 1;
	}

	my @created = make_path( $path, { error => \my $err } );
	if ( $err && @{$err} )
	{
		for my $diag ( @{$err} )
		{
			my ( $f, $msg ) = %{$diag};
			if ( $f eq '' )
			{
				$msg = ": $msg";
			}
			else
			{
				$msg = " $f: $msg";
			}
			$self->_log("_ensure_path: Error creating directory$msg");
		}
		return 0;
	}

	return 1;
}

=item $ok = $self->_err_log( $msg, %params )

Appends a message to the dedicated error log. This could either be an error or
the correction of an earlier error.

The output format is YAML flavoured but may not be entirely valid YAML.

Recognised keys for the C<%params>:

=over

=item sent

Access events that have been sent in bulk. Typically, they will have previously
been stashed. Value should be an arrayref of arrayrefs, where the first element
is an Access DataObj and the second (if present) is a request URL.

=item stashed

Access events that have been stashed instead of being sent. Value should be as
for B<sent>.

=item response

Body of the error response sent back by Matomo.

=back

=cut

sub _err_log
{
	my ( $self, $msg, %params ) = @_;
	my $repo = $self->{repository};

	my @lines;

	push @lines, "time: " . EPrints::Time::iso_datetime();
	push @lines, "message: $msg";
	if ( defined $params{response} )
	{
		push @lines, "response: >";
		my @response_lines = split( "\n", $params{response} );
		foreach my $response_line (@response_lines)
		{
			push @lines, "  $response_line";
		}
	}
	foreach my $key ( 'sent', 'stashed' )
	{
		if ( defined $params{$key} )
		{
			push @lines, "$key:";
			foreach my $tuple ( @{ $params{$key} } )
			{
				my ( $access, $request_url ) = @{$tuple};
				$request_url //= '???';
				push @lines, '- ' . $access->id . " > $request_url";
			}
		}
	}

	my $error = join( "\n  ", @lines );

	my $error_file = $repo->config('variables_path') . ERROR_LOG;
	open( my $fh, '>>', $error_file ) or do
	{
		$self->_log("_err_log: Could not log error:\n  $error\n  $!");
		return 0;
	};
	print $fh "- $error\n";
	close($fh) or warn "Failed to close $error_file: $!";
	return 1;
}

=item $self->_log( $msg )

Write message to Indexer log.

=cut

sub _log
{
	my ( $self, $msg ) = @_;
	$self->{repository}->log("PureEvent::$msg");
	select()->flush();
	return;
}

=item $message = $self->_ping( $access, [ $request_url ] )

Sends a ping to the configured Matomo Tracking HTTP API, representing a single
access event.

A request URL will be calculated if blank or undefined.

Returns a log message indicating how it went.

=cut

sub _ping
{
	my ( $self, $access, $request_url ) = @_;
	my $repo = $self->{repository};

	my $tracker_url = URI->new( $repo->config( 'oaping', 'tracker' ) );

	# Convert access to form data:
	my %qf_params = $self->_as_form( $access, $request_url );
	return unless %qf_params;

	# Add random number to prevent caching:
	$qf_params{rand} = int( rand(10000) );

	my $token_auth = $repo->config( 'oaping', 'token_auth' );
	if ( defined $token_auth )
	{
		$qf_params{token_auth} = $token_auth;
	}
	else
	{
		# Of course, should never happen.
		$self->_log("_ping: token_auth not found!");

		# Dangerous to send info if will be attributed to now instead of then.
		if ( exists $qf_params{cdt} )
		{
			$self->_stash( $access, $request_url );
			my $error = 'Could not notify of dated access without token_auth';
			$self->_err_log( $error, stashed => [ [ $access, $request_url ] ] );
			return $error;
		}

		# Move to a non-authenticated key.
		if ( exists $qf_params{cip} )
		{
			$qf_params{uid} = $qf_params{cip};
			delete $qf_params{cip};
		}
	}

	$tracker_url->query_form(%qf_params);

	my $response = $self->_ua->head($tracker_url);
	my $error;
	my %err_details;
	if (   $response->header('Client-Warning')
		&& $response->header('Client-Warning') eq 'Internal response"' )
	{
		$error = 'Failed to send request';
	}
	elsif ( $response->code > 399 )
	{
		$error =
		  'Tracker responded ' . $response->code . ' ' . $response->message;
		$err_details{response} = $response->decoded_content();
	}

	if ($error)
	{
		$self->_stash( $access, $request_url );
		$err_details{stashed} = [ [ $access, $request_url ] ];
		$self->_err_log( $error, %err_details );
		return $error;
	}

	my $accessid = $access->id;
	return "Sent access $accessid to tracker";
}

=item $ok = $self->_stash($access, $request_url )

Records a failed ping attempt so it can be retried later.

Stashing an event converts an undefined C<%request_url> to an empty string.

=cut

sub _stash
{
	my ( $self, $access, $request_url ) = @_;
	$request_url //= q();
	my $repo = $self->{repository};

	my $panic_msg =
		"_stash: Could not stash ping for access "
	  . $access->id . " = "
	  . ( $request_url || "???" );

	my $replay_dir = $repo->config('variables_path') . REPLAY_DIR;

	if ( !$self->_ensure_path($replay_dir) )
	{
		$self->_log($panic_msg);
		return 0;
	}

	my $replay_file = $replay_dir . '/' . $access->id;
	open( my $fh, '>', $replay_file ) or do
	{
		$self->_log($panic_msg);
		return 0;
	};
	print $fh $request_url;
	close($fh) or warn "Failed to close $replay_file: $!";
	return 1;
}

=item $ua = $self->_ua

User agent for making calls to APIs.

=cut

sub _ua
{
	my ($self) = @_;

	if ( !defined $self->{ua} )
	{
		$self->{ua} = LWP::UserAgent->new( conn_cache => LWP::ConnCache->new );
		$self->{ua}->env_proxy;
	}

	return $self->{ua};
}

=item @accesses = $self->_unstash()

Loads and removes stashed access events and returns them as an array of arrayrefs,
where the first element is an C<$access> object and the second is a request URL.
Elements are not likely to be in chronological order.

=cut

sub _unstash
{
	my ($self) = @_;
	my $repo = $self->{repository};

	my @accesses;

	my $replay_dir = $repo->config('variables_path') . REPLAY_DIR;

	if ( !$self->_ensure_path($replay_dir) )
	{
		return @accesses;
	}

	opendir( my $dh, $replay_dir ) || return @accesses;
	while ( my $accessid = readdir($dh) )
	{
		next if $accessid =~ /^\.{1,2}$/;
		my $access = $self->_ds_acc->get_object( $repo, $accessid );
		next unless defined $access;
		open( my $fh, '<', "$replay_dir/$accessid" ) or next;
		read( $fh, my $request_url, -s $fh );
		close($fh) or warn "Failed to close $replay_dir/$accessid: $!";
		$request_url =~ s/^\s+|\s+$//g;
		push @accesses, [ $access, $request_url ];
		unlink "$replay_dir/$accessid";
	}
	closedir($dh);

	return @accesses;
}

=back

=cut

1;
