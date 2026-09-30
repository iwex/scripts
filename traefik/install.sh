#!/bin/bash
#
# Installs or upgrades Traefik as a systemd service running under a dedicated
# system user.
#
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s            # latest release
#   wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s v3.7.12    # pinned version
#
# Layout:
#   /usr/local/bin/traefik      binary (root, 755)
#   /etc/traefik/traefik.toml   static config (root:traefik, 640), kept on re-run
#   /etc/traefik/dynamic/       dynamic config for the file provider
#   /var/lib/traefik/           data, e.g. acme.json (traefik, 750)
#   /var/log/traefik/           access log (traefik, 750), rotated by logrotate
#
# Re-running upgrades the binary, unit file and logrotate config. An existing
# /etc/traefik/traefik.toml is never overwritten. A config from the old
# /root/traefik layout is migrated once.

set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/iwex/scripts/main/traefik"
RELEASES_URL="https://github.com/traefik/traefik/releases"

TRAEFIK_USER="traefik"
BIN="/usr/local/bin/traefik"
CONF_DIR="/etc/traefik"
CONF="$CONF_DIR/traefik.toml"
DATA_DIR="/var/lib/traefik"
LOG_DIR="/var/log/traefik"
UNIT="/etc/systemd/system/traefik.service"
OLD_DIR="/root/traefik"

VERSION="${1:-latest}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# fetch <url> <dest> <description>
fetch() {
  curl -fsSL -o "$2" "$1" || die "cannot download $3: $1"
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
if [ ! -f "$CONF" ] && [ ! -f "$OLD_DIR/traefik.toml" ]; then
  fetch "$RAW_URL/traefik.toml" "$TMP/traefik.toml" "default config"
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

if [ -f "$CONF" ]; then
  info "Keeping existing $CONF"
elif [ -f "$OLD_DIR/traefik.toml" ]; then
  info "Migrating $OLD_DIR/traefik.toml to $CONF"
  sed -E "s#$OLD_DIR/logs?/#$LOG_DIR/#g" "$OLD_DIR/traefik.toml" > "$CONF"
  warn "old install left in $OLD_DIR; review $CONF, then remove $OLD_DIR"
else
  info "Installing default $CONF"
  cp "$TMP/traefik.toml" "$CONF"
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
info "HTTPS: optional, see the websecure block in $CONF"
