# Mosquitto MQTT VPS Installer (Ubuntu 24.04 LTS)

This repo installs and configures an internet-facing Mosquitto broker with:

- MQTT over TLS (8883) by default
- Let’s Encrypt automation (certbot standalone)
- Renewal **deploy hook** that restarts Mosquitto after successful cert renewal
- Username/password authentication (no anonymous)
- Optional ACL enforcement (recommended)

## What was fixed

The installer now writes `/etc/mosquitto/conf.d/99-vps.conf` using **atomic writes** (temp file + install).
This prevents the `0 bytes` snippet situation that leaves Mosquitto in local-only mode.

## What is an ACL?

**ACL** = **Access Control List**. In Mosquitto, ACL rules control **which users** can
**publish/subscribe** to **which topics**.

- Passwords authenticate (“who are you?”)
- ACLs authorize (“what are you allowed to do?”)

If you want “one username/password per top-level topic”, you need ACLs.

## Note about logging

Mosquitto’s `log_dest file` requires the path on the same line:

```text
log_dest file /var/log/mosquitto/mosquitto.log
```

This installer handles it automatically when `MOSQ_LOG_DEST=file`.

## Install

```bash
cp mosquitto.env.example mosquitto.env
nano mosquitto.env
sudo chmod +x install_mosquitto_vps.sh uninstall_mosquitto_vps.sh
sudo ./install_mosquitto_vps.sh ./mosquitto.env
```

## User setup (passwords)

```bash
sudo mosquitto_passwd /etc/mosquitto/passwd watergauge_user
sudo mosquitto_passwd /etc/mosquitto/passwd mqttplot_user
sudo systemctl restart mosquitto
```

## ACL example

Edit:

```bash
sudo nano /etc/mosquitto/aclfile
```

Example:

```conf
user watergauge_user
topic write watergauge/#
topic read  watergauge/cmd/#

user mqttplot_user
topic read mqttplot/#

user admin
topic readwrite #
```

Apply:

```bash
sudo systemctl restart mosquitto
```

## Renewal hook

Installed at:
`/etc/letsencrypt/renewal-hooks/deploy/restart-mosquitto.sh`

Dry-run renew:

```bash
sudo certbot renew --dry-run
```

## Cert health check

```bash
./scripts/cert_health_check.sh <domain>
```
