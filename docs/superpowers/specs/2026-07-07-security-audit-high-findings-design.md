# Fix High-severity security audit findings (bridged exposure, mathoid EOL)

Date: 2026-07-07

## Context

A security audit of the Docker Compose infrastructure (deferred twice already —
see `docs/superpowers/specs/2026-07-02-judge-addkarel-integration-design.md`
and `docs/superpowers/specs/2026-07-07-fork-submodule-repoint-design.md`)
identified two High-severity findings. This spec fixes both. Medium/Low
findings (pdfoid `SYS_ADMIN`, tracked `.env` files, read-write `repo/` mounts,
texoid/pdfoid unpinned clones, missing TLS, base image `curl | bash`, etc.)
are explicitly out of scope — separate follow-up work.

### H1: `bridged` over-exposure

`bridged` (`dmoj/docker-compose.yml`) is the judge-facing daemon that accepts
grading connections and injects verdicts into the database. It currently:

- Publishes `9999:9999` to the host (`0.0.0.0`), bypassing the host firewall
  (Docker inserts its own iptables rules ahead of firewalld/ufw).
- Is attached to the `nginx` network in addition to `site` and `db`.

Both are unnecessary: the in-compose judge (`judge-tier3-1`) reaches
`bridged:9999` over the internal `site` Docker network by hostname — the host
port publish has no purpose for the current setup, and there are no
external (out-of-compose) judges. Docker network membership is internal
segmentation, not external exposure — `nginx`'s reverse proxy config
(`dmoj/nginx/conf.d/*.conf`) only proxies to `site:8000` and `wsevent`, never
to `bridged`, so that network membership serves no purpose and only adds
unneeded lateral connectivity.

### H2: mathoid on EOL Node 10 with an abandoned upstream package

`dmoj/mathoid/Dockerfile` builds `FROM node:10.21.0` (EOL since April 2021)
and runs `npm install mathoid` with no version pin. The `mathoid` package on
the npm registry is stuck at `0.7.6`, published 2022, still targeting
`node >= 10` — but it is not the actively maintained source. Mathoid's real
upstream moved to GitLab
(`https://gitlab.wikimedia.org/repos/mediawiki/services/mathoid`) and merged
a Node 24 migration on 2026-05-12 (commit `3eeedbb879dd2316eac7d0c0b8a5da02c6601050`,
"Merge branch 'node-24' into 'main'"): `package.json` now declares
`"engines": { "node": ">=24" }`, drops the old native `librsvg` addon
dependency, and bumps to Express 5 / service-runner 6. This was never
republished to npm under a new version. The unpinned `npm install mathoid`
against the stale registry package is also the likely root cause of the
"Node/commander incompatibility" that `scripts/doctor` already flags as a
known failure (noted in `CLAUDE.md`'s prior session ledger) — unpinned
transitive dependency resolution can silently pull a newer `commander` (or
other transitive dep) that the ancient Node 10 runtime can't run.

## Change

### H1: `dmoj/docker-compose.yml`

On the `bridged` service:
- Remove the `ports: - 9999:9999` mapping entirely.
- Change `networks: [site, nginx, db]` to `networks: [site, db]`.

No other services change. `judge-tier3-1` already only needs `bridged:9999`
over `site`, which is unaffected.

### H2: `dmoj/mathoid/Dockerfile`

Rewrite to build mathoid from its actual maintained source, pinned to a
specific commit, instead of installing an abandoned npm package:

```dockerfile
FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    git clone https://gitlab.wikimedia.org/repos/mediawiki/services/mathoid.git /node_modules/mathoid && \
    cd /node_modules/mathoid && \
    git checkout 3eeedbb879dd2316eac7d0c0b8a5da02c6601050 && \
    rm -rf .git && \
    npm ci --omit=dev && \
    ln -sfv /node_modules/mathoid/app.js /node_modules/app.js

EXPOSE 10044
WORKDIR /node_modules/mathoid
CMD /node_modules/mathoid/server.js
```

Key decisions:
- **Clone pinned to a commit, not a submodule.** Matches the existing
  `pdfoid`/`texoid` pattern (clone inside the Dockerfile, nothing checked
  into this repo's git tree) — just adding a pin where those two currently
  float on upstream `HEAD`. No `.gitmodules` entry, no persistent checked-out
  copy to maintain; bumping the mathoid version later is a one-line SHA edit
  in the Dockerfile, same effort as bumping the `FROM node:` tag.
- **`npm ci --omit=dev`, not `npm install`.** Uses the `package-lock.json`
  already committed in mathoid's own repo — reproducible, integrity-checked
  install, eliminating the unpinned-transitive-dependency drift that caused
  H2's underlying instability.
- **`rm -rf .git`** after checkout — drops the cloned repo's git history from
  the image layer (not needed at runtime, keeps the image smaller).
- **`git`/`ca-certificates` installed via apt** — `node:24-bookworm` does not
  include `git` by default; same requirement `pdfoid`/`texoid` already have
  and handle the same way.
- **`CMD` and `EXPOSE` unchanged** — `server.js` still exists at the cloned
  repo's root with the same `#!/usr/bin/env node` shebang; the existing
  bind-mount `./mathoid/config.yaml:/node_modules/mathoid/config.yaml`
  (`dmoj/docker-compose.yml`) continues to work unchanged, overwriting the
  cloned repo's own `config.yaml` (which is a symlink to `config.dev.yaml`
  in the new source) with the already-used local config.
- **New build-time dependency:** network access to `gitlab.wikimedia.org`
  during `docker compose build`. Not a new category of requirement — `base`
  already fetches from `deb.nodesource.com`, and `pdfoid`/`texoid` already
  clone from `github.com` at build time.

## Out of scope

- All Medium/Low findings from the audit (pdfoid `SYS_ADMIN`, tracked
  `.env` files, read-write `repo/` mounts, texoid/pdfoid unpinned clones,
  missing TLS, base image `curl | bash` / EOL Node 16, Redis auth, etc.) —
  separate follow-up specs.
- Whether `scripts/doctor`'s existing mathoid failure is fully resolved by
  this change — expected to improve (root cause addressed), confirmed via
  testing below, but not the primary goal of this spec.
- Any change to `pdfoid`/`texoid`'s own unpinned-clone pattern — noted as
  precedent here, not fixed here.

## Testing / verification

- `docker compose build bridged judge-tier3-1` still succeeds; no service
  definition errors from the compose file changes.
- `docker compose up -d` — `judge-tier3-1` still reaches `bridged` and shows
  `online: true` via `./scripts/judge_status` (confirms removing `bridged`'s
  host port publish and `nginx` network membership didn't break the
  judge-to-bridged path, which was always over `site`).
- `ss -tlnp` (or `docker compose port bridged 9999`, expected to fail/empty)
  on the host confirms port `9999` is no longer listening on `0.0.0.0`.
- `docker compose build mathoid` succeeds using `node:24-bookworm` and
  `npm ci` (no dependency resolution errors).
- `docker compose up -d mathoid` — container starts and stays up (no crash
  loop).
- Functional smoke test: POST a sample TeX snippet (e.g. `E=mc^2`) to
  mathoid's `/` endpoint (via `docker compose exec` curl from another
  container on the `site` network, e.g. `curl -X POST -d 'q=E=mc^2' -d
  'type=tex' http://mathoid:10044/`) and confirm a successful SVG/MathML
  response, not just that the container is running.
- `./scripts/doctor` — check whether the mathoid check now passes (it was
  previously failing on a Node/commander incompatibility); document the
  result either way.
