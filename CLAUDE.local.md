# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Docker Compose setup that runs a self-hosted clone of the [DMOJ online judge](https://github.com/DMOJ/online-judge) (a Django app), plus supporting services: mathoid (math rendering), pdfoid (PDF rendering), texoid (LaTeX image rendering), a bridged judge daemon, a websocket event daemon, and nginx. The actual DMOJ site source code lives in the `dmoj/repo` git submodule, pointed at the user's fork (`AresLOLXD/online-judge`, tracking its `master` branch) rather than upstream `DMOJ/online-judge` — this repo only contains the Docker infrastructure and site configuration around it, not application code.

## Repo layout

- `dmoj/docker-compose.yml` — the compose file defining all services (`db`, `redis`, `texoid`, `pdfoid`, `mathoid`, `base`, `site`, `celery`, `bridged`, `wsevent`, `nginx`).
- `dmoj/base/Dockerfile` — shared base image (Python deps, Node for sass/postcss) that `site`, `celery`, and `bridged` all build `FROM`.
- `dmoj/{site,celery,bridged,wsevent,mathoid,pdfoid,texoid}/Dockerfile` — per-service images.
- `dmoj/environment/*.env` — env files (`mysql.env`, `mysql-admin.env`, `site.env`) consumed by `docker-compose.yml`. Contain secrets (DB passwords, Django `SECRET_KEY`) — never commit real values here.
- `dmoj/nginx/conf.d/` — nginx site config; `server_name` must be set here for production.
- `dmoj/scripts/` — operational helper scripts (see below), all designed to be run from the repo root (they `cd` into `dmoj/` internally).
- `dmoj/repo/` — git submodule, the actual DMOJ Django application (`DMOJ/online-judge`).
- `config.js`, `local_settings.py`, `uwsgi.ini` (repo root) — templates that `scripts/initialize` moves into the submodule (`repo/websocket/config.js`, `repo/dmoj/local_settings.py`, `repo/uwsgi.ini`) during first-time setup. Edit these root copies, not files inside `repo/`, since `repo/` is a submodule.

## Common commands

All scripts in `dmoj/scripts/` are run from the `dmoj/` directory (e.g. `cd dmoj && ./scripts/migrate`).

- `./scripts/initialize` — one-time setup: creates `problems/` and `media/` dirs, moves root-level `config.js`, `local_settings.py`, `uwsgi.ini` into the `repo/` submodule.
- `docker compose build` — build all images.
- `docker compose up -d site` — bring up just the site (needed before first migrate/collectstatic).
- `./scripts/migrate` — run Django migrations inside the `site` container (`manage.py migrate`).
- `./scripts/copy_static` — rebuild static assets: runs `make_style.sh`, `collectstatic`, `compilemessages`, `compilejsi18n`, then copies resources/502.html/logo.png/robots.txt into the `assets` volume. Run this whenever static files change.
- `./scripts/manage.py <args>` — run arbitrary Django management commands inside the `site` container.
- `./scripts/enter_site` — open a bash shell inside the running `site` container.
- `docker compose up -d` — start the full stack.
- Loading initial fixtures (first-time only): `./scripts/manage.py loaddata navbar`, `./scripts/manage.py loaddata language_small`, `./scripts/manage.py loaddata demo`.

### Updating after changes

- If a base dependency changed (base image), rebuild the dependent services: `docker compose up -d --build base site celery bridged wsevent`.
- If only source code (in `repo/`) changed: `docker compose restart site celery bridged wsevent` is enough.
- If static files changed: rerun `./scripts/copy_static`.

## Architecture notes

- `base` builds with `network_mode: none` — it's a pure build stage (installs OS packages, Node tooling, and `repo/requirements.txt`) that `site`, `celery`, and `bridged` all extend `FROM ninjaclasher/dmoj-base:latest`.
- `site` (uwsgi/Django), `celery` (async task worker), and `bridged` (judge-facing bridge daemon) all mount the same `repo/` submodule read-write and share `mysql.env`/`site.env`.
- `wsevent` is a separate Node service (not built from `base`) running `repo/websocket/daemon.js`; it powers live-update websockets, proxied by nginx at `/event/` and `/channels/`.
- `nginx` fronts everything: serves static assets from the `assets` volume, proxies uwsgi to `site:8000`, and proxies websocket traffic to `wsevent`. It depends on `site` and `wsevent` being up, and must be restarted after those services restart (it caches DNS — see README "502 Bad Gateway" note).
- `mathoid`, `pdfoid`, `texoid` are independent rendering microservices reached over the internal `site` Docker network at fixed hostnames/ports (`mathoid:10044`, `pdfoid:8888`, `texoid:8888`), configured via `local_settings.py` (`MATHOID_URL`, `DMOJ_PDF_PDFOID_URL`, `TEXOID_URL`).
- Shared named volumes (`assets`, `pdfcache`, `datacache`, `cache`) let `site`, `celery`, `bridged`, and `nginx` share generated content (static assets, PDF/user-data caches, mathoid/texoid render caches) without direct network calls.
- Three Docker networks isolate concerns: `db` (site/celery/bridged/db), `site` (internal service-to-service), `nginx` (public-facing, only services nginx proxies to).
- `local_settings.py` is the primary place to change DMOJ site behavior (feature flags, external service URLs, email backend, judge bridge address/port, logging, etc.) — it's a Django settings overlay read via env vars defined in `dmoj/environment/site.env` and `mysql.env`.
