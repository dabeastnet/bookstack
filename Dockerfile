# Production-ready Dockerfile for BookStack with pinned component versions
#
# This Dockerfile builds a BookStack image using a multi‑stage build.  It pins
# the PHP and Alpine versions to ensure reproducible builds and explicitly
# enables GD with JPEG and FreeType support.  Composer is also pinned to
# a known version for dependency installation.  The runtime stage installs
# only the libraries required to run the compiled PHP extensions and sets
# up an unprivileged user with appropriate permissions.

###############################
# 1) Builder stage
###############################

# Pin the PHP and Alpine versions via build arguments.  Adjust these
# values when upgrading BookStack; using specific tags prevents the
# underlying base image from changing unexpectedly.  See the PHP
# official Docker image documentation for available tags.
ARG PHP_VERSION=8.3.3
ARG ALPINE_VERSION=3.19

# The builder uses a PHP image with development tools to compile
# extensions and install dependencies.  We pin the full tag to
# `php:8.3.3-fpm-alpine3.19` to avoid pull drift.  Optionally you can
# append a digest (@sha256:...) for even stronger reproducibility.
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS builder

# Install development headers and libraries needed to build PHP
# extensions.  Versions can be pinned (pkg=ver) if desired by
# inspecting the package repository for Alpine ${ALPINE_VERSION}.
RUN apk add --no-cache \
        git \
        unzip \
        libzip-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        oniguruma-dev \
        libxml2-dev \
        zlib-dev \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mysqli \
        mbstring \
        xml \
        dom \
        zip \
        bcmath \
        pcntl \
    && docker-php-ext-enable opcache

# Enable GD with JPEG and FreeType support.  This ensures that
# BookStack can generate thumbnails from JPEG images.  Without
# `--with-jpeg` JPEG support would be disabled【686742135763062†L33-L37】.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd

# Pin Composer to a specific version for deterministic dependency
# installation.  Here we use Composer 2.7.1 but you can update it as
# needed.  The SHA384 signature is not checked because the installer
# script downloads the phar directly.
ARG COMPOSER_VERSION=2.7.1
RUN curl -fsSL "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" -o /usr/local/bin/composer \
    && chmod +x /usr/local/bin/composer

# Set working directory and copy composer manifests.  Copying only the
# manifests first leverages Docker layer caching when dependencies
# haven't changed.
WORKDIR /build/bookstack
COPY composer.json composer.lock ./

# Install PHP dependencies without executing scripts.  We disable
# scripts because BookStack's composer hooks rely on the full source
# being present【960969724376565†L96-L105】.  Running with `--no-scripts` allows
# vendor installation while avoiding these hooks at this stage.
RUN composer install --no-dev --prefer-dist --no-interaction --no-scripts

# Copy the remainder of the application source into the build stage.
COPY . .

# Optimise the autoloader now that the full codebase is available.
RUN composer dump-autoload --optimize

# Clear cached configuration and views.  These will be rebuilt at
# runtime based on environment variables.
RUN php artisan config:clear && php artisan view:clear && php artisan event:clear

###############################
# 2) Runtime stage
###############################

FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

# Install only the runtime dependencies required by the compiled PHP
# extensions.  Libraries installed here should match those used in
# the builder; pin versions if necessary.
RUN apk add --no-cache \
        nginx \
        supervisor \
        curl \
        bash \
        libzip \
        libpng \
        libjpeg-turbo \
        freetype \
        oniguruma \
        libxml2 \
        zlib

# Copy compiled PHP extensions and configuration from the builder.
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d



# Copy the tuned PHP configuration.  This file defines sensible
# production defaults such as memory limits and upload size.
COPY docker/php.ini /usr/local/etc/php/php.ini

# Copy the built application from the builder stage.
WORKDIR /var/www/bookstack
COPY --from=builder /build/bookstack /var/www/bookstack

# Copy nginx and supervisor configuration.  nginx serves only the
# public directory and proxies PHP requests; supervisor starts
# php‑fpm and nginx together for web mode.
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/supervisord.conf /etc/supervisord.conf

# Copy helper scripts and entrypoint.  These wrap the common modes
# (web, worker, scheduler) and perform initialization tasks.
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/run-web.sh /usr/local/bin/run-web
COPY docker/run-worker.sh /usr/local/bin/run-worker
COPY docker/run-scheduler.sh /usr/local/bin/run-scheduler
RUN chmod +x /entrypoint.sh /usr/local/bin/run-* \
    && mkdir -p /run/nginx

# Create a dedicated unprivileged user and ensure all writable
# directories exist.  The public uploads directory is created here
# since it does not exist in the source tree.  Directory permissions
# are set so the bookstack user can write files.
RUN addgroup -g 1000 bookstack && adduser -D -u 1000 -G bookstack bookstack \
    && mkdir -p storage/framework/sessions storage/framework/views storage/framework/cache \
    && mkdir -p bootstrap/cache public/uploads \
    && chown -R bookstack:bookstack storage bootstrap/cache public/uploads \
    && chmod -R 775 storage bootstrap/cache public/uploads

# Create nginx log and temporary directories so nginx can start as
# an unprivileged user.  These are normally created when running
# as root; here we pre-create them and assign ownership.
RUN mkdir -p /var/lib/nginx/logs /var/lib/nginx/tmp/client_body \
    && touch /var/lib/nginx/logs/error.log /var/lib/nginx/logs/access.log \
    && chown -R bookstack:bookstack /var/lib/nginx \
    && mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi \
    && chmod -R 777 /tmp/nginx

# Expose the port nginx listens on.  In ECS/EKS you will map this to
# 80 or 443 behind a load balancer.
EXPOSE 8080

# Switch to the unprivileged user for all subsequent operations.
USER bookstack

# Use a lightweight healthcheck that does not rely on sessions or
# database.  This path should be configured in your load balancer.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/status || exit 1

# Set the entrypoint.  The entrypoint handles one‑time setup such as
# generating the APP_KEY and optionally running migrations.  The
# default command starts the web server; override it to "worker" or
# "scheduler" in your orchestrator.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["web"]