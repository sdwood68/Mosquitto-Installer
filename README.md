# Mosquitto Installer (Ubuntu 24.04 LTS)

Security-first Mosquitto broker installer for an internet-facing VPS.

## What’s included
- TLS listener on 8883
- Optional Let's Encrypt issuance via certbot standalone
- Cert renewal deploy hook that:
  - re-applies hardened LE directory permissions (when needed)
  - restarts Mosquitto so it picks up new keys
- Username/password auth
- Optional ACL authorization (recommended)

## Key lessons baked into the installer

### 1) Let's Encrypt directory traversal
Some hosts keep:
- `/etc/letsencrypt/live` as `0700 root:root`
- `/etc/letsencrypt/archive` as `0700 root:root`

Mosquitto cannot traverse the symlink chain from:
`/etc/letsencrypt/live/<domain>/privkey.pem -> ../../archive/<domain>/privkeyN.pem`

If `LETSENCRYPT_FIX_DIR_PERMS=true`, the installer sets group `mosquitto`
and mode `0750` on these directories (and per-domain subdirs when the domain is known).

### 2) Password + ACL file permissions
Mosquitto must read:
- `/etc/mosquitto/passwd`
- `/etc/mosquitto/aclfile` (if enabled)

Installer sets both to `root:mosquitto 0640`.

### 3) Plaintext listener
Mosquitto does **not** support `port 0` (it errors with “Invalid port value (0)”).
To keep 1883 closed, we simply do **not** configure a plaintext listener unless
`OPEN_PLAINTEXT_1883=true` (and we only open UFW 1883 in that case).

## Install

```bash
cp mosquitto.env.example mosquitto.env
nano mosquitto.env
sudo chmod +x install_mosquitto.sh uninstall_mosquitto.sh
sudo ./install_mosquitto.sh ./mosquitto.env
```

## Users

```bash
sudo mosquitto_passwd /etc/mosquitto/passwd myuser
sudo systemctl restart mosquitto
```

## ACLs (Access Control Lists)

ACLs restrict publish/subscribe permissions per user/topic prefix.

Example `/etc/mosquitto/aclfile`:

```conf
user watergauge_user
topic readwrite watergauge/#

user garage_user
topic readwrite garage/#
```

If `WRITE_DEFAULT_ACL=true`, the installer writes a starter ACL for the initial
`MQTT_USERNAME` granting `topic readwrite ACL_TOPIC_PREFIX`.

## Client test (Linux)
Some older Mosquitto clients do not support `--tls-hostname`. This works broadly:

```bash
mosquitto_sub -h mqtt.example.com -p 8883 --capath /etc/ssl/certs   -u myuser -P 'mypassword' -t 'test/#' -v -d
```
