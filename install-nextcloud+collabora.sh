#!/bin/sh
# install-nextcloud+collabora.sh — Nextcloud + Collabora CODE (Podman)
# Separate from Stardust (Backdrop control plane). Do not drop this under
# /srv/platforms or /srv/stardust. Counterpart to owncloud-install.sh.
#
# Host target: Devuan sysvinit starhq.knarr (also works on systemd).
# Reuses Apache + MariaDB + PHP if Stardust already installed them.
# Aligns with Stardust dnsmasq: *.knarr / *.devel -> LAN/WG, Apache *:80.
#
#   install-nextcloud+collabora.sh [-n] [-y] [-H HOST] [-u USER] [-g GROUP]
#   install-nextcloud+collabora.sh --keep-path --skip-code
#   install-nextcloud+collabora.sh --office-only
#   install-nextcloud+collabora.sh -h
#
# Default layout (outside Stardust trees):
#   /srv/apps/nextcloud          code (DocumentRoot)
#   /srv/apps/nextcloud-data     data directory (not web-reachable)
#   /srv/apps/nextcloud-secrets  generated passwords (0640)
#   http://drive.starhq.knarr/   name-based vhost on *:80
#   127.0.0.1:9980              CODE via Podman --network host
#
# PHP: Nextcloud current line needs >= 8.1 (8.3 recommended). Script
# stops if PHP is older. Tarball is the published latest.tar.bz2.
