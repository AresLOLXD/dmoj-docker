# Tasks

## 1. Image check in update (test first, then script)

- [ ] 1.1 In `dmoj/tests/update.sh`, make the fake `docker` fail when `FAIL_CHECK` is set and its arguments contain `manage.py check`, and add the cases `image check failure aborts before the stop` and `image check precedes the stop` as written in design.md Decision 3. Verify: `bash -n dmoj/tests/update.sh` and `shellcheck dmoj/tests/update.sh` are clean, and run against the current `update` the two new cases print `FAIL` while the existing four still print `PASS`.
- [ ] 1.2 In `dmoj/scripts/update`, add the step between the rebuild and the stop: heading `== Checking the new site image ==`, the command from design.md Decision 1, and on failure the message, `Backup:` line and `git -C repo checkout $PREV_SHA` line from Decision 2, then `exit 1`. Verify: Scenarios "A failing image check aborts before the stop" and "The check runs after the builds and before the stop".
- [ ] 1.3 Verify the script and test as a whole: `bash -n dmoj/scripts/update` is clean, `shellcheck dmoj/scripts/update` reports no finding on added lines other than SC2181 and SC2086 (the style the script already uses), and `bash dmoj/tests/update.sh` prints six `PASS` lines and exits 0.

## 2. README

- [ ] 2.1 In "Updating The Site", add one sentence saying the new `site` image is checked with `manage.py check` before the app is stopped, that a failed check leaves everything running and prints the backup path and the `git -C repo checkout` command, and that the services should not be recreated until the cause is fixed. Verify: `grep -n 'manage.py check' README.md` shows the sentence and the wording matches `dmoj/scripts/update`.

## 3. Integration checks

- [ ] 3.1 Confirm nothing outside the plan changed: `git diff --stat` lists only `dmoj/scripts/update`, `dmoj/tests/update.sh`, `README.md` and this change's files, and `cd dmoj && docker compose config -q` exits 0.
- [ ] 3.2 Positive check with the real command: in a clone with a correct `site` image (the rehearsal clone), run `docker compose run --rm --no-deps --entrypoint python3 site manage.py check`. Verify: it prints `System check identified` and exits 0, with no uwsgi output.
- [ ] 3.3 Negative check with the real command: with a temporary compose override kept outside the repo that points `site` at an image without Django (for example `docker.io/library/python:3.13-slim`), run the same command. Verify: it exits non-zero, which is the case `update` turns into the abort.
- [ ] 3.4 Produce the Scenario-to-check report for this change. Verify: each of the two Scenarios maps to a check that was run, and the only checks that map to no Scenario are the `docker compose config -q` guard in 3.1 and the real-command checks in 3.2 and 3.3, reported as such.

## Workflow follow-up

- Open the follow-up change for the root cause: `additional_contexts` mapping `ninjaclasher/dmoj-base:latest` to `service:base` in `docker-compose.yml`. It changes the image build contract, so it goes through its own proposal.
- Before the first Django 5.2 deploy the maintainer runs, on the server after building the images, `sudo docker compose run --rm --no-deps --entrypoint pip site list | grep -i -E "^(django|webauthn) "` and expects Django 5.2.x and webauthn 3.x.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
- Detailed plans from `writing-plans` go in `openspec/changes/update-verify-image-before-stop/plans/`, one per task group above.
