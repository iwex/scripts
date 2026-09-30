# scripts

Small server setup scripts, meant to be run straight from GitHub.

## swap

Creates a swap file, enables it and adds it to `/etc/fstab`. The size is optional, default 4G.

```sh
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/swap.sh | bash -s
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/swap.sh | bash -s 8G
```

## traefik

Installs or upgrades [Traefik](https://doc.traefik.io/traefik/) as a systemd service running under a dedicated `traefik` user, with optional HTTPS via Let's Encrypt.

### Install

```sh
# latest release
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s

# pinned version
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s v3.7.12
```

On a fresh install the script asks a few questions:

- enable HTTPS (`websecure` entry point on :443 with Let's Encrypt)?
- Let's Encrypt account email
- challenge type: `tls` (port 443), `http` (port 80) or `cloudflare` (DNS via the Cloudflare API: works behind the Cloudflare proxy or a firewall, allows wildcard certificates)
- Cloudflare API token, for the `cloudflare` challenge only
- is traffic proxied through Cloudflare? Traefik then trusts Cloudflare IP ranges for `X-Forwarded-For`
- redirect all HTTP to HTTPS?
- use the Let's Encrypt staging CA? (untrusted certificates, no rate limits: for testing)

Re-running the script upgrades Traefik and keeps the existing config.

### Change the configuration

Asks the questions again and rewrites `/etc/traefik/traefik.toml`. The previous config is backed up next to it as `traefik.toml.bak.<timestamp>`.

```sh
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s reconfigure
```

### Non-interactive

Without a terminal (cloud-init, CI) the answers come from environment variables. With a terminal they are offered as defaults.

| Variable | Values | Default |
|---|---|---|
| `TRAEFIK_HTTPS` | `y` / `n` | `n` |
| `ACME_EMAIL` | email | required for HTTPS |
| `ACME_CHALLENGE` | `tls` / `http` / `cloudflare` | `tls` |
| `CF_DNS_API_TOKEN` | Cloudflare token with Zone / DNS / Edit | required for `cloudflare` |
| `CF_PROXIED` | `y` / `n` | `n` |
| `HTTPS_REDIRECT` | `y` / `n` | `y` |
| `ACME_STAGING` | `y` / `n` | `n` |

```sh
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh \
  | TRAEFIK_HTTPS=y ACME_EMAIL=me@example.com ACME_CHALLENGE=cloudflare CF_DNS_API_TOKEN=... bash -s
```

### Using HTTPS

Routers opt in to the `websecure` entry point and get a certificate automatically, e.g. with a Docker label:

```
traefik.http.routers.<name>.entrypoints=websecure
```

### Layout

| Path | Purpose |
|---|---|
| `/usr/local/bin/traefik` | binary |
| `/etc/traefik/traefik.toml` | static config, kept on re-run |
| `/etc/traefik/traefik.env` | secrets read by the service, e.g. the Cloudflare token (root, 600) |
| `/etc/traefik/dynamic/` | dynamic config for the file provider |
| `/var/lib/traefik/` | data, e.g. `acme.json` |
| `/var/log/traefik/access.log` | access log, rotated daily by logrotate |

### Operations

```sh
journalctl -u traefik -f          # Traefik's own log
systemctl restart traefik         # after editing traefik.toml
```

Dashboard: `http://<server>:8080/dashboard/`. It has no auth: restrict port 8080 with a firewall.
