# Tasks

## 1. The Host header in doctor

- [x] 1.1 In `dmoj/scripts/doctor`, read `HOST` with `docker compose exec -T $COMPOSE_EXEC_FLAGS site printenv HOST` and add `-H "Host: $HOST"` to the nginx curl only when it is non-empty. Verify: `bash -n dmoj/scripts/doctor` and `shellcheck dmoj/scripts/doctor` show no findings on the new lines.
- [x] 1.2 Extend `dmoj/tests/doctor.sh`: the fake server answers 400 unless the `Host` header equals the stub's `HOST`; the fake `docker` answers `printenv HOST`; add a case with an empty `HOST`. Verify: `bash dmoj/tests/doctor.sh` passes, and fails every nginx case against the previous `doctor`.
- [x] 1.3 Produce the Scenario-to-check report. Verify: each Scenario of this change maps to a check that ran.

## Workflow follow-up

- On the production host the maintainer runs `cd /opt/dmoj-docker/dmoj && sudo ./scripts/doctor | grep nginx` and expects `✓ nginx responds on 127.0.0.1:8081`.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
