# Replication Guide (App + Supabase + Redis)

This guide recreates the **full stack** on a new server with **no data**. It includes:
- TitanFlow app (Elixir/Phoenix)
- Supabase (self-hosted via Docker)
- Redis
- Nginx + systemd

If you need **data migration**, see the optional section at the end.

---

## 0) Assumptions
- New server: Ubuntu 22.04 (or similar)
- Target paths:
  - App: `/root/titan_flow`
  - Supabase: `/root/supabase/docker`
- You already have a GitHub repo with the latest code.
- You want **same components and config** as this server (but empty data).

---

## 1) System Prep (one-time)

### 1.1 Update OS + base tools
```bash
apt-get update -y
apt-get upgrade -y
apt-get install -y git curl unzip build-essential ca-certificates
```

### 1.2 Set timezone to IST
```bash
timedatectl set-timezone Asia/Kolkata
```

### 1.3 Install Docker + Compose plugin
```bash
apt-get install -y docker.io docker-compose-plugin
systemctl enable --now docker
```

### 1.4 Install Redis
```bash
apt-get install -y redis-server
```

### 1.5 Install Nginx
```bash
apt-get install -y nginx
systemctl enable --now nginx
```

### 1.6 Install Elixir/Erlang via asdf
```bash
apt-get install -y libssl-dev libncurses5-dev libreadline-dev
apt-get install -y libwxgtk3.0-gtk3-dev libgl1-mesa-dev libglu1-mesa-dev
apt-get install -y libxml2-utils xsltproc fop

# asdf
if [ ! -d "$HOME/.asdf" ]; then
  git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
fi
. ~/.asdf/asdf.sh

asdf plugin add erlang || true
asdf plugin add elixir || true

# Match the versions used here
asdf install erlang 25.3.2.12
asdf install elixir 1.16.3-otp-25
asdf global erlang 25.3.2.12
asdf global elixir 1.16.3-otp-25
```

---

## 2) Clone the App Repo
```bash
cd /root
git clone https://github.com/ggs-mudraserve/titan_flow.git
cd /root/titan_flow
```

---

## 3) Supabase Setup (Docker)

### 3.1 Copy Supabase Docker stack from current server
On **current server**, copy `/root/supabase/docker` to new server:
```bash
# Example (run on current server):
rsync -avz /root/supabase/docker root@NEW_SERVER_IP:/root/supabase/
```

### 3.2 Configure Supabase
On **new server**:
```bash
cd /root/supabase/docker
cp .env.example .env
```
Now edit `/root/supabase/docker/.env` to match your current server’s Supabase config.
Key items:
- `POSTGRES_PASSWORD`
- `JWT_SECRET`
- `ANON_KEY`, `SERVICE_ROLE_KEY`
- `SITE_URL`, `API_EXTERNAL_URL`

### 3.3 Start Supabase
```bash
docker compose up -d
```
Verify containers:
```bash
docker ps
```

---

## 4) Redis Setup

Edit `/etc/redis/redis.conf`:
```
requirepass <your_password>
```
(Optional) adjust memory policy if needed:
```
maxmemory 4gb
maxmemory-policy allkeys-lru
```
Restart Redis:
```bash
systemctl restart redis-server
```
Verify:
```bash
redis-cli -a <your_password> ping
```

---

## 5) App Environment Config

Copy `.env.production` from the current server, then edit:
```bash
cp /root/titan_flow/.env.production /root/titan_flow/.env.production
```
Update:
- `PHX_HOST` (your domain)
- `PORT` (default 4001)
- `DATABASE_HOST=127.0.0.1`
- `DATABASE_PORT=6543` (Supavisor)
- `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_NAME`
- `REDIS_HOST=127.0.0.1`, `REDIS_PASSWORD`
- `SECRET_KEY_BASE`, `ADMIN_PIN`

---

## 6) Build + Deploy App

```bash
cd /root/titan_flow
PATH=/root/.asdf/shims:$PATH ./deploy.sh build
PATH=/root/.asdf/shims:$PATH ./deploy.sh deploy
```
This does:
- `mix ecto.migrate` (creates all app tables)
- restarts the `titan_flow` systemd service

Check status:
```bash
systemctl status titan_flow --no-pager -l
```

---

## 7) Nginx + SSL

### 7.1 Nginx config
Copy `deploy/nginx.conf` from current server and edit host/port:
```bash
cp /root/titan_flow/deploy/nginx.conf /etc/nginx/sites-available/titan_flow
ln -sf /etc/nginx/sites-available/titan_flow /etc/nginx/sites-enabled/titan_flow
nginx -t
systemctl reload nginx
```

### 7.2 SSL (optional)
```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d your.domain.com
```

---

## 8) Meta Webhooks
Update Meta webhook URL + verify token to your new server:
- Verify token must match `WEBHOOK_VERIFY_TOKEN` in `.env.production`
- Update callback URL to `https://your.domain.com/api/webhooks/whatsapp`

---

## 9) Sanity Checks

### 9.1 App health
```bash
curl -I http://127.0.0.1:4001/
```

### 9.2 DB connectivity
```bash
PGPASSWORD="<db_pass>" psql -h 127.0.0.1 -p 6543 -U <db_user> -d titan_flow -c "select 1;"
```

### 9.3 Redis
```bash
redis-cli -a <redis_pass> ping
```

---

## 10) What This Replicates

This process gives you:
- Same **Supabase services** (auth/storage/etc)
- Same **Redis** setup (empty data)
- Same **app schema + migrations**
- Same **runtime configs** (after copying .env files)

It does **not** copy data unless you explicitly migrate it.

---

## Optional: Data Migration

If you want to migrate data later:

### Postgres
```bash
# On old server
pg_dump -Fc -h 127.0.0.1 -p 6543 -U <db_user> titan_flow > /tmp/titan_flow.dump

# Copy to new server, then restore
pg_restore -h 127.0.0.1 -p 6543 -U <db_user> -d titan_flow /tmp/titan_flow.dump
```

### Redis (optional)
If you want to transfer Redis data, use:
- `SAVE` + copy `dump.rdb`, or
- `redis-cli --rdb` export

---

## Notes
- Always update secrets on the new server (JWT/keys/passwords).
- Migrations create all **latest app tables**, so the schema always matches the repo.
- Supabase config is controlled by the Docker `.env` file, so keep that in sync.
