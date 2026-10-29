# Tasks

## 1. Stubbed-run test for update

- [ ] 1.1 Write `dmoj/tests/update.sh`: it builds a temporary tree with a copy of `scripts/update`, a fake `scripts/backup_db`, and fake `docker` and `git` on `PATH` that log their arguments and fail on `FAIL_BACKUP` / `FAIL_MIGRATE`; four cases print `PASS backup failure aborts before any change`, `PASS stop precedes migrate and up follows it`, `PASS migrate failure keeps the stack stopped and prints the recipe`, `PASS success prints the backup path`. Verify: `bash -n dmoj/tests/update.sh` and `shellcheck dmoj/tests/update.sh` are clean, and run against the current `update` the four cases do not print `PASS` (the test fails first).

## 2. Rework scripts/update

- [ ] 2.1 In `dmoj/scripts/update`, capture the previous submodule commit and take the backup first, aborting with exit 1 before the submodule update when it fails. Verify: Scenario "A failed backup aborts before anything changes".
- [ ] 2.2 Replace the rebuild, restart and migrate steps with: `docker compose build base`, `docker compose build site celery bridged wsevent`, `docker compose stop site celery bridged`, the one-off migration (`docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py migrate`), then `docker compose up -d site celery bridged wsevent` and `docker compose restart wsevent`. Verify: Scenario "Services are stopped before the migration and started after it".
- [ ] 2.3 On a failed migration print the backup path, the previous commit and the three recovery commands, and exit 1 without starting anything. On success print the backup path and the `./scripts/restore_db` hint after "Update complete.". Verify: Scenarios "The recovery recipe is printed and nothing is restarted" and "The backup path is printed at the end".
- [ ] 2.4 Verify the script as a whole: `bash -n dmoj/scripts/update`, `shellcheck dmoj/scripts/update` report no new findings, and `bash dmoj/tests/update.sh` prints four `PASS` lines and exits 0.

## 3. README

- [ ] 3.1 Update the `update` description (README.md around line 106) and the "migrate failed" paragraph (around line 234) to describe the backup, the stop during migration and the recovery steps. Verify: `grep -n 'pre-update' README.md` shows both places, and the commands quoted there match `dmoj/scripts/update`.

## 4. Integration checks

- [ ] 4.1 Confirm nothing outside the plan changed: `git diff --stat` lists only `dmoj/scripts/update`, `dmoj/tests/update.sh`, `README.md` and this change's files, and `cd dmoj && docker compose config -q` exits 0.
- [ ] 4.2 With the local stack up, run `cd dmoj && docker compose run --rm --no-deps --entrypoint python3 site manage.py check` (the same one-off invocation `update` uses, with `check` instead of `migrate`). Verify: it prints `System check identified no issues` and exits 0, with no uwsgi output.
- [ ] 4.3 Produce the Scenario-to-check report for this change. Verify: each of the four Scenarios maps to a check that was run, and the only check that maps to no Scenario is the `docker compose config -q` regression guard in 4.1, reported as such.

## Workflow follow-up

- Delete the two superseded untracked files the maintainer authorized (look at them first): `docs/superpowers/plans/2026-09-04-update-rollback-safety-net.md` and `docs/superpowers/specs/2026-09-04-update-rollback-safety-net-design.md`.
- The maintainer runs the manual pre-deploy checklist from proposal.md on production and rehearses a full `./scripts/update` on a restored copy before the first Django 5.2 deploy.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
- Detailed plans from `writing-plans` go in `openspec/changes/update-backup-and-stop-before-migrate/plans/`, one per task group above.
