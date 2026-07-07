# Security audit Medium quick wins: .env gitignore + repo/ read-only

Date: 2026-07-07

## Context

First sub-project of the Medium-severity findings from the Docker-setup
security audit (see the High-findings spec/plan for the audit history:
`docs/superpowers/specs/2026-07-07-security-audit-high-findings-design.md`).
The remaining Medium/Low findings (pdfoid `SYS_ADMIN` + unpinned clone,
texoid unpinned clone + root user, missing TLS, base image `curl | bash` +
EOL Node) are independent subsystems and will each get their own
spec/plan later — not covered here.

This spec covers the two lowest-risk, fastest fixes:

- **M2:** `dmoj/environment/*.env` files are tracked in git with no
  `.gitignore` entry — the moment an operator fills in real production
  secrets (DB password, Django `SECRET_KEY`), a routine `git add -A` /
  `git commit` would commit them into history.
- **M3:** `./repo/:/site/` is bind-mounted read-write into `site`, `celery`,
  and `bridged` — all long-lived services, one directly internet-facing via
  nginx (`site`). An RCE in any of these lets an attacker rewrite the shared
  application source on disk, propagating a backdoor to the other two
  services and surviving container restarts.

## M2: `.env` files out of git

1. Rename (git `mv`) the three currently-tracked files to templates,
   content unchanged (still placeholder values — no real secrets exist in
   git history to worry about):
   - `dmoj/environment/mysql.env` → `dmoj/environment/mysql.env.example`
   - `dmoj/environment/mysql-admin.env` → `dmoj/environment/mysql-admin.env.example`
   - `dmoj/environment/site.env` → `dmoj/environment/site.env.example`
2. Add `dmoj/environment/*.env` to `.gitignore` (the `.example` files
   remain tracked; the real, potentially-secret-filled files do not).
3. `dmoj/scripts/initialize` gains a step that copies (not moves — the
   template must stay in git for future reference/reset) each
   `.env.example` to its real name, only if the real file doesn't already
   exist (idempotent, non-destructive — matches the existing pattern for
   `config.js`/`local_settings.py`/`uwsgi.ini`, but with `cp` instead of
   `mv` since these templates live inside `dmoj/environment/`, not at the
   repo root, and should persist in git rather than being moved away).

## M3: `repo/` read-only for site/celery/bridged, with a writable path for static builds

`scripts/copy_static` (`make_style.sh`, `collectstatic`,
`compilemessages`, `compilejsi18n`) writes generated files directly into
the `repo/` tree before copying selected outputs to the `assets` volume —
this must keep working, so a blanket read-only mount would break it.

1. **`dmoj/docker-compose.yml`:** change `./repo/:/site/` to
   `./repo/:/site/:ro` on the `site`, `celery`, and `bridged` services
   (their only volume-mount change — nothing else in these three services'
   definitions changes).
2. **New anchor + one-off service** for static builds:
   ```yaml
   x-site-static-base: &site-static-base
     build:
       context: .
       dockerfile: ./site/Dockerfile
     image: ninjaclasher/dmoj-site
     working_dir: /site/
     env_file: [environment/mysql.env, environment/site.env]

   services:
     site-static-build:
       <<: *site-static-base
       profiles: ["tools"]
       volumes:
         - assets:/assets/
         - ./repo/:/site/:rw
       networks: [site]
   ```
   `profiles: ["tools"]` excludes this service from `docker compose up` /
   `up -d` entirely (with or without `--build`) — it only ever runs via an
   explicit `docker compose run --rm site-static-build ...`, never
   alongside the always-on stack. It needs no `db`/`nginx` network, no
   `depends_on`, and no `restart` policy — it's a short-lived, on-demand
   container that only touches the local filesystem (`collectstatic`,
   `compilemessages`, `compilejsi18n`, and `make_style.sh` are pure
   filesystem operations; they don't query the database).
3. **`dmoj/scripts/copy_static`:** replace
   `docker compose exec $COMPOSE_EXEC_FLAGS site /bin/bash -c "..."` with
   `docker compose run --rm $COMPOSE_EXEC_FLAGS site-static-build /bin/bash -c "..."`
   — the inner command string (the `make_style.sh && collectstatic && ...`
   chain) is unchanged.
4. **`dmoj/scripts/migrate`** is unaffected — `manage.py migrate` only
   writes to the database, never to the filesystem, so it keeps running
   against the normal (now read-only) `site` container without any change.

## Out of scope

- All other Medium/Low audit findings (pdfoid, texoid, TLS, base image) —
  separate specs.
- Any change to `judge-tier3-1`'s existing read-only problem/config mounts
  (already correct, established precedent this spec follows).
- Rotating any already-deployed real secrets — not applicable here since no
  real secrets have ever been committed (confirmed: current tracked `.env`
  files contain only placeholder values).

## Testing / verification

- `git status` / `git log` show the three `.env` files renamed to
  `.env.example` with identical placeholder content, and no longer appear
  as tracked `.env` files.
- `git check-ignore dmoj/environment/mysql.env` (after manually creating it
  from the template) confirms it's ignored.
- Running `./scripts/initialize` on a checkout with no existing `.env`
  files creates all three from their templates; running it again when the
  real files already exist (e.g., with filled-in secrets) does not
  overwrite them.
- `docker compose config --services` lists `site-static-build` under the
  `tools` profile (not returned by a plain `docker compose up -d` — no
  extra container starts for the default stack).
- `docker compose up -d` (no profile flag) — `site-static-build` does NOT
  start; `site`, `celery`, `bridged` come up as before.
- `docker compose exec site touch /site/test-write-should-fail` (or
  equivalent inside `celery`/`bridged`) fails with a read-only-filesystem
  error, confirming the `:ro` mount is in effect on all three.
- `./scripts/copy_static` (using the new `site-static-build` one-off
  service) completes successfully end-to-end — same verification as the
  live run already performed in this session: compiled CSS (light + dark)
  and translations land in the `assets` volume.
- `./scripts/migrate` still runs successfully against the (now read-only)
  `site` container.
