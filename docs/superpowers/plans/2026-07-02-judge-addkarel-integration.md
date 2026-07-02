# Judge (AddKarel fork) integration + management scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Docker judge service built from the `AresLOLXD/judge-server` `AddKarel` fork, plus eight operational scripts (`register_judge`, `judge_status`, `new_judge`, `doctor`, `update`, `backup_db`, `restore_db`, `logs`) that make the judge and the rest of the stack easier to manage.

**Architecture:** One new judge Docker service (`judge-tier3-1`) is added to `dmoj/docker-compose.yml`, networked only to `bridged` via the internal `site` network. Eight new bash scripts follow the existing `dmoj/scripts/*` convention (`cd` to `dmoj/`, shell out to `docker compose`/`docker compose exec`). No new host dependencies are introduced.

**Tech Stack:** Docker Compose (v3.7 file format, YAML anchors), bash, `openssl` (key generation), `sed` (targeted YAML edits), Django `manage.py shell` (judge registration/status queries), `mysqldump`/`mysql` (backup/restore).

## Global Constraints

- Scripts live in `dmoj/scripts/`, are executable (`chmod +x`), start with `cd $(dirname $(dirname $0)) || exit`, and use `$COMPOSE_EXEC_FLAGS` when calling `docker compose exec` — copy this pattern exactly from `dmoj/scripts/migrate`.
- The committed scripts and `docker-compose.yml` use the `docker compose` CLI (this is the project's documented, portable convention — do not rewrite it to `podman`).
- **For your own ad-hoc verification commands during implementation on this host**, use `podman compose` / `podman` instead of `docker` — the `docker` binary exists on PATH but is not the working engine here. Run `podman compose` from inside the `dmoj/` directory (it needs the compose file in CWD).
- `judge.yml` and `dmoj/environment/*.env` use the placeholder convention `<description of value>` (e.g. `<secret key>`) for any field that must be filled in per-deployment — never invent a fake real-looking value.
- Image name for the judge: `areslolxd/dmoj-judge-tier3`.
- The judge container gets exactly one added capability: `SYS_PTRACE`. Never add `privileged: true`.
- The judge service is only ever on the `site` network — never `db` or `nginx`.
- No TLS/secure (`-s`) flag between judge and bridged — matches the existing unencrypted internal setup.

---

## Task 1: Judge Docker service (`judge-tier3-1`)

**Files:**
- Create: `dmoj/judge-tier3-1/Dockerfile`
- Create: `dmoj/judge-tier3-1/judge.yml`
- Modify: `dmoj/docker-compose.yml`

**Interfaces:**
- Produces: a buildable `judge-tier3-1` compose service, and the `x-judge-tier3-base` YAML anchor that Task 4 (`new_judge`) references in its printed scaffold instructions.

- [ ] **Step 1: Create the judge Dockerfile**

Create `dmoj/judge-tier3-1/Dockerfile`:

```dockerfile
FROM dmoj/runtimes-tier3

ARG TAG=AddKarel
RUN mkdir /judge /problems && cd /judge && \
	curl -L https://github.com/AresLOLXD/judge-server/archive/"${TAG}".tar.gz | tar -xz --strip-components=1 && \
    python3 -m venv --prompt=DMOJ /env && \
	/env/bin/pip3 install cython setuptools && \
	/env/bin/pip3 install -e . && \
	/env/bin/python3 setup.py develop && \
	HOME=~judge . ~judge/.profile && \
	runuser -u judge -w PATH -- /env/bin/dmoj-autoconf -V > /judge-runtime-paths.yml && \
	echo '  crt_x86_in_lib32: true' >> /judge-runtime-paths.yml

ENTRYPOINT ["/usr/bin/tini", "--", "/judge/.docker/entry"]
```

This is copied verbatim from `AresLOLXD/judge-server`'s `.docker/tier3/Dockerfile` (`AddKarel` branch) — it already defaults `TAG` to `AddKarel`, so the fork's Karel executor is what gets built.

- [ ] **Step 2: Create the judge config file**

Create `dmoj/judge-tier3-1/judge.yml`:

```yaml
# This must match the "name" of the Judge object created in /admin/judge/.
# scripts/register_judge sets this automatically to match the directory name.
id: <judge name>
# Generated via the "Regenerate" button in /admin/judge/, or by scripts/register_judge.
key: <judge authentication key>
# Any directory matching this glob with an init.yml file is treated as a problem.
problem_storage_globs:
  - /problems/*
```

- [ ] **Step 3: Add the judge service to docker-compose.yml**

Read `dmoj/docker-compose.yml` first. Add a top-level `x-judge-tier3-base` anchor (place it directly above the `services:` key), then add the `judge-tier3-1` service inside `services:` (after `bridged`, before `wsevent`, to keep judge-related services grouped near `bridged`):

```yaml
x-judge-tier3-base: &judge-tier3-base
  init: true
  restart: unless-stopped
  cap_add:
    - SYS_PTRACE
  networks: [site]
  depends_on: [bridged]
  command: run -c /judge-config/judge.yml bridged
```

```yaml
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

- [ ] **Step 4: Validate the compose file parses correctly**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && podman compose config`
Expected: no errors, and the output includes a `judge-tier3-1` service block with `cap_add: [SYS_PTRACE]`, `networks: {site: null}`, `image: areslolxd/dmoj-judge-tier3`, and the two volume mounts. Confirm the anchor was merged correctly (i.e. `restart: unless-stopped`, `depends_on: [bridged]`, and `command` all appear under `judge-tier3-1`, not just under the anchor definition).

- [ ] **Step 5: Build the judge image**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && podman compose build judge-tier3-1`
Expected: build succeeds (this pulls the large `dmoj/runtimes-tier3` base image and compiles the judge from source — expect this to take several minutes and require significant disk space; if the sandboxed environment cannot complete it due to time/resource limits, note that explicitly and defer this step to the target deployment host rather than silently skipping it).

- [ ] **Step 6: Verify the Karel executor is present in the built image**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && podman compose run --rm judge-tier3-1 test 2>&1 | grep -i karel`
Expected: output mentions the `KAREL` executor (either passing self-test or at least being loaded/listed) — confirms the image was built from the `AddKarel` branch and not upstream `DMOJ/judge-server`.

- [ ] **Step 7: Commit**

```bash
git add dmoj/judge-tier3-1/Dockerfile dmoj/judge-tier3-1/judge.yml dmoj/docker-compose.yml
git commit -m "$(cat <<'EOF'
Add judge-tier3-1 Docker service built from AddKarel fork

Adds a judge container (AresLOLXD/judge-server, AddKarel branch) so
Karel submissions can be graded. Only SYS_PTRACE is granted and the
service is isolated to the internal site network.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `scripts/register_judge`

**Files:**
- Create: `dmoj/scripts/register_judge`

**Interfaces:**
- Consumes: a running `site` container (from Task 1's `docker-compose.yml`, `site` service already exists in the repo).
- Produces: an executable script `scripts/register_judge <judge-dir>` that Task 5 (`doctor`) and the README checklist both reference by name.

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/register_judge`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

JUDGE_DIR="$1"
if [ -z "$JUDGE_DIR" ]; then
    echo "Usage: $0 <judge-dir>" 1>&2
    echo "Example: $0 judge-tier3-1" 1>&2
    exit 1
fi

JUDGE_YML="$JUDGE_DIR/judge.yml"
if [ ! -f "$JUDGE_YML" ]; then
    echo "Error: $JUDGE_YML does not exist" 1>&2
    exit 1
fi

KEY=$(openssl rand -base64 75 | tr -d '\n')

docker compose exec $COMPOSE_EXEC_FLAGS site python3 manage.py shell -c "
from judge.models import Judge
judge, _ = Judge.objects.update_or_create(name='$JUDGE_DIR', defaults={'auth_key': '$KEY'})
print(f'Registered judge: {judge.name}')
"

if [ $? -ne 0 ]; then
    echo "Error: failed to register judge in the database" 1>&2
    exit 1
fi

sed -i "s|^id: .*|id: $JUDGE_DIR|" "$JUDGE_YML"
sed -i "s|^key: .*|key: $KEY|" "$JUDGE_YML"

echo "Updated $JUDGE_YML with the new id/key."
echo "Next: docker compose up -d --build $JUDGE_DIR"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/register_judge`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/register_judge`
Expected: no errors (warnings about unquoted `$COMPOSE_EXEC_FLAGS` are pre-existing style in this repo's other scripts and can be ignored — check `shellcheck dmoj/scripts/migrate` first to confirm that warning is already tolerated there).

- [ ] **Step 4: Verify usage-error path**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && ./scripts/register_judge`
Expected: prints `Usage: ./scripts/register_judge <judge-dir>` to stderr and exits non-zero (`echo $?` shows `1`).

- [ ] **Step 5: Verify missing-directory error path**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && ./scripts/register_judge nonexistent-judge`
Expected: prints `Error: nonexistent-judge/judge.yml does not exist` to stderr, exits non-zero.

- [ ] **Step 6: Verify the sed placeholder replacement in isolation**

This checks the `sed` logic works against the real file format from Task 1, without needing a live site container:

Run:
```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
cp judge-tier3-1/judge.yml /tmp/judge-test.yml
sed -i "s|^id: .*|id: judge-tier3-1|" /tmp/judge-test.yml
sed -i "s|^key: .*|key: dGVzdGtleQ==|" /tmp/judge-test.yml
grep -E "^(id|key):" /tmp/judge-test.yml
rm /tmp/judge-test.yml
```
Expected output:
```
id: judge-tier3-1
key: dGVzdGtleQ==
```

- [ ] **Step 7: Note the full-registration path for later end-to-end verification**

Full registration (steps requiring a live `site` container connected to a migrated database) is exercised in Task 9's end-to-end verification checklist, not here — this task's automated steps only cover argument handling and the `sed` logic in isolation, since standing up the full site stack is out of scope for an individual script task.

- [ ] **Step 8: Commit**

```bash
git add dmoj/scripts/register_judge
git commit -m "$(cat <<'EOF'
Add scripts/register_judge to automate judge DB registration

Generates a key, creates/updates the Judge row via manage.py shell,
and writes id/key into the judge's judge.yml — replaces the manual
admin-panel + copy-paste flow.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `scripts/judge_status`

**Files:**
- Create: `dmoj/scripts/judge_status`

**Interfaces:**
- Consumes: a running `site` container.
- Produces: an executable `scripts/judge_status` that Task 5 (`doctor`) check #6 shells out to (reuses this script directly rather than re-implementing the query).

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/judge_status`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

docker compose exec $COMPOSE_EXEC_FLAGS site python3 manage.py shell -c "
from judge.models import Judge
judges = Judge.objects.all().order_by('name')
if not judges:
    print('No judges registered.')
else:
    print(f'{\"NAME\":<20} {\"TIER\":<6} {\"ONLINE\":<8} {\"LAST IP\"}')
    for j in judges:
        print(f'{j.name:<20} {j.tier:<6} {str(j.online):<8} {j.last_ip or \"-\"}')"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/judge_status`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/judge_status`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add dmoj/scripts/judge_status
git commit -m "$(cat <<'EOF'
Add scripts/judge_status to list judge online/offline state

Replaces manually checking /admin/judge/ with a one-line table of
name, tier, online status, and last IP for every registered judge.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/new_judge`

**Files:**
- Create: `dmoj/scripts/new_judge`

**Interfaces:**
- Consumes: `x-judge-tier3-base` anchor name (from Task 1) — printed literally in this script's output, so it must match exactly (`judge-tier3-base`).
- Produces: an executable `scripts/new_judge <name> [template]` that scaffolds `dmoj/<name>/{Dockerfile,judge.yml}` from an existing judge directory.

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/new_judge`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

NAME="$1"
TEMPLATE="${2:-judge-tier3-1}"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <name> [template]" 1>&2
    echo "Example: $0 judge-tier3-2" 1>&2
    exit 1
fi

if [ ! -d "$TEMPLATE" ]; then
    echo "Error: template directory $TEMPLATE does not exist" 1>&2
    exit 1
fi

if [ -e "$NAME" ]; then
    echo "Error: $NAME already exists" 1>&2
    exit 1
fi

cp -r "$TEMPLATE" "$NAME"
sed -i "s|^id: .*|id: <judge name>|" "$NAME/judge.yml"
sed -i "s|^key: .*|key: <judge authentication key>|" "$NAME/judge.yml"

echo "Created $NAME/ from $TEMPLATE/."
echo ""
echo "Add this to docker-compose.yml under services:"
echo ""
cat <<COMPOSE
  $NAME:
    <<: *judge-tier3-base
    build:
      context: .
      dockerfile: ./$NAME/Dockerfile
    image: areslolxd/dmoj-judge-tier3
    volumes:
      - ./problems/:/problems/:ro
      - ./$NAME/judge.yml:/judge-config/judge.yml:ro
COMPOSE
echo ""
echo "Then run: ./scripts/register_judge $NAME"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/new_judge`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/new_judge`
Expected: no errors.

- [ ] **Step 4: Verify usage-error path**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && ./scripts/new_judge`
Expected: prints usage to stderr, exits non-zero.

- [ ] **Step 5: Verify the scaffold works end-to-end (dry run against real Task 1 files)**

```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
./scripts/new_judge judge-tier3-2
ls judge-tier3-2/
grep -E "^(id|key):" judge-tier3-2/judge.yml
diff judge-tier3-1/Dockerfile judge-tier3-2/Dockerfile
rm -rf judge-tier3-2
```
Expected:
- `ls` shows `Dockerfile` and `judge.yml`.
- `grep` shows `id: <judge name>` and `key: <judge authentication key>` (placeholders, not copied from `judge-tier3-1`'s real values).
- `diff` shows no differences (Dockerfile copied verbatim).
- The printed compose block includes `dockerfile: ./judge-tier3-2/Dockerfile` and `./judge-tier3-2/judge.yml:/judge-config/judge.yml:ro`.

- [ ] **Step 6: Verify the already-exists guard**

```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
./scripts/new_judge judge-tier3-1
```
Expected: prints `Error: judge-tier3-1 already exists` to stderr, exits non-zero, and does **not** overwrite the real `judge-tier3-1/judge.yml`. Confirm with `git status` that no changes were made to `judge-tier3-1/`.

- [ ] **Step 7: Commit**

```bash
git add dmoj/scripts/new_judge
git commit -m "$(cat <<'EOF'
Add scripts/new_judge to scaffold additional judge instances

Copies an existing judge directory, resets id/key to placeholders,
and prints the docker-compose.yml block to paste in — avoids
hand-copying boilerplate when adding judge-tier3-2, etc.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `scripts/doctor`

**Files:**
- Create: `dmoj/scripts/doctor`

**Interfaces:**
- Consumes: `scripts/judge_status` (Task 3) — check #6 calls it directly rather than re-implementing the judge query.
- Produces: an executable `scripts/doctor` with exit code 0 (all checks passed) or 1 (at least one check failed).

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/doctor`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

FAILED=0

check() {
    local desc="$1"
    shift
    if "$@" >/tmp/doctor-check.log 2>&1; then
        echo "✓ $desc"
    else
        echo "✗ $desc"
        sed 's/^/    /' /tmp/doctor-check.log
        FAILED=1
    fi
    rm -f /tmp/doctor-check.log
}

echo "== Containers =="
EXPECTED_SERVICES=$(docker compose config --services)
for svc in $EXPECTED_SERVICES; do
    STATE=$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null)
    if [ "$STATE" = "running" ]; then
        echo "✓ $svc is running"
    else
        echo "✗ $svc is '$STATE' (expected running)"
        FAILED=1
    fi
done

echo ""
echo "== Django =="
check "Django system check" docker compose exec -T $COMPOSE_EXEC_FLAGS site python3 manage.py check --deploy
check "Database reachable" docker compose exec -T $COMPOSE_EXEC_FLAGS site python3 manage.py showmigrations

echo ""
echo "== Redis =="
check "Redis reachable" docker compose exec -T $COMPOSE_EXEC_FLAGS redis redis-cli ping

echo ""
echo "== Bridged =="
check "Bridged judge port (9999) open" docker compose exec -T $COMPOSE_EXEC_FLAGS bridged sh -c "echo > /dev/tcp/localhost/9999"
check "Bridged Django port (9998) open" docker compose exec -T $COMPOSE_EXEC_FLAGS bridged sh -c "echo > /dev/tcp/localhost/9998"

echo ""
echo "== Judges =="
./scripts/judge_status
if ! docker compose exec -T $COMPOSE_EXEC_FLAGS site python3 manage.py shell -c "
from judge.models import Judge
import sys
sys.exit(0 if Judge.objects.filter(online=True).exists() else 1)
"; then
    echo "✗ No judges are online"
    FAILED=1
else
    echo "✓ At least one judge is online"
fi

echo ""
echo "== Static assets =="
check "Assets volume is non-empty" docker compose exec -T $COMPOSE_EXEC_FLAGS site sh -c "[ -n \"\$(ls -A /assets/)\" ]"

echo ""
echo "== nginx =="
check "nginx responds on :80" curl -sf http://localhost/ -o /dev/null

echo ""
echo "== wsevent =="
check "wsevent get port (15100)" docker compose exec -T $COMPOSE_EXEC_FLAGS site sh -c "echo > /dev/tcp/wsevent/15100"
check "wsevent post port (15101)" docker compose exec -T $COMPOSE_EXEC_FLAGS site sh -c "echo > /dev/tcp/wsevent/15101"
check "wsevent http port (15102)" docker compose exec -T $COMPOSE_EXEC_FLAGS site sh -c "echo > /dev/tcp/wsevent/15102"

echo ""
echo "== Rendering services =="
check "mathoid responds" docker compose exec -T $COMPOSE_EXEC_FLAGS site curl -sf http://mathoid:10044/ -o /dev/null
check "pdfoid responds" docker compose exec -T $COMPOSE_EXEC_FLAGS site curl -sf http://pdfoid:8888/ -o /dev/null
check "texoid responds" docker compose exec -T $COMPOSE_EXEC_FLAGS site curl -sf http://texoid:8888/ -o /dev/null

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All checks passed."
else
    echo "Some checks failed — see ✗ lines above."
fi
exit $FAILED
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/doctor`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/doctor`
Expected: fix any real errors reported (e.g. unquoted variables that could break on empty/whitespace values); warnings consistent with the rest of the repo's script style can be left as-is.

- [ ] **Step 4: Note on full verification**

Full end-to-end verification (all 10 checks passing against a live stack) happens in Task 9's end-to-end checklist, once `site`, `db`, `redis`, `bridged`, `judge-tier3-1`, and the rendering services are all actually running together. This task's own verification is limited to shellcheck and confirming the script errors out cleanly with a helpful message if `docker compose` itself isn't available (i.e. no stack running at all):

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && ./scripts/doctor; echo "exit: $?"`
Expected: with no containers running, most checks print `✗`, the script does not crash (no unbound variable errors, no stack traces), and it exits with `exit: 1`.

- [ ] **Step 5: Commit**

```bash
git add dmoj/scripts/doctor
git commit -m "$(cat <<'EOF'
Add scripts/doctor for a full-stack read-only health check

Ten checks covering containers, Django, DB, Redis, bridged, judges,
static assets, nginx, wsevent, and the rendering microservices.
Exits non-zero if anything fails.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `scripts/update`

**Files:**
- Create: `dmoj/scripts/update`

**Interfaces:**
- Consumes: existing `dmoj/scripts/migrate` (Task calls it, does not reimplement).
- Produces: an executable `scripts/update` documented in the README's script table.

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/update`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

echo "== Updating dmoj/repo submodule =="
git -C .. submodule update --remote --merge repo
if [ $? -ne 0 ]; then
    echo "Error: submodule update failed" 1>&2
    exit 1
fi

echo ""
echo "== Rebuilding base, site, celery, bridged, wsevent =="
docker compose up -d --build base site celery bridged wsevent
if [ $? -ne 0 ]; then
    echo "Error: rebuild failed" 1>&2
    exit 1
fi

echo ""
echo "== Running migrations =="
./scripts/migrate
if [ $? -ne 0 ]; then
    echo "Error: migration failed" 1>&2
    exit 1
fi

echo ""
echo "Update complete."
echo "If static files changed upstream, run: ./scripts/copy_static"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/update`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/update`
Expected: no errors.

- [ ] **Step 4: Verify the submodule command syntax against the real submodule**

This validates the `git submodule` invocation without actually mutating the tracked commit (using `--dry-run` is not supported by `submodule update`, so instead verify the command against the current, unmodified state and confirm it's a no-op when already up to date):

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker && git submodule update --remote --merge repo && git status --short dmoj/repo`
Expected: command exits 0; `git status --short dmoj/repo` shows either no output (submodule already at the latest tracked-remote commit) or a modified submodule pointer — either way confirms the command itself is valid syntax against this repo's actual submodule config. If it shows a change, that's real information for the (separate, out-of-scope) freshness audit — do not commit a submodule pointer bump as part of this task; if `git status` shows the submodule pointer changed, run `git checkout -- dmoj/repo` (or equivalent restore) to leave the working tree as it was before this verification step, since bumping the submodule is not part of this plan's scope.

- [ ] **Step 5: Commit**

```bash
git add dmoj/scripts/update
git commit -m "$(cat <<'EOF'
Add scripts/update to automate pulling and rebuilding after upstream changes

Runs submodule update --remote, rebuilds the dependent images, and
migrates — collapses the README's "Updating The Site" section into
one command.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `scripts/backup_db` and `scripts/restore_db`

**Files:**
- Create: `dmoj/scripts/backup_db`
- Create: `dmoj/scripts/restore_db`
- Create: `dmoj/.gitignore` (new file — excludes `backups/` from version control; no `.gitignore` exists at the repo root or in `dmoj/` currently, so this is the first one)

**Interfaces:**
- Produces: `scripts/backup_db [output-path]` (default `dmoj/backups/dmoj-<timestamp>.sql`) and `scripts/restore_db <path>`.

- [ ] **Step 1: Write the backup script**

`environment/mysql.env` holds `MYSQL_DATABASE`/`MYSQL_USER`/`MYSQL_PASSWORD`;
`MYSQL_ROOT_PASSWORD` lives separately in `environment/mysql-admin.env` — both
must be sourced.

Create `dmoj/scripts/backup_db`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

set -a
source environment/mysql.env
source environment/mysql-admin.env
set +a

OUTPUT="${1:-backups/dmoj-$(date +%Y-%m-%d-%H%M%S).sql}"
mkdir -p "$(dirname "$OUTPUT")"

docker compose exec -T $COMPOSE_EXEC_FLAGS db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" > "$OUTPUT"

if [ $? -eq 0 ]; then
    echo "Backup written to $OUTPUT"
else
    echo "Error: mysqldump failed" 1>&2
    rm -f "$OUTPUT"
    exit 1
fi
```

- [ ] **Step 2: Write the restore script**

Create `dmoj/scripts/restore_db`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

set -a
source environment/mysql.env
source environment/mysql-admin.env
set +a

INPUT="$1"
if [ -z "$INPUT" ]; then
    echo "Usage: $0 <path-to-sql-file>" 1>&2
    exit 1
fi
if [ ! -f "$INPUT" ]; then
    echo "Error: $INPUT does not exist" 1>&2
    exit 1
fi

echo "This will OVERWRITE the current database ($MYSQL_DATABASE) with $INPUT."
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

docker compose exec -T $COMPOSE_EXEC_FLAGS db mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < "$INPUT"

if [ $? -eq 0 ]; then
    echo "Restore complete."
else
    echo "Error: restore failed" 1>&2
    exit 1
fi
```

- [ ] **Step 3: Make both scripts executable**

Run: `chmod +x dmoj/scripts/backup_db dmoj/scripts/restore_db`

- [ ] **Step 4: Shellcheck both scripts**

Run: `shellcheck dmoj/scripts/backup_db dmoj/scripts/restore_db`
Expected: no errors. Fix any real issues (e.g. `source` needing `.` for POSIX sh compliance is fine here since the shebang is `#!/bin/bash`).

- [ ] **Step 5: Add dmoj/.gitignore to exclude backups**

Create `dmoj/.gitignore`:

```
backups/
```

- [ ] **Step 6: Verify restore_db's usage and confirmation-prompt guards**

```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
./scripts/restore_db
echo "exit: $?"
./scripts/restore_db /nonexistent/path.sql
echo "exit: $?"
echo "no" | ./scripts/restore_db dmoj/scripts/restore_db
echo "exit: $?"
```
Expected:
- First call: usage message, exit 1.
- Second call: `Error: /nonexistent/path.sql does not exist`, exit 1.
- Third call: prints the overwrite warning, reads `no`, prints `Aborted.`, exits 1 (confirms it does **not** proceed without explicit `yes`, and does not fail trying to reach a database — the abort happens before the `docker compose exec` call).

- [ ] **Step 7: Verify backup_db's mkdir + default-path behavior (without a live DB)**

```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
rm -rf backups
./scripts/backup_db 2>&1 | tail -5
ls backups/ 2>&1
rm -rf backups
```
Expected: since no `db` container is running, `mysqldump` fails and the script prints `Error: mysqldump failed` and removes the empty/partial output file — confirm `ls backups/` shows no leftover `.sql` file (the `rm -f "$OUTPUT"` cleanup worked), even though the `backups/` directory itself was created by `mkdir -p`.

- [ ] **Step 8: Commit**

```bash
git add dmoj/scripts/backup_db dmoj/scripts/restore_db dmoj/.gitignore
git commit -m "$(cat <<'EOF'
Add scripts/backup_db and scripts/restore_db

Timestamped mysqldump backups and a guarded restore (requires typing
"yes" before overwriting the live database).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `scripts/logs`

**Files:**
- Create: `dmoj/scripts/logs`

**Interfaces:**
- Produces: an executable `scripts/logs <service>`.

- [ ] **Step 1: Write the script**

Create `dmoj/scripts/logs`:

```bash
#!/bin/bash
cd $(dirname $(dirname $0)) || exit

SERVICE="$1"
if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service>" 1>&2
    echo "Available services:" 1>&2
    docker compose config --services 1>&2
    exit 1
fi

docker compose logs -f --tail=100 "$SERVICE"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dmoj/scripts/logs`

- [ ] **Step 3: Shellcheck the script**

Run: `shellcheck dmoj/scripts/logs`
Expected: no errors.

- [ ] **Step 4: Verify the usage-error path lists real service names**

Run: `cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj && ./scripts/logs`
Expected: usage message on stderr, followed by the list of services from `podman compose config --services` run against this repo's actual (now-modified) compose file — confirm `judge-tier3-1` appears in that list, proving Task 1's compose change is visible here.

- [ ] **Step 5: Commit**

```bash
git add dmoj/scripts/logs
git commit -m "$(cat <<'EOF'
Add scripts/logs as a thin docker compose logs wrapper

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Documentation updates + end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: all scripts and files from Tasks 1–8 (this task references every one of them by exact name).

- [ ] **Step 1: Add a "Setting up a judge" section to README.md**

Read `README.md` first (it's short — see the version already loaded in this conversation for exact current content/section order). Insert a new section after "### Multiple Nginx Instances" and before "## Common Errors":

```markdown
### Setting up a judge

The judge (`judge-tier3-1`) needs to be registered with the site before it
can connect to `bridged`. Checklist:

- [ ] `docker compose build judge-tier3-1`
- [ ] `docker compose up -d site` and `./scripts/migrate` (if not already running)
- [ ] `./scripts/register_judge judge-tier3-1`
- [ ] `docker compose up -d --build judge-tier3-1`
- [ ] `./scripts/judge_status` (or `./scripts/doctor`) to confirm it shows `online: True`
- [ ] Submit the `demo` fixture's sample problem and confirm it gets graded by this judge

To add another judge instance (e.g. a second tier-3 judge for capacity), use
`./scripts/new_judge <name>` to scaffold the directory and print the
`docker-compose.yml` block to add, then follow the same checklist above with
the new judge's name.
```

- [ ] **Step 2: Document the new scripts in README.md**

In the "## Notes" section, add a new "### Scripts" subsection (after "### Managing Static Files", before "### Updating The Site" — since `scripts/update` supersedes/automates that section's manual steps, cross-reference it there too):

```markdown
### Scripts

In addition to the scripts already covered above (`migrate`, `copy_static`,
`manage.py`, `enter_site`, `initialize`), the following are available under
`dmoj/scripts/`:

- `register_judge <judge-dir>` — registers a judge (e.g. `judge-tier3-1`) in
  the site's database and writes the generated `id`/`key` into its
  `judge.yml`.
- `judge_status` — lists all registered judges and whether they're online.
- `new_judge <name> [template]` — scaffolds a new judge directory from an
  existing one (default template `judge-tier3-1`) and prints the
  `docker-compose.yml` block to add.
- `doctor` — runs a full read-only health check across every service
  (containers, Django, DB, Redis, bridged, judges, static assets, nginx,
  wsevent, mathoid/pdfoid/texoid) and exits non-zero if anything's wrong.
- `update` — pulls the latest `dmoj/repo` submodule commit, rebuilds the
  dependent images, and migrates. See [Updating The Site](#updating-the-site)
  below for what this automates.
- `backup_db [output-path]` — dumps the database to a timestamped `.sql`
  file under `backups/` (or the given path).
- `restore_db <path>` — restores the database from a `.sql` file, after
  confirming with a `yes` prompt.
- `logs <service>` — `docker compose logs -f --tail=100 <service>`.
```

- [ ] **Step 3: Update CLAUDE.md's repo-layout section**

Read `CLAUDE.md` first. In the "## Repo layout" section, add a line after the `dmoj/{site,celery,bridged,wsevent,mathoid,pdfoid,texoid}/Dockerfile` line:

```markdown
- `dmoj/judge-tier3-1/Dockerfile`, `dmoj/judge-tier3-1/judge.yml` — the judge (sandboxed code execution) service, built from the `AresLOLXD/judge-server` `AddKarel` fork. Connects outbound to `bridged:9999`. Add more judges with `./scripts/new_judge`.
```

- [ ] **Step 4: Update CLAUDE.md's common-commands section**

In the "## Common commands" section, add a new bullet list after the existing script bullets (before "### Updating after changes"):

```markdown
- `./scripts/register_judge <judge-dir>` — register a judge (e.g. `judge-tier3-1`) with the site and write its `id`/`key` into `judge.yml`.
- `./scripts/judge_status` — list registered judges and their online status.
- `./scripts/new_judge <name> [template]` — scaffold a new judge directory from an existing one.
- `./scripts/doctor` — full-stack read-only health check; exits non-zero if any check fails.
- `./scripts/update` — pull the latest `dmoj/repo` commit, rebuild dependent images, and migrate.
- `./scripts/backup_db [path]` / `./scripts/restore_db <path>` — dump/restore the database.
- `./scripts/logs <service>` — tail a service's logs.
```

- [ ] **Step 5: Commit the documentation**

```bash
git add README.md CLAUDE.md
git commit -m "$(cat <<'EOF'
Document the judge setup checklist and new management scripts

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: End-to-end verification against a live stack**

This is the first point in the plan where the full stack is actually
brought up together — everything before this was validated in isolation
per-task. Run from `/var/home/areslolxd/Documentos/dmoj-docker/dmoj`:

```bash
podman compose up -d db redis
sleep 10
podman compose up -d --build base site celery bridged wsevent mathoid pdfoid texoid nginx
./scripts/migrate
./scripts/copy_static
./scripts/manage.py loaddata navbar
./scripts/manage.py loaddata language_small
./scripts/manage.py loaddata demo
podman compose up -d --build judge-tier3-1
./scripts/register_judge judge-tier3-1
podman compose up -d --build judge-tier3-1
sleep 15
./scripts/judge_status
./scripts/doctor; echo "doctor exit: $?"
```

Expected:
- `./scripts/judge_status` shows `judge-tier3-1` with `ONLINE: True`.
- `./scripts/doctor` prints all ten check groups with `✓`, and `doctor exit: 0`.

If any check fails, fix the underlying script/config (not the check itself)
and rerun — do not mark this task complete until `doctor` exits 0 against
this live stack. Note in your final report which steps required the real
`docker`/`podman` engine vs. which were validated statically, since a
future maintainer running this same stack with plain `docker compose` needs
to trust these scripts work under both.

- [ ] **Step 7: Tear down the verification stack**

```bash
cd /var/home/areslolxd/Documentos/dmoj-docker/dmoj
podman compose down
```

This leaves no long-running containers behind after verification.
