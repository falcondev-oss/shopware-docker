# Shopware in Docker

Production image and Docker Swarm stack for Shopware 6.7, for use behind any reverse proxy. Extensions are installed and updated in the Administration, like on a normal server. No custom build is needed.

```text
ghcr.io/falcondev-oss/shopware:6.7.16.1   # exact Shopware version
ghcr.io/falcondev-oss/shopware:6.7        # newest 6.7 patch release
ghcr.io/falcondev-oss/shopware:latest
```

The image is built from the official `ghcr.io/shopware/docker-base` FrankenPHP image with PHP 8.4. It is rebuilt every week to get PHP and OS security fixes, for amd64 and arm64.

## Services

| Service | Job |
|---|---|
| `web` | FrankenPHP (Caddy with PHP), port 8000 |
| `worker` | `messenger:consume webhook async low_priority`, 2 replicas. Restarts every hour, at 384 MB, or when an extension changes |
| `scheduler` | `scheduled-task:run`, puts due scheduled tasks into the queue |
| `database` | MariaDB 11.8 |
| `valkey-cache` | HTTP cache and object cache, in memory only |
| `valkey-store` | Sessions, carts, locks, message queue, delayed cache invalidation. Persisted with AOF |

`web`, `worker` and `scheduler` run the same image. There is no separate setup service: every Shopware container compares the Shopware version in the database with its own on start. When they differ, one container takes a database lock and runs the [Deployment Helper](https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/deployment-helper/) (installation on the first start, later migrations and `theme:compile`). The others wait for it. When they match, the container starts at once.

## Start

`compose.yaml` is a Swarm stack file. Deploy it in Portainer with the variables from `.env.example`, or on the command line:

```sh
cp .env.example .env   # fill in APP_URL, secrets and the admin password
set -a && . ./.env && set +a
docker stack deploy -c compose.yaml shop
```

The first start installs Shopware. Log in at `<APP_URL>/admin` as `admin` with `INSTALL_ADMIN_PASSWORD`.

Docker Compose is not supported: it gives all `worker` replicas the same messenger consumer name.

The volumes are local to the node. On a Swarm with more than one node, keep all services on one node, or put the shared volumes (`plugins`, `apps`, `bundles`, `files`, `media`, `thumbnail`, `theme`, `sitemap`) on shared storage.

## Reverse proxy

Connect the proxy to `web` on port 8000 and send the usual `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` headers. Traefik, Caddy and nginx with default settings work. Shopware trusts these headers from private addresses only (`TRUSTED_PROXIES=private_ranges`). Example for Traefik in Swarm mode, added to `web`:

```yaml
    networks: [default, traefik]
    deploy:
      labels:
        traefik.enable: 'true'
        traefik.swarm.network: traefik
        traefik.http.routers.shop.rule: Host(`shop.example.com`)
        traefik.http.services.shop.loadbalancer.server.port: '8000'
```

Do not publish port 8000 on a public address. Swarm forwards public traffic from a private address, so anyone could then fake the client IP and the scheme.

## Extensions

Install, update and remove plugins and apps in the Administration: from the Shopware Store or as an uploaded zip. They are stored in the `plugins` and `apps` volumes, which all containers share. After a change, each container rebuilds its Symfony container on its next request, and the workers restart.

Plugins that need extra Composer packages at install time do not work, because Shopware would have to run `composer require` in the image. The image already contains the one most shops need: `shopware/paypal-sdk` 1.x for SwagPayPal 10.x.

## Shop-specific config

Set `SHOPWARE_CONFIG` to Symfony or Shopware config as YAML. All Shopware containers load it. One line is enough:

```sh
SHOPWARE_CONFIG={shopware: {stock: {enable_stock_management: false}}}
```

With `SHOPWARE_CONFIG` set, each container builds its container cache on start instead of using the one in the image. Its first request takes a few seconds longer. A changed value takes effect on the next deploy.

## Update Shopware

Change `IMAGE` in `.env` to the new version, then:

```sh
set -a && . ./.env && set +a
docker stack deploy -c compose.yaml shop
```

The first new container runs the migrations. Swarm starts the new `web` next to the old one and stops the old one only when the new one is healthy, so no request fails. If the new `web` does not get healthy, the old one keeps serving and Swarm pauses the update of `web`. `worker` and `scheduler` already run the new image, which works because the migrations are compatible with the old code (`BLUE_GREEN_DEPLOYMENT=1`). Fix the cause and deploy again. Going back to the old `IMAGE` works for the same reason, but it does not undo the migrations: containers with an older image than the database start without the Deployment Helper. Back up the database first, and check in the Administration that your extensions support the new version.

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
