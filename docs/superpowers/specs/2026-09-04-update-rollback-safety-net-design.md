# `scripts/update` Rollback Safety Net — Design

## Goal

Today, `dmoj/scripts/update` has no recovery path if the Django migration
step fails partway through. Worst case: the submodule has already advanced
to new code and `site`/`celery`/`bridged`/`wsevent` have already been
restarted onto it, but the database schema is old or partially migrated —
new code running against a schema it doesn't expect.

This design adds a manual safety net: `update` captures a rollback point
(submodule SHA + a DB backup) before touching anything, and on failure
prints exact, ready-to-run instructions to restore that point. It does not
attempt to roll back automatically.

## Context

- Single self-hosted deployment, one maintainer, no formal maintenance
  window, 4GB production host.
- `repo/` (the `dmoj/repo` submodule) is mounted **read-only at runtime**
  into `site`/`celery`/`bridged` — it is never baked into a Docker image.
  This means reverting code is purely a matter of reverting the submodule's
  checked-out commit and restarting the affected containers; **no image
  rebuild is needed for rollback**, even though `update` does rebuild
  images as part of the normal (forward) update path.
- The existing `./scripts/backup_db [output-path]` and
  `./scripts/restore_db <path>` scripts already do dump/restore correctly
  and are reused as-is — this design does not change backup retention,
  compression, or encryption (that's a separate, already-identified
  brainstorming topic).

## Flow

`scripts/update` gains one step at the very start, before any of its
existing steps:

1. **Capture rollback point** (new):
   - `PREV_SHA=$(git -C dmoj/repo rev-parse HEAD)`
   - `./scripts/backup_db backups/pre-update-$(date +%Y-%m-%d-%H%M%S).sql`
   - If the backup itself fails, `update` aborts immediately (exit
     non-zero) — proceeding without a rollback point defeats the purpose
     of this feature entirely.
2. Update submodule (existing step, unchanged).
3. Rebuild `base site celery bridged wsevent` (existing step, unchanged).
4. Restart `site celery bridged wsevent` (existing step, unchanged).
5. Run `./scripts/migrate` (existing step, unchanged).

On failure, the error message differs by which step failed, since the
blast radius differs:

- **Submodule update fails** (step 2): nothing was touched yet. No
  rollback needed — just report the error as today.
- **Rebuild fails** (step 3): images may be partially rebuilt, but
  containers haven't restarted yet, so they're still running the old code
  against the old schema. Print the captured SHA in case the user wants to
  `git -C dmoj/repo checkout <sha>` before retrying, but this is low-risk.
- **Restart fails** (step 4): containers may be down or crash-looping.
  Same as above — the DB schema hasn't been touched, so the SHA is enough
  to consider reverting, but this is primarily a "fix the restart problem"
  situation, not a rollback situation.
- **Migrate fails** (step 5, the critical case): new code is already
  live and the schema is old or partially migrated. Print the full
  rollback recipe:
    ```
    Error: migration failed. To roll back:
      1. git -C dmoj/repo checkout <PREV_SHA>
      2. ./scripts/restore_db backups/pre-update-<timestamp>.sql
      3. docker compose restart site celery bridged wsevent
    ```
    Exit non-zero. `update` does not run any of these three commands
    itself.

## Why not automate the restore

An automatic rollback that itself fails (e.g. `restore_db` hitting a
permissions error, or the DB container being unreachable) would leave the
system in a state that's harder to reason about than simply stopping and
handing the operator three explicit, individually-verifiable commands.
Given there's a single maintainer and no on-call rotation, a clear manual
recipe printed at the moment of failure is more reliable than an automated
path that has never been exercised against a real partial-migration
failure.

## Files touched

- `dmoj/scripts/update` — add the capture step at the start; add
  step-specific error messages (including the rollback recipe on migrate
  failure).

No other script changes. `backup_db`/`restore_db` are called, not
modified.

## Testing

Production is remote and this can't be safety-tested there. Verification
plan, run locally:

1. Bring up a local `db` + `site` against disposable test data.
2. Force a migration failure (e.g. temporarily add a Django migration that
   raises an error) and run the modified `update` up through the `migrate`
   step failing.
3. Confirm: the pre-update backup file exists and is non-empty, the
   printed `PREV_SHA` matches `git -C dmoj/repo rev-parse HEAD` from
   before the (test) submodule update, and the printed recipe's three
   commands, run manually, actually restore the site to a working state.
4. Revert the deliberately-broken migration used for the test; it is not
   part of this change.
