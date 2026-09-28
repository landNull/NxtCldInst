#!/bin/sh
# nextcloud-uninstall.sh — remove the NxtCldInst Nextcloud + Collabora stack
# as if nextcloud-install.sh / nextcloud-dnsmasq-align.sh never ran.
#
# Does NOT remove Stardust, Apache, MariaDB server, PHP, Redis, Podman,
# dnsmasq, or any other vhost. Packages stay installed.
#
#   nextcloud-uninstall.sh -n
#   nextcloud-uninstall.sh -y
#   nextcloud-uninstall.sh -y --purge-image
#
# Host: Devuan sysvinit (starhq.knarr). Also works on systemd.

set -eu

PROG=${0##*/}
DRYRUN=0
NONINTERACTIVE=0
PURGE_IMAGE=0

NC_ROOT=/srv/apps/nextcloud
NC_DATA=/srv/apps/nextcloud-data
NC_SEC=/srv/apps/nextcloud-secrets
DB_NAME=nextcloud
DB_USER=nextcloud
CODE_NAME=collabora-nextcloud
CODE_IMAGE=docker.io/collabora/code:latest

usage() {
  cat <<EOF
$PROG — wipe Nextcloud + Collabora CODE written by nextcloud-install.sh

  $PROG -n                 show what would be removed
  $PROG -y                 remove without typing NUKE
  $PROG -y --purge-image   also delete the Collabora OCI image

Removes
  * podman container $CODE_NAME, init.d unit, /usr/local/sbin runner
  * Apache sites nextcloud.conf / nextcloud-localhost.conf (+ backups)
  * PHP 99-nextcloud.ini, MariaDB 60-nextcloud.cnf
  * cron / logrotate / Apache nextcloud logs
  * MariaDB database $DB_NAME and user $DB_USER
  * $NC_ROOT $NC_DATA $NC_SEC
  * leftover tarball under /tmp

Keeps
  * apache2 mariadb php redis podman dnsmasq (Stardust)
  * /etc/hosts (already scrubbed; backups *.nextcloud-*.bak stay)
  * ownCloud vhosts, Stardust sites, other databases
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

run() {
  if [ "$DRYRUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
    return 0
  fi
  "$@"
}

rm_rf() {
  p=$1
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    return 0
  fi
  log "rm $p"
  if [ "$DRYRUN" -eq 1 ]; then
    printf '+ rm -rf %s\n' "$p"
    return 0
  fi
  rm -rf "$p"
}

rm_f() {
  p=$1
  [ -e "$p" ] || [ -L "$p" ] || return 0
  log "rm $p"
  if [ "$DRYRUN" -eq 1 ]; then
    printf '+ rm -f %s\n' "$p"
    return 0
  fi
  rm -f "$p"
}

while [ $# -gt 0 ]; do
  case $1 in
    -n) DRYRUN=1 ;;
    -y|--yes) NONINTERACTIVE=1 ;;
    --purge-image) PURGE_IMAGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || [ "$DRYRUN" -eq 1 ] || die "run as root (sudo $PROG -y)"

# Refuse to follow a path that is Stardust or the OS web root alone.
assert_safe_tree() {
  p=$1
  case $p in
    /|/var|/var/www|/srv|/srv/apps|/srv/stardust|/srv/platforms|/etc|/usr|/home)
      die "refusing to delete $p"
      ;;
  esac
  case $p in
    /srv/stardust/*|/srv/platforms/*)
      die "refusing to delete Stardust path $p"
      ;;
  esac
}

confirm() {
  [ "$DRYRUN" -eq 1 ] && return 0
  [ "$NONINTERACTIVE" -eq 1 ] && return 0
  [ -r /dev/tty ] || die "no TTY — pass -y"
  printf '\nThis deletes Nextcloud code, data, DB, vhosts, and Collabora.\n' >/dev/tty
  printf 'Type NUKE to continue: ' >/dev/tty
  IFS= read -r ans </dev/tty || ans=
  [ "$ans" = NUKE ] || die "aborted"
}

stop_code() {
  if command -v podman >/dev/null 2>&1; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ podman stop/rm $CODE_NAME"
    else
      podman stop "$CODE_NAME" >/dev/null 2>&1 || true
      podman rm -f "$CODE_NAME" >/dev/null 2>&1 || true
      log "podman: removed container $CODE_NAME"
    fi
    if [ "$PURGE_IMAGE" -eq 1 ]; then
      if [ "$DRYRUN" -eq 1 ]; then
        log "+ podman rmi $CODE_IMAGE"
      else
        podman rmi "$CODE_IMAGE" >/dev/null 2>&1 || true
        log "podman: removed image $CODE_IMAGE"
      fi
    fi
  fi
  if [ -x /etc/init.d/collabora-nextcloud ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ service collabora-nextcloud stop"
    else
      service collabora-nextcloud stop >/dev/null 2>&1 || true
    fi
  fi
  if command -v update-rc.d >/dev/null 2>&1; then
    run update-rc.d -f collabora-nextcloud remove >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1; then
    run systemctl disable collabora-nextcloud >/dev/null 2>&1 || true
  fi
  rm_f /etc/init.d/collabora-nextcloud
  rm_f /usr/local/sbin/collabora-nextcloud-run
}

drop_apache() {
  if command -v a2dissite >/dev/null 2>&1; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ a2dissite nextcloud.conf nextcloud-localhost.conf"
    else
      a2dissite nextcloud.conf >/dev/null 2>&1 || true
      a2dissite nextcloud-localhost.conf >/dev/null 2>&1 || true
    fi
  fi
  rm_f /etc/apache2/sites-enabled/nextcloud.conf
  rm_f /etc/apache2/sites-enabled/nextcloud-localhost.conf
  rm_f /etc/apache2/sites-available/nextcloud.conf
  rm_f /etc/apache2/sites-available/nextcloud-localhost.conf
  rm_f /etc/apache2/sites-available/nextcloud.conf.align.bak
  rm_f /etc/apache2/sites-available/nextcloud-localhost.conf.align.bak
  rm_f /var/log/apache2/nextcloud-error.log
  rm_f /var/log/apache2/nextcloud-access.log
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ apache2ctl configtest && service apache2 reload"
    return 0
  fi
  if command -v apache2ctl >/dev/null 2>&1; then
    apache2ctl configtest || die "apache2ctl configtest failed after site removal"
  fi
  if command -v service >/dev/null 2>&1; then
    service apache2 reload || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2 >/dev/null 2>&1 || true
  fi
}

drop_php_mysql_snippets() {
  for f in /etc/php/*/apache2/conf.d/99-nextcloud.ini \
           /etc/php/*/fpm/conf.d/99-nextcloud.ini \
           /etc/php/*/cli/conf.d/99-nextcloud.ini
  do
    rm_f "$f"
  done
  rm_f /etc/mysql/mariadb.conf.d/60-nextcloud.cnf
  rm_f /etc/mysql/conf.d/60-nextcloud.cnf
}

drop_cron_logrotate() {
  rm_f /etc/cron.d/nextcloud
  rm_f /etc/logrotate.d/nextcloud
}

drop_db() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ DROP DATABASE $DB_NAME; DROP USER $DB_USER@localhost"
    return 0
  fi
  if ! command -v mysql >/dev/null 2>&1; then
    log "note: mysql client missing — drop $DB_NAME by hand"
    return 0
  fi
  mysql --protocol=socket -u root <<SQL || log "note: MariaDB drop failed (server down?)"
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  log "MariaDB: dropped $DB_NAME / $DB_USER"
}

drop_trees() {
  assert_safe_tree "$NC_ROOT"
  assert_safe_tree "$NC_DATA"
  assert_safe_tree "$NC_SEC"
  rm_rf "$NC_ROOT"
  rm_rf "$NC_DATA"
  rm_rf "$NC_SEC"
  # empty parent only if we emptied it
  if [ -d /srv/apps ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ rmdir /srv/apps if empty"
    else
      rmdir /srv/apps 2>/dev/null || true
    fi
  fi
}

drop_tmp() {
  rm_f /tmp/nextcloud-latest.tar.bz2
  rm_f /tmp/nextcloud-latest.tar.bz2.sha256
  rm_rf /tmp/nc-unpack
}

print_left() {
  cat <<EOF

Removed (or would remove) the NxtCldInst stack.
Not touched: apache2, mariadb-server, php, redis, podman, dnsmasq, Stardust.

Check:
  getent hosts drive.starhq.knarr
  ls /etc/apache2/sites-enabled
  podman ps -a | grep collabora || true
  mysql -e 'SHOW DATABASES;'
  ls /srv/apps 2>/dev/null || echo '/srv/apps gone or empty'

Reinstall: nextcloud-install.sh from feature/inst-nxtcld-refactor (70c38d6).
EOF
}

confirm
log "uninstall Nextcloud + Collabora (dryrun=$DRYRUN purge-image=$PURGE_IMAGE)"
stop_code
drop_cron_logrotate
drop_apache
drop_php_mysql_snippets
drop_db
drop_trees
drop_tmp
print_left
