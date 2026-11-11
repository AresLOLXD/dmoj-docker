# Proposal

## Why

The nginx check added by `doctor-probe-published-nginx-port` requests `http://127.0.0.1:PORT/` with curl's default `Host` header (`127.0.0.1:PORT`). The site sets `ALLOWED_HOSTS = [HOST]`, so Django answers that request with 400 and the check fails on any correctly configured install. Seen live on 2026-11-10 on the production host: `curl http://127.0.0.1:8081/` gave 400, and the same request with `Host: <HOST>` gave 200, while real users were being served normally. The check reported a healthy stack as broken, which is the opposite failure of the one the earlier change fixed, and just as bad: an operator learns to ignore the red line.

## What Changes

- The `nginx responds` check in `dmoj/scripts/doctor` sends `Host: <HOST>` with its request, where `<HOST>` is the value the running `site` container has in its `HOST` environment variable (the same value `ALLOWED_HOSTS` is built from).
- If the container reports no `HOST`, no header is sent, so the request behaves as before.
- `dmoj/tests/doctor.sh` is extended: its fake HTTP server answers 400 unless the `Host` header matches, so the cases fail without this change.

## Non-goals (what we would not build)

- No change to `ALLOWED_HOSTS` or to any site setting: allowing the loopback host would widen the security posture to make a health check pass.
- No `X-Forwarded-Proto` header: the 2026-11-10 probe showed 200 without it.
- No `--host` flag or environment variable for `doctor`; the running container is the source of truth.
- No change to the pass criterion (`curl -sf`, status below 400) and no change to any other check.

## Capabilities

### New Capabilities

### Modified Capabilities
- `stack-health-check`: the nginx check also states which `Host` header it sends.

## Impact

- `dmoj/scripts/doctor`: one extra `docker compose exec` to read `HOST`, and one optional curl argument.
- `dmoj/tests/doctor.sh`: server and stub updated, one new case.
- Behavior for operators: `./scripts/doctor` goes green on hosts with a real `HOST`. On an install whose `HOST` is empty or a placeholder, the check still fails, as before.
