
# Adding a New Laravel App to the MIS Infrastructure

This guide covers the complete process of deploying a new Laravel application to the MIS server (`MIS-WS02` / `192.168.2.221`) running Docker + nginx + PHP-FPM on WSL2.

quick reminder: if you encounter permission/role errors when executing any commands inside wsl terminal, prepend them with 'sudo'.
```
# example
sudo docker ps
```

----------

## Table of Contents

1.  [Prerequisites](#prerequisites)
2.  [Infrastructure Overview](#infrastructure-overview)
3.  [Docker Desktop Configuration](#docker-desktop-configuration)
4.  [Ubuntu Ownership and Permission](#ubuntu-ownership-and-permission)
5.  [Step-by-Step Deployment](#step-by-step-deployment)
    -   [Step 1 — Clone the Repository](#step-1--clone-the-repository)
    -   [Step 2 — Set File Permissions](#step-2--set-file-permissions)
    -   [Step 3 — Configure the Environment File](#step-3--configure-the-environment-file)
    -   [Step 4 — Update `docker-compose.yml`](#step-4--update-docker-composeyml)
    -   [Step 5 — Add an nginx Server Block](#step-5--add-an-nginx-server-block)
    -   [Step 6 — Install Composer Dependencies](#step-6--install-composer-dependencies)
    -   [Step 7 — Build Frontend Assets](#step-7--build-frontend-assets)
    -   [Step 8 — Bootstrap the Application](#step-8--bootstrap-the-application)
    -   [Step 9 — Restart Docker Services](#step-9--restart-docker-services)
6.  [Scripts Reference](#scripts-reference)
7.  [Dockerfile Reference](#dockerfile-reference)
8.  [Nginx Reference](#nginx-reference)
9.  [Docker Compose Reference](#docker-compose-reference)
10.  [Opcache Reference](#opcache-reference)
11. [Entrypoint Reference](#entrypoint-reference) 
12. [Port Assignments](#port-assignments)
13. [WSL Node Installation](#wsl-node-installation)
14. [Troubleshooting](#troubleshooting)
	-   [502 Bad Gateway](#502-bad-gateway)
	-   [500 Internal Server Error](#500-internal-server-error)
	-   [Blank page or missing assets](#blank-page-or-missing-assets)
	-   [DB connection refused inside container](#db-connection-refused-inside-container)
	-   [Changes to default.conf not reflected](#changes-to-defaultconf-not-reflected)
	-   [Stray newline after <?php causing silent failures](#stray-newline-after-php-causing-silent-failures)
	-   [Linux case sensitivity breaking imports](#linux-case-sensitivity-breaking-imports)
----------

## Prerequisites

Before adding a new app, make sure the following are in place:
-   You already have Node js installed in Ubuntu. If not, refer to [WSL Node Installation](#wsl-node-installation)
-   You have SSH access to `MIS-WS02` (192.168.2.221) or are working inside the WSL2 instance directly. You can also remote into it. Ask the MIS team for the WSL2 Ubuntu credentials if you don't have them yet.
-   You installed WSL 2 (not WSL 1. this is important 😉😉😉)
-   You have set up the following files (see [Infrastructure Overview](#infrastructure-overview), the files and folders must match that!!) (see [Table of Contents to see the files' reference](#table-of-contents)):
	- php/Dockerfile
	- php/entrypoint.sh
	- nginx/default.conf
	- docker-compose.yml
	- scripts/setup-app-perms.sh
-   Docker and Docker Compose are running (`docker ps` returns active containers)
-   You have the Git repository URL for the new application
-   A port has been decided for the new app (see [Port Assignments](#port-assignments))
-   The app's `.env` values (DB credentials, `APP_KEY`, etc.) are available

----------

## Infrastructure Overview

```
/var/www/
│
├── nginx/
│   └── default.conf          # All nginx server blocks live here
│
├── php/
│   ├── Dockerfile            # Shared PHP-FPM 8.2 image (used by all apps)
│   ├── opcache.ini           # OPcache configuration
│   └── entrypoint.sh         # Container entrypoint
│
├── docker-compose.yml        # All services defined here
│
├── scripts/
│   └── setup-app-perms.sh    # Permission setup script
│
├── facility-checklist/       # App
├── jorf/                     # App
└── <new-app>/                # ← Your new app goes here

```

## Docker Desktop Configuration
Open Windows' Docker Desktop > Settings > Resources > WSL Integration
1. check the "enable integration with my default WSL distro
2. Toggle "Ubuntu" on under "Enable integration with additional distros"

### How it works

Each Laravel app gets:

-   Its own **PHP-FPM service** in `docker-compose.yml` (built from the shared `/var/www/php/Dockerfile`)
-   Its own **nginx server block** in `nginx/default.conf` that proxies `.php` requests to that PHP-FPM service
-   Its own **port** exposed on the host

nginx and all PHP-FPM containers share the same Docker network, so nginx can reach each service by its container name (e.g., `facility-checklist:9000`).

----------

## Ubuntu Ownership and Permission
Give yourself the ability to mutate files/folder inside /var/www/. So that you can tinker inside it using Windows File Explorer.

```bash
sudo chown -R $(whoami):$(whoami) /var/www/scripts
```
```bash
sudo chmod -R 755 /var/www/scripts
```

## Step-by-Step Deployment

### Step 1 — Clone the Repository

Open a WSL2 terminal and navigate to `/var/www`, then clone the app:

```bash
cd /var/www
git clone https://github.com/MIS-Projects-2025/<repo-name>.git <app-folder-name>

```

> **Convention:** Use a short, lowercase, hyphenated name for the folder (e.g., `ppc-portal`, `hr-system`). This name will also be used as the Docker service name and nginx upstream.

----------

### Step 2 — Set File Permissions

Laravel requires that the `storage/` and `bootstrap/cache/` directories are writable by the PHP-FPM process (`www-data`, UID `33`). Your WSL user also needs ownership of the rest of the app for development.

Run the permissions script from the WSL terminal:

```bash
bash /var/www/scripts/setup-app-perms.sh <app-folder-name>

```

> See [Scripts Reference](#scripts-reference) for what this script does.

If `bootstrap/cache` does not exist yet (fresh clone), create it first:

```bash
mkdir -p /var/www/<app-folder-name>/bootstrap/cache

```

Then re-run the permissions script.
#### ⚠️ What about writable folders inside `public/`?

Some developers place upload directories directly under `public/` (e.g., `public/uploads/`) and grant `www-data` write access to them. **This is not recommended.**

`public/` is the webroot — everything in it is directly accessible via URL. Giving PHP-FPM write access to it means a vulnerability (e.g., an unrestricted file upload flaw) could allow an attacker to drop a PHP web shell inside a writable folder and execute it through the browser, bypassing every layer of Laravel's security.

**The correct alternative is to use Laravel's storage system:**

1.  Store uploads to `storage/app/public/<subfolder>/` — already writable by `www-data`
2.  Run `php artisan storage:link` once during setup — creates a `public/storage` symlink pointing to `storage/app/public/`
3.  Reference files via `Storage::url()` or `asset('storage/...')` in the app

This keeps uploaded files outside the webroot while still being publicly accessible through the symlink.

**If a developer absolutely must write to a folder under `public/`** (e.g., a legacy integration that cannot be changed), apply ownership to that specific subfolder only — never to all of `public/`:

bash
```bash
# Only do this if there is no alternative
sudo chown -R 33:33 /var/www/<app-folder-name>/public/<specific-subfolder>
```
Also ensure the folder blocks PHP execution via nginx by adding this to the app's server block in `default.conf`:

nginx
```nginx
location ~* /public/<specific-subfolder>/.*\.php$ {
    deny all;
}
```
Without that rule, any `.php` file uploaded into that folder is executable via URL.

----------

### Step 3 — Configure the Environment File

```bash
cd /var/www/<app-folder-name>
cp .env.example .env

```

Open `.env` in VS Code (via Remote SSH or `code .env`) and configure at minimum:

```dotenv
APP_NAME="Your App Name"
APP_ENV=production
APP_KEY=                        # Leave blank — generated in Step 8
APP_DEBUG=false
APP_URL=http://192.168.2.221:<port>

DB_CONNECTION=mysql
DB_HOST=host.docker.internal    # IMPORTANT: use this, not localhost or 127.0.0.1
DB_PORT=3306
DB_DATABASE=<database_name>
DB_USERNAME=<db_user>
DB_PASSWORD=<db_password>

```

> **`DB_HOST=host.docker.internal`** is required because the DB runs on the host (or another container), not inside the PHP-FPM container. The `extra_hosts` entry in `docker-compose.yml` maps this hostname to the host gateway automatically.

----------

### Step 4 — Update `docker-compose.yml`

Open `/var/www/docker-compose.yml` and make **two additions**:

#### 4a — Add a new PHP-FPM service

Add this block under `services:`, following the same pattern as existing apps:

```yaml
  <app-folder-name>:
    build:
      context: /var/www/php
    volumes:
      - /var/www/<app-folder-name>:/var/www
    environment:
      - APP_ENV=production
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped

```

#### 4b — Register the app in the `nginx` service

Under the `nginx` service, add to **`ports`**:

```yaml
      - "<port>:<port>"

```

Add to **`volumes`**:

```yaml
      - /var/www/<app-folder-name>:/var/www/<app-folder-name>

```

Add to **`depends_on`**:

```yaml
      - <app-folder-name>

```

----------

### Step 5 — Add an nginx Server Block

Open `/var/www/nginx/default.conf` and append a new `server {}` block:

```nginx
server {
    listen <port>;
    root /var/www/<app-folder-name>/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass <app-folder-name>:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /var/www/public$fastcgi_script_name;
        include fastcgi_params;
    }
}

```

> Replace `<port>` and `<app-folder-name>` with the actual values. The `fastcgi_pass` value must exactly match the service name in `docker-compose.yml` — that's how nginx resolves the PHP-FPM container by name.

----------

### Step 6 — Install Composer Dependencies

Since PHP and Composer live **inside the Docker container** (not on the host), you run `composer install` through Docker Compose.

First, bring up only the new service:

```bash
cd /var/www
docker compose up -d <app-folder-name>

```

Then exec into it and run Composer:

```bash
docker compose exec <app-folder-name> composer install --no-dev --optimize-autoloader

```

----------

### Step 7 — Build Frontend Assets

Node.js runs on the **WSL2 host**, not inside the PHP-FPM container, so these commands run directly in the app directory — no `docker compose exec` needed.

```bash
cd /var/www/<app-folder-name>
npm install
npm run build

```

`npm run build` invokes Vite, which compiles and fingerprints all JS/CSS assets into `public/build/`. The manifest file it generates (`public/build/manifest.json`) is what Laravel uses at runtime to resolve hashed asset filenames.

> **Don't skip this step.** Without a build, the app will either serve no styles/scripts or throw a `Vite manifest not found` exception.

#### If the app uses the `caseInsensitiveResolver` Vite plugin

Check `vite.config.js` — if the plugin is present (as it is in the PPC Portal), no extra action is needed; it runs automatically as part of `npm run build`. If you're setting up a new app and deploying to Linux for the first time, copy the plugin from an existing app to avoid case-sensitivity import failures. See [Linux case sensitivity breaking imports](#linux-case-sensitivity-breaking-imports).

----------

### Step 8 — Bootstrap the Application

Run the standard Laravel setup commands via `docker compose exec`:

```bash
# Generate the application key (fills APP_KEY in .env)
docker compose exec <app-folder-name> php artisan key:generate

# Run database migrations
docker compose exec <app-folder-name> php artisan migrate --force

# Create the public storage symlink (if the app uses file uploads)
docker compose exec <app-folder-name> php artisan storage:link

# Cache config and routes for production performance
docker compose exec <app-folder-name> php artisan config:cache
docker compose exec <app-folder-name> php artisan route:cache
docker compose exec <app-folder-name> php artisan view:cache

```

> `--force` on migrate is required in production (`APP_ENV=production`) to bypass the confirmation prompt.

----------

### Step 9 — Restart Docker Services

Bring up the full stack so nginx picks up the new config and all services are running:

```bash
cd /var/www
docker compose up -d --build --no-deps <new-app>
docker compose up -d --no-deps nginx
```

> `--build` is only strictly needed if the shared PHP image changed. If you only added a new service entry (which uses the same `build: context: /var/www/php`), Docker Compose will reuse the cached image. It's safe to include it regardless.

Once up, verify the new app is reachable:

```
http://192.168.2.221:<port>

```
----------

## Scripts Reference

### `scripts/setup-app-perms.sh`

```bash
#!/bin/bash
set -e

APP_NAME=$1

if [ -z "$APP_NAME" ]; then
  echo "Usage: ./setup-app-perms.sh <app-folder-name>"
  exit 1
fi

APP_PATH="/var/www/$APP_NAME"

echo "Setting permissions for $APP_PATH..."

sudo chown -R $USER:$USER "$APP_PATH"
sudo chown -R 33:33 "$APP_PATH/storage"
sudo chown -R 33:33 "$APP_PATH/bootstrap/cache"

echo "Done."
```
**Usage:**
```bash
bash /var/www/scripts/setup-app-perms.sh ppc-portal
```

## Dockerfile Reference
```
# Uses the official PHP FPM (FastCGI) image
FROM php:8.2-fpm
# Install OS libraries required for PHP extensions to compile correctly
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    zip \
    unzip

# Installs and enables PHP extensions (Database, Image handling, and cache)
RUN docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd zip opcache

# Grabs Composer from the official image (Multi-stage build)
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Copies project-specific PHP configurations
COPY opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# Entrypoint script for runtime initialization tasks
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Sets the base path for all container commands
WORKDIR /var/www

# Runs the initialization script every time the container starts
ENTRYPOINT ["/entrypoint.sh"]

# The command that starts the actual PHP process
CMD ["php-fpm"]
```

## Nginx Reference
```
# Sets the max allowed size of the client request body for uploads
client_max_body_size 100M;

# Memory buffers to handle large PHP responses without hitting the disk
fastcgi_buffers 16 16k;
fastcgi_buffer_size 32k;
fastcgi_busy_buffers_size 32k;

# Time limit for Nginx to wait for a PHP response
fastcgi_read_timeout 300;

# Compression settings to reduce transfer size of text/assets
gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css application/json application/javascript text/xml;

server {
    listen 80; # Internal port for the container
    root /var/www/APP_NAME/public; # Mapping to the public-facing directory
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass PHP_SERVICE_NAME:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /var/www/public$fastcgi_script_name;
        include fastcgi_params;
    }
}

server {
		you another app here 🥰
}
```

## Docker Compose Reference
```bash
services:
  nginx:
    image: nginx:alpine # Minimal Linux footprint for efficiency
    ports:
      - "HOST_PORT:CONTAINER_PORT" # External:Internal port mapping
      - 8199:8199 # <- example. it's better for them to be the same
    volumes:
      - /var/www/nginx/default.conf:/etc/nginx/conf.d/default.conf # don't forget this part!!!
      - ./LOCAL_SRC:/var/www/TARGET_PATH # Syncs local files with container
    depends_on:
      - PHP_SERVICE_NAME # Ensures backend is up before web server
    extra_hosts:
      - "host.docker.internal:host-gateway" # Fix for container-to-host communication
    restart: unless-stopped # Restarts container on failure or system reboot

  PHP_SERVICE_NAME:
    build:
      context: /var/www/php # Path to the folder with the Dockerfile
    volumes:
      - /var/www/APP_NAME:/var/www # Mounts source for the PHP processor
    environment:
      - APP_ENV=production # Injects environment-specific variables
    restart: unless-stopped
```
## Opcache Reference
```
opcache.enable=1
opcache.memory_consumption1=128
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
```
## Entrypoint Reference
```
#!/bin/sh 
find /var/www -path "_/storage_" -exec chown www-data:www-data {} + \
	&& find /var/www -path "_/storage_" -exec chmod 775 {} +
find /var/www -path "_/bootstrap/cache_" -exec chown www-data:www-data {} + \
	&& find /var/www -path "_/bootstrap/cache_" -exec chmod 775 {} +
	
exec "$@"
```

## Port Assignments
### If you forgot this step, I'll be sad...
Keep a running record here to avoid port collisions.

|Port|App Name|
|--------|:-------------:|
|8190|facility-checklist|
|8191|jorf|
|8192|rhtemp|
|8193|tptms|
|8194|mts|
|8195|mis-is|
|8196|mis-pmcs|
|8197|rims|
|8198|(unassigned)|
|8199|ppc|
|8200|authify|
|8300|store|
|8301|management-log|

> When assigning a new port, pick the next available number and add a row to this table. If you forgot this step, I'll be sad...

----------

## WSL Node Installation
To avoid "UNC Path" errors and permission conflicts, you must use Linux-native build tools. Even if you have Node/NPM on Windows, they will not work correctly for projects stored inside the WSL file system.

Run these commands once to provision your WSL environment:
```
# Install NVM (Node Version Manager)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

# Reload bash configuration to activate nvm
source ~/.bashrc

# Install and use the latest LTS version of Node
nvm install 20

# VERIFY: The path must be in your home directory, NOT /mnt/c/
which npm
```
> **Note:** If which `npm still` returns a path starting with `/mnt/c/Program Files/...`, your terminal is still prioritizing the Windows version. Run nvm use 20 to force the Linux version for your session.

## Troubleshooting

### 502 Bad Gateway

nginx is running but can't reach the PHP-FPM container.

-   Confirm the service name in `fastcgi_pass` exactly matches the service name in `docker-compose.yml`
-   Check that the PHP-FPM container is running: `docker compose ps`
-   Check its logs: `docker compose logs <app-folder-name>`

### 500 Internal Server Error

Usually a Laravel misconfiguration.

-   Check `storage/logs/laravel.log` inside the container: `docker compose exec <app-folder-name> tail -n 50 storage/logs/laravel.log`
-   Confirm `APP_KEY` is set in `.env`
-   Confirm `storage/` and `bootstrap/cache/` are writable (rerun the permissions script)

### Blank page or missing assets

-   Make sure `npm run build` was run and `public/build/` exists
-   Make sure `php artisan storage:link` was run
-   Make sure `public/` is the nginx `root`, not `/var/www` or the app root

### DB connection refused inside container

-   Confirm `DB_HOST=host.docker.internal` (not `localhost`)
-   Confirm the `extra_hosts` entry is present in the service definition in `docker-compose.yml`
-   Check that the database exists and the credentials are correct

### Changes to `default.conf` not reflected

nginx config is bind-mounted, so a config reload is enough (no full rebuild needed):

```bash
docker compose exec nginx nginx -s reload
```
### Stray newline after `<?php` causing silent failures

**Symptom:** Redirects don't work, session cookies aren't set, middleware behaves unexpectedly — no error in the logs, no obvious cause.

**Cause:** A file (commonly `routes/web.php`, `bootstrap/app.php`, or similar) has an invisible BOM (Byte Order Mark) or a stray newline before or after the opening `<?php` tag. This causes PHP to emit output before any headers are sent. Laravel's redirect and session machinery silently breaks as a result.

This typically happens when a file is created or edited on Windows and saved with a BOM, or when an editor inserts a blank line above `<?php`.

**Fix:**
Check for the BOM or leading whitespace:

bash
```bash
cat -A routes/web.php | head -3
```
If you see `^M` characters or a blank first line, the file is affected.

Strip it using `sed`:
bash
```bash
sed -i '1{/^\xEF\xBB\xBF/d}' routes/web.php   # remove BOM
sed -i '/./,$!d' routes/web.php                 # remove leading blank lines
```
Or in VS Code: open the file, open the Command Palette (`Ctrl+Shift+P`), run **Change File Encoding**, and save as **UTF-8** (not UTF-8 with BOM).

**Prevention:** In VS Code settings, set `"files.encoding": "utf8"` and `"files.insertFinalNewline": true`. Never use UTF-8 with BOM for PHP files.

----------

### Linux case sensitivity breaking imports

**Symptom:** The app works locally on Windows or macOS but throws cryptic `Module not found` errors or blank pages after deployment to the Linux server.

**Cause:** Windows and macOS filesystems are case-insensitive — `import Foo from './foo'` resolves even if the file is named `Foo.jsx`. Ubuntu's filesystem is case-sensitive, so the same import fails if the casing doesn't match exactly.

This most commonly affects React component imports and Laravel class autoloading.

**Fix for frontend (Vite):** Add a `caseInsensitiveResolver` plugin to `vite.config.js` that normalizes import paths at build time. This was implemented across MIS apps to handle this exact issue — refer to the existing apps for the plugin implementation (**ppc portal has this**).

**Fix for PHP/Laravel:** Check that all `use` statements, class names, and filenames match in casing exactly. PHP autoloading on Linux will fail to find `App\Models\myModel` if the file is named `MyModel.php`.

**Prevention:** Always name files and write imports with consistent, exact casing from the start. Treat the Linux server as the source of truth, not your local machine.
