# EPrints-OAPing

*Alternative EPrints extension for sending usage pings to the OpenAIRE Matomo
tracking API*

⚠️⚠️ This code is still being tested. Please don't use in production yet. ⚠️⚠️

## Installation

You can install this extension in several different ways:

- as an ingredient that you can then load into archives on a flavour-by-flavour
  basis;

- as an extension, individually into each archive.

### As an ingredient

Copy the `oaping` folder into your `~eprints/ingredients` folder, where
`~eprints` is typically something like `/opt/eprints3`.

To activate the ingredient for given flavours, you can add a file to
`~eprints/cfg/cfg.d` with lines like the following:

**~eprints/cfg/cfg.d/custom.pl**
```perl
push @{ $conf->{flavours}->{FLAVOUR_NAME} }, 'ingredients/oaping';
```

### As an extension

Unpack the contents of the `oaping` folder into your
`~eprints/archives/ARCHIVE_ID/cfg` folder.

## Configuration

Create a file to contain your OpenAIRE tracking credentials:

**ARCHIVE_ID/cfg/cfg_d/x_oaping.pl**
```perl
$c->{oaping}->{idsite} = '';
$c->{oaping}->{token_auth} = '';
```

It is recommended you exclude this file from any version control you might be
using. It is also good practice to restrict access to the file so it can only be
read by the user(s) as which the Web server and Indexer run. If they both only
run as `eprints`, this would work:

```bash
chown eprints ~eprints/archives/ARCHIVE_ID/cfg/cfg_d/x_oaping.pl
chmod 600 ~eprints/archives/ARCHIVE_ID/cfg/cfg_d/x_oaping.pl
```

There are a few other configuration options. You should set these in one of the
following places, according to taste:

-   alongside the credentials in **ARCHIVE_ID/cfg/cfg_d/x_oaping.pl**;
-   in a new file, **ARCHIVE_ID/cfg/cfg_d/z_oaping.pl**;
-   if it already exists, in **ARCHIVE_ID/cfg/cfg_d/oaping.pl** overwriting the
    values already there – if you've installed it as an ingredient, copy the
    file over first.

Options:

-   `$c->{plugins}->{'Event::OAPingEvent'}->{params}->{disable}`

    In the normal fashion, set the plugin's `disable` parameter to 0 to enable
    or 1 to disable it. Initial value is 0.

-   `$c->{oaping}->{tracker}`

    URL of the tracker to ping. Initial value is
    `https://analytics.openaire.eu/piwik.php`.

-   `$c->{oaping}->{max_payload}`

    The maximum number of access pings to send in a single bulk request.
    OpenAIRE's official generic solution defaults to 100. As bulk requests are
    typically made at least 60 seconds apart, busy repositories might need a
    higher value.

-   `$c->{oaping}->{verbosity}`

    Set to 1 to record in the Indexer log each Access ID that is successfully
    tracked. Initial value is 0 (succeed quietly).

-   `$c->{oaping}->{notify_mode}`

    **NOTE:** This setting is only effective if you overwrite the value in
    **oaping.pl**.

    Set to 1 or 2 to install a trigger that pings the tracker when a new access
    event is logged in the database. Mode 1 does some checking before sending
    the ping. Mode 2 pings first and asks questions later. See below for more
    details. The initial value is 0 (don't install a trigger).

    If you are installing the plugin into a running repository and want to send
    tracking information for historic Accesses, leave `notify_mode` set to 0
    and run the `legacy_notify` job as your first step:

    ```bash
    sudo -u eprints ~eprints/tools/schedule ARCHIVE_ID Event::OAPingEvent legacy_notify 0
    ```

    This job will respawn after each bulk notification it makes. Once it reports
    it is up to date, delete the job and set `notify_mode` to 1. A transition
    will occur in which **ARCHIVE_ID/var/oaping-legacy.json** is renamed
    **oaping-legacy.json.bak** and the **ARCHIVE_ID/var/oaping/** directory will
    fill with files; when that directory is empty again, the transition is
    complete.

    In any case, if using the trigger it is recommended that you choose mode 1
    to begin with, and during any period where you notice problems occurring.
    When things are running smoothly, switch to mode 2.

Remember to restart both the server and Indexer after changing the
configuration.

## Operation

The OAPing plugin works hard to ensure all pings get through to the tracker
safely. Unsent or unsuccessful pings are saved to disk ("stashed") in the
**ARCHIVE_ID/var/oaping/** directory to be retried later, and removed when they
succeed.

The `legacy_notify` job performs bulk requests in batches of configurable size.
It defaults to sending a ping for each non-trivial Access DataObj in the
database, though when you set it running you can choose how many of the
chronologically earliest ones to skip. If there are stashed pings, it will send
them instead of looking up the next batch from the database.

In notify mode 1, the `safe_notify` job will normally send a single ping to the
tracker each time a new Access DataObj is added to the database. If however
there are stashed pings, they will be sent with the triggering ping in a bulk
request. Similarly, if the job detects that the `legacy_notify` job has been
run, it will look to see if any Access DataObjs were missed between the last
`legacy_notify` run and the triggering Access DataObj, and if so send them with
the triggering ping in a bulk request; if there are too many to send in one go,
the remainder are stashed.

In notify mode 2, the `notify` job will send a single ping to the tracker each
time a new Access DataObj is added to the database. If this fails, a `retry` job
will be scheduled. The latter sends a batch of stashed pings in a bulk request;
if there are any left over, the job reschedules itself.

## Debugging

To help with debugging, the plugin writes one or two dedicated log files:

-   **ARCHIVE_ID/var/oaping-legacy.json**

    This records information about the last run of the `legacy_notify` job. It
    is also used when transitioning from that job to the normal `notify` job,
    after which it is renamed.

-   **ARCHIVE_ID/var/oaping-error.json**

    This records when calls to the tracker have failed, and also when previous
    errors have been resolved successfully. As well as a summary message, it
    records Access DataObjs that were stashed; stashed Access DataObjs that were
    later sent successfully; and any error messages sent back by the tracker.
