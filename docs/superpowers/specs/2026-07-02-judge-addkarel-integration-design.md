# Judge integration (AddKarel fork) + management scripts

Date: 2026-07-02

## Context

This repo currently has no judge (sandboxed code execution) service at all —
only `bridged`, the daemon that judges connect to on port 9999. The actual
DMOJ judge normally runs as a separate process/host. We are adding one as a
Docker service, built from a fork (`AresLOLXD/judge-server`, `AddKarel`
branch) that adds a Karel language executor on top of upstream
`DMOJ/judge-server`.

Two follow-up efforts were explicitly scoped **out** of this design and will
be handled as separate investigation passes, not specs:
- Security review of the existing Docker setup.
- Freshness check of `dmoj/repo` (site submodule) against upstream DMOJ.

The `scripts/update` script below is intentionally designed to make it easy
to *act* on the freshness check's findings, but the check itself is out of
scope here.

## Judge service

### New files

- `dmoj/judge-tier3-1/Dockerfile` — adapted from the fork's
  `.docker/tier3/Dockerfile`: `FROM dmoj/runtimes-tier3`, `ARG TAG=AddKarel`,
  pulls the source tarball from `AresLOLXD/judge-server` at build time (same
  mechanism the fork itself uses — no local build context needed beyond the
  Dockerfile). Runtime paths (compiler/interpreter locations) are
  auto-generated during the image build via `dmoj-autoconf` and merged
  automatically at runtime — we do not hand-maintain that block.
- `dmoj/judge-tier3-1/judge.yml` — versioned config file (same
  placeholder-value convention as `dmoj/environment/*.env`, e.g.
  `id: <judge name>`, `key: <judge authentication key>`), containing:
  ```yaml
  id: <judge name>
  key: <judge authentication key>
  problem_storage_globs:
    - /problems/*
  ```

### docker-compose.yml changes

Add an anchor for shared judge config, then one service per judge instance:

```yaml
x-judge-tier3-base: &judge-tier3-base
  init: true
  restart: unless-stopped
  cap_add:
    - SYS_PTRACE
  networks: [site]
  depends_on: [bridged]
  command: run -c /judge-config/judge.yml bridged

services:
  # ...existing services...
  judge-tier3-1:
    <<: *judge-tier3-base
    build:
      context: .
      dockerfile: ./judge-tier3-1/Dockerfile
    image: areslolxd/dmoj-judge-tier3
    volumes:
      - ./problems/:/problems/:ro
      - ./judge-tier3-1/judge.yml:/judge-config/judge.yml:ro
```

Key decisions:
- **Networking**: judge is only on the `site` network (not `db`, not
  `nginx`) — it only ever needs to reach `bridged:9999` by hostname
  (`BRIDGED_JUDGE_ADDRESS = [('bridged', 9999)]` in `local_settings.py`). No
  port is published to the host. This limits blast radius since the judge
  executes untrusted submitted code.
- **Capabilities**: only `SYS_PTRACE` is added (DMOJ's documented minimum
  requirement for the sandbox). No `privileged: true`.
- **Problems volume**: mounted read-only (`:ro`) — the judge only reads
  problem data, never writes it.
- **Scaling**: `docker compose --scale` is not viable, because DMOJ
  authenticates judges by a unique `name`/`key` pair registered in the
  Django admin, and scaled replicas would share the same `judge.yml` (same
  identity). Additional judges are added as explicit numbered services
  (`judge-tier3-2`, etc.) via the `new_judge` scaffold script below, reusing
  the `x-judge-tier3-base` anchor to avoid duplicating the boilerplate
  fields.
- **Image naming**: `areslolxd/dmoj-judge-tier3`, following this repo's
  `<namespace>/dmoj-<service>` convention, under the fork owner's namespace
  since it's a custom (Karel-enabled) image.

### Manual registration step

The judge's `name`/`key` must exist as a `Judge` row in the site's database
before `bridged` will accept its connection — this cannot be automated away
entirely, but `scripts/register_judge` (below) collapses it into one
command instead of a manual admin-panel visit + copy-paste.

## Scripts

All scripts follow the existing convention in `dmoj/scripts/`: a bash
script that `cd`s to the `dmoj/` directory and shells out to
`docker compose exec`/`docker compose`. No new host-side dependencies
(no Python/yq requirement) — string edits to YAML config files use `sed`
against known, fixed-format lines.

### `scripts/register_judge <judge-dir>`

Collapses "create Judge in admin" + "copy key" + "edit judge.yml" into one
step.

- `<judge-dir>` is used verbatim as the judge's `name`/`id` (e.g.
  `judge-tier3-1`), so the directory name and the registered name are
  always in sync by construction.
- Generates a random key with `openssl rand -base64 75`.
- Runs `docker compose exec site python3 manage.py shell -c "..."` to
  `Judge.objects.update_or_create(name=<judge-dir>, defaults={'auth_key':
  <key>})`.
- Rewrites the `id:` and `key:` lines in `dmoj/<judge-dir>/judge.yml` via
  `sed`.
- Prints a reminder to run `docker compose up -d --build <judge-dir>`.

### `scripts/judge_status`

Runs `docker compose exec site python3 manage.py shell -c "..."` to print a
table of all `Judge` rows: `name`, `tier`, `online`, `last_ip`. Replaces the
manual "check the admin page" step.

### `scripts/new_judge <name> [template]`

Scaffolds an additional judge instance (e.g. when adding `judge-tier3-2`).

- Copies `dmoj/<template>/` (default `judge-tier3-1`) to `dmoj/<name>/`,
  resetting `id`/`key` in the copied `judge.yml` back to placeholders.
- Prints the `docker-compose.yml` service block to paste in, using
  `<<: *judge-tier3-base` plus the instance-specific `build`, `image`, and
  `volumes` fields.
- Does not edit `docker-compose.yml` itself — compose service addition
  stays a manual, reviewable diff.

### `scripts/doctor`

Read-only health check across the whole stack. Prints ✓/✗ per check;
non-zero exit code if any check fails.

1. **Containers up** — `docker compose ps`; every defined service must be
   `running` (not `exited`/`restarting`).
2. **Django system check** — `manage.py check --deploy` inside `site`.
3. **DB reachable** — `manage.py showmigrations` (or `dbshell -c "SELECT
   1"`) inside `site`.
4. **Redis reachable** — `redis-cli -h redis ping` from a container on the
   `site` network.
5. **Bridged listening** — ports `9999` (judges) and `9998` (Django) open
   inside the `bridged` container.
6. **Judges** — reuses the `judge_status` query; counts `online=True`
   judges. Warns if judges are defined in compose but none are online.
7. **Assets generated** — the `assets` volume is non-empty (catches a
   missed `copy_static`).
8. **nginx responds** — `curl -sf http://localhost/`.
9. **wsevent** — the three internal ports from `config.js` respond:
   `15100` (get), `15101` (post), `15102` (http).
10. **mathoid / pdfoid / texoid** — `curl -sf` against `mathoid:10044`,
    `pdfoid:8888`, `texoid:8888` (URLs per `local_settings.py`) — confirms
    the process responds, not that rendering output is correct.

### `scripts/update`

Automates the README's "Updating The Site" section:

- `git submodule update --remote` on `dmoj/repo` (pulls latest upstream
  DMOJ commit tracked by the submodule).
- `docker compose up -d --build base site celery bridged wsevent`.
- `./scripts/migrate`.
- Prints a reminder to run `./scripts/copy_static` if static files changed
  (not auto-run, since it's not always needed and is slower).

### `scripts/backup_db` / `scripts/restore_db`

- `backup_db [output-path]`: `docker compose exec db mysqldump` piped to a
  timestamped file (default `./backups/dmoj-YYYY-MM-DD-HHMMSS.sql`).
- `restore_db <path>`: pipes the given SQL file into
  `docker compose exec -T db mysql`. Prints a confirmation prompt before
  running, since this overwrites the live database.

### `scripts/logs <service>`

Thin wrapper: `docker compose logs -f --tail=100 <service>`.

## Documentation updates

- `README.md`: new "Setting up a judge" section with the registration
  checklist:
  - [ ] `docker compose build judge-tier3-1`
  - [ ] `docker compose up -d site` + `./scripts/migrate` (if not already
        running)
  - [ ] `./scripts/register_judge judge-tier3-1`
  - [ ] `docker compose up -d --build judge-tier3-1`
  - [ ] `./scripts/judge_status` (or `./scripts/doctor`) to confirm it's
        online
  - [ ] Confirm a demo submission (including a Karel-language problem, if
        one is loaded) gets graded by this judge.
- `README.md`: document the new scripts (`register_judge`, `judge_status`,
  `new_judge`, `doctor`, `update`, `backup_db`, `restore_db`, `logs`)
  alongside the existing ones.
- `CLAUDE.md`: add `dmoj/judge-tier3-1/` to the repo-layout section, and
  the new scripts to "Common commands".

## Testing / verification

- `docker compose build judge-tier3-1` succeeds and produces the Karel
  executor (verify with `docker compose run --rm judge-tier3-1 test` or by
  checking the judge's self-test log for `KAREL` on startup).
- After `register_judge` + `up`, `./scripts/judge_status` shows the judge
  `online: true`.
- A demo submission (Python, from the `demo` fixture) is graded
  successfully by `judge-tier3-1`.
- If a Karel problem is available, a Karel submission is graded
  successfully.
- `./scripts/doctor` passes all 10 checks on a fully-started stack.
- `./scripts/backup_db` produces a restorable SQL dump; `./scripts/restore_db`
  round-trips it without error.

## Out of scope

- Security hardening review of the Docker setup as a whole (separate
  investigation).
- Checking `dmoj/repo` freshness against upstream DMOJ (separate
  investigation) — `scripts/update` supports acting on its findings but
  does not perform the check itself.
- Multiple judge tiers (tier1/tier2) — only `judge-tier3-1` is added now;
  `scripts/new_judge` exists to add more later without redesign.
- TLS/secure (`-s`) connection between judge and bridged — matches this
  repo's existing unencrypted internal setup.
