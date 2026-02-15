# Mosquitto Installer for Ubuntu 24.04 LTS

Security-first Mosquitto broker installer for an internet-facing VPS.

## Requirements

- Ubuntu 24.04 LTS (Noble)
- Mosquitto from Ubuntu packages (tested with mosquitto 2.0.18)

## What this installs

- TLS listener on port 8883
- Optional Let's Encrypt issuance via certbot (standalone)
- Cert renewal deploy hook that:
  - re-applies hardened Let's Encrypt directory permissions
  - restarts Mosquitto so it picks up new keys
- Username/password authentication
- Optional ACL authorization (recommended)

## Notes and gotchas

### Let's Encrypt directory traversal

Some hosts keep these as `0700 root:root`:

- `/etc/letsencrypt/live`
- `/etc/letsencrypt/archive`

Mosquitto cannot traverse the symlink chain from:

- `/etc/letsencrypt/live/<domain>/privkey.pem`
- `../../archive/<domain>/privkeyN.pem`

If `LETSENCRYPT_FIX_DIR_PERMS=true`, the installer sets group `mosquitto` and
mode `0750` on these directories and per-domain subdirectories.

### Plaintext listener and the 1883 double-bind issue

On Ubuntu 24.04 with Mosquitto 2.0.18, using an explicit stanza like:

```conf
listener 1883 127.0.0.1
```

can cause Mosquitto to attempt binding port 1883 twice and fail with:

- `Error: Address already in use`

To avoid this, if you enable plaintext 1883, the installer uses the legacy
listener form:

```conf
bind_address 127.0.0.1
port 1883
```

By default, the installer binds port 1883 to localhost even if you open the
firewall port.

### Password and ACL file permissions

Mosquitto reads:

- `/etc/mosquitto/passwd`
- `/etc/mosquitto/aclfile` (when ACLs are enabled)

To avoid future Mosquitto warnings, the installer sets these files to
`mosquitto:mosquitto` with mode `0600`.

### Client ID requirement

This installer sets:

```conf
allow_zero_length_clientid false
```

So your test clients must provide a client id via `-i`.

## Install

```bash
cp mosquitto.env.example mosquitto.env
nano mosquitto.env
sudo chmod +x install_mosquitto.sh uninstall_mosquitto.sh
sudo ./install_mosquitto.sh ./mosquitto.env
```

## Users

Add users later with:

```bash
sudo mosquitto_passwd /etc/mosquitto/passwd myuser
sudo systemctl restart mosquitto
```

## ACLs (Access Control Lists)

If `MOSQ_ENABLE_ACL=true`, you must define topic permissions. An empty ACL file
can result in clients connecting successfully but being unable to publish or
subscribe.

Example `/etc/mosquitto/aclfile`:

```conf
# Test topics
user watergauge
topic readwrite test/#

# WaterGauge topics
user watergauge
topic readwrite watergauge/#

# Example: read-only user
# user mqttplot
# topic read watergauge/#
```

If `WRITE_DEFAULT_ACL=true` and `CREATE_MQTT_USER=true`, the installer seeds a
starter rule for the initial user:

- `topic readwrite ACL_TOPIC_PREFIX`

## Test scripts

Run quick end-to-end one-shot tests (subscribe then publish) on the VPS.

```bash
chmod +x scripts/test_oneshot_*.sh

# TLS (8883) one-shot
auth_env=./mosquitto.env
./scripts/test_oneshot_tls.sh "$auth_env" test/tls

# Local plaintext (127.0.0.1:1883) one-shot
./scripts/test_oneshot_local.sh "$auth_env" test/baseline

# Run both
./scripts/test_oneshot_all.sh "$auth_env"
```

Notes:

- These scripts require `timeout` (coreutils).
- TLS script uses `LETSENCRYPT_DOMAIN` and `MOSQ_LISTENER_PORT` from the env file.
- Both scripts require `MQTT_USERNAME` and `MQTT_PASSWORD`.

## Client tests

### Linux

TLS subscribe:

```bash
mosquitto_sub -h mqtt.example.com -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  -i "test-sub-$(date +%s)" \
  -u myuser -P 'mypassword' \
  -t 'test/#' -v
```

TLS publish:

```bash
mosquitto_pub -h mqtt.example.com -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  -i "test-pub-$(date +%s)" \
  -u myuser -P 'mypassword' \
  -t 'test/hello' -m "hello $(date -Is)" -q 1
```

### Windows PowerShell

Use the full path to the Mosquitto client binaries, or ensure they are on your
`PATH`. Example (edit host, user, and password):

```powershell
& "C:\Program Files\mosquitto\mosquitto_sub.exe" `
  -h mqtt.example.com -p 8883 `
  --cafile "C:\Program Files\mosquitto\certs\ca.crt" `
    -i "test-sub-$([guid]::NewGuid().ToString())" `
  -u myuser -P "mypassword" `
  -t "test/#" -v
```

If you do not have a CA bundle on Windows, export the system roots to a file
or use the CA provided by your environment.
