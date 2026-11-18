# syntax=docker/dockerfile:1

ARG PHP_VERSION=8.4

FROM ghcr.io/shopware/docker-base:${PHP_VERSION}-frankenphp AS build

ARG SHOPWARE_VERSION=6.7.16.1

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

WORKDIR /var/www/html

RUN --mount=type=cache,target=/tmp/composer/cache,uid=82,gid=82 <<EOF
    set -e
    composer create-project --no-install --no-scripts shopware/production:${SHOPWARE_VERSION} .
    composer install --no-dev --no-scripts --optimize-autoloader
    # The Redis transport must match the Symfony version of Shopware.
    symfony=$(composer show symfony/messenger --format=json | php -r 'preg_match("/\d+\.\d+/", json_decode(stream_get_contents(STDIN))->versions[0], $m); echo $m[0];')
    # SwagPayPal 10.x expects the PayPal SDK in the project vendor, Shopware cannot install it at runtime.
    composer require --no-scripts --update-no-dev --optimize-autoloader shopware/deployment-helper "symfony/redis-messenger:~${symfony}.0" "shopware/paypal-sdk:^1.11"
    rm -rf .env* compose*.yaml
EOF

COPY --chown=82:82 app/ ./

# Directories that become volumes must exist with the right owner, so new volumes inherit it.
# The warm container cache lets a new container answer its first request at full speed.
RUN <<EOF
    set -e
    mkdir -p config/packages/prod/override files custom/plugins custom/apps public/media public/thumbnail public/theme public/sitemap
    export REDIS_CACHE_URL=redis://build REDIS_STORE_URL=redis://build
    php bin/console assets:install
    php bin/console cache:warmup
EOF

FROM ghcr.io/shopware/docker-base:${PHP_VERSION}-frankenphp

ARG SHOPWARE_VERSION=6.7.16.1

LABEL org.opencontainers.image.source=https://github.com/falcondev-oss/shopware-docker \
      org.opencontainers.image.version=${SHOPWARE_VERSION}

COPY --link docker/Caddyfile /etc/caddy/Caddyfile
COPY --link docker/entrypoint /usr/local/bin/shopware-entrypoint
COPY --link --from=build /var/www/html /var/www/html

# Extensions change at runtime, so OPcache checks files for changes every 2 seconds.
ENV BLUE_GREEN_DEPLOYMENT=1 \
    DO_NOT_TRACK=1 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1

EXPOSE 8000

ENTRYPOINT ["shopware-entrypoint"]
CMD ["--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
