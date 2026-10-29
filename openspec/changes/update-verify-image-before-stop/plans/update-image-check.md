# Check the new site image before stopping the app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking, but the checkboxes that count live only in `openspec/changes/update-verify-image-before-stop/tasks.md` (group 1). Tick them there, not here.

**Goal:** `dmoj/scripts/update` runs `manage.py check` in a one-off container of the freshly built `site` image before it stops any service, and aborts untouched if that fails.

**Architecture:** One new step in `dmoj/scripts/update` between the rebuild and the stop; two new cases in the existing stubbed-run test `dmoj/tests/update.sh`, written first.

**Tech Stack:** bash, `shellcheck`, docker compose (invoked as `docker compose`).

**Spec:** `openspec/changes/update-verify-image-before-stop/` (`specs/stack-update/spec.md`, `design.md`, Decisions 1-3).

## Global Constraints

- Only these files change in this plan: `dmoj/tests/update.sh` and `dmoj/scripts/update`. Not `backup_db`, `restore_db`, `migrate`, `docker-compose.yml`, any Dockerfile, `README.md` (a separate task group) or anything in `dmoj/repo/`.
- Code, comments and commit messages in English; Conventional Commits; end commit messages with `Refs #3`, a blank line and the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Keep the script's style: a `== Heading ==` echo per step, `if [ $? -ne 0 ]` checks printing `Error: ...` to stderr and `exit 1`. No `set -e`.
- Check command, verbatim: `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py check` (unquoted `$COMPOSE_EXEC_FLAGS`).
- New step heading, verbatim: `== Checking the new site image ==`. Position: after the `== Rebuilding base, site, celery, bridged, wsevent ==` block, before `== Stopping site, celery, bridged ==`.
- Failure output (stderr), verbatim lines: `Error: the new site image failed manage.py check; nothing was stopped`, `Backup: $BACKUP_PATH`, `The submodule is already updated; to realign the source with the running containers: git -C repo checkout $PREV_SHA`, then `exit 1`. Nothing is stopped, migrated, started or restarted on this path, and the script never runs `git checkout` itself.
- Do not edit the existing four test cases or any other step of `update`.
- Never run `dmoj/scripts/update` for real and never run docker/podman or touch a server; verification is the stubbed test, `bash -n` and `shellcheck`.
- The maintainer's dirty tree (`config.js`/`uwsgi.ini` deleted, untracked plans, `dmoj/repo` pointer) is not yours: stage only the files each commit step names.

## Review Focus

- The failure case also asserts the call log has no `restart` and no `up -d`, and still contains the earlier `build` calls (the check ran after the build, not instead of it).
- The ordering case compares real log line numbers of `build`, `manage.py check`, `stop`, `manage.py migrate` and `up -d`, and also requires the check line to contain `run --rm --no-deps` and `--entrypoint python3 site manage.py check` and not ` exec `.
- Every case still runs with `COMPOSE_EXEC_FLAGS` unset.

---

### Task 1: Two failing test cases for the image check

**Files:**
- Modify: `dmoj/tests/update.sh`

**Interfaces:**
- Consumes: the existing helpers `run_update`, `line_of`, `has_call`, `has_out`, `backup_path`, `pass`, `fail`, the variables `STATUS`, `TMP`, `CALLS`, and the existing fake `docker` heredoc inside `run_update`.
- Produces: environment variable `FAIL_CHECK` (when set, the fake `docker` exits 1 for any call whose arguments contain `manage.py check`), and two new cases whose pass lines are exactly `PASS image check failure aborts before the stop` and `PASS image check precedes the stop`.

- [ ] **Step 1: Add `FAIL_CHECK` to the fake `docker`.** Next to the existing `FAIL_MIGRATE` branch, add the same kind of branch for `FAIL_CHECK` and `manage.py check`; mention `FAIL_CHECK` in the comment above `run_update`.
- [ ] **Step 2: Add the two cases before the final `exit $RESULT`.**
  - `image check failure aborts before the stop` (run with `FAIL_CHECK=1 run_update`): `$STATUS` non-zero; the log has a `docker compose build site celery bridged wsevent` line and a `manage.py check` line; the log has no `docker compose stop`, no `manage.py migrate`, no `up -d`, no `restart`; `BACKUP=$(backup_path)` is non-empty and appears in the output; the output contains `failed manage.py check`, `nothing was stopped` and `git -C repo checkout abc1234`.
  - `image check precedes the stop` (no failures): `$STATUS` is 0; `BUILD`, `CHECK`, `STOP`, `MIGRATE`, `UP` are the `line_of` results for `docker compose build site celery bridged wsevent`, `manage.py check`, `docker compose stop site celery bridged`, `manage.py migrate`, `up -d site celery bridged wsevent`, all non-empty and strictly increasing in that order; the check line contains `run --rm --no-deps` and `--entrypoint python3 site manage.py check` and does not contain ` exec `.
- [ ] **Step 3: Lint and see it fail.** Run `bash -n dmoj/tests/update.sh && shellcheck dmoj/tests/update.sh; bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: no `bash -n`/shellcheck output, the original four `PASS` lines, `FAIL` for both new cases, `exit=1`. If a new case already passes against the old `update`, it is not testing the new behavior; fix the case.
- [ ] **Step 4: Commit** only `dmoj/tests/update.sh` with subject `test(update): cover the new site image check`, a short body (the two cases fail until the next commit), `Refs #3` and the trailer.

### Task 2: The check step in `dmoj/scripts/update`

**Files:**
- Modify: `dmoj/scripts/update`
- Test: `dmoj/tests/update.sh` (from Task 1)

**Interfaces:**
- Consumes: the variables `PREV_SHA` and `BACKUP_PATH` already set at the top of `update`, and the test from Task 1.
- Produces: the step described in Global Constraints; no new variables.

- [ ] **Step 1: Insert the step.** Between the rebuild block and the stop block add: an `echo ""` and the heading echo, the verbatim check command, and an `if [ $? -ne 0 ]` branch that prints the three failure lines from Global Constraints to stderr and exits 1. Touch nothing else.
- [ ] **Step 2: Run the checks.** Run `bash -n dmoj/scripts/update; shellcheck dmoj/scripts/update; bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: six `PASS` lines, `exit=0`; shellcheck reports no finding on the lines you added other than SC2181 (the `$?` style) and SC2086 (the unquoted `$COMPOSE_EXEC_FLAGS`), both already present in the script.
- [ ] **Step 3: Commit** only `dmoj/scripts/update` with subject `feat(update): check the new site image before stopping the app`, a short body (why: an image built on a stale base made `migrate` fail after the stop; what: `manage.py check` runs first and a failure aborts untouched), `Refs #3` and the trailer.

## Self-review

- **Spec coverage:** the requirement and its two Scenarios map to the two test cases and to Task 2 Step 1. README and the integration checks (`docker compose config -q`, the real-command positive and negative checks) are groups 2 and 3 of `tasks.md`, outside this plan on purpose.
- **Consistency:** the case names, `FAIL_CHECK`, the heading, the command and the three failure lines are spelled the same in Global Constraints, Task 1 and Task 2.
- **Proportion:** no script body is reproduced beyond the strings the test greps for.
