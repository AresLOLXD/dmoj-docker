# Design

## Context

See proposal.md for why. `dmoj/scripts/doctor` runs from `dmoj/` (it `cd`s there), counts failures in `FAILED`, and wraps most checks in a `check "<label>" <command...>` helper that prints `✓`/`✗`, shows the command's output on failure and never aborts the script. The container loop above it prints its own `✓`/`✗` lines directly and sets `FAILED=1`. The nginx check is one `check` call with a fixed label and URL.

Observed in this session: `docker compose port nginx 80` prints `ADDR:PORT` (for example `127.0.0.1:8080`) when nginx is running, and with nginx stopped it prints `service "nginx" is not running` and exits 1 (seen through the podman compose provider). A dual-stack publish can print one line per address family, and an IPv6 wildcard prints as `[::]:PORT`.

Nothing else in the repo depends on the old label text: README.md, CLAUDE.md and `dmoj/scripts/` were searched for `responds on`, and only `doctor` itself matches. No documentation change is needed.

## Goals / Non-Goals

**Goals:**
- The nginx check's target comes from compose, so it is right on the default setup, on the production host's `8081`, and on any future mapping.
- The output line states what was probed.

**Non-Goals:**
- Changing the pass criterion, adding configuration, or touching other checks (see proposal.md, Non-goals).
- Handling an nginx published on several different host ports: the first address compose reports is probed.

## Decisions

1. **Ask compose, not the compose file.** Use `docker compose port nginx 80`. It is the same source of truth the stack runs on, and it respects overrides such as the production host's modified `docker-compose.yml`. Alternatives: parse `docker-compose.yml` with `grep`/`yq` (duplicates compose, breaks on overrides); an `NGINX_PORT` variable for `doctor` (new configuration nobody asked for); probing from inside the container with `docker compose exec nginx wget` (never exercises the host publish that the external TLS proxy actually uses).
2. **Parse by splitting at the last colon.** Address is everything before it, port everything after, which handles `[::]:8080`. Take the first output line. Map `0.0.0.0`, `[::]` and `::` to `127.0.0.1` so a wildcard bind is still probed locally.
3. **Resolve before calling `check`.** The label contains the address, and `check` takes its label as an argument, so the lookup runs first. When it fails, print the `✗ nginx responds` line with a short reason and set `FAILED=1` directly, mirroring the container loop, then continue. This keeps `check` untouched.
4. **Keep `curl -sf http://ADDR:PORT/ -o /dev/null`.** Only the target changes.

## Risks / Trade-offs

- [`compose port` output differs between the docker compose binary and the podman provider, or between versions] → Verify on the local podman stack here, and give the production check as a command for the maintainer to run on the Docker host. This session cannot reach that host.
- [The check can still fail for a reason that is not nginx: `/` is served by Django, so an invalid `HOST` in `site.env` returns 400 and `-f` reports a failure] → Out of scope by decision; the failure message shows the curl output so the cause is visible.
- [The production host passed the old check by probing a different listener on port 80] → After this change that host may report a failure it did not report before. That is the intended correction, and it is called out in the proposal's Impact.
