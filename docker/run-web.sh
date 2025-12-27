#!/usr/bin/env bash
# Helper script to start the web server.  This wrapper is retained for
# compatibility with orchestrators that override the container
# command.  It simply execs the supervisor which manages php‑fpm and
# nginx.

exec /usr/bin/supervisord -c /etc/supervisord.conf