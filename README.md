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

Clone this Git repository inside your `~eprints/ingredients` folder, where
`~eprints` is typically something like `/opt/eprints3`. It is recommended to
simplify the directory name to `oaping`:

```bash
git clone git@github.com:alex-ball/EPrints-OAPing.git oaping
```

To activate the ingredient for given flavours, you can add a file to
`~eprints/cfg/cfg.d` with lines like the following:

**~eprints/cfg/cfg.d/custom.pl**
```perl
push @{ $conf->{flavours}->{FLAVOUR_NAME} }, 'ingredients/oaping';
```

Alternatively you could add `ingredients/oaping` as a line inside your flavour's
`inc` file, for example `~eprints/flavours/pub_lib/inc`, but that means having
to stash or rebase when you pull in upstream changes with Git.

### As an extension

Unpack the contents of the `cfg.d` and `plugins` folders into their counterparts
in your `~eprints/archives/ARCHIVE_ID/cfg` folder.

## Configuration

### Credentials

Create a file to contain your OpenAIRE tracking credentials:

**ARCHIVE_ID/cfg/cfg_d/x_oaping.pl**
```perl
$c->{oaping}->{idsite} = '';
$c->{oaping}->{token_auth} = '';
```

(You can call it whatever you like, within reason, but `x_` is a handy prefix
for reminding you about the following security concerns.)

It is recommended you exclude this file from any version control you might be
using. It is also good practice to restrict access to the file so it can only be
read by the user(s) as which the Web server and Indexer run. If they both only
run as `eprints`, this would work:

```bash
chown eprints ~eprints/archives/ARCHIVE_ID/cfg/cfg_d/x_oaping.pl
chmod 600 ~eprints/archives/ARCHIVE_ID/cfg/cfg_d/x_oaping.pl
```

### Operation

There are a few other configuration options. You should set these in one of the
following places, according to taste:

-   alongside the credentials in `ARCHIVE_ID/cfg/cfg_d/x_oaping.pl`;
-   in a new file, `ARCHIVE_ID/cfg/cfg_d/z_oaping.pl`;
-   if it already exists, in `ARCHIVE_ID/cfg/cfg_d/oaping.pl` overwriting the
    values already there – if you've installed it as an ingredient, copy the
    file over first.

Options:

-   `$c->{plugins}->{'Event::OAPingEvent'}->{params}->{disable}`

    In the normal fashion, set the plugin's `disable` parameter to 0 to enable
    or 1 to disable it. Initial value is 0.

-   `$c->{oaping}->{tracker}`

    URL of the tracker to ping. Initial value is the OpenAIRE tracker at
    `https://analytics.openaire.eu/piwik.php`.
    You should however be able to use this plugin to ping any Matomo instance.

-   `$c->{oaping}->{max_payload}`

    The maximum number of access pings to send in a single bulk request.
    OpenAIRE's official generic solution defaults to 100. As bulk requests are
    typically made at least 60 seconds apart, busy repositories might need a
    higher value.

-   `$c->{oaping}->{verbosity}`

    Set to 1 to record in the Indexer log (or server error log) each Access ID
    that is successfully tracked. Initial value is 0 (succeed quietly).

-   `$c->{oaping}->{notify_mode}`

    **NOTE:** This setting is only effective if you change the value where it
    appears in the `oaping.pl` file provided.

    Set to 1 or 2 to install a trigger that pings the tracker when a new access
    event is logged in the database. Mode 1 does some checking before sending
    the ping. Mode 2 pings first and asks questions later. See below for more
    details. The initial value is 0 (don't install a trigger).

    If you are installing the plugin into a running repository and want to send
    tracking information for historic Accesses, leave `notify_mode` set to 0 and
    run the `bulk_notify` job as your first step:

    ```bash
    sudo -u eprints ~eprints/tools/schedule ARCHIVE_ID Event::OAPingEvent bulk_notify 0
    ```

    (If you want to start uploading from a later point, replace the final 0 with
    the ID of the last Access you want to skip.)

    This job respawns after each bulk notification it makes.

    - If the ping failed, the next job is be scheduled 1 hour later.
    - If it succeeded and there are more Accesses to report, the next job is
      scheduled 1 minute later.
    - If it succeeded and there are no more Accesses to report, the next job is
      scheduled 1 day later. You should see "Up to date" as the second parameter
      for the job.
    
    It is fine, perhaps even preferable, to stay on mode 0 permanently. But if
    you are up to date and want to switch to live pinging, delete the job and
    set `notify_mode` to 1. A transition will occur in which the
    `oaping-bulk.json` file in `ARCHIVE_ID/var/` is renamed
    `oaping-bulk.json.bak` and the `ARCHIVE_ID/var/oaping/` directory will fill
    with files; when that directory is empty again, the transition is complete.

    You can switch freely between modes 1 and 2. If you are using live pings,
    it is recommended to use mode 1 in the first instance and during problematic
    periods (e.g. the tracker goes offline for maintenance), otherwise mode 2.

    If you are using live pings and want to switch to bulk pings, run in mode 1
    until a file `oaping-safe.json` file is generated or updated in
    `ARCHIVE_ID/var/`. Then switch to mode 0, and schedule the `bulk_notify`
    action as described above, using the access ID recorded in
    `oaping-safe.json` as the parameter.

Remember to restart both the server and Indexer after changing the
configuration.

## Operation

The OAPing plugin works hard to ensure all pings get through to the tracker
safely. Unsent or unsuccessful pings are saved to disk ("stashed") in the
`ARCHIVE_ID/var/oaping/` directory to be retried later, and removed when they
succeed.

The `bulk_notify` job performs bulk requests in batches of configurable size. It
defaults to sending a ping for each non-trivial Access DataObj in the database,
though when you set it running you can choose how many of the chronologically
earliest ones to skip. If there are stashed pings, it will send them instead of
looking up the next batch from the database.

In notify mode 1, the `safe_notify` job will normally send a single ping to the
tracker each time a new Access DataObj is added to the database. If however
there are stashed pings, they will be sent with the triggering ping in a bulk
request. Similarly, if the job detects that the `bulk_notify` job has been run,
it will look to see if any Access DataObjs were missed between the last
`bulk_notify` run and the triggering Access DataObj, and if so send them with
the triggering ping in a bulk request; if there are too many to send in one go,
the remainder are stashed.

In notify mode 2, the `fast_notify` job will send a single ping to the tracker
each time a new Access DataObj is added to the database. If this fails, a
`retry` job will be scheduled. The latter sends a batch of stashed pings in a
bulk request; if there are any left over, the job reschedules itself.

## Debugging

To help with debugging, the plugin writes one or two dedicated log files:

-   **ARCHIVE_ID/var/oaping-legacy.json**

    This records information about the last run of the `bulk_notify` job. It is
    also used when transitioning from that job to the normal `fast_notify` job,
    after which it is renamed.

-   **ARCHIVE_ID/var/oaping-error.json**

    This records when calls to the tracker have failed, and also when previous
    errors have been resolved successfully. As well as a summary message, it
    records Access DataObjs that were stashed; stashed Access DataObjs that were
    later sent successfully; and any error messages sent back by the tracker.
