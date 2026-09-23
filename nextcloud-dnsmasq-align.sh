#!/bin/sh
# nextcloud-dnsmasq-align.sh — point an existing Nextcloud + Collabora
# install at Stardust dnsmasq (*.knarr / *.devel) instead of loopback
# /etc/hosts + VirtualHost 127.0.0.1:80 + Alias /nextcloud.
#
# Standalone. Not a Stardust site. Do not drop this under
# /srv/platforms or /srv/stardust. Does not unpack Nextcloud;
# nextcloud-install.sh must have already run.
#
# Host target: Devuan sysvinit (starhq.knarr). Also works on systemd.
#
#   nextcloud-dnsmasq-align.sh [-n] [-y] [--keep-path] [--skip-code]
#       [-H HOST] [-u USER] [-g GROUP]
#   nextcloud-dnsmasq-align.sh -h
#
# Safe first pass on a live box (--keep-path --skip-code):
#   http://drive.starhq.knarr/nextcloud   unchanged URL
#   Collabora container                   left running
#   only DNS + *:80 vhost change
#
# Default after a full align:
#   http://drive.starhq.knarr/     Nextcloud at the domain root
#   /nextcloud                     301 → /
#   127.0.0.1:9980                 Collabora CODE (host net)
#   Apache                         <VirtualHost *:80> like Gitea / site-add
#
# dnsmasq (STEP 25) already maps *.knarr and *.devel → LAN/WG IP.
# This script never writes those names to 127.0.0.1 in /etc/hosts.

set -eu

PROG=${0##*/}
DRYRUN=0
NONINTERACTIVE=0
HTTP_USER=www-data
HTTP_GROUP=www-data
NC_HOST=drive.starhq.knarr
NC_ROOT=/srv/apps/nextcloud
NC_DATA=/srv/apps/nextcloud-data
NC_SEC=/srv/apps/nextcloud-secrets
NC_URL_PATH=/
KEEP_PATH=0
SKIP_CODE=0
VHOST_OLD=/etc/apache2/sites-available/nextcloud-localhost.conf
VHOST=/etc/apache2/sites-available/nextcloud.conf
CODE_NAME=collabora-nextcloud
CODE_IMAGE=docker.io/collabora/code:latest
CODE_PORT=9980
TZ_NAME=America/Denver

usage() {
  cat <<EOF
$PROG — align existing Nextcloud + Collabora with Stardust dnsmasq

  $PROG [options]

Options:
  -n              dry run
  -y              non-interactive
  -H HOST         ServerName / overwritehost (default drive.starhq.knarr)
  -u USER         PHP / occ user (default: owner of $NC_ROOT/config, else www-data)
  -g GROUP        PHP group (default: group of that user)
  --keep-path     keep http://HOST/nextcloud (do not flatten to /)
  --skip-code     do not rewrite or restart the Collabora container
  -h              this help

Does
  * drop 127.0.0.1 / 127.0.1.1 / ::1 pins for *.knarr and *.devel
    from /etc/hosts so dnsmasq wins on this box
  * replace nextcloud-localhost.conf (loopback Listen) with
    nextcloud.conf: <VirtualHost *:80>
  * occ trusted_domains + overwritehost
  * optional: flatten URL to / and 301 /nextcloud
  * optional: rewrite Collabora aliasgroup1 + restart CODE

Does not
  * touch the database, data dir, or Nextcloud tarball
  * expose CODE on 0.0.0.0
  * stardust site-add nextcloud
  * touch Backdrop vhosts or Gitea

Live box, do not break Office:
  $PROG -y --keep-path --skip-code
  # confirm login + open a .odt, then drop --skip-code / --keep-path
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

while [ $# -gt 0 ]; do
  case $1 in
    -n) DRYRUN=1 ;;
    -y|--yes) NONINTERACTIVE=1 ;;
    -H) NC_HOST=$2; shift ;;
    -u) HTTP_USER=$2; shift ;;
    -g) HTTP_GROUP=$2; shift ;;
    --keep-path) KEEP_PATH=1; NC_URL_PATH=/nextcloud ;;
    --skip-code) SKIP_CODE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

need_root() {
  [ "$(id -u)" -eq 0 ] || [ "$DRYRUN" -eq 1 ] || die "run as root"
}

php_bin() {
  command -v php >/dev/null 2>&1 && command -v php && return 0
  command -v php8.3 >/dev/null 2>&1 && command -v php8.3 && return 0
  command -v php8.4 >/dev/null 2>&1 && command -v php8.4 && return 0
  command -v php8.2 >/dev/null 2>&1 && command -v php8.2 && return 0
  echo php
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

lan_ips() {
  hostname -I 2>/dev/null || true
}

is_loopback_name() {
  case $1 in
    127.0.0.1|localhost|::1) return 0 ;;
  esac
  return 1
}

is_stardust_dns_name() {
  case $1 in
    *.devel|*.knarr|devel|knarr) return 0 ;;
  esac
  return 1
}

guess_php_user() {
  if [ -d "$NC_ROOT/config" ]; then
    o=$(stat -c '%U' "$NC_ROOT/config" 2>/dev/null || true)
    g=$(stat -c '%G' "$NC_ROOT/config" 2>/dev/null || true)
    [ -n "$o" ] && [ "$o" != root ] && HTTP_USER=$o
    [ -n "$g" ] && [ "$g" != root ] && HTTP_GROUP=$g
  fi
}

# --- /etc/hosts --------------------------------------------------------------

scrub_loopback_hosts() {
  hosts=/etc/hosts
  if [ ! -f "$hosts" ]; then
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ scrub *.knarr *.devel off 127.0.0.1/127.0.1.1/::1 in $hosts"
    grep -nE '^[[:space:]]*(127\.0\.0\.1|127\.0\.1\.1|::1)[[:space:]]' "$hosts" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp)
  changed=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|\#*)
        printf '%s\n' "$line" >> "$tmp"
        continue
        ;;
    esac
    # shellcheck disable=SC2086
    set -- $line
    ip=$1
    shift || true
    case $ip in
      127.0.0.1|127.0.1.1|::1) ;;
      *)
        printf '%s\n' "$line" >> "$tmp"
        continue
        ;;
    esac
    keep=""
    for n in "$@"; do
      case $n in
        \#*) keep="$keep $n"; continue ;;
      esac
      if is_stardust_dns_name "$n" || [ "$n" = "$NC_HOST" ]; then
        log "hosts: drop $n from $ip (dnsmasq owns *.devel / *.knarr)"
        changed=1
        continue
      fi
      keep="$keep $n"
    done
    if [ -n "$keep" ]; then
      printf '%s%s\n' "$ip" "$keep" >> "$tmp"
    else
      log "hosts: drop now-empty $ip line"
      changed=1
    fi
  done < "$hosts"
  if [ "$changed" -eq 1 ]; then
    cp "$hosts" "$hosts.nextcloud-align.bak"
    cat "$tmp" > "$hosts"
    log "hosts: wrote $hosts (backup $hosts.nextcloud-align.bak)"
  else
    log "hosts: no *.knarr / *.devel loopback pins"
  fi
  rm -f "$tmp"
}

# --- occ ---------------------------------------------------------------------

occ() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ occ $*"
    return 0
  fi
  php=$(php_bin)
  tmp=$(mktemp)
  {
    echo '#!/bin/sh'
    echo 'set -e'
    printf 'cd %s\n' "$(shell_quote "$NC_ROOT")"
    printf '%s -d apc.enable_cli=1 occ' "$php"
    for a in "$@"; do
      printf ' %s' "$(shell_quote "$a")"
    done
    echo
  } > "$tmp"
  chown "$HTTP_USER:$HTTP_GROUP" "$tmp"
  chmod 0700 "$tmp"
  su -s /bin/sh -c "/bin/sh $tmp" "$HTTP_USER"
  st=$?
  rm -f "$tmp"
  return "$st"
}

php_handler_block() {
  sock=""
  if [ -S /run/php/stardust-fpm.sock ]; then
    sock=/run/php/stardust-fpm.sock
  else
    for s in /run/php/php*-fpm.sock /run/php/php-fpm.sock; do
      [ -S "$s" ] || continue
      sock=$s
      break
    done
  fi
  if [ -n "$sock" ]; then
    cat <<EOF
    <FilesMatch "\\.php\$">
      SetHandler "proxy:unix:${sock}|fcgi://localhost/"
    </FilesMatch>
EOF
  fi
}

# --- Apache ------------------------------------------------------------------

write_vhost() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $VHOST  (VirtualHost *:80  ServerName $NC_HOST  path $NC_URL_PATH)"
    log "+ a2dissite nextcloud-localhost.conf ; a2ensite nextcloud.conf"
    return 0
  fi
  for f in "$VHOST" "$VHOST_OLD"; do
    [ -f "$f" ] || continue
    [ -f "$f.align.bak" ] && continue
    cp "$f" "$f.align.bak"
    log "backup $f.align.bak"
  done
  if command -v a2enmod >/dev/null 2>&1; then
    a2enmod rewrite headers env dir mime unique_id proxy proxy_http proxy_wstunnel ssl setenvif >/dev/null 2>&1 || true
    if [ -S /run/php/stardust-fpm.sock ] || [ -d /etc/php ]; then
      a2enmod proxy_fcgi >/dev/null 2>&1 || true
    fi
  fi

  handler=$(php_handler_block)
  aliases="localhost 127.0.0.1"
  case $NC_HOST in
    drive.starhq.knarr) aliases="$aliases drive.knarr" ;;
  esac
  if is_stardust_dns_name "$NC_HOST"; then
    short=${NC_HOST%%.*}
    case $NC_HOST in
      *.knarr) aliases="$aliases ${short}.knarr" ;;
      *.devel) aliases="$aliases ${short}.devel" ;;
    esac
  fi

  if [ "$KEEP_PATH" -eq 1 ]; then
    path_block="  Alias /nextcloud $NC_ROOT"
  else
    path_block=$(printf '%s\n' \
      '  # Previous URL was /nextcloud. Keep bookmarks working.' \
      '  RedirectMatch 301 ^/nextcloud$ /' \
      '  RedirectMatch 301 ^/nextcloud/(.*)$ /$1')
  fi

  cat > "$VHOST" <<EOF
# Nextcloud on the Stardust dnsmasq name. Not a Stardust Backdrop site.
# Written by $PROG. Re-run is safe.
# Name-based *:80 — same pattern as stardust-gitea.conf and site-add.
# Do NOT add Listen 127.0.0.1:80 (AH00072 if ports.conf already has Listen 80).
# Do NOT pin $NC_HOST to 127.0.0.1 in /etc/hosts (dnsmasq owns *.knarr).
<VirtualHost *:80>
  ServerName $NC_HOST
  ServerAlias $aliases
  DocumentRoot $NC_ROOT

  KeepAlive On
  KeepAliveTimeout 3
  MaxKeepAliveRequests 200
  HostnameLookups Off
  Timeout 120
  AllowEncodedSlashes NoDecode

$path_block

  <Directory $NC_ROOT>
    Options +FollowSymlinks -Indexes
    AllowOverride All
    Require all granted
    Satisfy Any
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
    SetEnv HOME $NC_ROOT
    SetEnv HTTP_HOME $NC_ROOT
$handler
  </Directory>

  <Directory $NC_DATA>
    Require all denied
  </Directory>

  Header always set Referrer-Policy "no-referrer"
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
  Header always set X-Permitted-Cross-Domain-Policies "none"
  Header always set X-Robots-Tag "noindex, nofollow"
  Header always set X-XSS-Protection "1; mode=block"

  SSLProxyEngine Off
  ProxyPreserveHost On
  ProxyPass           /browser http://127.0.0.1:${CODE_PORT}/browser retry=0
  ProxyPassReverse    /browser http://127.0.0.1:${CODE_PORT}/browser
  ProxyPass           /hosting/discovery http://127.0.0.1:${CODE_PORT}/hosting/discovery retry=0
  ProxyPassReverse    /hosting/discovery http://127.0.0.1:${CODE_PORT}/hosting/discovery
  ProxyPass           /hosting/capabilities http://127.0.0.1:${CODE_PORT}/hosting/capabilities retry=0
  ProxyPassReverse    /hosting/capabilities http://127.0.0.1:${CODE_PORT}/hosting/capabilities
  ProxyPassMatch      "/cool/(.*)\$" ws://127.0.0.1:${CODE_PORT}/cool/\$1 retry=0
  ProxyPass           /cool http://127.0.0.1:${CODE_PORT}/cool retry=0
  ProxyPassReverse    /cool http://127.0.0.1:${CODE_PORT}/cool
  ProxyPass           /loleaflet http://127.0.0.1:${CODE_PORT}/loleaflet retry=0
  ProxyPassReverse    /loleaflet http://127.0.0.1:${CODE_PORT}/loleaflet
  ProxyPassMatch      "/lool/(.*)\$" ws://127.0.0.1:${CODE_PORT}/lool/\$1 retry=0
  ProxyPass           /lool http://127.0.0.1:${CODE_PORT}/lool retry=0
  ProxyPassReverse    /lool http://127.0.0.1:${CODE_PORT}/lool

  ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
  CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
EOF

  if command -v a2dissite >/dev/null 2>&1; then
    a2dissite nextcloud-localhost.conf >/dev/null 2>&1 || true
  fi
  if [ -f "$VHOST_OLD" ] && grep -q '^Listen ' "$VHOST_OLD"; then
    log "note: $VHOST_OLD still has a Listen line — site disabled so it cannot double-bind :80"
  fi
  if command -v a2ensite >/dev/null 2>&1; then
    a2ensite nextcloud.conf >/dev/null 2>&1 || true
  fi
  if [ -f /etc/apache2/sites-enabled/owncloud-localhost.conf ]; then
    log "WARN: owncloud-localhost.conf is enabled. Two apps want the same Host."
    log "      a2dissite one of them, or give ownCloud its own ServerName."
  fi
}

apache_apply() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ apache2ctl configtest && service apache2 reload"
    return 0
  fi
  if command -v apache2ctl >/dev/null 2>&1; then
    apache2ctl configtest || die "apache2ctl configtest failed"
  fi
  if command -v service >/dev/null 2>&1; then
    service apache2 reload || service apache2 restart || die "Apache reload failed"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2 || systemctl reload httpd || die "Apache reload failed"
  fi
}

# --- Nextcloud config --------------------------------------------------------

set_trusted_domains() {
  i=0
  occ config:system:set trusted_domains $i --value="$NC_HOST"
  i=$((i + 1))
  for extra in localhost 127.0.0.1 drive.knarr; do
    [ "$extra" = "$NC_HOST" ] && continue
    occ config:system:set trusted_domains $i --value="$extra"
    i=$((i + 1))
  done
  hostn=$(hostname 2>/dev/null || true)
  if [ -n "$hostn" ] && [ "$hostn" != "$NC_HOST" ]; then
    occ config:system:set trusted_domains $i --value="$hostn"
    i=$((i + 1))
  fi
  for ip in $(lan_ips); do
    case $ip in
      127.*|::1) continue ;;
    esac
    occ config:system:set trusted_domains $i --value="$ip"
    i=$((i + 1))
  done
}

align_occ() {
  set_trusted_domains
  occ config:system:set overwritehost --value="$NC_HOST"
  occ config:system:set overwriteprotocol --value=http
  occ config:system:set allow_local_remote_servers --value=true --type=boolean
  if [ "$KEEP_PATH" -eq 1 ]; then
    occ config:system:set overwrite.cli.url --value="http://${NC_HOST}/nextcloud"
    occ config:system:set overwritewebroot --value="/nextcloud"
    occ config:system:set htaccess.RewriteBase --value=/nextcloud
  else
    occ config:system:set overwrite.cli.url --value="http://${NC_HOST}/"
    occ config:system:set overwritewebroot --value=""
    occ config:system:set htaccess.RewriteBase --value=/
  fi
  if [ "$DRYRUN" -eq 0 ]; then
    chown "$HTTP_USER:$HTTP_GROUP" "$NC_ROOT/.htaccess" "$NC_ROOT/.user.ini" 2>/dev/null || true
  fi
  occ maintenance:update:htaccess || log "note: occ could not update .htaccess"
}

# --- Collabora ---------------------------------------------------------------

rewrite_code_runner() {
  if [ "$SKIP_CODE" -eq 1 ]; then
    log "skip CODE runner rewrite (--skip-code)"
    return 0
  fi
  runner=/usr/local/sbin/collabora-nextcloud-run
  extra="--o:ssl.enable=false --o:ssl.termination=false --o:logging.level=warning --o:num_prespawn_children=2 --o:per_document.max_concurrency=4"
  aliases="http://${NC_HOST}|http://localhost|http://127.0.0.1|http://${NC_HOST}:80|http://127.0.0.1:80|http://drive.knarr|http://drive.knarr:80"
  codepass=admin
  if [ -f "$NC_SEC/code-admin.pass" ]; then
    codepass=$(cat "$NC_SEC/code-admin.pass")
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ rewrite $runner aliasgroup1=$aliases"
    return 0
  fi
  if ! command -v podman >/dev/null 2>&1; then
    log "note: podman not installed — skip CODE rewrite"
    return 0
  fi
  cat > "$runner" <<EOF
#!/bin/sh
set -eu
podman rm -f $CODE_NAME >/dev/null 2>&1 || true
exec podman run --name $CODE_NAME --replace --detach \\
  --network host \\
  --cap-add MKNOD \\
  -e "aliasgroup1=${aliases}" \\
  -e "extra_params=${extra}" \\
  -e "DONT_GEN_SSL_CERT=true" \\
  -e "dictionaries=en_US en_GB" \\
  -e "username=admin" \\
  -e "password=${codepass}" \\
  -e "TZ=${TZ_NAME}" \\
  $CODE_IMAGE
EOF
  chmod 0750 "$runner"
  log "CODE runner: aliasgroup1 uses $NC_HOST (loopback still in the list)"
}

restart_code() {
  if [ "$SKIP_CODE" -eq 1 ]; then
    log "skip CODE restart (--skip-code) — existing container stays up"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ restart $CODE_NAME"
    return 0
  fi
  if ! command -v podman >/dev/null 2>&1; then
    return 0
  fi
  if [ -x /usr/local/sbin/collabora-nextcloud-run ]; then
    /usr/local/sbin/collabora-nextcloud-run
  elif [ -x /etc/init.d/collabora-nextcloud ]; then
    /etc/init.d/collabora-nextcloud restart || true
  else
    log "note: no CODE runner — start Collabora later with nextcloud-install.sh --office-only"
    return 0
  fi
  n=0
  while [ "$n" -lt 20 ]; do
    if wget -q -O - "http://127.0.0.1:${CODE_PORT}/hosting/discovery" 2>/dev/null | grep -q -i wopi; then
      log "CODE discovery OK"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  log "WARN: CODE /hosting/discovery not ready; podman logs $CODE_NAME"
}

align_richdocuments() {
  if [ "$SKIP_CODE" -eq 1 ]; then
    log "skip richdocuments rewrite (--skip-code)"
    return 0
  fi
  if [ ! -x "$NC_ROOT/occ" ]; then
    return 0
  fi
  occ app:enable richdocuments 2>/dev/null || true
  occ app:disable richdocumentscode 2>/dev/null || true
  occ app:disable richdocumentscode_arm64 2>/dev/null || true
  occ config:app:set richdocuments wopi_url --value="http://127.0.0.1:${CODE_PORT}"
  occ config:app:set richdocuments public_wopi_url --value="http://${NC_HOST}"
  if [ "$KEEP_PATH" -eq 1 ]; then
    occ config:app:set richdocuments canonical_webroot --value="/nextcloud"
  else
    occ config:app:set richdocuments canonical_webroot --value=""
  fi
  allow="127.0.0.1,::1,127.0.0.0/8,10.8.0.0/24"
  for ip in $(lan_ips); do
    case $ip in 127.*|::1) continue ;; esac
    allow="$allow,$ip"
  done
  occ config:app:set richdocuments wopi_allowlist --value="$allow"
  occ config:app:set richdocuments disable_certificate_verification --value=yes
  occ richdocuments:activate-config 2>/dev/null || true
}

# --- report ------------------------------------------------------------------

print_summary() {
  ip=$(getent hosts "$NC_HOST" 2>/dev/null | awk '{print $1; exit}' || true)
  case $ip in
    127.*|::1)
      loop=WARN
      ;;
    '')
      loop="UNRESOLVED"
      ;;
    *)
      loop=ok
      ;;
  esac
  cat <<EOF

================================================================
Nextcloud aligned with Stardust dnsmasq
================================================================

Browse:
  http://${NC_HOST}${NC_URL_PATH}

DNS on this box:
  getent hosts ${NC_HOST}  →  ${ip:-none}  ($loop)
  expect the LAN/WG address from STEP 25, never 127.0.0.1

Apache:
  enabled  $VHOST
  disabled $VHOST_OLD  (Listen 127.0.0.1 + Alias /nextcloud)
  old URL  http://${NC_HOST}/nextcloud  301 → /

Collabora:
  PHP → CODE     http://127.0.0.1:${CODE_PORT}
  browser → CODE http://${NC_HOST}  (Apache /browser /cool proxy)
  service collabora-nextcloud restart

Checks:
  getent hosts ${NC_HOST} www.devel starhq.knarr
  apache2ctl -S | grep ${NC_HOST}
  curl -sI http://${NC_HOST}/ | head
  curl -sS http://127.0.0.1:${CODE_PORT}/hosting/discovery | head

Do not re-run nextcloud-install.sh after this unless you also
re-run $PROG — the old installer still writes the loopback vhost
and may put ${NC_HOST} back in /etc/hosts.

Laptops that do not use knarr as DNS still need:
  <LAN-IP>  ${NC_HOST}
in THEIR /etc/hosts. Never 127.0.0.1 — that is their own loopback.
EOF
}

# --- main --------------------------------------------------------------------

need_root
guess_php_user

if [ "$DRYRUN" -eq 0 ]; then
  [ -x "$NC_ROOT/occ" ] || die "no $NC_ROOT/occ — install Nextcloud first"
  [ -f "$NC_ROOT/config/config.php" ] || die "no config.php — occ maintenance:install has not run"
fi

if is_loopback_name "$NC_HOST"; then
  die "-H $NC_HOST is loopback. Use a *.knarr / *.devel name (default drive.starhq.knarr)"
fi

log "align Nextcloud at $NC_ROOT"
log "  host $NC_HOST"
log "  php  $HTTP_USER:$HTTP_GROUP"
log "  url  http://${NC_HOST}${NC_URL_PATH}"
log "  keep-path=$KEEP_PATH  skip-code=$SKIP_CODE"

scrub_loopback_hosts
write_vhost
apache_apply
align_occ
rewrite_code_runner
restart_code
align_richdocuments
print_summary
