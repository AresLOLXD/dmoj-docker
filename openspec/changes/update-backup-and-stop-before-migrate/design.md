# Design

## Context

Today `dmoj/scripts/update` runs: submodule update, `build base` + `up -d --build site celery bridged wsevent`, `restart` of the same four, then `./scripts/migrate`. `./scripts/migrate` is `docker compose exec site python3 manage.py migrate`, so it needs a running `site`. The `site` image has a shell-form `ENTRYPOINT uwsgi --ini uwsgi.ini`, so any command appended to `docker compose run site` is swallowed by uwsgi; `copy_static` already works around this with `--entrypoint`. `repo/` is mounted read-only into `site`, `celery`, `bridged` and `wsevent`, which is why a rebuild alone does not restart a running container. nginx re-resolves upstreams at request time (`resolver` in `nginx.conf`), so stopping and starting `site` needs no nginx restart. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- A failed update never leaves new code serving requests against an old or half-migrated schema.
- Every update leaves a restorable backup and tells the operator where it is.
- The ordering and the failure branches are checked by a test that needs neither Docker nor a database.

**Non-Goals:**
- Making the update zero-downtime or transactional (MariaDB DDL cannot be rolled back).
- Detecting whether a given migration is destructive; every update is backed up.
- Anything the proposal lists under Non-goals.

## Decisions

**1. New order: backup -> submodule -> build -> stop -> migrate -> start.** The backup comes first so a failure there changes nothing. Building before stopping keeps the downtime window to the migration itself. `docker compose up -d site celery bridged wsevent` replaces both the old `up -d --build` and the `restart` step: the three stopped services start on the new image and code, and `wsevent`, which is never stopped, is followed by `docker compose restart wsevent` so it picks up `repo/` changes. Alternative considered: stop first and build afterwards; rejected because it lengthens the outage by the build time.

**2. Migrate in a one-off container, inside `update`.** `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py migrate`. `--no-deps` stops compose from touching `db` and `redis`, which are already up; `--entrypoint python3` bypasses uwsgi; `$COMPOSE_EXEC_FLAGS` follows the other scripts' convention for non-TTY runs. It runs on the `site` service definition, so `repo/` stays read-only and the networks and env files are the same as production's. Alternatives rejected: `site-static-build` mounts `repo/` read-write, which this repo deliberately avoids for anything that is not static building; teaching `scripts/migrate` to fall back to `run` changes another script's interface; leaving `site` up and stopping only `celery` and `bridged` still lets the new code query the old schema.

**3. On failure, stay stopped.** `set -e` is not used (the script checks `$?` after each step, matching its current style). After the stop, a failing migrate prints the recipe and exits 1 without starting anything. The recipe is: `git -C repo checkout <PREV_SHA>`, `./scripts/restore_db <backup>`, `docker compose up -d site celery bridged wsevent`. Alternative rejected: restarting the old code on the failed schema, which is the situation this change exists to avoid. An interrupted run (Ctrl-C) during the migration also leaves the services stopped, which is the safe state.

**4. The test is a stubbed run, `dmoj/tests/update.sh`.** It copies `scripts/update` into a temporary `dmoj/scripts/`, puts a fake `backup_db` next to it and fake `docker` and `git` first on `PATH`. The fakes append their arguments to a log file and fail on demand through environment variables (`FAIL_BACKUP`, `FAIL_MIGRATE`). Each case asserts on the exit status, the order of the logged calls and the captured output, and prints `PASS <case>`. This is the executable check the project rules ask for each Scenario; there is no test suite in the repo to extend. Cases: backup failure, success ordering, migrate failure, backup path on success.

**5. Backup path.** `backups/pre-update-$(date +%Y-%m-%d-%H%M%S).sql`, relative to `dmoj/` like `backup_db`'s default, so it sits in the existing gitignored directory. It is stored in one variable and printed from there.

## Risks / Trade-offs

- [The stubbed test proves ordering and branches, not that real compose, podman or Docker accept the commands] -> The task list runs `docker compose config -q` and a manual `docker compose run --rm --no-deps --entrypoint python3 site manage.py check` on the local stack; the maintainer rehearses a full `update` on a restored copy before production (proposal, manual checklist).
- [The backup of a large database delays the start of an update] -> Accepted; it is the point of the change.
- [`site`, `celery` and `bridged` are down for the whole migration] -> Accepted and announced in the output; the migrations here are short.
- [A failure in `up -d` after a successful migration leaves the schema migrated and services stopped] -> The error says so and points at `docker compose up -d`; the backup path is printed.
- [`wsevent` restarts even if nothing in `repo/websocket` changed] -> It is cheap and matches today's behavior.
