#!/bin/bash
#
# Installs or upgrades Traefik as a systemd service running under a dedicated
# system user. On a fresh install it asks a few questions and generates the
# config, including optional HTTPS with Let's Encrypt (TLS, HTTP or Cloudflare
# DNS challenge).
#
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s                      # latest release
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s v3.7.12              # pinned version
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s reconfigure          # ask again, rewrite config
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s v3.7.12 reconfigure
#
# Without a terminal (cloud-init, CI) the questions are answered from the
# environment; with a terminal these are the defaults offered:
#   TRAEFIK_HTTPS=y|n        enable the websecure entry point on :443     (default n)
#   ACME_EMAIL=...           Let's Encrypt account email                  (required for HTTPS)
#   ACME_CHALLENGE=tls|http|cloudflare                                    (default tls)
#   CF_DNS_API_TOKEN=...     Cloudflare API token, Zone:DNS:Edit          (required for cloudflare)
#   CF_PROXIED=y|n           traffic comes through the Cloudflare proxy   (default n)
#   HTTPS_REDIRECT=y|n       redirect all HTTP to HTTPS                   (default y)
#   ACME_STAGING=y|n         use the Let's Encrypt staging CA             (default n)
#
# Layout:
#   /usr/local/bin/traefik      binary (root, 755)
#   /etc/traefik/traefik.toml   static config (root:traefik, 640), kept on re-run
#   /etc/traefik/traefik.env    secrets for the service, e.g. Cloudflare token (root, 600)
#   /etc/traefik/dynamic/       dynamic config for the file provider
#   /var/lib/traefik/           data, e.g. acme.json (traefik, 750)
#   /var/log/traefik/           access log (traefik, 750), rotated by logrotate
#
# Re-running upgrades the binary, unit file and logrotate config. An existing
# /etc/traefik/traefik.toml is kept unless 'reconfigure' is given, which backs
# it up and generates a new one. A config from the old /root/traefik layout is
# migrated once.

set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/iwex/scripts/main/traefik"
RELEASES_URL="https://github.com/traefik/traefik/releases"
CF_IPS_URL="https://www.cloudflare.com/ips"

TRAEFIK_USER="traefik"
BIN="/usr/local/bin/traefik"
CONF_DIR="/etc/traefik"
CONF="$CONF_DIR/traefik.toml"
ENV_FILE="$CONF_DIR/traefik.env"
DATA_DIR="/var/lib/traefik"
LOG_DIR="/var/log/traefik"
UNIT="/etc/systemd/system/traefik.service"
OLD_DIR="/root/traefik"

VERSION="latest"
RECONFIGURE=""
for arg in "$@"; do
  case "$arg" in
    reconfigure) RECONFIGURE=1 ;;
    *)           VERSION="$arg" ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# fetch <url> <dest> <description>
fetch() {
  curl -fsSL -o "$2" "$1" || die "cannot download $3: $1"
}

# --- prompts -----------------------------------------------------------------
# stdin is the script itself when piped from wget, so questions are read from
# the terminal on fd 3. Without a terminal the defaults (environment) are used.

INTERACTIVE=""
if ( : </dev/tty ) 2>/dev/null; then
  exec 3</dev/tty
  INTERACTIVE=1
fi

# yn <value>: normalises y/yes/1/true to y, anything else to n
yn() {
  case "${1,,}" in y|yes|1|true) echo y ;; *) echo n ;; esac
}

# ask <var> <prompt> <default>
ask() {
  local reply=""
  if [ -n "$INTERACTIVE" ]; then
    printf '%s [%s]: ' "$2" "$3"
    IFS= read -r reply <&3 || reply=""
  fi
  printf -v "$1" '%s' "${reply:-$3}"
}

# ask_yn <var> <prompt> <y|n>: sets <var> to y or n
ask_yn() {
  local ans
  while :; do
    ask ans "$2 (y/n)" "$3"
    case "${ans,,}" in
      y|yes) printf -v "$1" y; return ;;
      n|no)  printf -v "$1" n; return ;;
    esac
    [ -n "$INTERACTIVE" ] || die "$2: expected y or n, got '$ans'"
    echo "  please answer y or n"
  done
}

# ask_secret <var> <prompt> <default>: no echo, the default is never shown
ask_secret() {
  local reply=""
  if [ -n "$INTERACTIVE" ]; then
    printf '%s%s: ' "$2" "${3:+ [enter keeps the current one]}"
    IFS= read -rs reply <&3 || reply=""
    echo
  fi
  printf -v "$1" '%s' "${reply:-$3}"
}

# --- configuration questions -------------------------------------------------

# defaults come from the environment, see the header
HTTPS="$(yn "${TRAEFIK_HTTPS:-n}")"
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_CHALLENGE="${ACME_CHALLENGE:-tls}"
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
CF_PROXIED="$(yn "${CF_PROXIED:-n}")"
HTTPS_REDIRECT="$(yn "${HTTPS_REDIRECT:-y}")"
ACME_STAGING="$(yn "${ACME_STAGING:-n}")"
CF_TRUSTED_IPS=""

configure() {
  echo
  info "HTTPS setup"
  local default
  ask_yn HTTPS "Enable HTTPS: websecure entry point on :443 with Let's Encrypt certificates?" "$HTTPS"
  [ "$HTTPS" = y ] || return 0

  default="$ACME_EMAIL"
  while :; do
    ask ACME_EMAIL "Let's Encrypt account email (expiry notices go there)" "$default"
    case "$ACME_EMAIL" in *@*.*) break ;; esac
    [ -n "$INTERACTIVE" ] || die "ACME_EMAIL is required for HTTPS"
    echo "  a valid email is required"
  done

  echo "How should Let's Encrypt verify your domains?"
  echo "  tls         TLS-ALPN on port 443: 443 must reach traefik directly, not through the Cloudflare proxy"
  echo "  http        HTTP on port 80: 80 must reach traefik directly, not through the Cloudflare proxy"
  echo "  cloudflare  DNS records via the Cloudflare API: works behind the proxy or a firewall, allows wildcards"
  default="${ACME_CHALLENGE,,}"
  while :; do
    ask ACME_CHALLENGE "Challenge (tls/http/cloudflare)" "$default"
    ACME_CHALLENGE="${ACME_CHALLENGE,,}"
    case "$ACME_CHALLENGE" in tls|http|cloudflare) break ;; esac
    [ -n "$INTERACTIVE" ] || die "ACME_CHALLENGE must be tls, http or cloudflare, got '$ACME_CHALLENGE'"
    echo "  please answer tls, http or cloudflare"
  done

  if [ "$ACME_CHALLENGE" = cloudflare ]; then
    echo "Create a token at https://dash.cloudflare.com/profile/api-tokens with Zone / DNS / Edit for the zones traefik serves."
    while :; do
      ask_secret CF_DNS_API_TOKEN "Cloudflare API token" "$CF_DNS_API_TOKEN"
      [ -n "$CF_DNS_API_TOKEN" ] && break
      [ -n "$INTERACTIVE" ] || die "CF_DNS_API_TOKEN is required for the cloudflare challenge"
      echo "  a token is required"
    done
  fi

  ask_yn CF_PROXIED "Does traffic come through the Cloudflare proxy (orange cloud)? Traefik then trusts Cloudflare IPs for X-Forwarded-For" "$CF_PROXIED"
  if [ "$CF_PROXIED" = y ] && [ "$ACME_CHALLENGE" != cloudflare ]; then
    warn "the $ACME_CHALLENGE challenge does not work behind the Cloudflare proxy: use the cloudflare challenge, or turn the proxy off while certificates are issued"
  fi

  ask_yn HTTPS_REDIRECT "Redirect all plain HTTP to HTTPS?" "$HTTPS_REDIRECT"
  ask_yn ACME_STAGING "Use the Let's Encrypt staging CA? Untrusted certificates, no rate limits: for testing only" "$ACME_STAGING"
  echo
}

# write_config <base.toml> <dest>: base config plus the generated HTTPS sections
write_config() {
  cp "$1" "$2"
  [ "$HTTPS" = y ] || return 0
  {
    cat <<EOF

# --- HTTPS: generated by install.sh, re-run it with 'reconfigure' to change ---
[entryPoints.websecure]
address = ":443"
  # every router on websecure gets a certificate from this resolver:
  # docker label  traefik.http.routers.<name>.entrypoints=websecure
  [entryPoints.websecure.http.tls]
  certResolver = "letsencrypt"
EOF
    if [ "$HTTPS_REDIRECT" = y ]; then
      cat <<EOF

# redirect all plain HTTP to HTTPS
[entryPoints.web.http.redirections.entryPoint]
to = "websecure"
scheme = "https"
permanent = true
EOF
    fi
    if [ -n "$CF_TRUSTED_IPS" ]; then
      cat <<EOF

# behind the Cloudflare proxy: take the client IP from X-Forwarded-For sent by these ranges
[entryPoints.web.forwardedHeaders]
trustedIPs = [$CF_TRUSTED_IPS]
[entryPoints.websecure.forwardedHeaders]
trustedIPs = [$CF_TRUSTED_IPS]
EOF
    fi
    cat <<EOF

[certificatesResolvers.letsencrypt.acme]
email = "$ACME_EMAIL"
storage = "$DATA_DIR/acme.json"
EOF
    if [ "$ACME_STAGING" = y ]; then
      echo '# staging CA: certificates are not trusted by browsers'
      echo 'caServer = "https://acme-staging-v02.api.letsencrypt.org/directory"'
    fi
    case "$ACME_CHALLENGE" in
      tls)
        echo '  [certificatesResolvers.letsencrypt.acme.tlsChallenge]'
        ;;
      http)
        echo '  [certificatesResolvers.letsencrypt.acme.httpChallenge]'
        echo '  entryPoint = "web"'
        ;;
      cloudflare)
        echo "  # the API token is CF_DNS_API_TOKEN in $ENV_FILE"
        echo '  [certificatesResolvers.letsencrypt.acme.dnsChallenge]'
        echo '  provider = "cloudflare"'
        echo '  resolvers = ["1.1.1.1:53", "1.0.0.1:53"]'
        ;;
    esac
  } >> "$2"
}

# --- preflight ---------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "run as root"

for cmd in curl tar sha256sum systemctl useradd; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found"
done

case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l)        ARCH="armv7" ;;
  armv6l)        ARCH="armv6" ;;
  *)             die "unsupported architecture: $(uname -m)" ;;
esac

if [ "$VERSION" = "latest" ]; then
  # GitHub redirects /releases/latest to /releases/tag/<version>; no API, no rate limit.
  VERSION="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES_URL/latest")" \
    || die "cannot resolve latest Traefik version"
  VERSION="${VERSION##*/}"
fi
case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac

# A config is generated on a fresh install and on 'reconfigure'.
NEED_CONFIG=""
if [ -n "$RECONFIGURE" ] || { [ ! -f "$CONF" ] && [ ! -f "$OLD_DIR/traefik.toml" ]; }; then
  NEED_CONFIG=1
  # on reconfigure, offer the stored Cloudflare token as the default
  if [ -z "$CF_DNS_API_TOKEN" ] && [ -f "$ENV_FILE" ]; then
    CF_DNS_API_TOKEN="$(sed -n 's/^CF_DNS_API_TOKEN=//p' "$ENV_FILE")"
  fi
  configure
fi

# --- download everything first -----------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE="traefik_${VERSION}_linux_${ARCH}.tar.gz"
DOWNLOAD_URL="$RELEASES_URL/download/$VERSION"

info "Downloading Traefik $VERSION ($ARCH)"
fetch "$DOWNLOAD_URL/$ARCHIVE"                         "$TMP/$ARCHIVE"          "release archive (is '$VERSION' a valid release?)"
fetch "$DOWNLOAD_URL/traefik_${VERSION}_checksums.txt" "$TMP/checksums.txt"     "checksums"
fetch "$RAW_URL/traefik.service"                       "$TMP/traefik.service"   "systemd unit"
fetch "$RAW_URL/traefik.logrotate"                     "$TMP/traefik.logrotate" "logrotate config"
if [ -n "$NEED_CONFIG" ]; then
  fetch "$RAW_URL/traefik.toml" "$TMP/traefik.toml" "default config"
fi

if [ -n "$NEED_CONFIG" ] && [ "$HTTPS" = y ] && [ "$CF_PROXIED" = y ]; then
  info "Downloading Cloudflare IP ranges"
  if curl -fsSL "$CF_IPS_URL-v4" -o "$TMP/cf-ips" && curl -fsSL "$CF_IPS_URL-v6" >> "$TMP/cf-ips"; then
    # one CIDR per line -> "a", "b", "c"
    CF_TRUSTED_IPS="$(grep -E '^[0-9a-fA-F.:]+/[0-9]+$' "$TMP/cf-ips" | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')"
  fi
  [ -n "$CF_TRUSTED_IPS" ] || warn "cannot download Cloudflare IP ranges from $CF_IPS_URL-v4: X-Forwarded-For will not be trusted"
fi

info "Verifying checksum"
(cd "$TMP" && grep " $ARCHIVE\$" checksums.txt | sha256sum -c --quiet -) \
  || die "checksum mismatch for $ARCHIVE"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP" traefik

# --- user and directories ----------------------------------------------------

if ! id -u "$TRAEFIK_USER" >/dev/null 2>&1; then
  info "Creating system user $TRAEFIK_USER"
  useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$TRAEFIK_USER"
fi

if getent group docker >/dev/null; then
  usermod -aG docker "$TRAEFIK_USER"
else
  warn "group 'docker' not found: the Docker provider will not work. Install Docker and re-run this script."
fi

install -d -m 750 -o root           -g "$TRAEFIK_USER" "$CONF_DIR" "$CONF_DIR/dynamic"
install -d -m 750 -o "$TRAEFIK_USER" -g "$TRAEFIK_USER" "$DATA_DIR" "$LOG_DIR"

# --- binary ------------------------------------------------------------------

info "Installing binary to $BIN"
install -m 755 -o root -g root "$TMP/traefik" "$BIN.new"
mv -f "$BIN.new" "$BIN"   # same filesystem: atomic, safe while the old binary is running
"$BIN" version >/dev/null || die "installed binary does not run"

# --- config ------------------------------------------------------------------

if [ -n "$NEED_CONFIG" ]; then
  if [ -f "$CONF" ]; then
    BACKUP="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    info "Backing up $CONF to $BACKUP"
    cp -p "$CONF" "$BACKUP"
    warn "manual edits in the old config are not carried over; compare it with $BACKUP"
  fi
  info "Writing $CONF"
  write_config "$TMP/traefik.toml" "$CONF"

  if [ "$HTTPS" = y ] && [ "$ACME_CHALLENGE" = cloudflare ]; then
    info "Writing $ENV_FILE"
    (umask 077; printf '# generated by install.sh, read by the systemd unit\nCF_DNS_API_TOKEN=%s\n' "$CF_DNS_API_TOKEN" > "$ENV_FILE.new")
    chown root:root "$ENV_FILE.new"
    mv -f "$ENV_FILE.new" "$ENV_FILE"
  elif [ -f "$ENV_FILE" ]; then
    info "Removing $ENV_FILE (no longer used)"
    rm -f "$ENV_FILE"
  fi
elif [ -f "$CONF" ]; then
  info "Keeping existing $CONF"
elif [ -f "$OLD_DIR/traefik.toml" ]; then
  info "Migrating $OLD_DIR/traefik.toml to $CONF"
  sed -E "s#$OLD_DIR/logs?/#$LOG_DIR/#g" "$OLD_DIR/traefik.toml" > "$CONF"
  warn "old install left in $OLD_DIR; review $CONF, then remove $OLD_DIR"
fi
chown root:"$TRAEFIK_USER" "$CONF"
chmod 640 "$CONF"

# --- systemd and logrotate ---------------------------------------------------

info "Installing systemd unit"
install -m 644 -o root -g root "$TMP/traefik.service" "$UNIT"

if [ -d /etc/logrotate.d ]; then
  install -m 644 -o root -g root "$TMP/traefik.logrotate" /etc/logrotate.d/traefik
else
  warn "logrotate not installed: $LOG_DIR/access.log will not be rotated"
fi

systemctl daemon-reload
systemctl enable -q traefik

info "Starting traefik"
systemctl restart traefik || die "traefik failed to start; check: journalctl -u traefik -n 50"

info "Traefik $VERSION is running"
info "Dashboard: http://<server>:8080/dashboard/ (no auth: restrict port 8080 with a firewall)"
if grep -q '^\[entryPoints\.websecure\]' "$CONF"; then
  info "HTTPS: on, :443 with Let's Encrypt. Routers opt in with: traefik.http.routers.<name>.entrypoints=websecure"
  if [ "$ACME_STAGING" = y ]; then
    warn "staging CA in use: re-run with 'reconfigure' for real certificates"
  fi
else
  info "HTTPS: off. Enable it with: wget -O- $RAW_URL/install.sh | bash -s reconfigure"
fi
info "Config: $CONF, change it with: wget -O- $RAW_URL/install.sh | bash -s reconfigure"
