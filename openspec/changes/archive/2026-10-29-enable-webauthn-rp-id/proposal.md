# Proposal

## Why

Security-key (WebAuthn) 2FA is off on the live site and nobody can enrol a key, even though the code that supports it is deployed. The fork defaults `WEBAUTHN_RP_ID` to `None`, every WebAuthn view answers 404 while it is falsy, and the settings template this repo ships does not set it (issue #4). Staff who want a YubiKey need it set. The hazard the issue names (enabling it on the old, abandoned `webauthn` 0.4.7 code) no longer applies: production has run webauthn 3.0.1 on Django 5.2.18 since 2026-10-29 and the submodule pin of this repo points at that fork commit (`6bb58d7`).

## What Changes

- The root `local_settings.py` template sets `WEBAUTHN_RP_ID = HOST`, right after the `ALLOWED_HOSTS = [HOST]` block, with a short comment saying what the value must be.
- `README.md` gets a short "Security keys (WebAuthn)" note under Notes: what controls it, how to enrol, the fallback advice and what not to change in nginx or the proxy.

## Non-goals (what we would not build)

- No change to the live server file. `dmoj/repo/dmoj/local_settings.py` is untracked inside the submodule, so the maintainer adds the same line by hand on each server, when they choose; the exact steps are in tasks.md.
- No change for any particular account and no forced 2FA: `DMOJ_REQUIRE_STAFF_2FA` is not touched.
- No nginx, proxy or Cloudflare tunnel change.
- No validation that `HOST` is a well-formed hostname.
- No change to the fork's default (`None`) or to any fork code.
- No change to the TOTP flow and no key-management feature.

## Capabilities

### New Capabilities
- `site-settings-defaults`: what the settings template this repo ships turns on by default. There is no main spec for it yet, so this change introduces it with the requirement it touches.

### Modified Capabilities

## Impact

- `local_settings.py` (template), `README.md` and the OpenSpec files change. Nothing else.
- Existing installs see no effect until the maintainer copies the line into their live file: `scripts/initialize` only runs on first-time setup and never overwrites an existing `repo/dmoj/local_settings.py`. New installs get WebAuthn enabled for their `HOST`.
- Not tested by the agent: the login and 2FA pages in a browser after the 2026-10-29 deploy, and the enrolment of an actual key. The first needs a browser session on the live site and the second a hardware key, and both stay with the maintainer.
