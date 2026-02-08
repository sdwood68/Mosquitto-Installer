# Mosquitto MQTT VPS Installer (Ubuntu 24.04 LTS)

This repo installs and configures an internet-facing Mosquitto broker with:
- MQTT over TLS (port 8883) by default
- Let’s Encrypt automation (certbot standalone)
- A renewal **deploy hook** that restarts Mosquitto after successful certificate renewal
- Username/password authentication (no anonymous)
- Optional ACL enforcement (recommended)
- UFW firewall rules (SSH + MQTT; port 80 for LE challenge)

## What is an ACL?

**ACL** stands for **Access Control List**. In Mosquitto, an ACL is a set of rules that controls **which users can publish and/or subscribe to which topics**.

- **Passwords authenticate** (“who are you?”).
- **ACLs authorize** (“what are you allowed to do?”).

If you want “a username/password per top-level topic”, you *need* ACLs, otherwise any valid user could read/write any topic.

## Files
- `install_mosquitto_vps.sh` — install + configure Mosquitto + certbot + renewal hook
- `uninstall_mosquitto_vps.sh` — remove managed config and data; optionally purge packages
- `mosquitto.env.example` — template config (safe to commit)
- `scripts/cert_health_check.sh` — prints cert expiry + days remaining
- `.gitignore` — prevents committing secrets

## Prerequisites
1. DNS for your broker name must resolve to your VPS public IP.
2. Inbound ports allowed at both provider firewall and UFW:
   - 22/tcp (SSH)
   - 80/tcp (Let’s Encrypt HTTP-01 standalone validation for issue/renew)
   - 8883/tcp (MQTT over TLS)

## Install
1) Copy the template:
```bash
cp mosquitto.env.example mosquitto.env
nano mosquitto.env
```

2) Set at minimum in `mosquitto.env`:
- `LETSENCRYPT_DOMAIN` (recommended: `mqtt.yourdomain.com`)
- `LETSENCRYPT_EMAIL`
- TLS paths for Mosquitto:
  - `MOSQ_CA_FILE=/etc/letsencrypt/live/<domain>/fullchain.pem`
  - `MOSQ_CERT_FILE=/etc/letsencrypt/live/<domain>/fullchain.pem`
  - `MOSQ_KEY_FILE=/etc/letsencrypt/live/<domain>/privkey.pem`

3) Run the installer:
```bash
sudo chmod +x install_mosquitto_vps.sh uninstall_mosquitto_vps.sh
sudo ./install_mosquitto_vps.sh ./mosquitto.env
```

## Verify
```bash
sudo systemctl status mosquitto --no-pager
sudo ss -lntp | grep mosquitto
sudo tail -n 50 /var/log/mosquitto/mosquitto.log
```

Renewal hook (installed by script):
```bash
sudo ls -l /etc/letsencrypt/renewal-hooks/deploy/restart-mosquitto.sh
sudo certbot renew --dry-run
```

Cert health check:
```bash
./scripts/cert_health_check.sh <domain>
```

## Creating MQTT users
Passwords are stored hashed in `/etc/mosquitto/passwd` (default from env).

Add a user:
```bash
sudo mosquitto_passwd /etc/mosquitto/passwd <username>
sudo systemctl restart mosquitto
```

## Recommended: per-top-level-topic users via ACLs

### 1) Create users
Example:
```bash
sudo mosquitto_passwd /etc/mosquitto/passwd watergauge_user
sudo mosquitto_passwd /etc/mosquitto/passwd mqttplot_user
```

### 2) Create/edit ACL file
```bash
sudo nano /etc/mosquitto/aclfile
```

Example ACL rules:
```conf
# watergauge_user can publish sensor data and read its command topics
user watergauge_user
topic write watergauge/#
topic read  watergauge/cmd/#

# mqttplot_user can read its own namespace
user mqttplot_user
topic read mqttplot/#

# Optional admin: full access
user admin
topic readwrite #
```

Apply:
```bash
sudo systemctl restart mosquitto
```

### Why this is recommended
- Limits blast radius if a credential leaks
- Lets you share the broker safely among systems
- Keeps the broker configuration simple

## Uninstall
Keep packages:
```bash
sudo ./uninstall_mosquitto_vps.sh ./mosquitto.env false
```

Purge packages:
```bash
sudo ./uninstall_mosquitto_vps.sh ./mosquitto.env true
```
