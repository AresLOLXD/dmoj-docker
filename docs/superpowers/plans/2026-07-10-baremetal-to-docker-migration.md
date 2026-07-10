# Bare-Metal to Docker-Compose DMOJ Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move an existing bare-metal DMOJ install (site/uwsgi, celery, bridged, judges, nginx, MySQL/MariaDB, Redis, all running as systemd services) onto this repo's docker-compose stack, on the same host, preserving the database, `problems/`, and `media/` content, with a maintenance-window downtime.

**Architecture:** Logical dump/restore migration. Stop the bare-metal services to freeze state, extract the database via `mysqldump`/`mariadb-dump` and the `problems/`/`media/` trees via `rsync`, then import everything into the already-initialized docker-compose stack (`dmoj/environment/*.env` generated, `dmoj/repo` submodule checked out, `dmoj/database/`+`problems/`+`media/` currently empty). Judges are re-registered against the imported database using this repo's existing `scripts/register_judge`/`scripts/new_judge` tooling — no new judge image is needed since the user's existing `runtimes-tier3:karel` image already covers all languages in use (Karel + C/C++/Java/Python/etc.).

**Tech Stack:** Docker/podman compose, MariaDB (`mariadb` image), Django (DMOJ, `AresLOLXD/online-judge` fork), bash.

## Global Constraints

- Same host, in-place migration (spec §Context).
- Downtime via maintenance window is acceptable — no live-cutover mechanism needed (spec §Context).
- Site code is unmodified upstream DMOJ — no application-code porting (spec §Context).
- Use a logical dump (`mysqldump`/`mariadb-dump`) + `rsync`/`tar`, not a physical MySQL datadir copy (spec §Approach).
- Do not re-run `scripts/initialize` — it has already run in this checkout (spec §3).
- Empty/reinitialize `dmoj/database/` before importing the dump, rather than importing on top of the current fresh-init state (spec §3, confirmed by user).
- Order is stop-bare-metal-first, then extract data — never extract while bare-metal is still accepting writes (spec §2, confirmed by user).
- No new judge runtime image needs to be built; `runtimes-tier3:karel` already covers all required languages (spec §Context).
- All `dmoj/scripts/*` commands are run from the repo root, per this repo's convention (they `cd` into `dmoj/` internally).

---

### Task 1: Inventory the bare-metal install

**Files:**
- Create: `dmoj-migration/inventory.md` (scratch notes, not committed to git — this repo's `.gitignore` root; place it outside the repo tree instead, e.g. `~/dmoj-migration/inventory.md`, to avoid any chance of committing secrets)

**Interfaces:**
- Produces: a written inventory (DB engine/version, DB name, DB connection user, `problems`/`media` real paths, full `local_settings.py` contents, list of judge names, systemd unit names) that Task 2 and Task 3 consume as concrete values (referred to below as `$DB_NAME`, `$DB_USER`, `$BAREMETAL_PROBLEMS_DIR`, `$BAREMETAL_MEDIA_DIR`, `$BAREMETAL_LOCAL_SETTINGS`, `$JUDGE_NAMES`, `$SYSTEMD_UNITS`).

This task is pure discovery on the bare-metal host — it does not stop anything or change any state.

- [ ] **Step 1: Identify the DB engine and version**

Run:
```bash
mysql --version 2>/dev/null || mariadb --version
```
Record the output (engine + version) in the inventory notes. This confirms the dump tool to use in Task 2 (`mysqldump` if MySQL, `mariadb-dump` if MariaDB — both are interchangeable for a `--single-transaction` logical dump, but record which is present).

- [ ] **Step 2: Find the DB name and connection user**

Locate the bare-metal Django settings file (commonly `local_settings.py` next to `settings.py` in the DMOJ install directory) and read its `DATABASES` block:
```bash
grep -A8 "^DATABASES" /path/to/baremetal/dmoj/dmoj/local_settings.py
```
Record `NAME`, `USER`, `HOST` as `$DB_NAME`, `$DB_USER`, `$DB_HOST` in the inventory notes. (`PASSWORD` is needed live in Task 2, not recorded to disk in plaintext if avoidable — read it directly from the file when running the dump command.)

- [ ] **Step 3: Find the real `problems/` and `media/` paths**

```bash
grep -E "DMOJ_PROBLEM_DATA_ROOT|MEDIA_ROOT" /path/to/baremetal/dmoj/dmoj/local_settings.py
```
Record the two paths as `$BAREMETAL_PROBLEMS_DIR` and `$BAREMETAL_MEDIA_DIR`.

- [ ] **Step 4: Capture the full bare-metal `local_settings.py`**

```bash
cp /path/to/baremetal/dmoj/dmoj/local_settings.py ~/dmoj-migration/baremetal_local_settings.py
```
This file is `$BAREMETAL_LOCAL_SETTINGS` for Task 3. Note in the inventory any values that differ from this repo's `dmoj/repo/dmoj/local_settings.py` defaults — in particular `SECRET_KEY`, `ALLOWED_HOSTS`/`HOST`, email backend settings, and any mathoid/pdfoid/texoid URL overrides.

- [ ] **Step 5: List active judges**

Find the judge config files (commonly `/etc/dmoj/judge.yml` or similar per judge instance, or wherever the bare-metal judge processes were configured) and record each judge's `id`. These are informational only (languages are already covered by `runtimes-tier3:karel`) but Task 5 needs the count/names to decide how many `judge-tier3-N` directories to scaffold.

- [ ] **Step 6: List the systemd units to stop**

```bash
systemctl list-units --type=service | grep -iE "dmoj|uwsgi|celery|bridged|nginx"
```
Record the exact unit names as `$SYSTEMD_UNITS` — Task 2 Step 1 stops exactly these.

- [ ] **Step 7: Save the inventory**

Write all recorded values into `~/dmoj-migration/inventory.md` in plain key: value form. No commit — this is scratch data outside the repo, kept only for reference during the remaining tasks.

---

### Task 2: Stop bare-metal services and extract data

**Files:**
- Create: `~/dmoj-migration/dump.sql`, `~/dmoj-migration/problems.tar.gz`, `~/dmoj-migration/media.tar.gz`

**Interfaces:**
- Consumes: `$DB_NAME`, `$DB_USER`, `$BAREMETAL_PROBLEMS_DIR`, `$BAREMETAL_MEDIA_DIR`, `$SYSTEMD_UNITS` from Task 1.
- Produces: `~/dmoj-migration/dump.sql`, `~/dmoj-migration/problems.tar.gz`, `~/dmoj-migration/media.tar.gz` — consumed by Task 4.

- [ ] **Step 1: Stop bare-metal services**

```bash
sudo systemctl stop $SYSTEMD_UNITS
```
Stop site/uwsgi, celery, bridged, and every judge unit first. Leave nginx running only if serving a static maintenance page with no proxy to Django; otherwise stop it too. This is the read-only-mode switch — no more writes can land in the DB or `media/` after this step.

- [ ] **Step 2: Verify nothing is still writing**

```bash
sudo systemctl is-active $SYSTEMD_UNITS
```
Expected: every unit reports `inactive` or `failed` (not `active`). If anything still shows `active`, stop it before proceeding — an in-flight write during the dump would be lost silently.

- [ ] **Step 3: Dump the database**

```bash
mysqldump --single-transaction --routines --triggers \
  -u"$DB_USER" -p -h "$DB_HOST" "$DB_NAME" > ~/dmoj-migration/dump.sql
```
(Use `mariadb-dump` instead of `mysqldump` if Task 1 Step 1 found MariaDB and `mysqldump` isn't available as a compatibility shim.)

Verify the dump is non-empty and contains real table data:
```bash
grep -c "^INSERT INTO" ~/dmoj-migration/dump.sql
```
Expected: a number greater than 0.

- [ ] **Step 4: Archive `problems/` and `media/`**

```bash
tar -czf ~/dmoj-migration/problems.tar.gz -C "$(dirname "$BAREMETAL_PROBLEMS_DIR")" "$(basename "$BAREMETAL_PROBLEMS_DIR")"
tar -czf ~/dmoj-migration/media.tar.gz -C "$(dirname "$BAREMETAL_MEDIA_DIR")" "$(basename "$BAREMETAL_MEDIA_DIR")"
```
Verify each archive is non-empty:
```bash
tar -tzf ~/dmoj-migration/problems.tar.gz | head
tar -tzf ~/dmoj-migration/media.tar.gz | head
```
Expected: both list real file/directory entries.

- [ ] **Step 5: Confirm all three artifacts exist**

```bash
ls -lh ~/dmoj-migration/dump.sql ~/dmoj-migration/problems.tar.gz ~/dmoj-migration/media.tar.gz
```
Expected: all three files present with non-zero size. This is the end of Task 2 — do not restart any bare-metal service yet (rollback in Task 7 still needs the bare-metal install intact and stoppable/restartable).

---

### Task 3: Prepare the docker-compose stack

**Files:**
- Modify: `dmoj/environment/mysql.env`, `dmoj/environment/site.env` (verify only, edit if inconsistent)
- Modify: `dmoj/repo/dmoj/local_settings.py` (submodule-tracked file, not part of this outer repo's git history — do not `git add`/`git commit` it here)
- Delete and recreate: `dmoj/database/*` (this repo's bind-mounted MariaDB datadir)

**Interfaces:**
- Consumes: `$BAREMETAL_LOCAL_SETTINGS` from Task 1.
- Produces: a built, un-started docker-compose stack ready for Task 4's data import.

- [ ] **Step 1: Verify env file credentials**

```bash
cat dmoj/environment/mysql.env
```
Confirm `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` are set to values you're comfortable importing the dump under (they don't need to match the bare-metal DB name/user — the dump's `CREATE TABLE`/`INSERT` statements target whatever database the import command points at in Task 4, not a name baked into the dump itself, since `mysqldump` without `-B`/`--databases` omits `CREATE DATABASE`). If `mysql.env` doesn't exist yet, stop — `scripts/initialize` should already have created it from `mysql.env.example`; investigate before proceeding rather than re-running `initialize`.

- [ ] **Step 2: Stop and empty the `db` service's datadir**

```bash
docker compose -f dmoj/docker-compose.yml stop db
sudo rm -rf dmoj/database/*
```
Verify:
```bash
ls -A dmoj/database/
```
Expected: empty output.

- [ ] **Step 3: Build all images**

```bash
cd dmoj && docker compose build
```
This includes `judge-tier3-1`, which builds `FROM localhost/areslolxd/runtimes-tier3:karel` — confirm that image is present first:
```bash
docker images | grep runtimes-tier3
```
Expected: at least one `areslolxd/runtimes-tier3` entry. If missing, stop — this is a precondition documented in this repo's README ("Setting up a judge") and out of scope for this migration.

- [ ] **Step 4: Port bare-metal `local_settings.py` values into the docker-compose fork's copy**

Open `dmoj/repo/dmoj/local_settings.py` (this is the file actually mounted into the `site`/`celery`/`bridged` containers, per this repo's `CLAUDE.md` architecture notes) and, diffing against `$BAREMETAL_LOCAL_SETTINGS`, port over any non-default values found in Task 1 Step 4 that aren't already environment-variable-driven in this repo's version — in particular:
- Any `INSTALLED_APPS` additions.
- Email backend settings (`EMAIL_BACKEND` and related).
- Any `MATHOID_URL`/`DMOJ_PDF_PDFOID_URL`/`TEXOID_URL` override that differs from this repo's defaults (`mathoid:10044`, `pdfoid:8888`, `texoid:8888` — only port overrides if the bare-metal install customized these ports/paths, otherwise leave this repo's defaults in place since they match the docker network hostnames).

Do **not** port `SECRET_KEY`, `ALLOWED_HOSTS`/`HOST`, or `BRIDGED_JUDGE_ADDRESS`/`BRIDGED_DJANGO_ADDRESS` — those are environment-variable-driven in this repo (`SECRET_KEY`/`HOST` via `site.env`) or intentionally different (bridged address is `bridged:9999`/`bridged:9998` in the docker network, not the bare-metal host's address). Changing `SECRET_KEY` would invalidate all existing user sessions, which is expected and fine for a full cutover — but it must be set via `dmoj/environment/site.env`'s `SECRET_KEY` variable, not hardcoded into `local_settings.py`.

Verify:
```bash
diff dmoj/repo/dmoj/local_settings.py ~/dmoj-migration/baremetal_local_settings.py
```
Review the diff manually — every remaining difference should be an intentional docker-vs-bare-metal difference (bridged addresses, env-var-driven fields), not a missed customization.

- [ ] **Step 5: Confirm `site.env` has a real `SECRET_KEY` and correct `HOST`**

```bash
grep -E "^SECRET_KEY|^HOST" dmoj/environment/site.env
```
Expected: `SECRET_KEY` is a long random string (not empty, not a placeholder), `HOST` is the site's real domain. If either is wrong, edit `dmoj/environment/site.env` directly (this file is real-secrets, gitignored — do not commit it).

---

### Task 4: Import data

**Files:**
- None created in this repo (data lands in the `dmoj/database/`, `dmoj/problems/`, `dmoj/media/` bind mounts, which are gitignored runtime state, not tracked files)

**Interfaces:**
- Consumes: `~/dmoj-migration/dump.sql`, `~/dmoj-migration/problems.tar.gz`, `~/dmoj-migration/media.tar.gz` from Task 2; `dmoj/environment/mysql.env` credentials from Task 3.
- Produces: a running `db` + `site` with imported data, migrated schema — consumed by Task 5 (judge registration) and Task 6 (verification).

- [ ] **Step 1: Start `db` clean**

```bash
cd dmoj && docker compose up -d db
```
Wait for it to be ready:
```bash
docker compose logs db --tail 20
```
Expected: log lines indicating MariaDB finished initialization and is `ready for connections`.

- [ ] **Step 2: Import the dump**

```bash
source dmoj/environment/mysql.env
docker compose -f dmoj/docker-compose.yml exec -T db \
  mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" < ~/dmoj-migration/dump.sql
```
Verify tables landed:
```bash
docker compose -f dmoj/docker-compose.yml exec db \
  mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SHOW TABLES;" | wc -l
```
Expected: a number in the dozens (DMOJ's schema has well over 50 tables) — not 0 or 1.

- [ ] **Step 3: Restore `problems/` and `media/`**

```bash
tar -xzf ~/dmoj-migration/problems.tar.gz -C /tmp/
tar -xzf ~/dmoj-migration/media.tar.gz -C /tmp/
rsync -a /tmp/problems/ dmoj/problems/
rsync -a /tmp/media/ dmoj/media/
```
(Adjust the `/tmp/problems`/`/tmp/media` extracted subdirectory names to match whatever `$(basename ...)` produced in Task 2 Step 4.)

Verify:
```bash
ls dmoj/problems/ | wc -l
ls dmoj/media/ | wc -l
```
Expected: both non-zero, matching the counts seen in the bare-metal directories during Task 1/2.

- [ ] **Step 4: Start `site` and run migrations**

```bash
docker compose up -d site
./scripts/migrate
```
Run from the repo root (`scripts/migrate` `cd`s into `dmoj/` itself). Expected: `Operations to perform` / `Applying ...` lines ending without a traceback. If the fork has new migrations beyond what the bare-metal DB had applied, they run now.

- [ ] **Step 5: Spot-check imported data**

```bash
./scripts/manage.py shell -c "
from judge.models import Profile, Problem, Submission
print('users:', Profile.objects.count())
print('problems:', Problem.objects.count())
print('submissions:', Submission.objects.count())
"
```
Expected: three counts, all greater than 0 and roughly matching what you'd expect from the bare-metal install (cross-check against the bare-metal admin panel numbers noted in Task 1 if available).

---

### Task 5: Register judges

**Files:**
- Create: `dmoj/judge-tier3-N/` directories for each judge beyond the first (via `scripts/new_judge`)
- Modify: `dmoj/judge-tier3-1/judge.yml` and each new judge's `judge.yml` (auth key written in place)
- Modify: `dmoj/docker-compose.yml` (new judge service blocks, if more than one judge)

**Interfaces:**
- Consumes: `$JUDGE_NAMES` count from Task 1; the running `site` container from Task 4.
- Produces: registered, online judges — consumed by Task 6's functional verification.

- [ ] **Step 1: Scaffold additional judge directories**

If Task 1 found more than one bare-metal judge, for each one beyond the first:
```bash
./scripts/new_judge judge-tier3-2
```
Run once per extra judge (`judge-tier3-3`, etc.), incrementing the name. This prints the `docker-compose.yml` block to add — paste it into `dmoj/docker-compose.yml` under `services:`, following the pattern of the existing `judge-tier3-1` block (it extends `x-judge-tier3-base` and builds from the same `runtimes-tier3:karel`-based Dockerfile pattern copied into the new directory).

Verify:
```bash
ls dmoj/judge-tier3-2/
```
Expected: `Dockerfile` and `judge.yml` present, copied from `judge-tier3-1`.

- [ ] **Step 2: Register every judge**

```bash
./scripts/register_judge judge-tier3-1
./scripts/register_judge judge-tier3-2   # repeat per judge directory
```
Expected output per judge: `Registered judge: judge-tier3-N` followed by `Updated .../judge.yml with the new id/key.`

- [ ] **Step 3: Build and start every judge**

```bash
docker compose up -d --build judge-tier3-1
docker compose up -d --build judge-tier3-2   # repeat per judge directory
```

- [ ] **Step 4: Confirm all judges are online**

```bash
./scripts/judge_status
```
Expected: every registered judge listed with `online: True`. If any show `False`, check its container logs (`docker compose logs judge-tier3-N`) before proceeding — do not move to Task 6 with an offline judge.

---

### Task 6: Static assets, full stack, and functional verification

**Files:**
- None created — this task runs existing scripts and verifies runtime behavior.

**Interfaces:**
- Consumes: the fully imported, judge-registered stack from Tasks 4 and 5.
- Produces: a verified, ready-to-cut-over stack — consumed by Task 7.

- [ ] **Step 1: Rebuild static assets**

```bash
./scripts/copy_static
```
Expected: completes without error (runs `make_style.sh`, `collectstatic`, `compilemessages`, `compilejsi18n`, then copies into the `assets` volume).

- [ ] **Step 2: Start the full stack**

```bash
cd dmoj && docker compose up -d
```
Expected: `nginx`, `wsevent`, `bridged`, `celery`, `redis`, all judges, `db`, and `site` all report `Up` (or `running`):
```bash
docker compose ps
```

- [ ] **Step 3: Run the integrated health check**

```bash
cd dmoj && ./scripts/doctor
```
Expected: exits 0 with all checks passing. If anything fails, resolve it before Task 7 — `doctor` is designed to catch exactly the kind of misconfiguration a migration like this can introduce (bad env values, unreachable services, stale DNS cache in nginx).

- [ ] **Step 4: Functional check — login and browse**

Using a real (migrated) user account, log into the site through nginx (`http://127.0.0.1:8080/` or through the external proxy if already pointed here in a test capacity) and open a problem page that references `media/` content (e.g. an uploaded image in a problem statement). Confirm the page renders correctly and the image loads.

- [ ] **Step 5: Functional check — submission grading**

Submit a real problem (or the `demo` fixture's sample problem if no real one is convenient) as that user and confirm a judge picks it up and returns a verdict:
```bash
./scripts/judge_status
```
Watch the submission's status in the UI or via:
```bash
./scripts/manage.py shell -c "
from judge.models import Submission
s = Submission.objects.latest('id')
print(s.id, s.status, s.result)
"
```
Expected: `status` progresses to `D` (done) with a `result` set (e.g. `AC`), not stuck on `QU`/`G` (queued/grading) indefinitely.

---

### Task 7: Cutover and rollback safety

**Files:**
- Modify: whatever config file the external TLS-terminating proxy (Cloudflare Tunnel/Caddy) uses to route to the old bare-metal nginx — not part of this repo, edited on the proxy's own host/config.

**Interfaces:**
- Consumes: the verified stack from Task 6.
- Produces: live cutover, with the bare-metal install preserved (disabled, not deleted) as rollback.

- [ ] **Step 1: Point the external proxy at the docker-compose nginx**

Edit the external TLS-terminating proxy's config (Cloudflare Tunnel config or Caddyfile, outside this repo) to forward to `127.0.0.1:8080` (this repo's `nginx` service) instead of whatever the bare-metal nginx listened on, setting `X-Forwarded-Proto: https` as this repo's `CLAUDE.md` architecture notes require. Reload the proxy.

- [ ] **Step 2: Verify live traffic**

From outside the host (a browser, or `curl` from another machine), hit the site's real domain and confirm the response comes from the docker-compose stack:
```bash
curl -I https://<real-domain>/
```
Expected: `200 OK` (or expected redirect), and the response headers/behavior match what Task 6 verified locally.

- [ ] **Step 3: Disable (not remove) bare-metal services**

```bash
sudo systemctl disable $SYSTEMD_UNITS
```
Leave them stopped (already done in Task 2) and now disabled from starting on boot, but installed — this is the rollback path.

- [ ] **Step 4: Confirm rollback artifacts are retained**

```bash
ls -lh ~/dmoj-migration/
```
Expected: `dump.sql`, `problems.tar.gz`, `media.tar.gz`, `inventory.md`, `baremetal_local_settings.py` all still present. Keep these, along with the still-installed (disabled) bare-metal services, for a few days before any further cleanup/decommissioning — decommissioning itself is out of scope for this plan.

---

## Self-Review Notes

- **Spec coverage:** Task 1 ↔ spec §1 (inventory); Task 2 ↔ spec §2 (stop-then-extract, order confirmed); Task 3 ↔ spec §3 (prepare stack, empty `dmoj/database/` confirmed); Task 4 ↔ spec §4 (import); Task 5 ↔ spec §5 (judges); Task 6 ↔ spec §6 (static assets + verification); Task 7 ↔ spec §7 (cutover + rollback). Spec's "Out of scope" items (code porting, new judge image, zero-downtime, remote judges) are correspondingly absent from the plan.
- **Placeholder scan:** all shell variables (`$DB_NAME`, `$SYSTEMD_UNITS`, etc.) are populated by Task 1's discovery steps before any later task consumes them — none are unresolved TBDs.
- **Type/name consistency:** judge directory naming (`judge-tier3-1`, `judge-tier3-2`, ...) matches this repo's existing `judge-tier3-1` and the `new_judge`/`register_judge` script conventions throughout Tasks 3, 5, 6.
