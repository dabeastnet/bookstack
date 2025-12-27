#!/usr/bin/env bash
# Helper script to start the Laravel scheduler.  This script runs
# artisan schedule:work which keeps the scheduler running as a
# long‑running process.  A timezone can be provided via
# APP_TIMEZONE.

exec php artisan schedule:work --verbose --no-interaction --timezone=${APP_TIMEZONE:-UTC}