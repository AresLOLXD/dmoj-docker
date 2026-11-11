# Tasks

## 1. The broker check in update

- [ ] 1.1 In `dmoj/scripts/update`, add `abort_before_stop` (prints the error, `Backup:` and the checkout hint, exits 1) and use it for the site check. Verify: `bash dmoj/tests/update.sh` still passes its existing cases.
- [ ] 1.2 Add the broker check after the site check, as described in design.md decision 1 and 2. Verify: `bash -n dmoj/scripts/update` and `shellcheck` show no new findings on the new lines.
- [ ] 1.3 Extend `dmoj/tests/update.sh` with the three Scenarios (stub failure switch, ordering, no worker command). Verify: `bash dmoj/tests/update.sh` passes, and each new case fails when the broker check is removed or moved after the stop.

## 2. Docs and verification

- [ ] 2.1 Update the README step list and the failure note in "Updating The Site". Verify: the text names the broker check and says nothing was stopped on failure.
- [ ] 2.2 Re-run the scratch reproduction (locked dependencies, `redis:8.8-alpine`) with the exact `python3 -c` line: it fails with redis-py 5.2.1 and passes with 6.4.0. Verify: both outcomes observed.
- [ ] 2.3 Produce the Scenario-to-check report. Verify: each Scenario maps to a check that ran.

## Workflow follow-up

- The first `./scripts/update` on the production host after the merge is the live check of the `python3 -c` line inside the container.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
