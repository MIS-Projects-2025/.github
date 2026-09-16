# Deployment Guide: Adding a New App

Steps for onboarding a new app into the shared Docker/WSL2 environment at `/var/www`.

Replace `<app-name>` with your app's folder name (must match everywhere), and `<port>` with your chosen port.

---

## 1. Pick a port

Decide on the port this app will run on (e.g. `8306`). Check `nginx/default.conf` and `docker-compose.yml` to make sure it isn't already taken.

## 2. Clone the repo

```bash
# Open WSL, navigate to /var/www, use VS Code from there
cd /var/www
code .

# Clone from the MIS-Projects-2025 org
git clone https://github.com/MIS-Projects-2025/<app-name>.git
```

> The cloned folder name **must** match `<app-name>` used everywhere else below.

## 3. Add an nginx server block

In `nginx/default.conf`, add:

```nginx
server {
    listen <port>;
    root /var/www/<app-name>/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass <app-name>:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /var/www/public$fastcgi_script_name;
        include fastcgi_params;
    }
}
```

## 4. Add the service to `docker-compose.yml`

Add the new port to the `nginx` service:

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      # ...existing ports
      - "<port>:<port>"
    volumes:
      # ...existing volumes
      - /var/www/<app-name>:/var/www/<app-name>
    depends_on:
      # ...existing services
      <app-name>:
        condition: service_started
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: always
```

Then add the app's own service block (copy the pattern from an existing app, e.g. `facility-checklist` or `jorf`):

```yaml
<app-name>:
  build:
    context: /var/www/php
  volumes:
    - /var/www/<app-name>:/var/www
  environment:
    - APP_ENV=production
  extra_hosts:
    - "host.docker.internal:host-gateway"
  restart: always
```

## 5. Configure `.env`

```env
APP_NAME=<app-name>
APP_DISPLAY_NAME='<App Display Name>'
APP_URL=http://192.168.20.21:<port>
APP_TIMEZONE=Asia/Manila
APP_ENV=local
APP_KEY=base64:CtvfxAkkZBwHNnCXTAZNApE+9+bQpqBke3VmKiuYXfo=
APP_DEBUG=false

APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_FAKER_LOCALE=en_US

APP_MAINTENANCE_DRIVER=file
SSO_COOKIE_NAME=sso_token
PHP_CLI_SERVER_WORKERS=4

BCRYPT_ROUNDS=12

LOG_CHANNEL=stack
LOG_STACK=single
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug
```

And the database connection:

```env
DB_CONNECTION=mysql
DB_HOST=192.168.20.20
DB_PORT=6446
DB_DATABASE=<app-name>
DB_OUTPUT_MONITORING_DATABASE=output_monitoring
DB_USERNAME=clusteradmin
DB_PASSWORD=clusteradmin123
```

## 6. Build and start the app container

```bash
docker compose up -d --build <app-name>
```

## 7. Install dependencies and run Laravel setup

```bash
docker compose exec -it <app-name> bash
```

Inside the container:

```bash
composer install
php artisan migrate
# ...any other artisan commands needed (php artisan key:generate, db:seed, etc.)
exit
```

## 8. Build frontend assets

Back in `/var/www/<app-name>` (outside the container):

```bash
npm i
npm run build
```

## 9. Recreate nginx and restart the app

```bash
docker compose up -d nginx
docker compose restart <app-name>
```

---

## Checklist

- [ ] Port chosen and confirmed free
- [ ] Repo cloned into `/var/www/<app-name>`
- [ ] nginx server block added
- [ ] `docker-compose.yml` updated (nginx ports/volumes/depends_on + app service block)
- [ ] `.env` configured (app + database)
- [ ] Container built (`docker compose up -d --build <app-name>`)
- [ ] `composer install` + migrations run
- [ ] `npm i && npm run build`
- [ ] nginx recreated, app restarted
