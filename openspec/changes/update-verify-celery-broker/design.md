# Design

## Context

See proposal.md. The existing guard is one `docker compose run --rm --no-deps $COMPOSE_EXEC_FLAGS --entrypoint python3 site manage.py check` with an abort block that prints the error, `Backup: <path>` and the checkout command, and exits 1. The `celery` image is `base` plus `ENTRYPOINT celery -A dmoj_celery worker ...`; the `celery` service mounts the same read-only `repo/`, has `working_dir: /site/`, reads `mysql.env` and `site.env`, and is on the `site` and `db` networks, where Redis lives.

Reproduced on 2026-11-10 in a scratch Python 3.13 environment with the locked dependencies and the compose Redis image (`redis:8.8-alpine`): with redis-py 5.2.1, `Connection(url).ensure_connection(max_retries=1)` raises `VersionMismatch`; with 6.4.0 it connects. Its failure point (`Channel.__init__`) is the one in the production traceback.

## Goals / Non-Goals

**Goals:** an update whose new `celery` image cannot reach the broker aborts before anything is stopped.
**Non-Goals:** see proposal.md.

## Decisions

1. **Open the broker connection, do not start a worker.** `python3 -c "from dmoj_celery import app; app.connection_for_read().ensure_connection(max_retries=1, timeout=10)"`, run with `--entrypoint python3` in the `celery` service. It uses the app's own configuration (`CELERY_BROKER_URL` from `local_settings.py`), so it follows the real setting. Alternatives: `celery ... worker` for a few seconds (steals queued tasks; rejected); `celery inspect ping` (needs a running worker, so it only works after the start, which is what `doctor` already is); importing `kombu.transport.redis` and comparing versions by hand (re-implements kombu's own rule and misses other causes).
2. **Run it in the `celery` service, not the `site` one.** The two images share `base`, so either would work today, but the `celery` service carries the worker's environment, mounts and networks, and stays correct if the images diverge.
3. **Same position and same abort contract as the `site` check:** after the build, before the stop, nothing started, submodule left updated, three-line recovery output. The shared output goes into a function `abort_before_stop "<what failed>"` defined above the checks, so the second check does not copy the first.
4. **Bound it.** `max_retries=1` and a `timeout` keep a stopped Redis from hanging the update; the failure message names Redis as a possible cause.

## Risks / Trade-offs

- [The first real run is in production; the stubbed test cannot prove the `python3 -c` line works inside the container] → the line was exercised in the scratch environment against a real Redis; the first `./scripts/update` after merge is the live check, and its failure mode is an abort before the stop, which is safe.
- [`ensure_connection` creates a channel but publishes nothing, so a later broker problem (permissions, memory) is not covered] → accepted: the goal is the start-up failure that happened.
- [Redis not running makes the check fail and blocks an otherwise good update] → intended: with Redis down the worker would also fail to start; the message points at it.
