# Tasks

The tasks are tiny, so groups 1 and 2 can be done directly from this file; no separate plan is needed.

## 1. The settings template

- [ ] 1.1 In the root `local_settings.py`, add `WEBAUTHN_RP_ID = HOST` right after the `ALLOWED_HOSTS = [HOST]` line and before the `# Optional apps` comment, with the short comment from design.md Decision 1. Verify: the three CHECK commands in `specs/site-settings-defaults/spec.md` exit 0 (run from the repo root) and `python3 -c "import ast;ast.parse(open('local_settings.py').read())"` exits 0.

## 2. README

- [ ] 2.1 Add a "Security keys (WebAuthn)" section under Notes, after "TLS / HTTPS", with the content from design.md Decision 4. Verify: `grep -n 'WEBAUTHN_RP_ID' README.md` shows the section, and every command and setting name quoted there matches `local_settings.py` and `scripts/` as they are.

## 3. Integration checks

- [ ] 3.1 Confirm nothing outside the plan changed: `git diff --stat` lists only `local_settings.py`, `README.md` and this change's files, and `cd dmoj && docker compose config -q` exits 0.
- [ ] 3.2 Produce the Scenario-to-check report for this change. Verify: each of the three Scenarios maps to a check that was run, and the only check that maps to no Scenario is the `docker compose config -q` guard in 3.1, reported as such.

## Workflow follow-up

- On each server, when the maintainer chooses (the repo does not do this): add `WEBAUTHN_RP_ID = HOST` after `ALLOWED_HOSTS = [HOST]` in `dmoj/repo/dmoj/local_settings.py` (keep a copy of the file outside the repo first), then `sudo docker compose restart site` from `dmoj/`.
- Verify on the server: `sudo docker compose exec -T site python3 manage.py shell -c "from django.conf import settings; print(settings.WEBAUTHN_RP_ID)"` prints the public hostname, and `sudo docker compose exec -T site python3 -c "import importlib.metadata as m; print(m.version('webauthn'))"` prints `3.0.1`.
- Enrol the first key through the public hostname with a staff account that keeps TOTP enabled: the "Add" button for a security key on the profile edit page, then log out and log in with the key. Not tested by the agent.
- Archive with `/opsx:archive` only after verify is clean, in the same push as the code.
