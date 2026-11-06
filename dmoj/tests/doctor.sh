#!/bin/bash
# Runs a copy of scripts/doctor against a fake docker and a real local HTTP
# server, so the nginx check is exercised without the stack.
# Usage: bash tests/doctor.sh   (from anywhere; exits non-zero if any case fails)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(mktemp -d)
SERVER_PID=
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$BASE"' EXIT
unset COMPOSE_EXEC_FLAGS
RESULT=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; RESULT=1; }

# Free loopback port; the HTTP server below answers 200 on it.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir "$BASE/www"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$BASE/www" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
done

# Runs the copied doctor. PORT_OUT is what the fake `compose port` prints;
# FAIL_PORT makes it fail like a stopped service. Sets $STATUS and $TMP/out.
run_doctor() {
    TMP=$(mktemp -d -p "$BASE")
    mkdir -p "$TMP/dmoj/scripts" "$TMP/bin"
    cp "$ROOT/scripts/doctor" "$TMP/dmoj/scripts/doctor"
    printf '#!/bin/bash\n' > "$TMP/dmoj/scripts/judge_status"
    cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
case "$*" in
    "compose config --services") echo nginx ;;
    "compose ps"*) echo running ;;
    "compose port nginx 80")
        [ -z "$FAIL_PORT" ] || exit 1
        printf '%s\n' "$PORT_OUT"
        ;;
esac
STUB
    chmod +x "$TMP/dmoj/scripts/doctor" "$TMP/dmoj/scripts/judge_status" "$TMP/bin/docker"
    PATH="$TMP/bin:$PATH" bash "$TMP/dmoj/scripts/doctor" > "$TMP/out" 2>&1
    STATUS=$?
}

has_out() { grep -qF -- "$1" "$TMP/out"; }

NAME="published address is probed and shown"
PORT_OUT="127.0.0.1:$PORT" run_doctor
if has_out "✓ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

NAME="IPv4 wildcard bind is probed through loopback"
PORT_OUT="0.0.0.0:$PORT" run_doctor
if has_out "✓ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

NAME="IPv6 wildcard bind is probed through loopback"
PORT_OUT="[::]:$PORT" run_doctor
if has_out "✓ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

NAME="first line wins when compose reports two addresses"
PORT_OUT=$(printf '0.0.0.0:%s\n[::]:%s' "$PORT" "$PORT") run_doctor
if has_out "✓ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

NAME="stopped nginx fails without falling back to port 80, other sections still run"
FAIL_PORT=1 run_doctor
if [ "$STATUS" -eq 1 ] && has_out "✗ nginx responds: nginx is not running" \
    && ! has_out "responds on" && has_out "== wsevent ==" \
    && has_out "== Rendering services =="; then pass "$NAME"; else fail "$NAME"; fi

NAME="published port with nothing listening fails the check"
PORT_OUT="127.0.0.1:1" run_doctor
if [ "$STATUS" -eq 1 ] && has_out "✗ nginx responds on 127.0.0.1:1"; then pass "$NAME"; else fail "$NAME"; fi

exit $RESULT
