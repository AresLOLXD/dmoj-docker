# scripts/update: backup, stop, migrate, start — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking, but the checkboxes that count live only in `openspec/changes/update-backup-and-stop-before-migrate/tasks.md` (groups 1 and 2). Tick them there, not here.

**Goal:** `dmoj/scripts/update` backs up the database first, stops `site`, `celery` and `bridged` while it migrates, and starts them again only after the migration succeeds.

**Architecture:** One bash script changes (`dmoj/scripts/update`) and one new bash test (`dmoj/tests/update.sh`) runs a copy of it against fake `docker`, `git` and `backup_db` that log every call, so ordering and failure branches are asserted without Docker.

**Tech Stack:** bash, `shellcheck`, docker compose (invoked as `docker compose`, as every script here does; the local host is podman).

**Spec:** `openspec/changes/update-backup-and-stop-before-migrate/` (`specs/stack-update/spec.md`, `design.md`).

## Global Constraints

- Only these files change: `dmoj/scripts/update` (modify), `dmoj/tests/update.sh` (create). Do not touch `backup_db`, `restore_db`, `migrate`, `docker-compose.yml`, or anything in `dmoj/repo/`.
- Code, comments and commit messages are in English; commits are Conventional Commits and end with the attribution trailer the session was given.
- Keep the script's current style: `#!/bin/bash`, `cd $(dirname $(dirname $0)) || exit` first, a `== Heading ==` echo per step, and `if [ $? -ne 0 ]` checks that print `Error: ...` to stderr and `exit 1`. Do not add `set -e`.
- Migration command, verbatim: `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py migrate` (unquoted `$COMPOSE_EXEC_FLAGS`, as in the other scripts).
- Services stopped: `site celery bridged`. Services started: `site celery bridged wsevent`, then `docker compose restart wsevent`.
- Backup path: `backups/pre-update-$(date +%Y-%m-%d-%H%M%S).sql`, kept in the variable `BACKUP_PATH`; previous submodule commit in `PREV_SHA` from `git -C repo rev-parse HEAD`.
- Never run `restore_db` or `git checkout` from the script; failure only prints the recipe.
- The maintainer's untracked files and the dirty tree (`config.js`/`uwsgi.ini` deleted, untracked plans, `dmoj/repo` pointer) are not yours: stage only the files named in each commit step.
- Run commands from the repo root unless a step says otherwise.

## Review Focus

- The `FAIL_BACKUP` case also asserts the call log has no `docker` line and no `submodule` line (the read-only `rev-parse` is allowed).
- The migrate-failure case also asserts there is no `restart` and no `up -d` in the log, and that the stop already happened.
- Every case runs with `COMPOSE_EXEC_FLAGS` unset: the empty expansion must not break the migration command line.

---

### Task 1: Stubbed-run test for `update` (written first, fails first)

**Files:**
- Create: `dmoj/tests/update.sh`

**Interfaces:**
- Consumes: `dmoj/scripts/update` (copied, not modified, by the test).
- Produces: running `bash dmoj/tests/update.sh` prints exactly these lines when green, in this order, and exits 0 only if all four pass (non-zero and a `FAIL <name>` line otherwise): `PASS backup failure aborts before any change`, `PASS stop precedes migrate and up follows it`, `PASS migrate failure keeps the stack stopped and prints the recipe`, `PASS success prints the backup path`.

- [ ] **Step 1: Write `dmoj/tests/update.sh`.** Shape, so the implementer writes one reasonable thing:
  - `ROOT` is the `dmoj/` directory derived from the script's own path. A helper `run_update` builds a fresh `mktemp -d` tree per case containing `dmoj/scripts/update` (copy of `$ROOT/scripts/update`), a stub `dmoj/scripts/backup_db`, and `bin/docker` and `bin/git` stubs; it runs `PATH=$TMP/bin:$PATH CALLS=$TMP/calls bash $TMP/dmoj/scripts/update` with stdout and stderr to `$TMP/out`, and records the exit status in `$STATUS`.
  - Every stub appends its full command line to `$CALLS` as `<name> <args>` (`backup_db <path>`, `docker <args>`, `git <args>`). `backup_db` exits 1 when `FAIL_BACKUP` is set. `docker` exits 1 when `FAIL_MIGRATE` is set and its arguments contain `manage.py migrate`. `git` prints `abc1234` when its arguments contain `rev-parse`, and exits 0 otherwise.
  - A helper `line_of PATTERN` prints the first line number in `$CALLS` matching a fixed string, empty if none; a helper `pass NAME` / `fail NAME` prints `PASS NAME` / `FAIL NAME` and `fail` sets a non-zero final exit status.
  - Case assertions (names verbatim from the Produces line):
    - `backup failure aborts before any change` (`FAIL_BACKUP=1`): `$STATUS` non-zero; `$CALLS` has no `docker` line and no `submodule` line; `$TMP/out` contains `pre-update backup failed`.
    - `stop precedes migrate and up follows it` (no failures): `$STATUS` is 0; `docker compose stop site celery bridged` is logged; the migration line is logged and contains `run --rm --no-deps`, `--entrypoint python3 site manage.py migrate` and not ` exec `; the line numbers satisfy stop < migrate < `up -d site celery bridged wsevent`.
    - `migrate failure keeps the stack stopped and prints the recipe` (`FAIL_MIGRATE=1`): `$STATUS` non-zero; `$CALLS` has the stop line but no `up -d` and no `restart`; `$TMP/out` contains the backup path (taken from the `backup_db` line in `$CALLS`), `abc1234`, `git -C repo checkout abc1234`, `./scripts/restore_db` and `docker compose up -d`.
    - `success prints the backup path` (no failures): `$STATUS` is 0 and `tail -n 5 $TMP/out` contains the backup path and `./scripts/restore_db`.
- [ ] **Step 2: Syntax and lint.** Run `bash -n dmoj/tests/update.sh && shellcheck dmoj/tests/update.sh`. Expected: no output.
- [ ] **Step 3: Run it against the current `update` and see it fail.** Run `bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: no `PASS` line for the four names, at least one `FAIL` line, `exit` non-zero. If any case already passes against the old script, the case is not testing the new behavior; fix the case.

### Task 2: Rework `dmoj/scripts/update`

**Files:**
- Modify: `dmoj/scripts/update`
- Test: `dmoj/tests/update.sh` (from Task 1)

**Interfaces:**
- Consumes: `./scripts/backup_db <path>` (exit 0 on success, non-zero on failure, writes the dump to `<path>`), `git -C repo rev-parse HEAD` (run after the script's own `cd` into `dmoj/`), and the test from Task 1.
- Produces: the script behaves as the `stack-update` spec says; its output strings below are what the test greps for.

- [ ] **Step 1: Capture the rollback point and take the backup before anything else.** At the top, after the `cd` line, set `PREV_SHA` and `BACKUP_PATH`, print `== Backing up the database to $BACKUP_PATH (submodule at $PREV_SHA) ==`, run `./scripts/backup_db "$BACKUP_PATH"`; on failure print to stderr `Error: pre-update backup failed; nothing was changed` and `exit 1` before the submodule step.
- [ ] **Step 2: Keep the submodule step as is, then replace the rebuild/restart/migrate steps.** Order and headings: `== Rebuilding base, site, celery, bridged, wsevent ==` runs `docker compose build base && docker compose build site celery bridged wsevent` (keep the existing comment about building `base` first); then `== Stopping site, celery, bridged ==` runs `docker compose stop site celery bridged`; then `== Running migrations ==` runs the verbatim migration command from Global Constraints; then `== Starting site, celery, bridged, wsevent ==` runs `docker compose up -d site celery bridged wsevent && docker compose restart wsevent`, with the existing comment about `repo/` being a read-only mount adapted to explain why `wsevent` is restarted. Each step keeps the `if [ $? -ne 0 ]` / `Error: ...` / `exit 1` pattern. Delete the old `== Restarting ... ==` step.
- [ ] **Step 3: Migration-failure output.** When the migration step fails, print to stderr: `Error: migration failed`, a blank line, `site, celery and bridged are STOPPED and were not restored. Backup: $BACKUP_PATH`, then the numbered recovery steps `1. git -C repo checkout $PREV_SHA`, `2. ./scripts/restore_db $BACKUP_PATH`, `3. docker compose up -d site celery bridged wsevent`; `exit 1`. When the start step fails, print `Error: start failed; the schema is already migrated. Fix the cause and run: docker compose up -d site celery bridged wsevent` and `exit 1`.
- [ ] **Step 4: Success output.** After `Update complete.` and the existing `copy_static` hint, print `Pre-update backup: $BACKUP_PATH` and `To restore it: ./scripts/restore_db $BACKUP_PATH` as the last two lines.
- [ ] **Step 5: Run the checks.** Run `bash -n dmoj/scripts/update && shellcheck dmoj/scripts/update && bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: the four `PASS` lines, `exit=0`, and shellcheck reporting no finding on lines this change added (findings on untouched lines may remain; do not fix them here).
- [ ] **Step 6: Commit.**

```bash
git add dmoj/scripts/update dmoj/tests/update.sh
git commit -m "feat(update): back up the database and stop the app before migrating"
```

Body: one short paragraph (why: Django 5.2 brings destructive social-auth migrations; what: backup first, services stopped during migrate, recipe on failure), `Refs #3`, then the attribution trailer.

## Self-review

- **Spec coverage:** the four requirements/scenarios map one-to-one to the four test cases and to Steps 1-4 of Task 2. The `docker compose config -q` guard, the README and the local `manage.py check` are groups 3 and 4 of `tasks.md`, outside this plan on purpose.
- **Consistency:** `PREV_SHA`, `BACKUP_PATH`, the four case names and the migration command are spelled the same in Global Constraints, Task 1 and Task 2.
- **Proportion:** no script body is reproduced; steps give headings, commands and output strings the test depends on.
