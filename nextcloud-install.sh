#!/bin/sh
# Compatibility wrapper — source of truth is install-nextcloud+collabora.sh
exec "$(dirname "$0")/install-nextcloud+collabora.sh" "$@"
