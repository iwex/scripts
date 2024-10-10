#!/bin/bash

set -e

curl -s https://api.github.com/repos/traefik/traefik/releases/latest \
| grep -E "/traefik_.+_linux_amd64.tar.gz" \
| awk '{ print $2 }' \
| sed 's/,$//' \
| sed 's/"//g' \
| xargs wget -O /tmp/traefik.tar.gz

mkdir /root/traefik
mkdir /root/traefik/logs

cd /root/traefik

tar -xf /tmp/traefik.tar.gz traefik
rm /tmp/traefik.tar.gz

wget https://raw.githubusercontent.com/iwex/scripts/main/traefik/traefik.toml
wget https://raw.githubusercontent.com/iwex/scripts/main/traefik/traefik.service -O /etc/systemd/system/traefik.service

systemctl enable traefik --now
