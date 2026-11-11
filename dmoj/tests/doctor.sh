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
# Like the site with ALLOWED_HOSTS = [HOST]: 200 only when the Host header is the site's own hostname.
SITE_HOSTNAME=dmoj.example
cat > "$BASE/server.py" <<'PY'
import http.server, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.headers.get("Host") == sys.argv[2] else 400)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
python3 "$BASE/server.py" "$PORT" "$SITE_HOSTNAME" &
SERVER_PID=$!
for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
done

# Runs the copied doctor. PORT_OUT is what the fake `compose port` prints;
# FAIL_PORT makes it fail like a stopped service; the fake site container has
# HOST=$SITE_HOSTNAME unless the caller overrides it. Sets $STATUS and $TMP/out.
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
    "compose exec -T site printenv HOST") printf '%s' "$SITE_ENV_HOST" ;;
    "compose port nginx 80")
        [ -z "$FAIL_PORT" ] || exit 1
        printf '%s\n' "$PORT_OUT"
        ;;
esac
STUB
    chmod +x "$TMP/dmoj/scripts/doctor" "$TMP/dmoj/scripts/judge_status" "$TMP/bin/docker"
    PATH="$TMP/bin:$PATH" SITE_ENV_HOST="${SITE_ENV_HOST-$SITE_HOSTNAME}" bash "$TMP/dmoj/scripts/doctor" > "$TMP/out" 2>&1
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

NAME="Host header of the site is sent so a site that allows only its hostname passes"
PORT_OUT="127.0.0.1:$PORT" run_doctor
if [ "$STATUS" -eq 0 ] && has_out "✓ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

NAME="empty HOST sends no Host header"
SITE_ENV_HOST='' PORT_OUT="127.0.0.1:$PORT" run_doctor
if [ "$STATUS" -eq 1 ] && has_out "✗ nginx responds on 127.0.0.1:$PORT"; then pass "$NAME"; else fail "$NAME"; fi

exit $RESULT
