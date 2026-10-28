# Tasks

## 1. The nginx check in doctor

- [ ] 1.1 In `dmoj/scripts/doctor`, resolve the published address with `docker compose port nginx 80`: first line only, split at the last colon, wildcard hosts (`0.0.0.0`, `[::]`, `::`) mapped to `127.0.0.1`. Verify: `bash -n dmoj/scripts/doctor` and `shellcheck dmoj/scripts/doctor` report no new findings.
- [ ] 1.2 Replace the fixed `nginx responds on :80` check with `curl -sf http://ADDR:PORT/ -o /dev/null`, labelled `nginx responds on ADDR:PORT`. Verify: Scenario "The published address is probed and shown" (local stack up, grep for `✓ nginx responds on 127.0.0.1:8080`).
- [ ] 1.3 When the lookup fails, print a `✗ nginx responds` line with a short reason, set `FAILED=1` and continue with the next section. Verify: Scenarios "A stopped nginx fails the check instead of falling back to port 80" and "Remaining checks still run when the nginx check fails" (nginx stopped, both greps and the exit status).

## 2. Verification across setups

- [ ] 2.1 Check the wildcard bind with a temporary compose override published at `0.0.0.0:8080:80` kept in the scratchpad, not committed. Verify: Scenario "A wildcard bind is probed through the loopback address".
- [ ] 2.2 Run the full `./scripts/doctor` on the local podman stack. Verify: only the nginx line differs from a run before the change, and the final status is unchanged.
- [ ] 2.3 Produce the Scenario-to-check report for this change. Verify: each of the four Scenarios maps to a check that was run, and no check ran that maps to no Scenario.

## Workflow follow-up

- The production host (Docker, nginx published on `8081`) cannot be reached from the agent. The maintainer runs `cd /opt/dmoj-docker/dmoj && sudo ./scripts/doctor | grep nginx` and expects `✓ nginx responds on 127.0.0.1:8081`.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
- Detailed plans from `writing-plans` go in `openspec/changes/doctor-probe-published-nginx-port/plans/`, one per task group above.
