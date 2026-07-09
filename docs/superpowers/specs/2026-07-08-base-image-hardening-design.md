# Base image hardening: Node EOL, curl|bash, unpinned npm/pip (M7)

Date: 2026-07-08

## Context

Fifth and last sub-project of the Medium-severity findings from the
Docker-setup security audit (previous: `security-audit-medium-quickwins`,
`pdfoid-hardening`, `texoid-hardening`, `tls-secure-cookies`). This one
covers M7: `dmoj/base/Dockerfile` — the shared image `site`, `celery`, and
`bridged` all build `FROM` — installs Node 16 (EOL since September 2023)
via `curl -sL https://deb.nodesource.com/setup_16.x | bash -` (a script
piped straight into `bash`, unverified), and installs both npm packages
(`sass`, `postcss-cli`, `postcss`, `autoprefixer`) and pip packages
(`pymysql`, `mysqlclient`, `websocket-client`, `uwsgi`, `django-redis`,
`redis`) with no version pins — every rebuild can resolve different
versions with no integrity check, and this base image feeds three
services at once, so a single hijacked/incompatible dependency version
compromises or breaks all three simultaneously.

### Investigation

- Node 24 is the current LTS ("Krypton") — already used for mathoid in
  this repo (`security-audit-high-findings`), so this keeps Node version
  choice consistent across the project.
- Checked each npm package's latest version and Node-engine requirement —
  all compatible with Node 24: `sass@1.83.0` (already pinned in this repo
  from an earlier fix — kept as-is, no reason to churn a verified-working
  pin), `postcss-cli@11.0.1` (`node >=18`), `postcss@8.5.16`
  (`node ^10||^12||>=14`), `autoprefixer@10.5.2` (same range).
- Checked each pip package's latest version on PyPI, and found a real
  compatibility trap: `django-redis`'s latest release (`7.0.0`) requires
  `Django>=5.2`, but `dmoj/repo/requirements.txt` (the site's own
  dependency file) pins `Django>=4.2,<5` — installing `django-redis`
  latest would break the actual Django version this stack runs (this
  exact conflict already surfaced as a pip warning in an earlier base
  rebuild this session: "django-redis 7.0.0 requires Django<7.0,>=5.2,
  but you have django 4.2.30 which is incompatible"). `django-redis 5.4.0`
  requires only `Django>=3.2` — compatible, and the version chosen here.
  Other pip packages (`pymysql==1.2.0`, `mysqlclient==2.2.8`,
  `websocket-client==1.9.0`, `uwsgi==2.0.31`, `redis==5.2.1`) have no
  known compatibility conflicts with the site's stack.

## Change

### `dmoj/base/Dockerfile`

```dockerfile
FROM node:24-bookworm AS node

FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y \
        git gcc g++ make curl gettext wget \
        libxml2-dev libxslt1-dev zlib1g-dev \
        mariadb-client libmariadb-dev \
        libjpeg-dev debconf-utils pkg-config && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local /usr/local

RUN npm install -g sass@1.83.0 postcss-cli@11.0.1 postcss@8.5.16 autoprefixer@10.5.2
RUN pip3 install \
        pymysql==1.2.0 mysqlclient==2.2.8 websocket-client==1.9.0 \
        uwsgi==2.0.31 django-redis==5.4.0 redis==5.2.1

COPY repo/requirements.txt .
RUN pip3 install -r requirements.txt
```

Key decisions:
- **Multi-stage `COPY --from=node`, not `curl | bash`.** Node is obtained
  by copying the entire `/usr/local` tree from the official
  `node:24-bookworm` image (the same image already trusted and used for
  mathoid in this repo) into the base image, instead of downloading and
  executing NodeSource's setup script. This eliminates the "pipe an
  unverified script into a shell" pattern entirely — the Node binaries
  come from Docker Hub's official, signed `node` image, not a shell
  script fetched over HTTPS with no signature check.
- **`COPY --from=node /usr/local /usr/local`** copies the whole tree
  (not just the `node` binary) because that's where npm and its supporting
  `node_modules` (npm itself, corepack, etc.) live in the official image —
  copying only the `node` binary would leave `npm` missing.
- **All npm/pip packages pinned to specific versions** — removes the
  "whatever's newest at build time" resolution that previously let a
  transitive dependency shift unexpectedly between builds (this is the
  same class of problem that broke `copy_static` before the `sass` pin
  was added in an earlier fix this session).
- **`django-redis==5.4.0`, not the latest `7.0.0`** — the latest version's
  `Django>=5.2` requirement is incompatible with this site's pinned
  `Django>=4.2,<5`; `5.4.0`'s `Django>=3.2` requirement is compatible.
- **`repo/requirements.txt` is untouched and out of scope** — it belongs
  to the DMOJ site fork's own dependency management (a different
  codebase/PR process), not this repo's Docker infrastructure.

## Out of scope

- Pinning or otherwise modifying `dmoj/repo/requirements.txt` — the site
  fork's own concern.
- Any change to `site`, `celery`, or `bridged` Dockerfiles themselves
  (they only need to keep building `FROM` the hardened base image
  unchanged).
- Digest-pinning `node:24-bookworm` or `python:3.11-slim-bookworm` (tag
  pinning only, consistent with this repo's existing convention — noted
  as acceptable in a prior audit review of the mathoid fix).
- Any change to what packages are installed (only pinning existing ones —
  no new dependencies added, none removed).

## Testing / verification

- `docker compose build base` (via `podman compose build base` on this
  host) succeeds — the multi-stage `node` build stage builds/pulls
  successfully, `COPY --from=node` succeeds, pinned npm packages install
  without errors, pinned pip packages install without the previously-seen
  `django-redis`/Django version conflict warning.
- `podman compose run --rm --entrypoint node base --version` shows
  `v24.x.x`.
- `podman compose run --rm --entrypoint npm base --version` succeeds
  (confirms npm itself was copied correctly, not just the `node` binary).
- `podman compose run --rm --entrypoint sass base --version` shows
  `1.83.0`; `podman compose run --rm --entrypoint python3 base -c "import
  pymysql, MySQLdb, websocket, django_redis, redis; print('ok')"` succeeds
  with no import errors and confirms the pinned versions via
  `pip3 show <package>`.
- `docker compose up -d --build base site celery bridged` (via
  `podman compose`) — all three rebuild successfully `FROM` the new base
  image with no errors.
- Re-run `scripts/copy_static` (via the `site-static-build` service from
  the earlier `security-audit-medium-quickwins` fix) end-to-end — confirms
  the Node/sass/postcss toolchain still produces working CSS on the new
  base image, not just that it builds.
- `site`/`celery`/`bridged` start and stay up after rebuilding from the
  new base image (no crash loop from a pip package version mismatch).
