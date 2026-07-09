DMOJ Docker [![Build Status](https://github.com/Ninjaclasher/dmoj-docker/workflows/Build%20Docker%20Images/badge.svg)](https://github.com/Ninjaclasher/dmoj-docker/actions/)
=====

This repository contains the Docker files to run a clone of the [DMOJ site](https://github.com/DMOJ/online-judge), using the [AresLOLXD/online-judge](https://github.com/AresLOLXD/online-judge) fork for `dmoj/repo`. It configures some additional services, such as mathoid, pdfoid, and texoid.

> This fork of [AresLOLXD/online-judge](https://github.com/AresLOLXD/online-judge)
> is built for the Olimpiada Mexicana de Informática (OMI) and ships
> preloaded with Karel language support (see "Setting up a judge" below).
>
> **Legal note:** this fork inherits the GNU AGPLv3 license from
> `DMOJ/online-judge` (see `dmoj/repo/LICENSE`). AGPL §13 requires that a
> modified version run as a network service make the corresponding source
> available to its users. The site footer now includes a "source code"
> link pointing to this fork to satisfy that requirement.

## Installation

First, [Docker](https://www.docker.com/) and [Docker Compose](https://docs.docker.com/compose/) must be installed. Installation instructions can be found on their respective websites.

Clone the repository:
```sh
$ git clone https://github.com/Ninjaclasher/dmoj-docker
$ cd dmoj-docker
$ git submodule update --init --recursive
$ cd dmoj
```
From now on, it is assumed you are in the `dmoj` directory.

Initialize the setup by moving the configuration files into the submodule and by creating the necessary directories:
```sh
$ ./scripts/initialize
```
This also creates `dmoj/environment/mysql.env`, `mysql-admin.env`, and `site.env` from their `.env.example` templates (these real files hold secrets and are gitignored — only the `.example` templates are tracked).

Configure the environment variables in the files in `dmoj/environment/`. In particular, set the MYSQL passwords in `mysql.env` and `mysql-admin.env`, and the host and secret key in `site.env`. Also, configure the `server_name` directive in `dmoj/nginx/conf.d/nginx.conf`.

Next, build the images:
```sh
$ docker compose build
```

Start up the site, so you can perform the initial migrations and generate the static files:
```sh
$ docker compose up -d site
```

You will need to generate the schema for the database, since it is currently empty:
```sh
$ ./scripts/migrate
```

You will also need to generate the static files:
```
$ ./scripts/copy_static
```

Finally, the DMOJ comes with fixtures so that the initial install is not blank. They can be loaded with the following commands:
```sh
$ ./scripts/manage.py loaddata navbar
$ ./scripts/manage.py loaddata language_small
$ ./scripts/manage.py loaddata demo
```

## Usage
```
$ docker compose up -d
```

## Notes

### Migrating
As the DMOJ site is a Django app, you may need to migrate whenever you update. Assuming the site container is running, running the following command should suffice:
```sh
$ ./scripts/migrate
```

### Managing Static Files
If your static files ever change, you will need to rebuild them:
```
$ ./scripts/copy_static
```

### Scripts

In addition to the scripts already covered above (`migrate`, `copy_static`,
`manage.py`, `enter_site`, `initialize`), the following are available under
`dmoj/scripts/`:

- `register_judge <judge-dir>` — registers a judge (e.g. `judge-tier3-1`) in
  the site's database and writes the generated `id`/`key` into its
  `judge.yml`.
- `judge_status` — lists all registered judges and whether they're online.
- `new_judge <name> [template]` — scaffolds a new judge directory from an
  existing one (default template `judge-tier3-1`) and prints the
  `docker-compose.yml` block to add.
- `doctor` — runs a full read-only health check across every service
  (containers, Django, DB, Redis, bridged, judges, static assets, nginx,
  wsevent, mathoid/pdfoid/texoid) and exits non-zero if anything's wrong.
- `update` — pulls the latest `dmoj/repo` submodule commit, rebuilds the
  dependent images, and migrates. See [Updating The Site](#updating-the-site)
  below for what this automates.
- `backup_db [output-path]` — dumps the database to a timestamped `.sql`
  file under `backups/` (or the given path).
- `restore_db <path>` — restores the database from a `.sql` file, after
  confirming with a `yes` prompt.
- `logs <service>` — `docker compose logs -f --tail=100 <service>`.

### Updating The Site
Updating various sections of the site requires different images to be rebuilt.

If any prerequisites were modified, you will need to rebuild most of the images:
```sh
$ docker compose up -d --build base site celery bridged wsevent
```
If the static files are modified, read the section on [Managing Static Files](#managing-static-files).

If only the source code is modified, a restart is sufficient:
```sh
$ docker compose restart site celery bridged wsevent
```

### TLS / HTTPS

The `nginx` container does not terminate TLS itself — it only listens on
plain HTTP, published to `127.0.0.1:8080` on the host (not `0.0.0.0`, and
not port 80: this stack assumes an external TLS-terminating reverse proxy
running on the same host, e.g. Cloudflare Tunnel or a host-level Caddy/
Nginx instance, in front of it).

That external proxy must forward to `http://127.0.0.1:8080` and set the
`X-Forwarded-Proto: https` header — the `site` container trusts that
header (`SECURE_PROXY_SSL_HEADER` in `local_settings.py`) to mark
cookies as HTTPS-only. Without a proxy in front of it, the site is not
reachable from outside the host at all — this is intentional, not a bug
to work around by publishing `nginx` more broadly.

If you need a different host port (e.g. `127.0.0.1:8080` conflicts with
something else already running), change the `ports:` mapping under the
`nginx` service in `docker-compose.yml` and point your external proxy at
the new port instead.

For example, a possible host-level Nginx configuration acting as that
external proxy would be:
```
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    # ... your certificate directives here ...

    add_header X-UA-Compatible "IE=Edge,chrome=1";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host $http_host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_pass http://127.0.0.1:8080/;
    }
}
```

### Setting up a judge

`dmoj/judge-tier3-1/Dockerfile` builds `FROM localhost/areslolxd/runtimes-tier3:karel`
— a custom runtime image (built from a separate process, not part of this
repo) that already contains a fully-configured judge with a Karel
compiler/VM installed. This image must exist in your local image store
before `docker compose build judge-tier3-1` will succeed; there is no
automated way to produce it from this repo alone. Contact the image's
maintainer for the build recipe, or substitute your own pre-built
runtimes image in the `FROM` line.

The `localhost/` prefix is a podman-specific way of forcing image
resolution against the local store rather than a registry. Real Docker
resolves unqualified image names as `docker.io/...` regardless of a
`localhost/` prefix (which Docker instead reads as "a registry host named
localhost"), so this Dockerfile as committed only builds correctly under
podman. A Docker-based deployer will need to drop the `localhost/` prefix
(and ensure the image is tagged appropriately for Docker's local store) or
retag their own image to match.

The judge (`judge-tier3-1`) also needs to be registered with the site
before it can connect to `bridged`. Checklist:

- [ ] `docker compose build judge-tier3-1`
- [ ] `docker compose up -d site` and `./scripts/migrate` (if not already running)
- [ ] `./scripts/register_judge judge-tier3-1`
- [ ] `docker compose up -d --build judge-tier3-1`
- [ ] `./scripts/judge_status` (or `./scripts/doctor`) to confirm it shows `online: True`
- [ ] Submit the `demo` fixture's sample problem and confirm it gets graded by this judge

To add another judge instance (e.g. a second tier-3 judge for capacity), use
`./scripts/new_judge <name>` to scaffold the directory and print the
`docker-compose.yml` block to add, then follow the same checklist above with
the new judge's name.

## Common Errors
### 502 Bad Gateway
Ensure that you also restart the Nginx container if you restart the site container as Nginx caches DNS queries. Otherwise, Nginx will try to hit the old IP, causing a 502 Bad Gateway. See [this issue](https://github.com/docker/compose/issues/3314) for more information.
