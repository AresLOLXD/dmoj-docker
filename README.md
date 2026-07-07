DMOJ Docker [![Build Status](https://github.com/Ninjaclasher/dmoj-docker/workflows/Build%20Docker%20Images/badge.svg)](https://github.com/Ninjaclasher/dmoj-docker/actions/)
=====

This repository contains the Docker files to run a clone of the [DMOJ site](https://github.com/DMOJ/online-judge). It configures some additional services, such as mathoid, pdfoid, and texoid.

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

### Multiple Nginx Instances

The `docker-compose.yml` configures Nginx to publish to port 80. If you have another Nginx instance on your host machine, you may want to change the port and proxy pass instead.

For example, a possible Nginx configuration file on your host machine would be:
```
server {
    listen 80;
    listen [::]:80;

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
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_pass http://127.0.0.1:10080/;
    }
}
```

In this case, the port that the Nginx instance in the Docker container is published to would need to be modified to `10080`.

### Setting up a judge

The judge (`judge-tier3-1`) needs to be registered with the site before it
can connect to `bridged`. Checklist:

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
