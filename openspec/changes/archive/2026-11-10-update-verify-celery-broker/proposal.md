# Proposal

## Why

`./scripts/update` checks the new `site` image with `manage.py check` before it stops anything, but nothing exercises the `celery` worker's own start-up path. On 2026-11-10 the update brought in `kombu` 5.7.0 (through the fork's `uv.lock`) while `dmoj/base/Dockerfile` still pinned `redis==5.2.1`. `kombu` refuses the Redis broker below redis-py 6.1.0, so the worker crash-looped (46 restarts, `kombu.exceptions.VersionMismatch`) from the moment the stack came back up. The `site` check passed, the update reported success, and only `./scripts/doctor` (`celery is 'restarting'`) revealed it, minutes later. Background tasks were not processed in between.

The failure happens when the worker opens its broker connection, so a check that imports the site cannot see it. It can be reproduced without starting a worker, and without taking tasks from the live queue, by opening the connection the way the worker does.

## What Changes

- After the existing `site` image check and before stopping anything, `dmoj/scripts/update` runs a one-off container of the freshly built `celery` image that opens the Celery broker connection (`app.connection_for_read().ensure_connection(max_retries=1)` on `dmoj_celery`'s app, with a retry limit).
- If that fails, the update exits non-zero without stopping, migrating or starting anything, and prints what failed, the backup path and the `git -C repo checkout <previous commit>` realign command, like the `site` check does.
- The abort output of the two checks is produced by one small shell function instead of two copies of the same three lines.
- `dmoj/tests/update.sh` gets cases for the new check; the README step list and failure notes mention it.

## Non-goals (what we would not build)

- No real worker is started for the check: it would consume tasks from the live Redis queue while the old worker is still running.
- No check for `bridged`, `wsevent` or the judges: only the failure that actually happened is covered. `bridged` already imports the same Django code the `site` check loads.
- No change to `doctor`: it stays the after-the-fact health check. Making it wait for or retry `celery` is not part of this change.
- No protection against the `redis` pin in `dmoj/base/Dockerfile` going stale again: the check detects the break before the stop, it does not prevent it. Checking pins against the lock on every fork bump is a separate follow-up.
- No rollback automation: the update still only prints the recovery commands.

## Capabilities

### New Capabilities

### Modified Capabilities
- `stack-update`: a second pre-stop image check, for the celery worker's broker connection.

## Impact

- `dmoj/scripts/update`: one more `docker compose run` before the stop, and one shared abort function.
- `dmoj/tests/update.sh`, `README.md`: new cases and wording.
- Operator-visible: `update` takes a few seconds longer; an update that would have left `celery` crash-looping now aborts with everything still running. If Redis itself is not running, the check also fails (the message says to look at Redis), which is correct because the worker could not have started either.
