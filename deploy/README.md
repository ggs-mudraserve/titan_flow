# TitanFlow Production Deployment Guide

## Files Created

| File | Purpose |
|------|---------|
| `deploy.sh` | Main deployment script |
| `.env.production` | Environment variables |
| `deploy/titan_flow.service` | Systemd service |
| `deploy/nginx.conf` | Nginx reverse proxy |

---

## Step-by-Step Deployment

### 1. Install SSL Certificate (First Time Only)

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificate
sudo certbot certonly --standalone -d dashboard.getfastloans.in
```

### 2. Install Nginx Config

```bash
# Copy config
sudo cp /root/titan_flow/deploy/nginx.conf /etc/nginx/sites-available/titan_flow

# Enable site
sudo ln -sf /etc/nginx/sites-available/titan_flow /etc/nginx/sites-enabled/

# Test config
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

### 3. Build & Deploy Application

```bash
cd /root/titan_flow

# Build production release
./deploy.sh build

# Install systemd service (first time only)
./deploy.sh install

# Deploy (runs migrations + restarts)
./deploy.sh deploy
```

### 4. Useful Commands

```bash
# Check status
./deploy.sh status

# View live logs
./deploy.sh logs

# Restart service
./deploy.sh restart

# Full rebuild + deploy
./deploy.sh full
```

---

## Verify Deployment

```bash
# Check service
sudo systemctl status titan_flow

# Check logs
sudo journalctl -u titan_flow -f

# Test HTTPS
curl -I https://dashboard.getfastloans.in/
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Service won't start | Check logs: `journalctl -u titan_flow -n 50` |
| Database connection | Verify Supavisor is running on port 6543 |
| Nginx 502 | Check Phoenix is running on port 4000 |
| SSL errors | Run `sudo certbot renew` |
