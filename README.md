# Shopware in Docker

Shopware 6.7 for production with Docker Compose, behind any reverse proxy. Built on the official `ghcr.io/shopware/docker-base` FrankenPHP image.

## Services

| Service | Job |
|---|---|
| `init` | Runs the [Deployment Helper](https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/deployment-helper/) on every deploy: installs Shopware on the first start, afterwards migrations, extension install and update, `theme:compile`. The other Shopware services start after it succeeds |
| `web` | FrankenPHP (Caddy with PHP), port 8000 |
| `worker` | `messenger:consume webhook async low_priority`, 2 replicas. Restarts every 5 minutes or at 384 MB |
| `scheduler` | `scheduled-task:run`, puts due scheduled tasks into the queue |
| `database` | MariaDB 11.8 |
| `valkey-cache` | HTTP cache and object cache, in memory only |
| `valkey-store` | Sessions, carts, locks, message queue, delayed cache invalidation. Persisted with AOF |

## Start

```sh
cp .env.example .env   # fill in APP_URL, secrets and the admin password
docker compose up -d --build
```

The first start installs Shopware. Log in at `<APP_URL>/admin` as `admin` with `INSTALL_ADMIN_PASSWORD`.

## Reverse proxy

Point the proxy at `HTTP_BIND` (default `127.0.0.1:8000`) and send the usual `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` headers. Traefik, Caddy and nginx with default settings work. Shopware trusts these headers from private addresses only (`TRUSTED_PROXIES=private_ranges`).

Do not publish port 8000 on a public address. Docker forwards public traffic from a private gateway address, so anyone could then fake the client IP and the scheme.

## Deploy and update

All code is in the image. Every change is a new build:

```sh
docker compose up -d --build
```

| Change | How |
|---|---|
| Shopware version | Change `shopware/core` in `composer.json`, run `composer update "shopware/*" -W` |
| Extension from Composer | `composer require <package>`. The deploy installs and activates it |
| Extension from the Shopware Store | `composer config repositories.shopware-packages composer https://packages.shopware.com`, then `composer require store.shopware.com/<name>`. The build needs `COMPOSER_AUTH` with the token, see `.env.example` |
| Own plugin | Put it into `custom/static-plugins/<Name>` and `composer require` it |
| PHP security fixes | `docker compose build --pull && docker compose up -d` |

`init` runs before the new `web` starts. `BLUE_GREEN_DEPLOYMENT=1` keeps the database usable for the old code until the new containers run. Recreating `web` drops requests for under a second.

## What the container setup changes in Shopware

Containers lose all changes to their file system on the next deploy, and several containers run side by side. These Shopware features are off or moved for that reason:

| Feature | Setting | Why |
|---|---|---|
| Web updater | `auto_update.enabled: false`, module hidden | It would update the code in one container only, and the next deploy reverts it |
| Extension manager in the Administration | `runtime_extension_management: false`, `COMPOSER_PLUGIN_LOADER=1` | Uploaded or downloaded extensions disappear on the next deploy. Extensions come from Composer, see above |
| Local cache clear | `cluster_setup: true` | Never deletes the container cache built into the image. "Clear cache" in the Administration still clears Valkey |
| Admin worker | `enable_admin_worker: false` | The `worker` containers process the queue |
| File lock | `LOCK_DSN` on Valkey | `flock` only locks inside one container |
| `assets:install` on deploy | `SHOPWARE_DEPLOYMENT_SKIP_ASSETS_INSTALL=1` | The image already contains `public/bundles` |
| `.env` file | Not in the image | All configuration comes from the container environment, Symfony skips parsing `.env` |

## Performance

- Container cache built into the image (`cache:warmup`), classmap-authoritative autoloader, OPcache without timestamp checks.
- HTTP cache and object cache in Valkey, shared by all containers. On a 16-core machine, `web` serves a cached page about 2,500 times per second at 50 parallel requests.
- Cache entries and carts compressed with zstd. Sessions in Valkey through the native `phpredis` handler. Persistent Valkey connections.
- Queue on Valkey streams instead of MariaDB, mails sent through the queue.

## Data

Back up these volumes: `database`, `valkey-store`, `files`, `media`, `thumbnail`. `theme` and `sitemap` can be rebuilt (`theme:compile`, `sitemap:generate`). `valkey-cache` has no data.

## Settings

See `.env.example`. Tuning: `WORKER_REPLICAS`, `DB_BUFFER_POOL_SIZE` (about 70 % of the memory you give MariaDB), `CACHE_MAXMEMORY`, `PHP_MEMORY_LIMIT`. FrankenPHP starts 2 PHP threads per CPU; set `FRANKENPHP_CONFIG=num_threads 16` to change it.
