# BookStack Containerisation for Production

This repository adds the necessary files to build a production‑ready
container image for [BookStack](https://www.bookstackapp.com/) and
provide instructions for running it in a high‑availability, AWS
environment.  The goal is to follow the manual installation
instructions as closely as possible while embedding best practices for
security, performance and maintainability.  No reliance is placed on
any community images; everything is built from source.

## Overview

* **Multi‑stage build:** A first stage installs PHP dependencies using
  Composer with development packages removed.  Required PHP
  extensions such as `gd`, `mbstring`, `pdo_mysql` and `zip` are
  installed in accordance with the BookStack requirements.
  A second stage contains only the compiled application and a
  lightweight HTTP stack to minimise the final image size.
* **HTTP stack:** Nginx acts as a reverse proxy in front of php‑fpm.
  The configuration serves only the `public` directory and denies
  directory listing on the uploads path.  Security headers and
  configurable upload limits are set.  Both services are managed by
  `supervisord` when running in the `web` mode.
* **Multiple modes:** The same image can run in three modes via the
  container command:
  * `web` – starts Nginx and php‑fpm to serve HTTP traffic.
  * `worker` – runs the Laravel queue worker (`php artisan
    queue:work`).
  * `scheduler` – runs the Laravel scheduler (`php artisan
    schedule:work`).
* **Non‑root runtime:** A dedicated `bookstack` user is created at
  build time.  The container switches to this user before starting
  services so that neither php‑fpm nor Nginx run as root.  All
  writable directories (`storage`, `bootstrap/cache`, `public/uploads`)
  are owned by this user.
* **Healthcheck:** A healthcheck calls the `/status` endpoint on the
  internal port to indicate readiness.  This can be used by ECS or
  Kubernetes for liveness and readiness probes.

## Files Added

| File | Purpose |
| --- | --- |
| `Dockerfile` | Defines a multi‑stage build that compiles PHP dependencies and assembles a minimal runtime image. |
| `.dockerignore` | Excludes files and directories not needed in the build context to reduce build size. |
| `docker/nginx.conf` | Nginx configuration serving the `public` directory, proxying PHP requests and setting security headers. |
| `docker/php.ini` | Custom PHP configuration with sensible production defaults (memory limit, upload limits, opcache, etc.). |
| `docker/supervisord.conf` | Supervisor configuration running php‑fpm and Nginx together in the `web` mode. |
| `docker/entrypoint.sh` | Entrypoint script that performs one‑time setup (key generation, migrations, caching) and then starts the appropriate service. |
| `docker/run-web.sh` | Helper wrapper to start the web stack (supervisor) – used when overriding the command. |
| `docker/run-worker.sh` | Helper wrapper to start the background queue worker. |
| `docker/run-scheduler.sh` | Helper wrapper to start the Laravel scheduler. |
| `docker-compose.yml` | Local testing stack including BookStack, MariaDB and Redis for a full application experience. |

No application source files are modified.  Environment variables
control all runtime behaviour.

## Build Instructions

1. Ensure you have a BookStack source tree checked out.  The
   `release` branch is recommended.  The manual install guide
   requires copying `.env.example` to `.env` and making storage
   directories writable; however these steps are
   automated in the container.
2. Build the image:

   ```bash
   docker build -t your-registry/bookstack:latest .
   ```

   Replace `your-registry` with your registry prefix.  The build
   process installs the required PHP extensions and vendors via
   Composer in the builder stage.

3. Run the image in the desired mode.  For example, to start the web
   server locally on port 8080:

   ```bash
   docker run --rm -p 8080:8080 \
     -e APP_KEY=base64:… \
     -e DB_HOST=db.example.com \
     -e DB_DATABASE=bookstack \
     -e DB_USERNAME=bookstack \
     -e DB_PASSWORD=… \
     -e CACHE_DRIVER=redis \
     -e SESSION_DRIVER=redis \
     -e REDIS_SERVERS=redis.example.com:6379:0 \
     -e STORAGE_TYPE=s3 \
     -e STORAGE_S3_KEY=… \
     -e STORAGE_S3_SECRET=… \
     -e STORAGE_S3_BUCKET=my-bucket \
     -e STORAGE_S3_REGION=eu-west-1 \
     your-registry/bookstack:latest web
   ```

   Replace values with your own environment.  See **Configuration**
   below for all supported variables.

## Configuration & High Availability

### Database

* Use Amazon RDS for a managed MySQL database.  The BookStack
  requirements state support for MySQL ≥ 5.7 or MariaDB ≥ 10.2.
  AWS’s MySQL 8.0 Multi‑AZ deployment is recommended because it offers
  automatic failover, performance enhancements and compatibility with
  BookStack’s utf8mb4 character set.  Configure the following
  variables:

  | Variable | Description |
  | --- | --- |
  | `DB_CONNECTION` | Set to `mysql`. |
  | `DB_HOST` | Endpoint of your RDS instance. |
  | `DB_PORT` | Port (default `3306`). |
  | `DB_DATABASE` | Database name. |
  | `DB_USERNAME` / `DB_PASSWORD` | Credentials with full permissions on the database. |
  | `MYSQL_ATTR_SSL_CA` | Optional path to a CA bundle within the container to enable TLS.  Mount the RDS root certificate and set this variable to its path to enforce encryption in transit. |

### Cache & Sessions

The default BookStack installation stores session and cache data on the
local filesystem which does not work across multiple containers.  The
BookStack documentation recommends setting both cache and session
  drivers to Redis.  Use a highly available
managed Redis service (for example Amazon ElastiCache with automatic
failover) and point the environment variables at its primary endpoint.
  Avoid providing multiple hosts to BookStack as this triggers client
  side sharding without failover.

| Variable | Description |
| --- | --- |
| `CACHE_DRIVER` | Must be `redis` in HA setups. |
| `SESSION_DRIVER` | Must be `redis` in HA setups. |
| `REDIS_SERVERS` | `host:port:db[:password]`.  Provide a single primary endpoint only. |
| `QUEUE_CONNECTION` | Set to `redis` so queued jobs are also stored in Redis. |

You can optionally configure session cookies to be sent only over
HTTPS (`SESSION_SECURE_COOKIE=true`) and adjust session lifetime
(`SESSION_LIFETIME`).

### Storage

Uploaded files cannot be stored on the container filesystem when
running multiple replicas.  BookStack supports using Amazon S3 for
uploads.  To enable S3 storage set the following variables in your
environment:

| Variable | Description |
| --- | --- |
| `STORAGE_TYPE` | Must be `s3` for production. |
| `STORAGE_S3_KEY` / `STORAGE_S3_SECRET` | AWS access key and secret key.  Grant only the permissions required to write to the bucket. |
| `STORAGE_S3_BUCKET` | Name of the bucket.  Ensure it exists and is versioned. |
| `STORAGE_S3_REGION` | AWS region of the bucket (e.g., `eu-west-1`). |
| `STORAGE_URL` | (Optional) Custom base URL for serving images via a CDN or custom domain. |

Image uploads are made public in S3 by design.  Attachments remain private and are streamed through the application.  Ensure your
bucket policies restrict access accordingly.  For local testing set
`STORAGE_TYPE=local` to store uploads in `public/uploads`.

### Application Key & Migrations

An application key is required to encrypt sessions and other
sensitive data.  When `APP_KEY` is undefined and
`ALLOW_APP_KEY_GENERATION=true`, the entrypoint will run `php artisan
key:generate` once at startup.  In
production you should provision a stable key via environment
management and disable automatic generation.  Similarly, database
migrations can be executed during deployment by setting
`RUN_MIGRATIONS=true`.  When running multiple replicas migrations
should be executed as a one‑off task to avoid race conditions.

### Reverse Proxy & HTTPS

When running behind a load balancer configure `APP_URL` to the
external HTTPS URL of your instance.  Enable
`SESSION_SECURE_COOKIE=true` so cookies are only sent over HTTPS.
If your load balancer terminates TLS set `TRUSTED_PROXIES` (supported
by Laravel) to the CIDR ranges of your load balancer so that
BookStack correctly interprets `X‑Forwarded‑Proto` and other headers.

### Logging

All logs are written to stdout/stderr and can be collected by the
orchestrator.  The application log inside `storage/logs` is still
written by Laravel; mounting this directory to persistent storage is
optional.  Set `LOG_CHANNEL=stderr` to send Laravel logs to stderr if
desired.

## Operational Notes

* **Rolling deployments:** Use a readiness probe based on the
  `/status` endpoint.  Set the orchestrator to perform rolling updates
  with a minimum of one healthy replica during deployment.  Do not
  enable migrations during normal deployments; run them separately via
  a one‑off task.
* **Database TLS:** Download the AWS RDS root certificate and mount it
  into the container.  Then set `MYSQL_ATTR_SSL_CA=/path/to/ca.pem` to
  enforce encrypted connections.
* **Scaling workers:** Increase the number of `worker` replicas to
  process jobs in parallel.  The same image is used but invoked with
  `command: worker`.
* **Secrets management:** Use AWS Secrets Manager or Parameter Store
  to inject sensitive values as environment variables.  Secrets are
  never baked into the image.

## Why These Choices?

* **PHP & dependencies:** BookStack requires PHP ≥ 8.2 and a number of
  extensions.  These are installed explicitly in the
  builder stage to ensure compatibility and to avoid unnecessary
  packages.  Optional extensions like LDAP are not installed by
  default but can be added if needed.
* **MySQL 8.0 on RDS:** MySQL 8.0 offers improved performance,
  window functions and other modern features while remaining fully
  supported by BookStack.  AWS’s Multi‑AZ deployments provide
  automatic fail‑over and durability.
* **Redis for cache & sessions:** Storing sessions and cache in Redis
  avoids filesystem dependencies and scales out cleanly.
  Providing a single primary endpoint sidesteps client‑side sharding
  which would break fail‑over.
* **S3 for uploads:** The official documentation describes how to
  configure S3 by setting `STORAGE_TYPE=s3` and associated credentials
  and bucket details.  This offloads storage from
  the container and allows unlimited horizontal scaling.  Upload
  limits and other behaviour can be tuned via environment variables
  without modifying code.

## Next Steps

See `LOCAL_TESTING.md` for instructions on testing this setup locally
using Docker Compose.