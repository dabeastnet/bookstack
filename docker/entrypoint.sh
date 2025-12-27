#!/usr/bin/env bash
# entrypoint.sh
#
# This script is the main entrypoint for the BookStack container.  It
# performs idempotent initialisation steps before executing the
# requested mode (web, worker or scheduler).  Environment variables
# control behaviour such as database configuration, session/cache
# drivers and optional migration or key generation.  All output is
# sent to stdout/stderr to play nicely with container log drivers.

set -euo pipefail

function log() {
    echo "[init] $*"
}

function error_exit() {
    echo "[init] ERROR: $*" >&2
    exit 1
}

# Validate required environment variables when in production.  Only
# check variables when running the application; arbitrary commands
# passed to the container bypass these checks.
if [[ "$1" =~ ^(web|worker|scheduler)$ ]]; then
    : "${DB_HOST?Environment variable DB_HOST must be set}"
    : "${DB_DATABASE?Environment variable DB_DATABASE must be set}"
    : "${DB_USERNAME?Environment variable DB_USERNAME must be set}"
    : "${DB_PASSWORD?Environment variable DB_PASSWORD must be set}"
    : "${CACHE_DRIVER?Environment variable CACHE_DRIVER must be set}"
    : "${SESSION_DRIVER?Environment variable SESSION_DRIVER must be set}"
fi

# Generate application key if missing and explicitly permitted.  The
# BookStack documentation instructs to run `php artisan key:generate`
# during installation【960969724376565†L146-L158】.  In a high‑availability setup
# this must only be done once to avoid mismatched keys across
# replicas.  Therefore generation is gated behind
# ALLOW_APP_KEY_GENERATION=true.
if [[ "${APP_KEY:-}" == "" ]]; then
    if [[ "${ALLOW_APP_KEY_GENERATION:-false}" == "true" ]]; then
        log "Generating new application key..."
        php artisan key:generate --force --ansi
        log "Generated APP_KEY: $(php -r "require 'vendor/autoload.php'; echo getenv('APP_KEY');")"
    else
        error_exit "APP_KEY is not set and automatic generation is disabled.  Set APP_KEY or enable ALLOW_APP_KEY_GENERATION=true."
    fi
fi

# Run database migrations if explicitly enabled.  In a clustered
# environment migrations should be run as a one‑off task instead of
# during every deployment.  Controlled via RUN_MIGRATIONS=true.
if [[ "${RUN_MIGRATIONS:-false}" == "true" ]]; then
    log "Running database migrations..."
    php artisan migrate --force
fi

# Cache configuration and routes for performance.  This is safe to run
# every start and will pick up any new environment variables.
log "Optimising configuration..."
php artisan config:cache
php artisan route:cache || true
php artisan view:cache || true

# Ensure writable directories have correct permissions.  The runtime
# user must be able to write to storage and cache directories.  Since
# these directories are copied from the image they already have the
# correct owner, but when mounting volumes locally this may need to
# be corrected at runtime.  We avoid using sudo by owning the files
# during build and runtime as the same UID/GID.
log "Setting file permissions..."
chown -R bookstack:bookstack storage bootstrap/cache public/uploads || true

# Execute command based on first argument.  Additional arguments are
# passed through verbatim.
case "$1" in
    web)
        log "Starting web server..."
        exec /usr/bin/supervisord -c /etc/supervisord.conf
        ;;
    worker)
        log "Starting queue worker..."
        exec php artisan queue:work --sleep=3 --tries=3 --timeout=90
        ;;
    scheduler)
        log "Starting scheduler..."
        # Laravel’s schedule:work no longer accepts a --timezone flag; set timezone via APP_TIMEZONE instead.
        exec php artisan schedule:work --verbose --no-interaction
        ;;
    *)
        # Fall back to whatever the user passed, without init steps.
        exec "$@"
        ;;
esac