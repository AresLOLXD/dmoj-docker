# Proposal

## Why

`./scripts/update` stops `site`, `celery` and `bridged` before it finds out whether the image it just built can run the new code. In a rehearsal on the maintainer's laptop (rootless podman) the builder resolved `FROM ninjaclasher/dmoj-base:latest` against the registry instead of the base that had just been built: the digest used (`sha256:c8c3e335...`) was not the local base (`sha256:05535cb3...`). `site`, `celery` and `bridged` came out with Django 4.2.30 and webauthn 0.4.7, while the fork's code needs Django 5.2 and `webauthn>=3`. The script only noticed at `migrate`, after the stop: `manage.py migrate` died at import time (`ImportError: cannot import name 'verify_authentication_response' from 'webauthn'`, `judge/forms.py:16`) and the app stayed down until the recovery recipe was run. With the images built correctly, the same migration passed on a restored copy of the production database.

The production builder is `default` with driver `docker` (checked by the maintainer with `docker buildx ls`), the ordinary setup where `FROM` uses the local image store, so production is probably not affected. A bad image should still stop the update before anything is stopped, and the check costs one short container run.

## What Changes

- After the images are built and before `docker compose stop`, `dmoj/scripts/update` runs Django's system check in a one-off container of the freshly built `site` image (`docker compose run --rm --no-deps ... --entrypoint python3 site manage.py check`), under the heading `== Checking the new site image ==`.
- If that check fails, `update` exits non-zero without stopping, migrating or starting anything. It prints that the new image failed the check and that nothing was stopped, the backup path, and the command that realigns the source with the running containers (`git -C repo checkout <previous commit>`), which it does not run itself.
- `dmoj/tests/update.sh` gains two cases for this: the failure branch and the ordering (builds, check, stop, migrate, start).
- README: one sentence in "Updating The Site" says the image is checked before the app is stopped.

## Non-goals (what we would not build)

- No fix for the root cause of the wrong `FROM` resolution. The likely fix is compose `additional_contexts` mapping `ninjaclasher/dmoj-base:latest` to `service:base`; it changes the image build contract (`docker-compose.yml`), so it deserves its own change. It is the recommended follow-up.
- No forcing or detection of the builder (`BUILDX_BUILDER`, `docker buildx` inspection).
- No assertion of installed package versions against `uv.lock`. `manage.py check` catches code that cannot import with the installed dependencies; it does not catch an image that is stale but still compatible.
- No change to the backup step, the stop/migrate/start order, `backup_db`, `restore_db`, `migrate`, `docker-compose.yml`, or the contents of the recovery recipe.
- No automatic realignment of the submodule after a failed check.
- No change to which commit the recovery recipe prints (see design.md, Decision 5).

## Capabilities

### New Capabilities

### Modified Capabilities
- `stack-update`: adds a requirement that the freshly built `site` image is checked before the application is stopped. No existing requirement changes.

## Impact

- `dmoj/scripts/update`: one new step between the build and the stop. When the image is fine the only difference for the operator is one extra short container run and its heading.
- `dmoj/tests/update.sh`: two new cases; the existing four stay as they are.
- `README.md`: one sentence.
- Evidence: the rehearsal log shows the stale-base build and the late `ImportError`; the maintainer's `docker buildx ls` on the production server shows `default*` with driver `docker`, so the production exposure is unconfirmed rather than known. The maintainer should still compare `pip list` of the freshly built `site` image on the server before the first Django 5.2 deploy.
- Unblocks deploying the Django 5.2 bump with one fewer way to end with the app down.
