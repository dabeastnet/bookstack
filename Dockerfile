# Use multi-stage builds to create a production‑ready BookStack container.
# The builder stage uses a PHP image with development tools to install
# dependencies. The final stage contains only what’s required to run the
# application together with a lightweight HTTP server.  Using
# separate stages keeps the runtime small and secure.

###############################
# 1) Builder stage
###############################
FROM php:8.3-fpm-alpine AS builder

# Install build and runtime dependencies.  The builder needs tools
# like git and unzip to fetch and unpack Composer packages.  We
# deliberately install only the extensions required by the BookStack
# manual installation requirements【960969724376565†L96-L105】 to keep the
# image minimal.  These include GD for image manipulation,
# DOM/XML for HTML parsing, and Zip for archive support.
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
        gd \
        zip \
        bcmath \
        pcntl \
    && docker-php-ext-enable opcache

# Install Composer.  Composer is needed to install PHP dependencies
# during the build.  The official installer signature is checked
# automatically by the installer script.
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Set working directory and copy project files into the builder.  The
# build context should contain a checked‑out BookStack release.  Only
# composer.json/lock are copied initially to leverage Docker layer
# caching when dependencies have not changed.
WORKDIR /build/bookstack
COPY composer.json composer.lock ./

# Install PHP dependencies without development packages.  We disable
# script execution here because BookStack's composer hooks assume
# that the application source has already been copied.  Running
# composer with --no-scripts allows us to install the vendor
# dependencies without triggering those scripts prematurely.  We
# intentionally omit --optimize-autoloader at this stage since we
# generate an optimised autoloader after the full source is present.
RUN composer install --no-dev --prefer-dist --no-interaction --no-scripts

# Once dependencies are installed, copy the remainder of the
# application source.  This includes the application code, public
# assets and configuration files.  The .dockerignore file should
# exclude files not needed in the final image.
COPY . .

# Now that the full application source is available we can build
# the optimised autoloader and run composer scripts.  The
# post-autoload-dump scripts defined by BookStack require files in
# the app directory, so this must occur after the COPY above.
RUN composer dump-autoload --optimize

# Perform a basic build step by caching the configuration.  Since
# configuration is loaded from environment variables at runtime we
# cannot fully cache config here, but optimising the autoloader
# improves startup times.
RUN php artisan config:clear && php artisan view:clear && php artisan event:clear


###############################
# 2) Runtime stage
###############################
FROM php:8.3-fpm-alpine AS runtime

# Install runtime packages.  We include a minimal HTTP server and
# process supervisor.  Nginx serves the public directory and proxies
# PHP requests to php‑fpm.  Supervisord manages both processes and
# ensures they run in the foreground.  The curl binary is installed
# solely for the health check defined later.
# RUN apk add --no-cache \
#         nginx \
#         supervisor \
#         curl \
#         bash
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

# Copy compiled extensions and enablement files from the builder.
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d

# Copy the PHP configuration tuned for production.  Settings such as
# memory_limit, upload limits and disabled PHP exposure are defined
# in this file.  See docker/php.ini for details.
COPY docker/php.ini /usr/local/etc/php/php.ini

# Copy the application from the builder stage.  We copy the built
# vendor directory and application source from the builder to avoid
# rebuilding dependencies in the runtime image.
WORKDIR /var/www/bookstack
COPY --from=builder /build/bookstack /var/www/bookstack

# Copy web server and supervisor configuration.  The nginx
# configuration serves only the public directory and disables
# directory indexing for uploads【338446874991254†L210-L215】.  Additional
# security headers are defined in the file.  Supervisord runs
# php‑fpm and nginx together in the “web” mode.  For other modes
# (worker and scheduler) only a single process is required.
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/supervisord.conf /etc/supervisord.conf

# Copy helper scripts and entrypoint.  These scripts wrap common
# commands for the different modes of operation.  They are
# intentionally kept simple so that application behaviour is clearly
# visible.  All scripts are made executable.
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/run-web.sh /usr/local/bin/run-web
COPY docker/run-worker.sh /usr/local/bin/run-worker
COPY docker/run-scheduler.sh /usr/local/bin/run-scheduler
RUN chmod +x /entrypoint.sh /usr/local/bin/run-* \
    && mkdir -p /run/nginx

# Create a dedicated unprivileged user.  Running as a non‑root user
# reduces the attack surface.  The UID/GID values are arbitrary but
# fixed to ensure consistent file ownership when using mounted
# volumes.  Ownership of the necessary writable directories is
# assigned to this user.
RUN addgroup -g 1000 bookstack && adduser -D -u 1000 -G bookstack bookstack \
    # Ensure writable directories exist before changing ownership.  The public/uploads
    # directory is not present in the source tree and is created on first run.
    && mkdir -p storage bootstrap/cache public/uploads \
    && chown -R bookstack:bookstack storage bootstrap/cache public/uploads

# Expose a non‑privileged port.  The web server listens on port
# 8080; this can be mapped to port 80 or 443 by the orchestrator.
EXPOSE 8080

# Run all subsequent commands as the unprivileged bookstack user.  This
# ensures that nginx and php‑fpm processes do not run as root.
USER bookstack

# Define a healthcheck that probes the BookStack status endpoint.  It
# relies on curl which will exit non‑zero on failure.  The timeout is
# kept short since health checks are run frequently in production.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -f http://localhost:8080/status || exit 1

# Set the entrypoint.  We use the entrypoint to perform one‑time
# initialisation tasks such as generating an application key and
# running migrations when explicitly enabled.  The default command
# will be overridden based on the desired mode.
ENTRYPOINT ["/entrypoint.sh"]

# The default command starts the web server.  Override this to
# "worker" or "scheduler" in your orchestrator to run other modes.
CMD ["web"]