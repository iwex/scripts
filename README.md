wget -O- https://raw.githubusercontent.com/iwex/scripts/main/swap.sh | bash -s

# traefik: latest release, or pass a version
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s
wget -O- https://raw.githubusercontent.com/iwex/scripts/main/traefik/install.sh | bash -s v3.7.12

# runs as user `traefik`; binary /usr/local/bin/traefik, config /etc/traefik/traefik.toml,
# dynamic config /etc/traefik/dynamic/, data /var/lib/traefik, access log /var/log/traefik
# logs:      journalctl -u traefik -f
# dashboard: http://<server>:8080/dashboard/ (no auth, restrict port 8080 with a firewall)
