# Shopware in Docker

Production image and Docker Compose stack for Shopware 6.7, for use behind any reverse proxy. Extensions are installed and updated in the Administration, like on a normal server. No custom build is needed.

```text
ghcr.io/falcondev-oss/shopware:6.7.16.1   # exact Shopware version
ghcr.io/falcondev-oss/shopware:6.7        # newest 6.7 patch release
ghcr.io/falcondev-oss/shopware:latest
```

The image is built from the official `ghcr.io/shopware/docker-base` FrankenPHP image with PHP 8.4. It is rebuilt every week to get PHP and OS security fixes, for amd64 and arm64.

## Services

| Service | Job |
|---|---|
| `init` | Runs the [Deployment Helper](https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/deployment-helper/) on every start: installs Shopware on the first start, afterwards database migrations and `theme:compile`. The other Shopware services start after it succeeds |
| `web` | FrankenPHP (Caddy with PHP), port 8000 |
| `worker` | `messenger:consume webhook async low_priority`, 2 replicas. Restarts every 5 minutes, at 384 MB, or when an extension changes |
| `scheduler` | `scheduled-task:run`, puts due scheduled tasks into the queue |
| `database` | MariaDB 11.8 |
| `valkey-cache` | HTTP cache and object cache, in memory only |
| `valkey-store` | Sessions, carts, locks, message queue, delayed cache invalidation. Persisted with AOF |

`init`, `web`, `worker` and `scheduler` run the same image.

## Start

Copy `compose.yaml` and `.env.example` to the server.

```sh
cp .env.example .env   # fill in APP_URL, secrets and the admin password
docker compose up -d
```

The first start installs Shopware. Log in at `<APP_URL>/admin` as `admin` with `INSTALL_ADMIN_PASSWORD`.

## Reverse proxy

Point the proxy at `HTTP_BIND` (default `127.0.0.1:8000`) and send the usual `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` headers. Traefik, Caddy and nginx with default settings work. Shopware trusts these headers from private addresses only (`TRUSTED_PROXIES=private_ranges`).

Do not publish port 8000 on a public address. Docker forwards public traffic from a private gateway address, so anyone could then fake the client IP and the scheme.

## Extensions

Install, update and remove plugins and apps in the Administration: from the Shopware Store or as an uploaded zip. They are stored in the `plugins` and `apps` volumes, which all containers share. After a change, each container rebuilds its Symfony container on its next request, and the workers restart.

Plugins that need extra Composer packages at install time do not work. Shopware would run `composer require` in the image. Few store plugins do this.

## Update Shopware

Change `IMAGE` in `.env` to the new version, then:

```sh
docker compose pull && docker compose up -d
```

`init` runs the migrations before the new `web` starts. Back up the database first, and check in the Administration that your extensions support the new version. Recreating `web` drops requests for under a second.

## What the container setup changes in Shopware

| Feature | Setting | Why |
|---|---|---|
| Web updater | `auto_update.enabled: false`, module hidden | It would change the code in one container only, and the next start reverts it. Update by changing the image |
| Composer at runtime | `cluster_setup: true` | Never runs Composer or deletes the container cache of a single container |
| Admin worker | `enable_admin_worker: false` | The `worker` containers process the queue |
| File lock | `LOCK_DSN` on Valkey | `flock` only locks inside one container |
| Extension lifecycle on deploy | `.config/shopware-project.yml` | The Deployment Helper would install and activate every plugin it finds. Extensions stay as you set them in the Administration |
| `.env` file | Not in the image | All configuration comes from the container environment, Symfony skips parsing `.env` |

## Performance

- Container cache built into the image, so a new container serves its first request at full speed until an extension is installed.
- HTTP cache and object cache in Valkey, shared by all containers. On a 16-core machine, `web` serves a cached page about 2,500 times per second at 50 parallel requests.
- `valkey-cache` uses `allkeys-lru` with the tag-version cache adapter: Valkey can evict any key, and an evicted tag version invalidates its entries. No cleanup job is needed for orphaned cache tags.
- Cache entries and carts compressed with zstd. Sessions in Valkey through the native `phpredis` handler. Persistent Valkey connections.
- Queue on Valkey streams instead of MariaDB, mails sent through the queue.
- OPcache checks files every 2 seconds, so extension updates take effect without a restart.

## Data

Back up these volumes: `database`, `valkey-store`, `plugins`, `apps`, `files`, `media`, `thumbnail`. `bundles`, `theme` and `sitemap` can be rebuilt (`assets:install`, `theme:compile`, `sitemap:generate`). `valkey-cache` has no data.

## Settings

See `.env.example`. Tuning: `WORKER_REPLICAS`, `DB_BUFFER_POOL_SIZE` (about 70 % of the memory you give MariaDB), `CACHE_MAXMEMORY`, `PHP_MEMORY_LIMIT`. FrankenPHP starts 2 PHP threads per CPU; set `FRANKENPHP_CONFIG=num_threads 16` to change it.

## Build the image

```sh
docker build --build-arg SHOPWARE_VERSION=6.7.16.1 -t shopware .
```

A new Shopware version needs only a new `SHOPWARE_VERSION` in the `Dockerfile`. CI publishes the image on every push to `main`.
