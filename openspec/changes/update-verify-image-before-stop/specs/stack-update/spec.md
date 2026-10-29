# Spec Delta

## ADDED Requirements

### Requirement: The new site image is checked before the application is stopped
After building the images and before stopping any service, the update SHALL run Django's system check in a one-off container of the freshly built `site` image. If the check fails, the update SHALL exit non-zero without stopping, migrating or starting anything, SHALL NOT change the submodule by itself, and SHALL print the backup path and the command that realigns the source with the running containers.

#### Scenario: A failing image check aborts before the stop
- **WHEN** the backup, submodule update and image builds succeed but the system check fails, and `./scripts/update` runs
- **THEN** it exits non-zero, `stop`, the migration, `up -d` and `restart` were never invoked, and the error output says the new site image failed the check and nothing was stopped, and contains the backup path and `git -C repo checkout` with the previous commit
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS image check failure aborts before the stop'` exits 0

#### Scenario: The check runs after the builds and before the stop
- **WHEN** every step succeeds, and `./scripts/update` runs
- **THEN** the image builds happen before the system check, the system check happens before `stop site celery bridged`, and the migration and `up -d` follow in that order
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS image check precedes the stop'` exits 0
