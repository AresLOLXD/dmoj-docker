#!/bin/bash
# Runs a copy of scripts/update against fake docker, git and backup_db that log
# every call, so ordering and failure branches are checked without Docker.
# Usage: bash tests/update.sh   (from anywhere; exits non-zero if any case fails)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
unset COMPOSE_EXEC_FLAGS
RESULT=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; RESULT=1; }

# Builds a fresh tree in $TMP, runs the copied update and sets $STATUS.
# FAIL_BACKUP / FAIL_CHECK / FAIL_BROKER / FAIL_MIGRATE in the environment make the matching stub fail.
run_update() {
    TMP=$(mktemp -d -p "$BASE")
    CALLS=$TMP/calls
    : > "$CALLS"
    mkdir -p "$TMP/dmoj/scripts" "$TMP/bin"
    cp "$ROOT/scripts/update" "$TMP/dmoj/scripts/update"

    cat > "$TMP/dmoj/scripts/backup_db" <<'STUB'
#!/bin/bash
echo "backup_db $*" >> "$CALLS"
[ -z "$FAIL_BACKUP" ]
STUB
    cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$CALLS"
if [ -n "$FAIL_MIGRATE" ] && [[ "$*" == *"manage.py migrate"* ]]; then
    exit 1
fi
if [ -n "$FAIL_CHECK" ] && [[ "$*" == *"manage.py check"* ]]; then
    exit 1
fi
if [ -n "$FAIL_BROKER" ] && [[ "$*" == *ensure_connection* ]]; then
    exit 1
fi
STUB
    cat > "$TMP/bin/git" <<'STUB'
#!/bin/bash
echo "git $*" >> "$CALLS"
if [[ "$*" == *rev-parse* ]]; then
    echo abc1234
fi
STUB
    chmod +x "$TMP/dmoj/scripts/backup_db" "$TMP/bin/docker" "$TMP/bin/git"

    PATH="$TMP/bin:$PATH" CALLS="$CALLS" bash "$TMP/dmoj/scripts/update" > "$TMP/out" 2>&1
    STATUS=$?
}

# First line number in $CALLS containing the fixed string $1; empty if none.
line_of() { grep -nF -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
has_call() { grep -qF -- "$1" "$CALLS"; }
has_out() { grep -qF -- "$1" "$TMP/out"; }
backup_path() { sed -n 's/^backup_db //p' "$CALLS" | head -n 1; }

NAME="backup failure aborts before any change"
FAIL_BACKUP=1 run_update
if [ "$STATUS" -ne 0 ] && ! grep -q '^docker ' "$CALLS" && ! has_call submodule \
    && has_out "pre-update backup failed"; then pass "$NAME"; else fail "$NAME"; fi

NAME="stop precedes migrate and up follows it"
run_update
STOP=$(line_of "docker compose stop site celery bridged")
MIGRATE=$(line_of "manage.py migrate")
UP=$(line_of "up -d site celery bridged wsevent")
MIGRATE_LINE=$(sed -n "${MIGRATE:-1}p" "$CALLS")
if [ "$STATUS" -eq 0 ] && [ -n "$STOP" ] && [ -n "$MIGRATE" ] && [ -n "$UP" ] \
    && [[ "$MIGRATE_LINE" == *"run --rm --no-deps"* ]] \
    && [[ "$MIGRATE_LINE" == *"--entrypoint python3 site manage.py migrate"* ]] \
    && [[ "$MIGRATE_LINE" != *" exec "* ]] \
    && [ "$STOP" -lt "$MIGRATE" ] && [ "$MIGRATE" -lt "$UP" ]; then pass "$NAME"; else fail "$NAME"; fi

NAME="migrate failure keeps the stack stopped and prints the recipe"
FAIL_MIGRATE=1 run_update
BACKUP=$(backup_path)
if [ "$STATUS" -ne 0 ] && has_call "docker compose stop site celery bridged" \
    && ! has_call "up -d" && ! has_call restart \
    && [ -n "$BACKUP" ] && has_out "$BACKUP" && has_out abc1234 \
    && has_out "git -C repo checkout abc1234" && has_out "./scripts/restore_db" \
    && has_out "docker compose build base" && has_out "docker compose up -d"; then pass "$NAME"; else fail "$NAME"; fi

NAME="success prints the backup path"
run_update
BACKUP=$(backup_path)
TAIL=$(tail -n 5 "$TMP/out")
if [ "$STATUS" -eq 0 ] && [ -n "$BACKUP" ] && [[ "$TAIL" == *"$BACKUP"* ]] \
    && [[ "$TAIL" == *"./scripts/restore_db"* ]] \
    && [[ "$TAIL" == *"docker compose stop site celery bridged"* ]] \
    && [[ "$TAIL" == *"git -C repo checkout abc1234"* ]]; then pass "$NAME"; else fail "$NAME"; fi

NAME="image check failure aborts before the stop"
FAIL_CHECK=1 run_update
BACKUP=$(backup_path)
if [ "$STATUS" -ne 0 ] && has_call "docker compose build site celery bridged wsevent" \
    && has_call "manage.py check" && ! has_call "docker compose stop" \
    && ! has_call "manage.py migrate" && ! has_call "up -d" && ! has_call restart \
    && [ -n "$BACKUP" ] && has_out "Backup: $BACKUP" && has_out "failed manage.py check" \
    && has_out "nothing was stopped" && has_out "git -C repo checkout abc1234"; then pass "$NAME"; else fail "$NAME"; fi

NAME="image check precedes the stop"
run_update
BUILD=$(line_of "docker compose build site celery bridged wsevent")
CHECK=$(line_of "manage.py check")
STOP=$(line_of "docker compose stop site celery bridged")
MIGRATE=$(line_of "manage.py migrate")
UP=$(line_of "up -d site celery bridged wsevent")
CHECK_LINE=$(sed -n "${CHECK:-1}p" "$CALLS")
if [ "$STATUS" -eq 0 ] && [ -n "$BUILD" ] && [ -n "$CHECK" ] && [ -n "$STOP" ] \
    && [ -n "$MIGRATE" ] && [ -n "$UP" ] \
    && [[ "$CHECK_LINE" == *"run --rm --no-deps"* ]] \
    && [[ "$CHECK_LINE" == *"--entrypoint python3 site manage.py check"* ]] \
    && [[ "$CHECK_LINE" != *" exec "* ]] \
    && [ "$BUILD" -lt "$CHECK" ] && [ "$CHECK" -lt "$STOP" ] \
    && [ "$STOP" -lt "$MIGRATE" ] && [ "$MIGRATE" -lt "$UP" ]; then pass "$NAME"; else fail "$NAME"; fi

NAME="broker check failure aborts before the stop"
FAIL_BROKER=1 run_update
BACKUP=$(backup_path)
if [ "$STATUS" -ne 0 ] && has_call "docker compose build site celery bridged wsevent" \
    && has_call "manage.py check" && has_call ensure_connection \
    && ! has_call "docker compose stop" && ! has_call "manage.py migrate" \
    && ! has_call "up -d" && ! has_call restart \
    && [ -n "$BACKUP" ] && has_out "Backup: $BACKUP" && has_out "could not reach the broker" \
    && has_out "nothing was stopped" && has_out "git -C repo checkout abc1234"; then pass "$NAME"; else fail "$NAME"; fi

NAME="broker check runs after the site check and before the stop"
run_update
CHECK=$(line_of "manage.py check")
BROKER=$(line_of ensure_connection)
STOP=$(line_of "docker compose stop site celery bridged")
MIGRATE=$(line_of "manage.py migrate")
UP=$(line_of "up -d site celery bridged wsevent")
BROKER_LINE=$(sed -n "${BROKER:-1}p" "$CALLS")
if [ "$STATUS" -eq 0 ] && [ -n "$CHECK" ] && [ -n "$BROKER" ] && [ -n "$STOP" ] \
    && [ -n "$MIGRATE" ] && [ -n "$UP" ] \
    && [[ "$BROKER_LINE" == *"run --rm --no-deps"* ]] \
    && [[ "$BROKER_LINE" == *"--entrypoint python3 celery -c"* ]] \
    && [[ "$BROKER_LINE" != *" exec "* ]] \
    && [ "$CHECK" -lt "$BROKER" ] && [ "$BROKER" -lt "$STOP" ] \
    && [ "$STOP" -lt "$MIGRATE" ] && [ "$MIGRATE" -lt "$UP" ]; then pass "$NAME"; else fail "$NAME"; fi

NAME="broker check opens a connection and starts no worker"
run_update
BROKER_LINE=$(sed -n "$(line_of ensure_connection)p" "$CALLS")
if [ "$STATUS" -eq 0 ] && [[ "$BROKER_LINE" == *connection_for_read* ]] \
    && [[ "$BROKER_LINE" == *ensure_connection* ]] \
    && ! has_call "celery -A" && ! has_call " worker"; then pass "$NAME"; else fail "$NAME"; fi

exit $RESULT
