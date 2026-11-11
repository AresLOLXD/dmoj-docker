# Spec Delta

## ADDED Requirements

### Requirement: The new celery image is checked against the broker before the application is stopped
After the new site image check and before stopping any service, the update SHALL open the Celery broker connection once from a one-off container of the freshly built `celery` image, without starting a worker. If that fails, the update SHALL exit non-zero without stopping, migrating or starting anything, and SHALL print which check failed, the backup path and the command that realigns the source with the running containers.

#### Scenario: A failing broker check aborts before the stop
- **WHEN** the backup, submodule update, builds and site image check succeed but the broker connection check fails, and `./scripts/update` runs
- **THEN** it exits non-zero, `stop`, the migration, `up -d` and `restart` were never invoked, and the error output says the new celery image could not reach the broker and nothing was stopped, and contains the backup path and `git -C repo checkout` with the previous commit
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS broker check failure aborts before the stop'` exits 0

#### Scenario: The broker check runs after the site check and before the stop
- **WHEN** every step succeeds, and `./scripts/update` runs
- **THEN** the broker check call is recorded after the `manage.py check` call and before the `stop` call
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS broker check runs after the site check and before the stop'` exits 0

#### Scenario: The check opens the connection without starting a worker
- **WHEN** `./scripts/update` runs
- **THEN** the broker check invokes the Celery app's connection and never the `celery ... worker` command
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS broker check opens a connection and starts no worker'` exits 0
