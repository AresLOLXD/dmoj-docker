# Design

## Context

The fork's `dmoj/settings.py` defines `WEBAUTHN_RP_ID = None`. While it is falsy, the WebAuthn views answer 404 (`judge/views/two_factor.py:138`) and `HAS_WEBAUTHN` is false in the templates (`judge/template_context.py:66`). The template this repo ships (`local_settings.py` at the root) defines `HOST = os.environ.get('HOST', '')` and `ALLOWED_HOSTS = [HOST]`. `scripts/initialize` copies the template into `dmoj/repo/dmoj/local_settings.py` once, on first-time setup, and the copy inside the submodule is untracked, so editing the template never changes an existing install. The browser's `Host` header already reaches Django unchanged (`uwsgi_pass` plus `include uwsgi_params`), and the site builds the expected origin from `request.get_host()`. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- A new install gets WebAuthn enabled for its `HOST` without editing the template.
- The relying-party id has the same value the site is already configured to serve.

**Non-Goals:**
- Everything listed under Non-goals in proposal.md.

## Decisions

**1. An active line `WEBAUTHN_RP_ID = HOST`, right after the `ALLOWED_HOSTS = [HOST]` block, with a short comment.** The line must come after `HOST` is defined, and next to `ALLOWED_HOSTS` it sits with the other setting that consumes `HOST`. The comment says the value is the relying-party id, must be the bare lowercase public hostname with no scheme or port, and that an empty value keeps WebAuthn disabled. *(Agent's call on placement and wording; the line itself is what the issue prescribes.)* Alternative considered: a commented-out example, so a new install keeps WebAuthn off until its owner opts in. Rejected because the maintainer's issue asks for the active line, and an empty `HOST` already gives the opt-out.

**2. The shipped placeholder `HOST=<host>` makes the setting truthy but meaningless.** With `site.env.example`'s placeholder the feature would look enabled while no browser accepts the id. This is accepted and not guarded: an install has to set a real `HOST` for `ALLOWED_HOSTS` anyway, and a guard would be code for a configuration that does not work for other reasons. *(Agent's call.)*

**3. The live server file is changed by hand, not from this repo.** The file inside the submodule is untracked, so the maintainer adds the same line there, restarts `site`, and verifies with `docker compose exec -T site python3 manage.py shell -c ...`. The issue's own check, `./scripts/manage.py shell -c "..."`, does not work as written because `scripts/manage.py` passes `$@` unquoted and splits the quoted code; the steps in tasks.md use `docker compose exec` directly. *(Agent's call on the commands; the timing and the account to enrol first stay with the maintainer.)*

**4. README gets a short note, under Notes, after the TLS / HTTPS section.** It covers what controls the feature, that keys must be enrolled only through the public hostname, the rollout advice from the issue (keep TOTP as the fallback until keys have been used for a while; unsetting the setting makes the endpoints 404 again and locks out any account whose only 2FA is a key), and that nginx and the proxy need no change (no `USE_X_FORWARDED_HOST`, no `httpHostHeader` in a Cloudflare tunnel). *(Agent's call on the placement.)*

**5. The checks are three one-liners on the template.** One for the line, one for the order of `HOST` and the new line, and one that runs the head of the template with a real `HOST` and asserts the value. They fail on the current template and pass once the line exists; each was run against a temporary copy of the template before it went into the spec.

## Risks / Trade-offs

- [Enrolment through another host (`127.0.0.1:8080`, a Tailscale name) is rejected: with `ALLOWED_HOSTS = [HOST]` those requests get a 400, and browsers refuse a relying-party id on an IP address or an unrelated domain] -> README says enrolment only works through the public hostname.
- [Keys are bound to the exact `WEBAUTHN_RP_ID` string, so changing `HOST` (a domain move, a typo in `site.env`) has the same effect as unsetting it: every enrolled key stops working and key-only accounts are locked out] -> README and the template comment say so; keep TOTP until keys have been used for a while.
- [An uppercase `HOST` passes `ALLOWED_HOSTS` but the relying-party id would not match the lowercase value browsers use, so enrolment fails with an opaque error] -> The template comment says "lowercase"; no `HOST.lower()` guard (found in review, deferred).
- [Unsetting `WEBAUTHN_RP_ID` after keys exist locks out accounts whose only 2FA is a key, because keys have no scratch codes] -> README says to keep TOTP until keys have been used for a while.
- [A new install with the placeholder `HOST` shows WebAuthn enabled but no key can be enrolled] -> Decision 2; the install needs a real `HOST` to serve anything.
- [The agent cannot test the browser flow or a hardware key] -> Listed in proposal.md under Impact; the maintainer enrols the first key with a staff account that keeps TOTP.
