
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

=item $c->{oaping}->{verbosity}

Set to 1 to log each Access ID that is successfully tracked.

=cut

$c->{oaping}->{verbosity} = 0;

=item $c->{oaping}->{legacy_loaded}

If you are installing the plugin into a running repository and want to send
tracking information for historic Accesses, leave C<legacy_loaded> set to 0 and
run the C<legacy_notify> job as your first step. Set C<legacy_loaded> to 1 once
the C<legacy_notify> job reports it is up to date.

Otherwise, set C<legacy_loaded> to 1 to start tracking new Accesses immediately.

This setting installs a trigger that activates when a new access event is logged
in the database, creating a new C<notify> job in the Indexer.

=cut

$c->{oaping}->{legacy_loaded} = 0;

if ( $c->{oaping}->{legacy_loaded} )
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

			# Create job to send (internal_uri will be converted to object):
			EPrints::DataObj::EventQueue->create_unique(
				$repo,
				{
					start_time => EPrints::Time::iso_datetime( time() ),
					pluginid   => 'Event::OAPingEvent',
					action     => 'notify',
					params     => [ $access->internal_uri, $canonical_url ],
				}
			);

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
