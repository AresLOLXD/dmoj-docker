# Add OMI/Karel context and AGPL compliance note to README

Date: 2026-07-08

## Context

This repo runs a fork of DMOJ (`AresLOLXD/online-judge`) as `dmoj/repo`. Two
facts about the fork aren't currently visible to anyone reading the README:

1. The fork exists specifically to support the Olimpiada Mexicana de
   Informática (OMI) and already ships with Karel language support baked in
   (the `judge-tier3-1` judge is built `FROM
   localhost/areslolxd/runtimes-tier3:karel`, documented later in the README
   under "Setting up a judge"). A first-time reader has no way to know this
   without digging into the judge Dockerfile.

2. `dmoj/repo/LICENSE` is GNU AGPLv3 (inherited from upstream
   `DMOJ/online-judge`). AGPL §13 requires that a modified version run as a
   network service must offer users the corresponding source, including
   local modifications. Checked `templates/base.html:281-300` in the
   submodule: the footer only links to `https://dmoj.ca` (the upstream
   project's own site), never to the source actually running. There's an
   admin-editable `misc_config.footer` field that could hold a link, but it
   is empty by default and is a runtime/database setting, not something
   guaranteed by code. No other footer/base template in the submodule links
   to source. This is a real compliance gap, not yet fixed.

## Change

Edit `README.md` (repo root) only. Insert a new blockquote section
immediately after the existing introductory paragraph (the one starting
"This repository contains the Docker files...") and before the
`## Installation` heading. Two parts in the same block:

1. A short note that this fork targets the OMI and comes preloaded with
   Karel support, pointing to the `judge-tier3-1` section later in the doc.
2. A "legal note" documenting the AGPL inheritance and the missing
   source-link gap described above, explicitly flagged as pending — no code
   fix included in this change.

Exact wording (English, matching the rest of the README):

```markdown
> This fork of [AresLOLXD/online-judge](https://github.com/AresLOLXD/online-judge)
> is built for the Olimpiada Mexicana de Informática (OMI) and ships
> preloaded with Karel language support (see "Setting up a judge" below).
>
> **Legal note:** this fork inherits the GNU AGPLv3 license from
> `DMOJ/online-judge` (see `dmoj/repo/LICENSE`). AGPL §13 requires that a
> modified version run as a network service make the corresponding source
> available to its users. As of this writing, the site does not expose a
> link to the source actually running (the footer only links to
> `dmoj.ca`). This is a known compliance gap, tracked here as a pending
> item — not yet fixed.
```

## Out of scope

- No changes inside `dmoj/repo` (the submodule) — no footer/template edit,
  no `misc_config.footer` configuration.
- No new `LICENSE` file added to the repo root. The Docker infrastructure in
  this outer repo isn't itself AGPL-encumbered; the obligation applies to
  the application code in the submodule.
- No implementation of the actual source-link fix — this task only records
  that it's missing.

## Testing / verification

- `grep -n "OMI\|Karel\|AGPL" README.md` shows the new block.
- The README renders as valid Markdown (visually inspect the blockquote
  doesn't break surrounding structure).
- No files outside `README.md` are touched.
