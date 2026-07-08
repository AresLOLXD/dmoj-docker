# texoid hardening: pin clone + non-root user + ImageMagick policy.xml

Date: 2026-07-07

## Context

Third sub-project of the Medium-severity findings from the Docker-setup
security audit (previous ones: `security-audit-medium-quickwins`,
`pdfoid-hardening`). This one covers texoid's M4 finding:
`dmoj/texoid/Dockerfile` clones `DMOJ/texoid` from upstream `HEAD` with no
commit pin (non-reproducible builds), runs entirely as root (no `USER`
directive), and installs ImageMagick with its default `policy.xml` —
ImageMagick's historically rich exploit surface (the "ImageTragick" class
of CVEs) when fed attacker-influenced markup, reachable here since texoid
renders LaTeX from problem statements.

### Investigation

- `DMOJ/texoid` has had no commits since 2023 — stable to pin, latest
  commit `f482221061e0d5e33296e60c77a0ead2c985f649` ("Touch up README.md").
- Read `texoid/backends/direct.py` (at the pinned commit): the render
  pipeline is `latex` → `dvisvgm` → `convert` (ImageMagick). The `convert`
  invocation is always the fixed command
  `convert -identify render.svg png:-` — it only ever reads a
  dvisvgm-produced SVG and writes a PNG to stdout. It never needs any of
  ImageMagick's other format coders or delegates (PostScript, PDF, MSL,
  URL/HTTP, etc.) — those are exactly the coders implicated in the
  ImageTragick CVE family.
- The container currently has no `useradd`/`USER` directive — everything,
  including the `convert`/`latex`/`dvisvgm` subprocess pipeline, runs as
  root. The pipeline only ever writes to a `tempfile.mkdtemp()` directory
  and reads TeX Live's installed files — nothing requires root.

## Change

### `dmoj/texoid/Dockerfile`

```dockerfile
FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        texlive-binaries texlive-latex-base texlive-latex-extra texlive-latex-recommended \
        texlive-pictures texlive-pstricks librsvg2-bin xxd imagemagick dvisvgm git && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m texoid

COPY texoid/policy.xml /etc/ImageMagick-6/policy.xml

RUN git clone https://github.com/DMOJ/texoid/ && \
    cd texoid && git checkout f482221061e0d5e33296e60c77a0ead2c985f649 && rm -rf .git
WORKDIR /texoid/
RUN pip3 install -e .

EXPOSE 8888
USER texoid
ENTRYPOINT texoid --address=texoid --port=8888
```

### New file: `dmoj/texoid/policy.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<policymap>
  <!-- Resource limits: defense-in-depth against malformed/oversized input -->
  <policy domain="resource" name="memory" value="512MiB"/>
  <policy domain="resource" name="map" value="512MiB"/>
  <policy domain="resource" name="width" value="16KP"/>
  <policy domain="resource" name="height" value="16KP"/>
  <policy domain="resource" name="area" value="128MB"/>
  <policy domain="resource" name="disk" value="1GiB"/>

  <!-- Block @filename indirection (classic ImageTragick vector) -->
  <policy domain="path" rights="none" pattern="@*"/>

  <!-- Deny the coders/delegates texoid's pipeline never uses -->
  <policy domain="coder" rights="none" pattern="PS"/>
  <policy domain="coder" rights="none" pattern="PS2"/>
  <policy domain="coder" rights="none" pattern="PS3"/>
  <policy domain="coder" rights="none" pattern="EPS"/>
  <policy domain="coder" rights="none" pattern="PDF"/>
  <policy domain="coder" rights="none" pattern="XPS"/>
  <policy domain="coder" rights="none" pattern="MSL"/>
  <policy domain="coder" rights="none" pattern="MVG"/>
  <policy domain="coder" rights="none" pattern="TEXT"/>
  <policy domain="coder" rights="none" pattern="SHOW"/>
  <policy domain="coder" rights="none" pattern="URL"/>
  <policy domain="coder" rights="none" pattern="HTTP"/>
  <policy domain="coder" rights="none" pattern="HTTPS"/>
  <policy domain="coder" rights="none" pattern="EPHEMERAL"/>
  <policy domain="coder" rights="none" pattern="MPEG"/>

  <!-- Explicitly allow only what texoid's pipeline actually uses -->
  <policy domain="coder" rights="read" pattern="SVG"/>
  <policy domain="coder" rights="write" pattern="PNG"/>
</policymap>
```

Key decisions:
- **`policy.xml` path assumed `/etc/ImageMagick-6/policy.xml`** (Debian
  bookworm's `imagemagick` package ships ImageMagick 6). This must be
  confirmed against the actual built image before merging — if the real
  path differs, update the `COPY` destination accordingly (see Testing
  section).
- **`COPY` at build time, not a runtime bind mount** — unlike
  `mathoid/config.yaml` (which the compose file bind-mounts so it can be
  edited without a rebuild), this policy is a fixed security control with
  no need for runtime reconfiguration; baking it into the image keeps the
  Dockerfile self-contained and matches how `dmoj/pdfoid`/`dmoj/texoid`
  otherwise fetch all their content at build time.
- **Explicit allow-list for SVG/PNG, explicit deny-list for the rest** —
  belt-and-suspenders: even if a future ImageMagick update adds a new
  risky coder, the default-deny posture (nothing is allowed unless listed)
  from the deny-list entries plus the narrow allow-list means new coders
  aren't implicitly trusted.
- **`useradd -m texoid` + `USER texoid`** — moved before the `git clone`
  step is fine since `pip3 install -e .` still runs before `USER texoid`
  takes effect (as root, consistent with how `pdfoid`/`mathoid` install
  their dependencies before dropping privileges); only the final
  `ENTRYPOINT` process runs unprivileged.
- **Clone pinned to a commit, `.git` removed after checkout** — same
  pattern as mathoid/pdfoid/dmoj-repo elsewhere in this project.

## Out of scope

- Any change to texoid's own Python source or its LaTeX/dvisvgm/convert
  invocation logic.
- Other Medium/Low audit findings (TLS, base image) — separate specs.
- Hardening TeX itself (e.g. disabling `\write18`/shell-escape) — texoid's
  `latex` invocation already runs with `-interaction=nonstopmode` and no
  `-shell-escape` flag, so shell-escape is already off by default; not
  revisited here since it wasn't part of the audit finding.

## Testing / verification

- `docker compose build texoid` (via `podman compose build texoid` on this
  host) succeeds — pinned commit clones successfully, non-root user is
  created, `policy.xml` copies to the correct path.
- **Confirm the actual ImageMagick policy path inside the built image**
  before relying on the `COPY` destination: e.g.
  `podman compose run --rm --entrypoint find texoid /etc -iname 'policy.xml'`
  (or equivalent) — if it reports a path other than
  `/etc/ImageMagick-6/policy.xml`, update the Dockerfile's `COPY`
  destination to match and rebuild.
- `podman compose run --rm --entrypoint identify texoid -list policy` (or
  `convert -list policy`) shows the new restrictive policy in effect —
  confirms `PDF`/`PS`/`MSL`/etc. report `None` rights and `SVG`/`PNG` show
  the intended rights.
- `podman compose up -d texoid` — container starts and stays up (no crash
  loop).
- `podman compose exec texoid whoami` (or equivalent) reports `texoid`,
  not `root`.
- Functional smoke test: send a real LaTeX snippet to texoid's render
  endpoint (via `podman compose exec`/a helper container on the `site`
  network) and confirm a valid SVG+PNG response is returned — the
  `policy.xml` restrictions must not break the actual SVG→PNG conversion
  texoid depends on.
- `docker-compose.yml` is unchanged by this spec (texoid's service
  definition needs no edits) — confirm with `git diff` that only
  `dmoj/texoid/Dockerfile` and the new `dmoj/texoid/policy.xml` are
  touched.
