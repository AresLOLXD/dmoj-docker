# Proposal

## Why

`./scripts/doctor` checks nginx with `curl -sf http://localhost/`, which hardcodes port 80. The stack never publishes nginx there: compose maps it to `127.0.0.1:8080` (rootless podman cannot bind ports below 1024), and the production host maps `8081`. So the check always fails on the documented setup, and on a host where something else answers on port 80 it passes while probing that other listener, not the nginx container. A health check that can say "ok" about the wrong thing is worse than one that is missing. Seen live on 2026-10-28: the check passed on the production host only because the host itself answered on `:80`.

## What Changes

- The `nginx responds` check in `dmoj/scripts/doctor` asks compose which host address and port are published for the `nginx` service (`docker compose port nginx 80`) and probes that address.
- The check label shows the address that was probed (for example `nginx responds on 127.0.0.1:8081`), so the output proves what was tested.
- If nginx is not running, or publishes no port, the check fails with a clear message and `doctor` carries on with the remaining checks, as every other check already does.
- A wildcard bind (`0.0.0.0` or `[::]`) is probed through `127.0.0.1`.

## Non-goals (what we would not build)

- No change to what counts as "responds": the success criterion stays `curl -sf` (HTTP status below 400). Whether a bare reachability check should drop `-f`, as the rendering-service checks do, is a separate follow-up: it would change the pass criterion, so it needs its own change.
- No `--port` flag, environment variable or config file for `doctor`; compose is the single source of truth for the published port.
- No change to the compose port mapping, to nginx, or to any other check in `doctor`.
- No fix for the `HOST=<host>` placeholder case in `site.env`, where `/` answers 400 and the check fails for that reason.

## Capabilities

### New Capabilities
- `stack-health-check`: what `./scripts/doctor` verifies about the running stack and how it reports it. There is no main spec for it yet, so this change introduces it with the requirement it touches.

### Modified Capabilities

## Impact

- `dmoj/scripts/doctor`: one check and its label. The label text changes, so anything that greps the old `nginx responds on :80` text would stop matching; nothing in this repo does (checked in README.md, CLAUDE.md and `dmoj/scripts/`).
- Behavior change for operators: hosts where the old check passed by probing port 80 may now fail until nginx is really published and reachable, which is the point.
- No dependencies, images or compose changes.
