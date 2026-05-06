
=head1 OAPing

B<OAPing> - A usage tracking plugin for OpenAIRE's Matomo tracker.

=head2 Manifest

As well as this file, you should also install:

=over

=item *

B<EPrints::Plugin::Event::OAPingEvent> - Indexer jobs that do all the work.

=item *

B<x_oaping.pl> - Credentials (not included):

	$c->{oaping}->{idsite} - site identifier
	$c->{oaping}->{token_auth} - authorization token

=back

=head2 Configuration

=over

=item $c->{plugins}->{'Event::OAPingEvent'}->{params}->{disable}

In the normal fashion, set the plugin's C<disable> parameter to 0 to enable or 1
to disable.

=cut

$c->{plugins}->{'Event::OAPingEvent'}->{params}->{disable} = 0;

=item $c->{oaping}->{tracker}

You can change this URL if necessary.

=cut

$c->{oaping}->{tracker} = 'https://analytics.openaire.eu/piwik.php';

=item $c->{oaping}->{max_payload}

The maximum number of access pings to send in a single bulk request. OpenAIRE's
official generic solution defaults to 100. As bulk requests are typically made
at least 60 seconds apart, busy repositories might need a higher value.

=cut

$c->{oaping}->{max_payload} = 100;

=item $c->{oaping}->{verbosity}

Set to 1 to log each Access ID that is successfully tracked.

=cut

$c->{oaping}->{verbosity} = 0;

=item $c->{oaping}->{notify_mode}

The plugin can work in three different modes, selected by setting C<notify_mode>
to 0, 1, or 2.

In mode 0, the indexer sends usage information to the tracker in bulk. Since it
works from the EPrints Access table, it does not have access to the actual URL
used to request landing pages and files, so it calculates the most likely one.
This mode is recommended for busy repositories.

You need to set mode 0 running manually using the command-line C<schedule> tool.
The job needs plugin ID C<Event::OAPingEvent>, action C<bulk_notify>, with a
parameter being the Access ID of the I<last> access event to I<skip>. If you
want to upload your entire history of accesses, the parameter should be C<0>.

In mode 2, the web server will ping the tracker immediately as part of handling
every access request. In case of error it will schedule a C<retry> indexer job.
This mode is recommended for quiet repositories, once any historic access data
of interest has been uploaded using mode 0.

Mode 1 is designed for transitioning from mode 0 to mode 2 or vice versa. When
an access event occurs, it will first check to see if there are older events to
send, and if so send them in bulk (like the C<bulk_notify> and C<retry> jobs)
with the new event added to the end; otherwise it sends the event to the tracker
just as in mode 2. It writes out the Access ID of new access event it sent, so
you can use it as the parameter to C<bulk_notify> after transitioning to mode 0.

=cut

$c->{oaping}->{notify_mode} = 0;

if ( $c->{oaping}->{notify_mode} == 2 )
{
	$c->add_dataset_trigger(
		'access',
		EPrints::Const::EP_TRIGGER_CREATED,
		sub {
			my (%args) = @_;

			my $repo   = $args{repository};
			my $access = $args{dataobj};

			# Get current request URL as a URI object:
			my $request_url = $repo->current_url( host => 1 );

			# Convert to string:
			my $canonical_url = $request_url->canonical()->as_string();

			my $plugin = $repo->plugin('Event::OAPingEvent');
			my $status = $plugin->fast_notify( $access, $canonical_url );

			if ( $status != EPrints::Const::HTTP_OK )
			{
				# Retry 5 mins after last unsuccessful ping:
				my $start_time =
				  EPrints::Time::iso_datetime( time() + ( 5 * 60 ) );
				my $event = EPrints::DataObj::EventQueue->create_unique(
					$repo,
					{
						start_time => $start_time,
						pluginid   => $plugin->get_id,
						action     => 'retry',
					}
				);
				if ( $event->get_value('start_time') lt $start_time )
				{
					# Task was already set to run sooner, so delay start time:
					$event->set_value( 'start_time', $start_time );
					$event->commit;
				}
			}
		}
	);
}
elsif ( $c->{oaping}->{notify_mode} )
{
	$c->add_dataset_trigger(
		'access',
		EPrints::Const::EP_TRIGGER_CREATED,
		sub {
			my (%args) = @_;

			my $repo   = $args{repository};
			my $access = $args{dataobj};

			# Get current request URL as a URI object:
			my $request_url = $repo->current_url( host => 1 );

			# Convert to string:
			my $canonical_url = $request_url->canonical()->as_string();

			my $plugin = $repo->plugin('Event::OAPingEvent');
			$plugin->safe_notify( $access, $canonical_url );
		}
	);
}

=back

=head2 Debugging

To help with debugging, the plugin writes one or two dedicated log files:

=over

=item <archive>/var/oaping-legacy.json

This records information about the last run of the C<bulk_notify> job. It is
also used when transitioning from that job to the normal C<fast_notify> job.

=item <archive>/var/oaping-error.json

This records when calls to the tracker have failed, and also when previous
errors have been resolved successfully. As well as a summary message, it records
Accesses that were stashed (saved for a subsequent call); stashed Accesses that
were later sent successfully; and any error messages sent back by the tracker.

=back

=cut
