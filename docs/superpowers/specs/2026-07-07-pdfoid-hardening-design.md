# pdfoid hardening: SYS_ADMIN documentation + pin clone/chromedriver/apt-key

Date: 2026-07-07

## Context

Second sub-project of the Medium-severity findings from the Docker-setup
security audit (first was `docs/superpowers/specs/2026-07-07-security-audit-medium-quickwins-design.md`,
covering M2/M3). This one covers pdfoid's two findings:

- **M1:** `pdfoid` is granted `cap_add: SYS_ADMIN` (`dmoj/docker-compose.yml`)
  — a broad, near-root Linux capability.
- **M5:** `dmoj/pdfoid/Dockerfile` clones `DMOJ/pdfoid` from upstream `HEAD`
  with no commit pin (non-reproducible builds), installs `google-chrome-stable`
  with no version pin, downloads chromedriver from
  `chromedriver.storage.googleapis.com/LATEST_RELEASE` — an endpoint that no
  longer serves versions matching current Chrome releases — and trusts
  Google's apt signing key via the deprecated global `apt-key add` command.

### M1 investigation

Read `DMOJ/pdfoid`'s source (`pdfoid/backends/direct.py`, pinned commit
`55ebc64794d6531fc2837db28869e1b7c6cc6894`): it drives headless Chrome via
Selenium and only passes `--headless` to `ChromeOptions` — never
`--no-sandbox`. This means Chrome's own internal sandbox (which uses a
setuid helper binary requiring `CAP_SYS_ADMIN` under most kernel/container
configurations) is genuinely active, not a leftover/unused grant. The
existing mitigation — pdfoid's container already runs as a non-root user
(`USER pdfoid` in the Dockerfile) — meaningfully limits what that capability
can do in practice, which is why the audit rated this Medium rather than
High.

Two ways to actually remove the `SYS_ADMIN` requirement were considered and
explicitly rejected for this spec:
- Force `--no-sandbox` (e.g. via a wrapper script substituted for
  `CHROME_PATH`, which pdfoid already reads from the environment) — this
  would let `SYS_ADMIN` be dropped entirely, but disables Chrome's own
  internal renderer sandbox, relying solely on the outer container's
  isolation. This is standard practice for containerized headless Chrome,
  but it's a real reduction in defense-in-depth and a behavior change to
  pdfoid's Chrome invocation.
- A custom seccomp profile scoping the capability's effective syscalls —
  meaningfully more engineering effort and risk of subtly breaking Chrome
  if the profile is too restrictive, for uncertain benefit over the
  existing non-root mitigation.

Decision: neither is done here. This spec only documents why `SYS_ADMIN` is
required, so it isn't later mistaken for an oversight or copied elsewhere
without the same justification.

## Change

### M1: Document `SYS_ADMIN` in `dmoj/docker-compose.yml`

Add a comment directly above pdfoid's `cap_add: SYS_ADMIN` line:

```yaml
    # SYS_ADMIN is required because pdfoid does not pass --no-sandbox to
    # Chrome (see DMOJ/pdfoid's backends/direct.py) — Chrome's own internal
    # sandbox is active and needs this capability. Mitigated by pdfoid
    # running as a non-root user (see pdfoid/Dockerfile's `USER pdfoid`).
    cap_add:
      - SYS_ADMIN
```

No functional change — comment only.

### M5: Rewrite `dmoj/pdfoid/Dockerfile`

```dockerfile
FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl gnupg git unzip xvfb libxi6 libgconf-2-4 exiftool && \
    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google-chrome.list && \
    sed -i 's/^Components: main$/& contrib non-free/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        google-chrome-stable=150.0.7871.100-1 fonts-noto ttf-mscorefonts-installer && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://storage.googleapis.com/chrome-for-testing-public/150.0.7871.49/linux64/chromedriver-linux64.zip -o chromedriver_linux64.zip && \
    unzip chromedriver_linux64.zip && \
    mv chromedriver-linux64/chromedriver /usr/bin/chromedriver && \
    chmod +x /usr/bin/chromedriver && \
    rm -rf chromedriver_linux64.zip chromedriver-linux64 && \
    useradd -m pdfoid

RUN git clone https://github.com/DMOJ/pdfoid.git pdfoid && \
    cd pdfoid && git checkout 55ebc64794d6531fc2837db28869e1b7c6cc6894 && rm -rf .git
WORKDIR /pdfoid/
RUN pip3 install -e .

ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver
ENV EXIFTOOL_PATH=/usr/bin/exiftool

EXPOSE 8888
USER pdfoid
ENTRYPOINT pdfoid --address=pdfoid --port=8888
```

Key decisions:
- **`apt-key add` → `signed-by=` keyring.** `apt-key add` adds Google's key
  to the *global* trusted keyring, letting it sign packages from any
  configured repo, not just Google's own. Replaced with a keyring file at
  `/etc/apt/keyrings/google-chrome.gpg`, referenced via `signed-by=` in the
  sources-list entry — scoped to only that one repo.
- **`google-chrome-stable` pinned to `150.0.7871.100-1`** — the exact
  version currently published in Google's apt repo (confirmed via its
  `Packages` index), instead of always resolving to "whatever's newest at
  build time."
- **chromedriver sourced from Chrome for Testing, pinned, not the broken
  legacy endpoint.** `chromedriver.storage.googleapis.com/LATEST_RELEASE`
  no longer serves versions matching current Chrome releases. Google's
  Chrome for Testing project (`googlechromelabs.github.io/chrome-for-testing`)
  publishes an authoritative JSON manifest of Chrome+chromedriver version
  pairs confirmed compatible together; its designated "last known good
  Stable" pairing is `150.0.7871.49` — same `7871` build branch as the
  pinned apt Chrome version (`150.0.7871.100`), just a slightly earlier
  patch, which is standard practice for chromedriver/Chrome pairing (exact
  patch-level match is not required for compatibility). The download URL
  (`https://storage.googleapis.com/chrome-for-testing-public/...`) is a
  permanent, versioned archive, unlike the deprecated `LATEST_RELEASE`
  redirect.
- **`git clone` pinned to a commit, `.git` removed after checkout** —
  matches the pattern already established for mathoid and texoid in this
  repo (clone-in-Dockerfile, pinned to a specific commit, no submodule).
- **Why apt for Chrome instead of also pulling Chrome itself from Chrome
  for Testing:** Chrome's `.deb` package declares ~25 shared-library
  dependencies (`libnss3`, `libgtk-3-0`, `libatk-bridge2.0-0`, etc.) that
  apt resolves and installs automatically. Chrome for Testing only ships a
  self-contained `chrome-linux64.zip` with no dependency manifest —
  reconstructing that list by hand to install it standalone would be a
  meaningfully riskier, harder-to-verify change than keeping the
  well-tested apt-install path and only fixing its three concrete problems
  (key trust, version pin, chromedriver source).

## Out of scope

- Removing `SYS_ADMIN` entirely (would require `--no-sandbox` or a custom
  seccomp profile — explicitly deferred, see M1 investigation above).
- All other Medium/Low audit findings (texoid, TLS, base image) — separate
  specs.
- Any change to pdfoid's own Python source or its Selenium/Chrome
  invocation logic.

## Testing / verification

- `docker compose build pdfoid` (via `podman compose build pdfoid` on this
  host) succeeds — apt resolves the pinned Chrome version, the signed-by
  keyring is accepted without warnings/errors, chromedriver downloads from
  the pinned Chrome for Testing URL, and the pinned pdfoid commit clones
  and installs successfully.
- `podman compose up -d pdfoid` — container starts and stays up (no crash
  loop).
- Functional smoke test: send a real HTML-to-PDF render request to
  pdfoid's `/` endpoint (via `podman compose exec` curl from another
  container on the `site` network, e.g. a small HTML snippet) and confirm
  a valid PDF is returned (non-empty response with a PDF magic-byte
  header), not just that the container is running.
- `podman compose exec pdfoid google-chrome-stable --version` shows
  `150.0.7871.100`; `podman compose exec pdfoid chromedriver --version`
  shows `150.0.7871.49`.
- `docker-compose.yml`'s pdfoid block shows the new comment directly above
  `cap_add: SYS_ADMIN`, with no other change to that service's
  capabilities, networks, or volumes.
