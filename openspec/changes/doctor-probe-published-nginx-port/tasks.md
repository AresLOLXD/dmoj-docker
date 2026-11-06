# Tasks

## 1. The nginx check in doctor

- [x] 1.1 In `dmoj/scripts/doctor`, resolve the published address with `docker compose port nginx 80`: first line only, split at the last colon, wildcard hosts (`0.0.0.0`, `[::]`, `::`) mapped to `127.0.0.1`. Verify: `bash -n dmoj/scripts/doctor` and `shellcheck dmoj/scripts/doctor` report no new findings.
- [x] 1.2 Replace the fixed `nginx responds on :80` check with `curl -sf http://ADDR:PORT/ -o /dev/null`, labelled `nginx responds on ADDR:PORT`. Verify: Scenario "The published address is probed and shown" (local stack up, grep for `✓ nginx responds on 127.0.0.1:8080`).
- [x] 1.3 When the lookup fails, print a `✗ nginx responds` line with a short reason, set `FAILED=1` and continue with the next section. Verify: Scenarios "A stopped nginx fails the check instead of falling back to port 80" and "Remaining checks still run when the nginx check fails" (nginx stopped, both greps and the exit status).

## 2. Verification across setups

- [x] 2.1 Check the wildcard bind (IPv4 and IPv6) and the first-line rule with `dmoj/tests/doctor.sh`, which runs a copy of `doctor` against a fake `docker` and a real local HTTP server. Verify: Scenario "A wildcard bind is probed through the loopback address". The local host has no built images, so the live compose override was not run; the fake `docker` replaces it.
- [x] 2.2 Run `bash dmoj/tests/doctor.sh` on the new `doctor` (six cases pass) and on the previous one (all six fail). Verify: the test discriminates. A full live run needs the built stack and is left to the maintainer (see Workflow follow-up).
- [x] 2.3 Produce the Scenario-to-check report for this change. Verify: each of the four Scenarios maps to a check that was run, and no check ran that maps to no Scenario.

## Workflow follow-up

- The production host (Docker, nginx published on `8081`) cannot be reached from the agent. The maintainer runs `cd /opt/dmoj-docker/dmoj && sudo ./scripts/doctor | grep nginx` and expects `✓ nginx responds on 127.0.0.1:8081`.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
- Detailed plans from `writing-plans` go in `openspec/changes/doctor-probe-published-nginx-port/plans/`, one per task group above.
