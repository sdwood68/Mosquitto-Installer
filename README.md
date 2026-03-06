# Mosquitto Installer for Ubuntu 24.04 LTS

Security-first Mosquitto broker installer for an internet-facing VPS.

## Requirements

- Ubuntu 24.04 LTS (Noble)
- Mosquitto from Ubuntu packages
- A DNS name pointing at the broker if using Let's Encrypt

## What this installs

- TLS listener on port 8883 for remote clients
- Plaintext listener on `127.0.0.1:1883` for MQTTPlot or other local apps
- Optional Let's Encrypt issuance via certbot standalone
- Cert renewal deploy hook that:
  - re-applies hardened Let's Encrypt directory permissions
  - restarts Mosquitto so it picks up new keys
- Username/password authentication
- Optional ACL authorization
- Automatic post-install listener verification

## Key lessons baked into the installer

### Let's Encrypt directory traversal

Some hosts keep these as `0700 root:root`:

- `/etc/letsencrypt/live`
- `/etc/letsencrypt/archive`

Mosquitto cannot traverse the symlink chain from:

- `/etc/letsencrypt/live/<domain>/privkey.pem`
- `../../archive/<domain>/privkeyN.pem`

If `LETSENCRYPT_FIX_DIR_PERMS=true`, the installer sets group `mosquitto`
and mode `0750` on these directories and on the per-domain subdirectories.

### Listener layout for this project

The generated configuration uses two listeners:

- `8883` bound to `0.0.0.0` for internet-facing TLS
- `1883` bound to `127.0.0.1` for local plaintext access only

This lets MQTTPlot connect locally without TLS while keeping remote clients on
TLS. The installer verifies that port 1883 is not exposed on `0.0.0.0` or
`[::]` after restart.

### TLS listener configuration

For the server-side TLS listener, the important directives are:

- `certfile`
- `keyfile`

The installer only writes `cafile` when `REQUIRE_CLIENT_CERT=true`.
For a username/password broker with `require_certificate false`, using the
server `fullchain.pem` as broker `cafile` is unnecessary and can be confusing.

### Password and ACL file permissions

On this Ubuntu/Mosquitto combination, the password file and ACL file need to be
readable by the running Mosquitto service. The installer therefore keeps them
owned by `mosquitto:mosquitto`.

Default permissions are:

- `/etc/mosquitto/passwd` -> `0600`
- `/etc/mosquitto/aclfile` -> `0644`

### Client ID requirement

This installer sets:

```conf
allow_zero_length_clientid false
```

So test clients should provide a client ID with `-i`.

## Install

```bash
cp mosquitto.env.example mosquitto.env
nano mosquitto.env
sudo chmod +x install_mosquitto.sh uninstall_mosquitto.sh
sudo ./install_mosquitto.sh ./mosquitto.env
```

## What the automatic verification checks

After restarting Mosquitto, the installer verifies:

- the TLS listener is present on `MOSQ_BIND_ADDRESS:MOSQ_LISTENER_PORT`
- the plaintext listener is present on
  `MOSQ_PLAINTEXT_BIND_ADDRESS:1883` when enabled
- plaintext port `1883` is not listening on `0.0.0.0`, `::`, or `[::]`

If any of those checks fail, the installer exits non-zero and prints the socket
listening table.

## Users

Add or update users later with:

```bash
sudo mosquitto_passwd /etc/mosquitto/passwd myuser
sudo systemctl restart mosquitto
```

## ACLs

If `MOSQ_ENABLE_ACL=true`, you must define topic permissions. An empty ACL file
can result in clients connecting successfully but being unable to publish or
subscribe.

Example `/etc/mosquitto/aclfile`:

```conf
# Publisher
user watergauge
topic readwrite watergauge/#

# Local MQTTPlot subscriber
user MQTTPlot
topic read watergauge/#
```

If `WRITE_DEFAULT_ACL=true` and `CREATE_MQTT_USER=true`, the installer seeds a
starter rule for the initial user using `ACL_TOPIC_PREFIX`.

## Test scripts

Run quick end-to-end one-shot tests on the VPS.

```bash
chmod +x scripts/test_oneshot_*.sh

# TLS (8883) one-shot
./scripts/test_oneshot_tls.sh ./mosquitto.env test/tls

# Local plaintext (127.0.0.1:1883) one-shot
./scripts/test_oneshot_local.sh ./mosquitto.env test/local

# Run both
./scripts/test_oneshot_all.sh ./mosquitto.env
```

Notes:

- These scripts require `timeout`.
- The TLS script uses `LETSENCRYPT_DOMAIN` and `MOSQ_LISTENER_PORT`.
- Both scripts require `MQTT_USERNAME` and `MQTT_PASSWORD`.

## Client tests

### Linux

TLS subscribe:

```bash
mosquitto_sub -h mqtt.example.org -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  -i "test-sub-$(date +%s)" \
  -u myuser -P 'mypassword' \
  -t 'watergauge/#' -v
```

TLS publish:

```bash
mosquitto_pub -h mqtt.example.org -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  -i "test-pub-$(date +%s)" \
  -u myuser -P 'mypassword' \
  -t 'watergauge/test' -m "hello $(date -Is)"
```

### Windows PowerShell

If your Windows Mosquitto install does not include a CA bundle, download the
Let's Encrypt ISRG Root X1 certificate and point `--cafile` at it.

```powershell
Invoke-WebRequest `
  -Uri "https://letsencrypt.org/certs/isrgrootx1.pem.txt" `
  -OutFile "$HOME\Documents\certs\isrgrootx1.pem"

mosquitto_pub -d `
  -h mqtt.example.org `
  -p 8883 `
  --cafile "$HOME\Documents\certs\isrgrootx1.pem" `
  -u myuser `
  -P "mypassword" `
  -i winpub-1 `
  -t "watergauge/test" `
  -m "Hello from Windows"
```
