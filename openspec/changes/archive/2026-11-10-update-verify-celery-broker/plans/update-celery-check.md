# Check the celery broker connection before stopping the app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking, but the checkboxes that count live only in `openspec/changes/update-verify-celery-broker/tasks.md`. Tick them there, not here.

**Goal:** `dmoj/scripts/update` opens the Celery broker connection from a one-off container of the freshly built `celery` image before it stops any service, and aborts untouched if that fails. The two pre-stop checks share one abort function.

**Architecture:** One shell function and one new step in `dmoj/scripts/update`; three new cases in the stubbed-run test `dmoj/tests/update.sh`, written first; a README paragraph.

**Tech Stack:** bash, `shellcheck`, docker compose (invoked as `docker compose`).

**Spec:** `openspec/changes/update-verify-celery-broker/` (`specs/stack-update/spec.md`, `design.md`, Decisions 1-4).

## Global Constraints

- Files that change: `dmoj/scripts/update`, `dmoj/tests/update.sh`, `README.md` (Task 3 only). Not `backup_db`, `restore_db`, `migrate`, `doctor`, `docker-compose.yml`, any Dockerfile or anything in `dmoj/repo/`.
- Code, comments and commit messages in English; Conventional Commits; end commit messages with a blank line and the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Keep the script's style: a `== Heading ==` echo per step, `if [ $? -ne 0 ]` checks, no `set -e`.
- Abort function, verbatim name and behavior: `abort_before_stop` takes one argument (the failure description) and prints to stderr `Error: $1; nothing was stopped`, `Backup: $BACKUP_PATH`, `The submodule is already updated; to realign the source with the running containers: git -C repo checkout $PREV_SHA`, then `exit 1`. It is defined above the first check and used by both checks. The site check's visible text must stay identical: its argument is `the new site image failed manage.py check`.
- Broker step heading, verbatim: `== Checking the celery broker connection ==`. Position: after the site image check, before `== Stopping site, celery, bridged ==`.
- Broker command, verbatim (unquoted `$COMPOSE_EXEC_FLAGS`, the Python code in one double-quoted argument): `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 celery -c "from dmoj_celery import app; app.connection_for_read().ensure_connection(max_retries=1, timeout=10)"`.
- Broker failure argument, verbatim: `the new celery image could not reach the broker (is redis running?)`.
- The check never starts a worker: no `celery -A ... worker` anywhere in the new code.
- Do not edit the existing six test cases or any other step of `update`.
- Never run `dmoj/scripts/update` for real and never run docker/podman or touch a server; verification is the stubbed test, `bash -n` and `shellcheck`.
- The maintainer's dirty tree (`config.js`/`uwsgi.ini` deleted, untracked plans, `dmoj/repo` pointer) is not yours: stage only the files each commit step names.

## Review Focus

- The failure case asserts the call log has no `stop`, `manage.py migrate`, `up -d` or `restart`, and still contains the build and the site `manage.py check` lines.
- The ordering case compares real log line numbers (site check < broker check < stop < migrate < up -d) and requires the broker line to contain `run --rm --no-deps` and `--entrypoint python3 celery -c` and not ` exec `.
- The function refactor changes no output of the site check path: the existing `image check failure aborts before the stop` case still passes unedited.
- Every case still runs with `COMPOSE_EXEC_FLAGS` unset.

---

### Task 1: Extract `abort_before_stop` and add three failing test cases

**Files:**
- Modify: `dmoj/scripts/update`, `dmoj/tests/update.sh`

**Interfaces:**
- Consumes: the existing helpers `run_update`, `line_of`, `has_call`, `has_out`, `backup_path`, `pass`, `fail`, the variables `STATUS`, `TMP`, `CALLS`, the fake `docker` heredoc inside `run_update`, and the existing site check block in `update`.
- Produces: the function `abort_before_stop` (see Global Constraints) used by the site check; environment variable `FAIL_BROKER` (when set, the fake `docker` exits 1 for any call whose arguments contain `ensure_connection`); and three new cases whose pass lines are exactly `PASS broker check failure aborts before the stop`, `PASS broker check runs after the site check and before the stop` and `PASS broker check opens a connection and starts no worker`.

- [ ] **Step 1: Refactor.** In `dmoj/scripts/update`, define `abort_before_stop` just above the `== Checking the new site image ==` block and make the site check's failure branch call `abort_before_stop "the new site image failed manage.py check"`. Run `bash dmoj/tests/update.sh`: the six existing cases still pass.
- [ ] **Step 2: Add `FAIL_BROKER` to the fake `docker`** next to the `FAIL_CHECK` branch (match on `ensure_connection`), and mention it in the comment above `run_update`.
- [ ] **Step 3: Add the three cases before the final `exit $RESULT`.**
  - `broker check failure aborts before the stop` (`FAIL_BROKER=1 run_update`): `$STATUS` non-zero; the log has the `docker compose build site celery bridged wsevent` line, a `manage.py check` line and an `ensure_connection` line; no `docker compose stop`, no `manage.py migrate`, no `up -d`, no `restart`; `BACKUP=$(backup_path)` non-empty and `Backup: $BACKUP` in the output; the output contains `could not reach the broker`, `nothing was stopped` and `git -C repo checkout abc1234`.
  - `broker check runs after the site check and before the stop` (no failures): `$STATUS` 0; `CHECK`, `BROKER`, `STOP`, `MIGRATE`, `UP` are the `line_of` results for `manage.py check`, `ensure_connection`, `docker compose stop site celery bridged`, `manage.py migrate`, `up -d site celery bridged wsevent`, all non-empty and strictly increasing in that order; the broker line contains `run --rm --no-deps` and `--entrypoint python3 celery -c` and does not contain ` exec `.
  - `broker check opens a connection and starts no worker` (no failures): `$STATUS` 0; the broker line contains `connection_for_read` and `ensure_connection`; the log has no line containing `celery -A` and none containing ` worker`.
- [ ] **Step 4: Lint and see it fail.** Run `bash -n dmoj/tests/update.sh dmoj/scripts/update; shellcheck dmoj/tests/update.sh; bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: the six original `PASS` lines, `FAIL` for the three new cases, `exit=1`, no new shellcheck finding in the test. A new case that already passes against the old script is not testing the new behavior; fix it.
- [ ] **Step 5: Commit** only `dmoj/scripts/update` and `dmoj/tests/update.sh` with subject `test(update): cover the celery broker check` and a short body (the function refactor changes no output; the three cases fail until the next commit).

### Task 2: The broker step in `dmoj/scripts/update`

**Files:**
- Modify: `dmoj/scripts/update`
- Test: `dmoj/tests/update.sh` (from Task 1)

**Interfaces:**
- Consumes: `abort_before_stop` and the tests from Task 1.
- Produces: the step described in Global Constraints; no new variables.

- [ ] **Step 1: Insert the step.** After the site check block and before the stop block add an `echo ""`, the heading echo, the verbatim broker command, and an `if [ $? -ne 0 ]; then abort_before_stop "the new celery image could not reach the broker (is redis running?)"; fi`. Add a one-line comment saying the check opens the connection instead of starting a worker, because a worker would take tasks from the live queue. Touch nothing else.
- [ ] **Step 2: Run the checks.** Run `bash -n dmoj/scripts/update; shellcheck dmoj/scripts/update; bash dmoj/tests/update.sh; echo "exit=$?"`. Expected: nine `PASS` lines, `exit=0`; shellcheck reports on your added lines only SC2181 and SC2086, both already present in the script.
- [ ] **Step 3: Commit** only `dmoj/scripts/update` with subject `feat(update): check the celery broker connection before stopping the app`, a short body (why: on 2026-11-10 a stale redis-py pin made the celery worker crash-loop after an update that passed the site check; what: open the broker connection from a one-off celery container first and abort untouched on failure) and the trailer.

### Task 3: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update "Updating The Site".** The numbered list currently has the image-check step (3 of 5). Make that step cover both checks ("checks the freshly built `site` image with `manage.py check` and the `celery` image's broker connection before stopping anything, and aborts with everything still running if either fails"), keeping the list at five steps. In the failure paragraph, say the same checkout-promptly advice applies to either check and that a failing broker check usually means Redis is not running or a Python dependency of the worker is incompatible. Change nothing else.
- [ ] **Step 2: Verify.** `git diff README.md` shows only those two edits; the numbered list is still 1-5.
- [ ] **Step 3: Commit** only `README.md` with subject `docs(readme): describe the celery broker check in update` and the trailer.

## Self-review

- **Spec coverage:** the requirement and its three Scenarios map to the three test cases and to Task 2 Step 1. The scratch reproduction and the Scenario-to-check report (`tasks.md` 2.2 and 2.3) are the controller's, outside this plan.
- **Consistency:** the case names, `FAIL_BROKER`, `abort_before_stop`, the heading, the command and the failure argument are spelled the same in Global Constraints and the tasks.
- **Proportion:** no script body is reproduced beyond the strings the tests grep for.
