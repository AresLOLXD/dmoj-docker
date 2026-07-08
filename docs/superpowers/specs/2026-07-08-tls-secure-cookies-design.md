# TLS/secure cookies: trust an external TLS-terminating proxy (M6)

Date: 2026-07-08

## Context

Fourth sub-project of the Medium-severity findings from the Docker-setup
security audit (previous: `security-audit-medium-quickwins`,
`pdfoid-hardening`, `texoid-hardening`). This one covers M6: `nginx` only
listens on plain HTTP (`listen 80`, no TLS), and Django's
`CSRF_COOKIE_SECURE`/`SESSION_COOKIE_SECURE` are commented out — so
credentials, session cookies, and CSRF tokens travel unencrypted, and even
if something upstream added HTTPS later, cookies would still be sent over
any non-TLS connection too since nothing tells Django to require it.

The user's actual deployment: an external TLS-terminating proxy (e.g.
Cloudflare Tunnel, Caddy) runs on the same host as this Docker Compose
stack and forwards to nginx. This spec implements that scenario —
`nginx` itself does not terminate TLS; Django trusts the external proxy's
`X-Forwarded-Proto` header to know a request arrived over HTTPS.

### Investigation: why "just add the Django settings" isn't sufficient

For `SECURE_PROXY_SSL_HEADER` to be trustworthy, nginx must not be
reachable by anyone except the trusted external proxy — otherwise anyone
could hit nginx directly and forge `X-Forwarded-Proto: https` themselves,
making Django believe an unencrypted connection is secure (defeating the
whole point). `docker-compose.yml` currently publishes nginx as
`80:80` — bound to `0.0.0.0`, reachable from anywhere the host is
reachable. This must become `127.0.0.1:80:80` so only the proxy running on
the same host can reach it.

Separately: `nginx.conf`'s `@uwsgi` location uses `uwsgi_pass` (the raw
uwsgi protocol, not `proxy_pass`'s HTTP proxying), which does not forward
arbitrary incoming headers to the upstream automatically. Even with the
external proxy correctly sending `X-Forwarded-Proto: https` to nginx, that
header will not reach Django unless nginx is explicitly told to relay it
into a `uwsgi_param`.

### Investigation: `local_settings.py` has two copies

Per this repo's own documented convention (`CLAUDE.md`): `config.js`,
`local_settings.py`, and `uwsgi.ini` at the `dmoj-docker` repo root are
git-tracked templates that `scripts/initialize` moves (`mv`, one-time)
into the `dmoj/repo` submodule, where the submodule's own `.gitignore`
(confirmed: `dmoj/repo/.gitignore` line 9, `dmoj/local_settings.py`)
intentionally keeps that file out of the submodule's git history. In this
environment, `scripts/initialize` already ran — the root-level
`local_settings.py` template no longer exists on disk (shows as deleted
in `git status`, but its content is still recoverable from git history
via `git show HEAD:local_settings.py`), and the live file Django actually
reads is `dmoj/repo/dmoj/local_settings.py`.

No prior sub-project in this audit's remediation touched any of these
three specially-templated files (H1/H2/M2/M3/pdfoid/texoid all only
touched files that live solely in the `dmoj-docker` repo, with a single
source of truth) — this is the first one that does, so this dual-copy
handling is new to this spec, not a gap in earlier work.

## Change

### 1. `dmoj/docker-compose.yml` — restrict nginx to localhost

```yaml
  nginx:
    ...
    ports:
      - 127.0.0.1:80:80
```

(replacing `- 80:80`)

### 2. `dmoj/nginx/conf.d/nginx.conf` — relay `X-Forwarded-Proto` to Django

Inside the existing `location @uwsgi { ... }` block, add:

```nginx
        uwsgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
```

### 3. `local_settings.py` — both copies get the same three lines

Root template (`dmoj-docker/local_settings.py`, currently absent from the
working tree but tracked in git — recreate it with `git show
HEAD:local_settings.py` as the starting content, then apply this change)
and the live file (`dmoj/repo/dmoj/local_settings.py`) both get:

```python
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True
```

The existing commented-out lines in both files
(`#CSRF_COOKIE_SECURE = True` / `#SESSION_COOKIE_SECURE = True`) are
uncommented and set to `True`, plus the new `SECURE_PROXY_SSL_HEADER`
line is added near them.

`SECURE_SSL_REDIRECT` is deliberately NOT set — that HTTP→HTTPS redirect
is the external proxy's job; Django/nginx never see a plain HTTP request
from real end users in this topology (only from the trusted local proxy,
which only ever forwards what it already terminated as HTTPS).

### 4. Documentation (`README.md` and/or `CLAUDE.md`)

Add a note that this stack assumes an external TLS-terminating proxy
(e.g. Cloudflare Tunnel, Caddy) running on the same host, forwarding to
`nginx` on `127.0.0.1:80`, and setting `X-Forwarded-Proto: https`.
Without such a proxy, the site is not reachable from outside the host at
all — this is intentional, not a bug to work around by reverting the
port binding.

## Out of scope

- Any TLS termination inside nginx itself (certificates, `listen 443`,
  HSTS) — not needed given the external-proxy topology chosen.
- Setting up the actual external proxy (Cloudflare Tunnel/Caddy
  installation/configuration) — that's the user's own infrastructure,
  outside this repo.
- `DMOJ_HTTPS` (a cosmetic setting affecting only `<link rel='canonical'>`
  generation, not a security control) — left as-is, not part of this
  finding.
- Other Medium/Low audit findings (base image M7) — separate spec.

## Testing / verification

- `docker-compose.yml`'s nginx service shows `127.0.0.1:80:80`, not
  `80:80`.
- `podman compose up -d nginx` — nginx starts; `ss -tlnp | grep :80`
  shows it bound to `127.0.0.1:80`, not `0.0.0.0:80`.
- From the host: `curl -H 'X-Forwarded-Proto: https' -b '' -c - -s -o
  /dev/null -D - http://localhost/accounts/login/` (or any page that sets
  a cookie) shows a `Set-Cookie` header with the `Secure` attribute
  present. The same request without the `X-Forwarded-Proto: https` header
  should NOT show `Secure` on the cookie (confirms Django is actually
  reading the forwarded header, not just always marking cookies secure
  regardless).
- `curl` from outside the host (or `curl http://<host-external-ip>/`, if
  testable) to port 80 fails to connect — confirms nginx is no longer
  reachable except via `127.0.0.1`.
- `git show HEAD:local_settings.py` vs. the recreated-and-edited root
  template file: diff shows only the three added/uncommented lines.
- `dmoj/repo/dmoj/local_settings.py` (the live file) contains the same
  three lines — `grep -n "SECURE_PROXY_SSL_HEADER\|CSRF_COOKIE_SECURE\|SESSION_COOKIE_SECURE" dmoj/repo/dmoj/local_settings.py`.
- After restarting `site`/`celery`/`bridged` to pick up the live
  `local_settings.py` change, the site still functions normally (login,
  session persistence) when accessed through a simulated proxy request
  carrying `X-Forwarded-Proto: https`.
