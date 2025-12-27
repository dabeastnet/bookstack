#!/usr/bin/env bash
# Helper script to start the queue worker.  This wrapper runs the
# Laravel queue worker with sensible default options.  It assumes the
# container’s user is already unprivileged.

exec php artisan queue:work --sleep=3 --tries=3 --timeout=90