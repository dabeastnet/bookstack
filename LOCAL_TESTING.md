# Local Testing Guide

This guide explains how to run the container locally using
Docker Compose.  It covers verifying the `/status` endpoint, creating
an admin user, testing session sharing across replicas and verifying
upload functionality in both local and S3 modes.

## Prerequisites

* Docker and Docker Compose installed.
* A BookStack source tree containing this repository.  The
  `docker-compose.yml` file included here defines services for BookStack,
  MariaDB and Redis.

## Getting Started

1. **Copy the environment file** (only required if you want to modify
   defaults).  The `docker-compose.yml` uses environment variables
   defined inline.  To customise them you can create a `.env` file in
   the project root with any overrides.

2. **Build and start the stack**:

   ```bash
   docker compose up --build
   ```

   This command will build the BookStack image, start a MariaDB
   instance with a `bookstack` database and user, a Redis instance
   and three BookStack containers: `bookstack` (web), `worker` and
   `scheduler`.  The web interface will be available at
   http://localhost:8080.

3. **Create an admin account**.  When BookStack starts for the first
   time it generates an application key and runs migrations (because
   `ALLOW_APP_KEY_GENERATION=true` and `RUN_MIGRATIONS=true` are set in
   `docker-compose.yml`).  Browse to `http://localhost:8080` and log
   in with the default credentials `admin@admin.com` / `password`.  You
   should immediately change these details via the web UI.

4. **Verify the `/status` endpoint**.  BookStack exposes a JSON
   status endpoint at `/status` which will return a 200 status code
   when the application is healthy.  Fetch it using curl:

   ```bash
   curl -s http://localhost:8080/status | jq
   ```

   A successful response will include database, cache and queue status.
   The healthcheck in the Dockerfile uses the same endpoint.

5. **Test session sharing**.  To ensure sessions are stored in Redis
   rather than the filesystem open two browser windows and log in to
   BookStack.  In the first terminal run:

   ```bash
   docker compose up --scale bookstack=2
   ```

   This will start a second web replica attached to the same Redis and
   database.  Refresh the page in both windows; you should remain
   logged in across both replicas.  If you become logged out when the
   container is restarted check that `CACHE_DRIVER=redis` and
   `SESSION_DRIVER=redis` are set.

6. **Test uploads in local mode**.  In your BookStack instance go to
   **Settings → Customization** and upload an image or file.  Files
   will be stored under `public/uploads/images` or
   `storage/uploads/files` depending on your settings.  Because the
   local storage is within the container, uploads will not persist
   across rebuilds; this is acceptable for local development.  Use
   `docker compose down -v` to remove the database and uploads.

7. **Test uploads in S3 mode** (optional).  To test S3 integration
   locally you need access to an S3 bucket or an S3‑compatible
   service.  Set the following variables on the `bookstack`, `worker`
   and `scheduler` services in `docker-compose.yml`:

   ```yaml
   environment:
     STORAGE_TYPE: s3
     STORAGE_S3_KEY: your-key
     STORAGE_S3_SECRET: your-secret
     STORAGE_S3_BUCKET: your-bucket
     STORAGE_S3_REGION: your-region
   ```

   Rebuild and start the stack.  Uploading an image should place it
   into your bucket under the `uploads/images` prefix.  To
   verify attachments remain private, download a file via BookStack and
   check that it is not publicly accessible from the bucket.

8. **Test the worker and scheduler**.  Create a page and upload a
   large image; the image processing job should appear in the queue.
   The `worker` service processes queued jobs; monitor its logs with:

   ```bash
   docker compose logs -f worker
   ```

   To test scheduled tasks, check the audit log or scheduled email
   reminders if enabled.  The `scheduler` service runs once per
   minute using the `schedule:work` command.

9. **Tear down**.  When finished stop the containers:

   ```bash
   docker compose down
   ```

   Add `-v` to remove volumes (`db-data`) and start fresh next time.

## Testing the Built Image Directly

If you wish to test the built image outside of Docker Compose you can
run it manually.  Replace the variables with your own values:

```bash
docker build -t bookstack-test .

docker run --rm -p 8080:8080 \
  -e APP_KEY=base64:… \
  -e DB_HOST=host.docker.internal \
  -e DB_DATABASE=bookstack \
  -e DB_USERNAME=bookstack \
  -e DB_PASSWORD=secret \
  -e CACHE_DRIVER=redis \
  -e SESSION_DRIVER=redis \
  -e REDIS_SERVERS=host.docker.internal:6379:0 \
  -e STORAGE_TYPE=local \
  bookstack-test web
```

In a second terminal start a MySQL and Redis server (for example
`docker run --name mysql -e MYSQL_ROOT_PASSWORD=secret -e
MYSQL_DATABASE=bookstack -e MYSQL_USER=bookstack -e MYSQL_PASSWORD=secret -p
3306:3306 -d mariadb:11.2` and similarly for Redis).  The container
will perform initial setup and then you can access BookStack on
http://localhost:8080.

## Troubleshooting

* **Migrations run on every start.**  Ensure that
  `RUN_MIGRATIONS=true` is only set for the first start.  Subsequent
  starts should have this unset to avoid concurrency issues.
* **Invalid APP_KEY errors.**  Set `ALLOW_APP_KEY_GENERATION=true` for
  the first run or provide an existing `APP_KEY` yourself.  Once
  generated the key is stored in your environment and should not
  change across replicas.
* **Access over HTTPS.**  When testing behind a reverse proxy (such as
  Traefik or an ELB) set `APP_URL` to the external URL and configure
  trusted proxies via Laravel’s `TRUSTED_PROXIES` option.