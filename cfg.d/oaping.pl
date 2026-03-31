
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

If you are installing the plugin into a running repository and want to send
tracking information for historic Accesses, leave C<notify_mode> set to 0 and
run the C<legacy_notify> job as your first step. Set C<notify_mode> to 1 once
the C<legacy_notify> job reports it is up to date.

Otherwise, set C<notify_mode> to 1 to start tracking new Accesses immediately.
This setting installs a trigger that activates when a new access event is logged
in the database.

When you are happy that everything is working, you can set C<notify_mode> to 2.
This is more efficient than mode 1 but does not handle the transition from
C<legacy_notify> and, when recovering from errors, new pings will likely be sent
before older failed pings are retried.

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
			my $status = $plugin->notify( $access, $canonical_url );

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

This records information about the last run of the C<legacy_notify> job. It is
also used when transitioning from that job to the normal C<notify> job.

=item <archive>/var/oaping-error.json

This records when calls to the tracker have failed, and also when previous
errors have been resolved successfully. As well as a summary message, it records
Accesses that were stashed (saved for a subsequent call); stashed Accesses that
were later sent successfully; and any error messages sent back by the tracker.

=back

=cut
