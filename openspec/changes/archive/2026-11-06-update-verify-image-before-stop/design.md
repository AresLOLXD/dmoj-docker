# Design

## Context

`dmoj/scripts/update` builds `base` and then `site celery bridged wsevent` (`site`, `celery` and `bridged` are `FROM ninjaclasher/dmoj-base:latest`), stops `site celery bridged`, runs `manage.py migrate` in a one-off container, and starts the services. `migrate` calls Django's system check first (`migrate.py` -> `self.check()`), and that check imports the URLconf, which imports every view module. That is where the rehearsal's `ImportError` surfaced, after the stop. Behavior this change builds on: the one-off `docker compose run --rm --no-deps ... --entrypoint python3 site manage.py ...` already used for the migration, and `manage.py check` not needing the database (it passed locally with `db` stopped). See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- A freshly built `site` image that cannot load the new code stops the update before any service is stopped.
- The operator gets the backup path and the command that realigns the source with the running containers.
- The new branch is covered by the same stubbed-run test as the rest of `update`.

**Non-Goals:**
- Everything listed under Non-goals in proposal.md, in particular fixing why `FROM` resolved to the wrong base.

## Decisions

**1. `manage.py check`, after the build and before the stop.** Command: `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py check`, under `== Checking the new site image ==`. It runs against the new image and the already updated `repo/`, which is exactly the pairing that will run after the update. It is the cheapest check that reproduces the observed failure (the URLconf import), it needs no database and no running services, and it exits non-zero only for errors, not for warnings. *(Agent's call.)* Alternatives considered: `migrate --check` or `makemigrations --check` (need the database, slower); `python3 -c "import judge.urls"` (a hand-rolled subset of what `check` already does and an extra thing to maintain); comparing `pip list` with `uv.lock` (catches stale-but-compatible images, but is a version-comparison feature nobody asked for).

**2. On failure, exit without touching anything and print the way back.** No `stop`, no migration, no `up -d`, no `restart`. The output says the new site image failed the check and nothing was stopped, prints `Backup: $BACKUP_PATH` and `git -C repo checkout $PREV_SHA`. The checkout is printed, not run: by this point the submodule has moved and `repo/` is mounted read-only into the containers that are still running, so realigning the source is the operator's decision. The existing "never restore, never checkout by itself" rule is unchanged. *(Agent's call on the message wording.)*

**3. The test grows by two cases, using the existing stubs.** The fake `docker` fails when `FAIL_CHECK` is set and its arguments contain `manage.py check`. `image check failure aborts before the stop` asserts a non-zero exit, no `stop`, no `manage.py migrate`, no `up -d`, no `restart`, and the output containing the failure message, the backup path and `git -C repo checkout abc1234`. `image check precedes the stop` asserts the order of `build`, `manage.py check`, `stop`, `manage.py migrate` and `up -d` in the call log. The existing four cases are not edited unless the new step makes one of them fail, which it should not.

**4. What this does not detect.** An image that is stale but still imports the new code is not caught. Detecting it would mean comparing installed versions with `uv.lock`, a version-comparison feature that nobody has asked for; it stays out until a stale-but-compatible image actually happens.

**5. The previous commit printed by the recipe is left as it is.** After an update that failed once the submodule had already moved, running `update` again prints the advanced commit as "previous" (the rehearsal printed `796ee023` instead of `13c33119`). Reading the commit the superproject records (`git -C .. ls-tree HEAD dmoj/repo`) would fix that case but breaks the ordinary one whenever a pulled commit bumps the pin, and persisting the commit next to the backup needs state shared between runs. Neither is a clear win, so this stays a known limitation: the first run prints the original commit on its first line (`submodule at <sha>`), and `git submodule status` before the first attempt shows it too. *(Agent's call, and the reason the proposal does not include it.)*

## Risks / Trade-offs

- [The check passes on a stale-but-compatible image] -> Decision 4; the maintainer compares `pip list` of the new `site` image before the first Django 5.2 deploy.
- [After a failed check the image tags `ninjaclasher/dmoj-*:latest` already point at the new images] -> Running containers keep the image they started from, so the app keeps running; the printed message tells the operator nothing was stopped, and the README says not to recreate the services (`up -d`) until the cause is fixed.
- [A few extra seconds per update for one container start] -> Accepted; it is before the downtime, not inside it.
- [`$COMPOSE_EXEC_FLAGS` unset in a shell without a TTY may make `docker compose run` fail] -> Same exposure as the migration command; a failure here is safe because nothing has been stopped yet.
