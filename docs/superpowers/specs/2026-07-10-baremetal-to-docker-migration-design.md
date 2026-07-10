# Migrating a bare-metal DMOJ install to this repo's docker-compose stack

## Context

An existing DMOJ install runs the traditional way (systemd services for
site/uwsgi, celery, bridged, one or more judges, plus nginx, MySQL/MariaDB,
and Redis directly on the host). It needs to move onto the docker-compose
stack in this repo, on the **same server**, replacing the bare-metal
install. The site code is unmodified upstream DMOJ, so the migration only
needs to carry over data and configuration — no application code porting.

Constraints confirmed with the user:

- Same host, in-place migration.
- A maintenance window (downtime) is acceptable — no live-cutover required.
- Existing judges cover multiple languages (C/C++/Java/Python/etc.) plus
  Karel; the user already has a `runtimes-tier3:karel` image built that
  covers all of them, so no new judge image needs to be built for this
  migration.
- Root/sudo access to the bare-metal server is available.
- `dmoj/environment/*.env` and the `dmoj/repo` submodule in this repo are
  already initialized (`scripts/initialize` has run); `dmoj/database/`,
  `dmoj/problems/`, `dmoj/media/` currently contain no real data — this is
  a fresh, un-migrated docker-compose checkout.

## Approach

Logical dump + restore (not a physical MySQL datadir copy): `mysqldump`/
`mariadb-dump` for the database, `rsync`/`tar` for `problems/` and
`media/`. This is portable regardless of whether the bare-metal DB engine
is MySQL or MariaDB or a different version than the `mariadb` image this
compose stack uses (unpinned in `docker-compose.yml`), and it reuses the
pattern this repo's `scripts/backup_db`/`restore_db` already assume. A
physical datadir copy was considered and rejected — it requires an exact
engine/version match and offers no meaningful speed benefit at the scale
implied here.

## Runbook

### 1. Inventory (bare-metal, before touching anything)

Collect, with root access, without stopping any service yet:

- DB engine/version (`mysql --version` / `mariadb --version`), DB name,
  connection user/host.
- Real paths of `problems/` and `media/` (from bare-metal
  `local_settings.py`/`settings.py`: `DMOJ_PROBLEM_DATA_ROOT`,
  `MEDIA_ROOT`).
- Full contents of the bare-metal `local_settings.py`: `SECRET_KEY`,
  `ALLOWED_HOSTS`, email backend config, `BRIDGED_JUDGE_ADDRESS`/port, any
  mathoid/pdfoid/texoid URLs or feature flags that differ from this repo's
  defaults.
- List of active judges: names and languages/tiers (informational only —
  the existing `runtimes-tier3:karel` image already covers all languages
  in use).
- systemd unit names for site/uwsgi, celery, bridged, wsevent, nginx, so
  the right services get stopped in the cutover step.

### 2. Stop bare-metal services, then extract data

Order matters: **stop first, then extract**, to guarantee a consistent
snapshot (no writes land between dump and cutover).

1. Stop the bare-metal site/uwsgi, celery, bridged, and judge services
   (nginx can stay up briefly to serve a maintenance page if desired, but
   must not allow further writes through to Django).
2. `mysqldump`/`mariadb-dump --single-transaction --routines --triggers`
   the DMOJ database to a `.sql` file.
3. `tar`/`rsync` the bare-metal `problems/` directory in full.
4. `tar`/`rsync` the bare-metal `media/` directory in full.
5. Copy the bare-metal `local_settings.py` (or the values noted in step 1)
   somewhere accessible for step 3 below.
6. Transfer all of the above to the docker-compose repo's host (same
   machine, so this can just be a local copy to a scratch directory
   outside the repo tree, or directly under `dmoj/` if disk space allows).

### 3. Prepare the docker-compose stack

`scripts/initialize` has already run in this checkout — do not re-run it.

1. Verify `dmoj/environment/mysql.env` and `site.env` have credentials
   consistent with what will be imported (DB name, user, password).
2. Stop `db` if running, then **empty `dmoj/database/`** so MariaDB
   reinitializes from scratch on next start — avoids carrying over any
   metadata from the current empty/fresh initialization.
3. `docker compose build` (all images, including `judge-tier3-1` and any
   additional judge directories created via `new_judge`) — requires
   `areslolxd/runtimes-tier3:karel` to already exist in the local image
   store.
4. Port the values collected in step 1 into this repo's
   `local_settings.py`. Since `scripts/initialize` already moved the root
   template into `repo/dmoj/local_settings.py`, edit that copy in place
   (not a root-level template, which no longer exists post-initialize).

### 4. Import data

1. `docker compose up -d db` (starts clean per step 3.2).
2. Ensure the `dmoj` database exists with the user/permissions defined in
   `mysql.env` (create it by hand first if the dump doesn't include
   `CREATE DATABASE`).
3. Import the dump: `docker compose exec -T db mariadb -u<user> -p<pass>
   dmoj < dump.sql` (check whether `scripts/restore_db` already
   encapsulates this before using it directly).
4. `rsync -a` the extracted `problems/` and `media/` trees into
   `dmoj/problems/` and `dmoj/media/` (plain bind mounts — no special
   ownership requirements beyond being readable by the `site`/judge
   containers).
5. `docker compose up -d site`.
6. `./scripts/migrate` — required even though data is already imported,
   since the `AresLOLXD/online-judge` fork may have newer migrations than
   the bare-metal install's DMOJ version.
7. Spot-check imported data via `./scripts/manage.py shell` (users,
   problems, submissions present and sane).

### 5. Judges

1. For each bare-metal judge, use `./scripts/new_judge <name>` (or reuse
   `judge-tier3-1` if there was only one) to scaffold the docker-compose
   judge directory.
2. `./scripts/register_judge <judge-dir>` for each — this does
   `Judge.objects.update_or_create(name=...)`, so old bare-metal judge
   rows with different names are simply left orphaned and harmless; no
   name collision handling needed.
3. `docker compose up -d --build <judge-dir>` for each.
4. `./scripts/judge_status` — confirm every judge shows `online: True`.

### 6. Static assets and verification

1. `./scripts/copy_static`.
2. `docker compose up -d` (full stack: `nginx`, `wsevent`, `bridged`,
   `celery`, judges).
3. `./scripts/doctor` as an integrated health check.
4. Functional check: log in as a real migrated user, view a problem that
   references `media/` content, submit a real (or the `demo` fixture)
   problem and confirm a judge grades it.

### 7. Cutover and rollback

1. Point the external TLS-terminating proxy (Cloudflare Tunnel/Caddy) at
   `nginx` on `127.0.0.1:8080`, replacing whatever it pointed at for the
   bare-metal install.
2. Disable (but do not remove) the bare-metal systemd units
   (`systemctl disable --now ...`) and keep the extracted dump/tarballs as
   a rollback path for a few days before decommissioning the old install
   entirely.

## Out of scope

- Porting custom site code/plugins/themes — bare-metal install is
  confirmed to be unmodified upstream DMOJ.
- Building a new judge runtime image — the existing
  `runtimes-tier3:karel` image already covers all languages in use.
- Zero-downtime/live migration — a maintenance window is acceptable.
- Judges running on separate hosts — not applicable here (all judges are
  on the same host being migrated).
