# stack-update Specification

## Purpose
Defines how `./scripts/update` upgrades a running stack safely: what it saves before changing anything, when the application may run while the database schema changes, and what it leaves behind and reports on success or failure.

## Requirements

### Requirement: A database backup precedes every change
The update SHALL take a database backup into a timestamped file before it updates the submodule or touches any container. If the backup fails, the update SHALL exit non-zero without updating the submodule and without running any `docker compose` command that changes containers or images.

#### Scenario: A failed backup aborts before anything changes
- **WHEN** the backup step fails, and `./scripts/update` runs
- **THEN** it exits non-zero, prints an error saying the pre-update backup failed, and the submodule update, the image builds, the stop and the migration were not invoked
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS backup failure aborts before any change'` exits 0

### Requirement: The application does not run during the migration
The update SHALL stop `site`, `celery` and `bridged` before it runs migrations, SHALL run the migrations in a one-off container built from the freshly built `site` image, and SHALL start the services again only after the migrations succeed.

#### Scenario: Services are stopped before the migration and started after it
- **WHEN** the backup, submodule update and image builds succeed, and `./scripts/update` runs
- **THEN** `stop site celery bridged` happens before the migration command, `up -d` happens after it, and the migration is not run through `exec` on a running `site`
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS stop precedes migrate and up follows it'` exits 0

### Requirement: A failed migration leaves the application stopped
If the migration fails, the update SHALL exit non-zero, SHALL NOT start `site`, `celery` or `bridged`, and SHALL NOT restore the database or change the submodule by itself. It SHALL print the backup path, the submodule commit that was checked out before the update, and the manual steps to go back.

#### Scenario: The recovery recipe is printed and nothing is restarted
- **WHEN** the migration command fails, and `./scripts/update` runs
- **THEN** it exits non-zero, `up -d` was never invoked, and the error output contains the backup path, the previous submodule commit and the commands `git -C repo checkout`, `./scripts/restore_db` and `docker compose up -d`
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS migrate failure keeps the stack stopped and prints the recipe'` exits 0

### Requirement: A successful update reports the backup path
When the update succeeds, it SHALL print the path of the pre-update backup so it can be restored with `./scripts/restore_db`.

#### Scenario: The backup path is printed at the end
- **WHEN** every step succeeds, and `./scripts/update` runs
- **THEN** it exits 0 and the last lines of the output contain the backup path and mention `./scripts/restore_db`
- **CHECK** `bash dmoj/tests/update.sh | grep -F 'PASS success prints the backup path'` exits 0
