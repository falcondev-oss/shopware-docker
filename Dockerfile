# syntax=docker/dockerfile:1

ARG PHP_VERSION=8.4

FROM ghcr.io/shopware/shopware-cli:latest-php-${PHP_VERSION} AS build

WORKDIR /src
COPY . .

# Installs Composer packages, builds the Administration and Storefront assets of all extensions
# and runs assets:install, so the image needs no build step at runtime.
RUN --mount=type=secret,id=composer_auth,env=COMPOSER_AUTH \
    --mount=type=cache,target=/root/.composer \
    --mount=type=cache,target=/root/.npm \
    CI=true /usr/local/bin/entrypoint.sh shopware-cli project ci /src

FROM ghcr.io/shopware/docker-base:${PHP_VERSION}-frankenphp

COPY --link docker/Caddyfile /etc/caddy/Caddyfile
COPY --link --chown=82:82 --from=build /src /var/www/html

ENV COMPOSER_PLUGIN_LOADER=1 \
    BLUE_GREEN_DEPLOYMENT=1 \
    SHOPWARE_DEPLOYMENT_SKIP_ASSETS_INSTALL=1 \
    DO_NOT_TRACK=1

# Directories that become volumes must exist with the right owner, so new volumes inherit it.
# The warm container cache makes every new container answer its first request at full speed.
RUN rm -rf var/cache/* \
    && mkdir -p files public/media public/thumbnail public/theme public/sitemap \
    && REDIS_CACHE_URL=redis://build REDIS_STORE_URL=redis://build php bin/console cache:warmup

EXPOSE 8000
