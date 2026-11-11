# Design

## Context

See proposal.md. `doctor` resolves the published address with `docker compose port nginx 80` and probes it with `check "nginx responds on ADDR:PORT" curl -sf ...`. `check` takes the command as arguments, so an optional `-H` can be added to the argument list.

## Goals / Non-Goals

**Goals:** the check passes on a correctly configured install and still fails when nginx or the site is really broken.
**Non-Goals:** see proposal.md.

## Decisions

1. **Read `HOST` from the running `site` container** with `docker compose exec -T $COMPOSE_EXEC_FLAGS site printenv HOST`. It is the exact value Django's `ALLOWED_HOSTS` is built from, it needs no file access (the `environment/*.env` files are root-owned on the production host), and `doctor` already runs other `exec site` checks. Alternatives: `grep` `environment/site.env` (needs root, duplicates parsing, can differ from what the container really got); a `doctor` variable or flag (new configuration nobody asked for).
2. **Send the header only when `HOST` is non-empty.** An empty value would send `Host:` with nothing, which is worse than the default; with no header the behavior is unchanged and the failure stays visible.
3. **Build the curl arguments in a bash array**, then pass it to `check`. The script already runs under bash.

## Risks / Trade-offs

- [`site` is down, so `printenv` yields nothing] → no header is sent, the request fails with 400 or no connection, and the `site is running` line above already reports the cause.
- [A request with the right `Host` also exercises the Django path, not only nginx] → this is intended: the check says "nginx responds" and a 200 for `/` through nginx to Django is the useful signal; the pass criterion does not change.
