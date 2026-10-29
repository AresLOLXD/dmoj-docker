# Proposal

## Why

`./scripts/update` restarts `site`, `celery` and `bridged` on the new code and only then runs `migrate`, with no backup. For the coming Django 5.2 bump this is unsafe: social-auth 5.0.0 -> 7.2.0 makes the first `migrate` apply `social_django` 0011-0022, several of which rewrite or drop data (0011 changes primary keys, 0013 and 0014 move `extra_data`, 0020 and 0021 repair identifier keys) and three have no-op reversals. MariaDB DDL is not transactional, so a failure partway leaves a half-migrated schema and restoring a backup is the only way back. Meanwhile the new code serves requests against the old schema. This blocks bumping `dmoj/repo` past `13c33119` (issue #3; together with issue #2, already committed as `432e266` and not pushed).

## What Changes

- `dmoj/scripts/update` takes a database backup (`backups/pre-update-<timestamp>.sql`) and records the current submodule commit before it changes anything. If the backup fails, it exits non-zero having touched no submodule and no container.
- The images are rebuilt first (`base`, then `site celery bridged wsevent`) without restarting anything. Then `site`, `celery` and `bridged` are stopped, migrations run in a one-off container on the freshly built `site` image, and only after `migrate` succeeds are the services started again (`wsevent` is restarted too, because it mounts `repo/`).
- If `migrate` fails, `site`, `celery` and `bridged` stay stopped, `update` exits non-zero and prints the backup path, the previous submodule commit and the manual recovery steps. Nothing is restored automatically.
- On success `update` prints the backup path so it can be restored with `./scripts/restore_db`.
- The separate "Restarting ..." step disappears: starting the stopped services is the restart.
- A stubbed-run test, `dmoj/tests/update.sh`, proves the ordering and the failure branches without Docker.
- README: the `update` description and the "migrate failed" troubleshooting paragraph describe the new behavior.

## Non-goals (what we would not build)

- No maintenance page: while `site` is stopped nginx already answers 502, which is enough for a short, operator-triggered window.
- No backup rotation or cleanup: `backups/` is gitignored and the operator prunes it.
- No automatic rollback or restore: `update` only prints the recipe and never runs `restore_db` or `git checkout`.
- No change to `backup_db`, `restore_db`, `migrate`, `docker-compose.yml` or `site-static-build`. `migrate` stays an `exec` into a running `site`; `update` uses its own one-off container because `site` is stopped at that point.
- The read-only production pre-checks are manual and NOT implemented in the script (see Impact).

## Capabilities

### New Capabilities
- `stack-update`: how `./scripts/update` upgrades a running stack: what it saves before changing anything, when the application is allowed to run during a migration, and what it leaves behind and reports on success or failure. There is no main spec for it yet, so this change introduces it.

### Modified Capabilities

## Impact

- `dmoj/scripts/update`: new step order, new output, a new way to run the migration. Anything that greps the old `== Restarting site, celery, bridged, wsevent ==` heading would stop matching; nothing in this repo does (checked in README.md, CLAUDE.md and `dmoj/scripts/`).
- Behavior change for operators: an update now needs a reachable `db` (the backup dumps it) and causes downtime for `site`, `celery` and `bridged` for the duration of the migration, by design. The backup of a large database can take a while before the update starts.
- New file `dmoj/tests/update.sh`; README text updated. No dependencies, images or compose changes.
- Superseded and to be deleted at the end of this change (authorized by the maintainer, both untracked): `docs/superpowers/plans/2026-09-04-update-rollback-safety-net.md` and `docs/superpowers/specs/2026-09-04-update-rollback-safety-net-design.md`.
- Manual pre-deploy checklist for the maintainer, on the production database (read-only), before the first Django 5.2 deploy:
  - `SELECT VERSION();` (production is `mariadb:12.3`; Django 5.2 was only tested against 11.8.8).
  - `SELECT provider, COUNT(*) FROM social_auth_usersocialauth GROUP BY provider;` (empty means the data migrations are moot).
  - `SELECT COUNT(*) FROM social_auth_usersocialauth WHERE uid = '';` must return 0.
  - Rehearse the migration once on a restored copy of a backup with the same `mariadb:12.3` image.
