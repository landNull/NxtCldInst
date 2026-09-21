#!/bin/sh
# nextcloud-install.sh — localhost Nextcloud + Collabora CODE (Podman)
# Separate from Stardust (Backdrop control plane). Do not drop this under
# /srv/platforms or /srv/stardust. Counterpart to owncloud-install.sh.
#
# Host target: Devuan sysvinit (also works on systemd). Reuses Apache +
# MariaDB + PHP if Stardust already installed them.
#
#   nextcloud-install.sh [-n] [-H HOST] [-u HTTP_USER] [-g HTTP_GROUP]
#   nextcloud-install.sh --office-only
#   nextcloud-install.sh -h
#
# Default layout (outside Stardust trees):
#   /srv/apps/nextcloud          code (DocumentRoot / Alias)
#   /srv/apps/nextcloud-data     data directory (not web-reachable)
#   /srv/apps/nextcloud-secrets  generated passwords (0640)
#   http://127.0.0.1/nextcloud   vhost on localhost only
#   127.0.0.1:9980              CODE via Podman --network host
#
# PHP: Nextcloud current line needs >= 8.1 (8.3 recommended). Script
# stops if PHP is older. Tarball is the published latest.tar.bz2.

set -eu

PROG=${0##*/}
DRYRUN=0
OFFICE_ONLY=0
HTTP_USER=www-data
HTTP_GROUP=www-data
NC_HOST=127.0.0.1
NC_ROOT=/srv/apps/nextcloud
NC_DATA=/srv/apps/nextcloud-data
NC_SEC=/srv/apps/nextcloud-secrets
NC_URL_PATH=/nextcloud
VHOST=/etc/apache2/sites-available/nextcloud-localhost.conf
CODE_NAME=collabora-nextcloud
CODE_IMAGE=docker.io/collabora/code:latest
CODE_PORT=9980
REDIS_SOCK=/var/run/redis/redis-server.sock
DB_NAME=nextcloud
DB_USER=nextcloud
PHONE_REGION=US
TZ_NAME=America/Denver
# 08:00 UTC = 01:00/02:00 America/Denver — overnight jobs, not daytime.
MAINT_HOUR=8

usage() {
  cat <<EOF
$PROG — Nextcloud localhost + Collabora CODE (Podman, not Docker)

  $PROG [options]
  $PROG --office-only     only start/reconfigure CODE + richdocuments

Options:
  -n              dry run
  -H HOST         trusted host (default 127.0.0.1)
  -u USER         Apache/PHP user (default www-data)
  -g GROUP        Apache/PHP group (default www-data)
  -h              this help

Does
  * packages: apache2, mariadb, redis, php (+ mods), podman
  * mkcert + libnss3-tools (local CA; LAN HTTPS without browser warnings)
  * MariaDB db+user (utf8mb4_bin), data dir outside the web root
  * occ maintenance:install on http://HOST/nextcloud
  * PHP 99-nextcloud.ini, MariaDB 60-nextcloud.cnf, Redis unix socket
  * APCu local + Redis distributed/locking, cron background jobs
  * Apache localhost vhost + security/speed snippets + CODE proxy
  * occ system/app settings that clear setup warnings on a local box
  * Podman CODE on 127.0.0.1:9980 --network host --cap-add MKNOD
  * richdocuments wopi_url -> http://127.0.0.1:9980

Podman vs Docker
  Yes. CODE is an OCI image (collabora/code). Podman runs it. Use
  --network host so the container can WOPI-callback to Nextcloud on
  localhost (container 127.0.0.1 is otherwise the container itself).
  --cap-add MKNOD is still required on many CODE builds. Rootless
  Podman often needs extra caps or a seccomp profile; this script
  uses rootful Podman for a reliable jail on Devuan sysvinit.

Not in scope
  Stardust site-add, Bee, public TLS/Let's Encrypt, CSF, Docker,
  GitHub/GitLab CLI, compiling Imagick from source.
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
    -H) NC_HOST=$2; shift ;;
    -u) HTTP_USER=$2; shift ;;
    -g) HTTP_GROUP=$2; shift ;;
    --office-only) OFFICE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

need_root() {
  [ "$(id -u)" -eq 0 ] || [ "$DRYRUN" -eq 1 ] || die "run as root (do not wrap the whole script in sudo)"
}

php_bin() {
  command -v php >/dev/null 2>&1 && command -v php && return 0
  command -v php8.3 >/dev/null 2>&1 && command -v php8.3 && return 0
  command -v php8.4 >/dev/null 2>&1 && command -v php8.4 && return 0
  command -v php8.2 >/dev/null 2>&1 && command -v php8.2 && return 0
  echo php
}

php_major_minor() {
  "$(php_bin)" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo 0.0
}

php_ok() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ check PHP >= 8.1"
    return 0
  fi
  mm=$(php_major_minor)
  case $mm in
    8.1|8.2|8.3|8.4|8.5) log "PHP $mm OK for Nextcloud"; return 0 ;;
    *) die "PHP $mm is not a supported Nextcloud runtime (need >= 8.1, 8.3 recommended)" ;;
  esac
}

tarball_url() {
  echo "https://download.nextcloud.com/server/releases/latest.tar.bz2"
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive run apt-get update -qq
    DEBIAN_FRONTEND=noninteractive run apt-get install -y \
      apache2 mariadb-server redis-server \
      openssl wget bzip2 ca-certificates \
      libapache2-mod-php php php-cli php-gd php-curl php-xml php-mbstring \
      php-zip php-intl php-mysql php-gmp php-bcmath php-imagick php-apcu \
      php-redis php-bz2 \
      podman uidmap slirp4netns
    # Optional extras — missing package must not abort the install.
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ apt-get install optional php extras + mkcert one-by-one"
    else
      # One package per call: a missing php-imap must not skip the others.
      for p in php-exif php-ftp php-ldap php-igbinary php-imap; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" \
          || log "note: optional $p not available"
      done
      # mkcert: local CA so LAN browsers trust HTTPS without the self-signed
      # interstitial. libnss3-tools is required for Firefox/Chrome NSS.
      for p in libnss3-tools mkcert; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" \
          || log "note: optional $p not available (LAN HTTPS without browser warnings)"
      done
    fi
  else
    die "apt-get not found; install apache/mariadb/php/redis/podman by hand"
  fi
}

ensure_dirs() {
  run mkdir -p "$NC_ROOT" "$NC_DATA" "$NC_SEC" /srv/apps
  if command -v crdir >/dev/null 2>&1; then
    run crdir -o "$HTTP_USER" -g "$HTTP_GROUP" -m 0750 "$NC_DATA"
    run crdir -o root -g "$HTTP_GROUP" -m 0750 "$NC_SEC"
  else
    run chown "$HTTP_USER:$HTTP_GROUP" "$NC_DATA"
    run chmod 0750 "$NC_DATA"
    run chown "root:$HTTP_GROUP" "$NC_SEC"
    run chmod 0750 "$NC_SEC"
  fi
}

secret_file() {
  name=$1
  path=$NC_SEC/$name
  if [ -f "$path" ] && [ "$DRYRUN" -eq 0 ]; then
    cat "$path"
    return 0
  fi
  val=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  if [ "$DRYRUN" -eq 0 ]; then
    umask 077
    printf '%s\n' "$val" > "$path"
    chown "root:$HTTP_GROUP" "$path"
    chmod 0640 "$path"
  fi
  printf '%s\n' "$val"
}

tune_mariadb() {
  f=/etc/mysql/mariadb.conf.d/60-nextcloud.cnf
  [ -d /etc/mysql/mariadb.conf.d ] || f=/etc/mysql/conf.d/60-nextcloud.cnf
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $f"
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
# Nextcloud — READ-COMMITTED is required (admin manual, linux_database_configuration)
[mysqld]
transaction_isolation = READ-COMMITTED
binlog_format = ROW
innodb_file_per_table = 1
innodb_large_prefix = 1
innodb_file_format = Barracuda
character_set_server = utf8mb4
collation_server = utf8mb4_bin
max_allowed_packet = 64M
innodb_buffer_pool_size = 512M
skip_name_resolve = 1
EOF
}

tune_php() {
  written=0
  for d in /etc/php/*/apache2/conf.d /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d; do
    [ -d "$d" ] || continue
    f=$d/99-nextcloud.ini
    if [ "$DRYRUN" -eq 1 ]; then
      log "+ write $f"
      written=1
      continue
    fi
    cat > "$f" <<'EOF'
; Nextcloud recommended PHP (admin manual: php_configuration + server_tuning)
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 360
max_input_time = 360
max_input_vars = 3000
output_buffering = Off
expose_php = Off
allow_url_include = Off
date.timezone = America/Denver
apc.enable_cli = 1
apc.shm_size = 128M
opcache.enable = 1
opcache.enable_cli = 0
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
opcache.jit = 1255
opcache.jit_buffer_size = 8M
EOF
    written=1
  done
  if command -v phpenmod >/dev/null 2>&1 && [ "$DRYRUN" -eq 0 ]; then
    phpenmod apcu redis 2>/dev/null || true
  fi
  if [ "$written" -eq 0 ]; then
    log "note: no PHP conf.d found; set memory_limit / output_buffering by hand"
  fi
}

tune_redis() {
  conf=/etc/redis/redis.conf
  [ -f "$conf" ] || conf=/etc/redis/redis-server.conf
  if [ ! -f "$conf" ]; then
    log "note: redis.conf not found — locking will use TCP 6379 if redis listens"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ tune redis unixsocket $REDIS_SOCK"
    return 0
  fi
  if grep -q '^unixsocket ' "$conf"; then
    sed -i "s|^unixsocket .*|unixsocket $REDIS_SOCK|" "$conf"
  elif grep -q '^# unixsocket ' "$conf"; then
    sed -i "s|^# unixsocket .*|unixsocket $REDIS_SOCK|" "$conf"
  else
    printf '\nunixsocket %s\nunixsocketperm 770\n' "$REDIS_SOCK" >> "$conf"
  fi
  if grep -q '^unixsocketperm ' "$conf"; then
    sed -i 's|^unixsocketperm .*|unixsocketperm 770|' "$conf"
  elif grep -q '^# unixsocketperm ' "$conf"; then
    sed -i 's|^# unixsocketperm .*|unixsocketperm 770|' "$conf"
  fi
  if getent group redis >/dev/null 2>&1; then
    usermod -aG redis "$HTTP_USER" 2>/dev/null || true
  fi
}

tune_apache_mods() {
  if command -v a2enmod >/dev/null 2>&1; then
    run a2enmod rewrite headers env dir mime unique_id proxy proxy_http proxy_wstunnel ssl setenvif >/dev/null 2>&1 || true
    if [ -S /run/php/stardust-fpm.sock ] || [ -d /etc/php ]; then
      run a2enmod proxy_fcgi >/dev/null 2>&1 || true
    fi
  fi
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

write_vhost() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $VHOST"
    return 0
  fi
  listen=""
  if ! grep -Rqs 'Listen 127.0.0.1:80' /etc/apache2/ports.conf /etc/apache2/sites-enabled /etc/apache2/sites-available 2>/dev/null; then
    listen="Listen 127.0.0.1:80"
  fi
  handler=$(php_handler_block)
  cat > "$VHOST" <<EOF
# Nextcloud localhost only. Not a Stardust site vhost.
# Do not a2ensite this together with owncloud-localhost.conf on the
# same ServerName without merging Alias/ProxyPass by hand.
$listen
<VirtualHost 127.0.0.1:80>
  ServerName $NC_HOST
  ServerAlias localhost 127.0.0.1
  DocumentRoot $NC_ROOT
  Alias $NC_URL_PATH $NC_ROOT

  KeepAlive On
  KeepAliveTimeout 3
  MaxKeepAliveRequests 200
  HostnameLookups Off
  Timeout 120
  AllowEncodedSlashes NoDecode

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

  # Data dir is outside the vhost tree on purpose.
  <Directory $NC_DATA>
    Require all denied
  </Directory>

  Header always set Referrer-Policy "no-referrer"
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
  Header always set X-Permitted-Cross-Domain-Policies "none"
  Header always set X-Robots-Tag "noindex, nofollow"
  Header always set X-XSS-Protection "1; mode=block"

  # Collabora CODE (Podman, host net, TLS off for localhost)
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
  if command -v a2ensite >/dev/null 2>&1; then
    run a2ensite nextcloud-localhost.conf >/dev/null 2>&1 || true
  fi
}

reload_services() {
  if command -v service >/dev/null 2>&1; then
    run service apache2 reload 2>/dev/null || run service apache2 restart || true
    run service mariadb start 2>/dev/null || run service mysql start || true
    run service redis-server start 2>/dev/null || run service redis start || true
    for s in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php-fpm; do
      if [ -x "/etc/init.d/$s" ]; then
        run service "$s" restart 2>/dev/null || true
        break
      fi
    done
  elif command -v systemctl >/dev/null 2>&1; then
    run systemctl reload apache2 2>/dev/null || run systemctl reload httpd || true
    run systemctl start mariadb 2>/dev/null || run systemctl start mysql || true
    run systemctl start redis-server 2>/dev/null || true
  fi
}

setup_db() {
  dbpass=$(secret_file db.pass)
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ CREATE DATABASE $DB_NAME / USER $DB_USER"
    return 0
  fi
  mysql --protocol=socket -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$dbpass';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

fetch_nextcloud() {
  if [ -f "$NC_ROOT/occ" ]; then
    log "Nextcloud already unpacked at $NC_ROOT"
    return 0
  fi
  url=$(tarball_url)
  t=/tmp/nextcloud-latest.tar.bz2
  hash=""
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ wget $url -> $t"
    log "+ verify sha256 of latest.tar.bz2 (ignore latest.metadata line)"
    return 0
  fi
  # Sidecar has two lines: latest.tar.bz2 and latest.metadata. Only the tarball line applies.
  wget -q -O "$t.sha256" "$url.sha256" 2>/dev/null || true
  if [ -s "$t.sha256" ]; then
    hash=$(awk '$2 ~ /tar\.bz2$/ { print $1; exit }' "$t.sha256")
  fi
  need_fetch=1
  if [ -f "$t" ] && [ -n "$hash" ]; then
    if echo "$hash  $t" | sha256sum -c -; then
      log "tarball checksum OK, skip download"
      need_fetch=0
    else
      log "existing $t failed checksum, re-fetch"
      rm -f "$t"
    fi
  fi
  if [ "$need_fetch" -eq 1 ]; then
    log "fetch $url"
    wget -O "$t" "$url"
    if [ -n "$hash" ]; then
      echo "$hash  $t" | sha256sum -c - || die "tarball checksum mismatch"
    else
      log "note: no sha256 sidecar for latest.tar.bz2; skipped verify"
    fi
  fi
  run mkdir -p /tmp/nc-unpack
  run tar -xjf "$t" -C /tmp/nc-unpack
  if [ -d /tmp/nc-unpack/nextcloud ]; then
    mkdir -p "$NC_ROOT"
    cp -a /tmp/nc-unpack/nextcloud/. "$NC_ROOT/"
  else
    die "tarball did not contain nextcloud/"
  fi
  chown -R "root:$HTTP_GROUP" "$NC_ROOT"
  chmod 0750 "$NC_ROOT"
  mkdir -p "$NC_ROOT/custom_apps"
  chown -R "$HTTP_USER:$HTTP_GROUP" \
    "$NC_ROOT/apps" "$NC_ROOT/config" "$NC_ROOT/themes" "$NC_ROOT/custom_apps" 2>/dev/null || true
  ensure_htaccess_writable
  rm -rf /tmp/nc-unpack "$t" "$t.sha256"
}

# occ maintenance:update:htaccess writes NC_ROOT/.htaccess as HTTP_USER.
ensure_htaccess_writable() {
  [ "$DRYRUN" -eq 1 ] && return 0
  for f in "$NC_ROOT/.htaccess" "$NC_ROOT/.user.ini"; do
    [ -e "$f" ] || continue
    chown "$HTTP_USER:$HTTP_GROUP" "$f"
    chmod 0640 "$f"
  done
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

occ() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ occ $*"
    return 0
  fi
  # Write a tiny script and run it as HTTP_USER. Passing class names
  # through su -c "..." eats backslashes (\O -> O -> OCMemcacheAPCu) and
  # Nextcloud then cannot boot occ at all.
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
  # mktemp is 0600 root:root; www-data cannot read it until we chown.
  chown "$HTTP_USER:$HTTP_GROUP" "$tmp"
  chmod 0700 "$tmp"
  su -s /bin/sh -c "/bin/sh $tmp" "$HTTP_USER"
  st=$?
  rm -f "$tmp"
  return "$st"
}

php_has_ext() {
  "$(php_bin)" -d apc.enable_cli=1 -r "exit(extension_loaded('$1') ? 0 : 1);" 2>/dev/null
}

# Edit config.php as a file (no occ). Needed for \OC\Memcache\* values and
# to unstick a box where occ dies on a mangled memcache.local.
config_php_set() {
  key=$1
  val=$2
  conf=$NC_ROOT/config/config.php
  [ -f "$conf" ] || return 1
  "$(php_bin)" -r '
$conf = $argv[1];
$key  = $argv[2];
$val  = $argv[3];
$s = file_get_contents($conf);
if ($s === false) { fwrite(STDERR, "cannot read config.php\n"); exit(1); }
$line = "  " . var_export($key, true) . " => " . var_export($val, true) . ",";
$re = "/^[ \t]*" . preg_quote(var_export($key, true), "/") . "[ \t]*=>.*$/m";
if (preg_match($re, $s)) {
  $s = preg_replace($re, $line, $s, 1);
} else {
  $s = preg_replace("/\n\);?\s*$/", "\n" . $line . "\n);\n", $s, 1);
}
if (file_put_contents($conf, $s) === false) exit(1);
' "$conf" "$key" "$val"
}

config_php_delete() {
  key=$1
  conf=$NC_ROOT/config/config.php
  [ -f "$conf" ] || return 0
  "$(php_bin)" -r '
$conf = $argv[1];
$key  = $argv[2];
$s = file_get_contents($conf);
if ($s === false) exit(0);
$re = "/^[ \t]*" . preg_quote(var_export($key, true), "/") . "[ \t]*=>.*\n/m";
$s = preg_replace($re, "", $s, 1);
file_put_contents($conf, $s);
' "$conf" "$key"
}

repair_mangled_memcache() {
  conf=$NC_ROOT/config/config.php
  [ -f "$conf" ] || return 0
  if grep -q 'OCMemcache' "$conf"; then
    log "repair: stripping mangled memcache.* from config.php so occ can start"
    config_php_delete memcache.local
    config_php_delete memcache.distributed
    config_php_delete memcache.locking
  fi
}

install_nextcloud() {
  if [ -f "$NC_ROOT/config/config.php" ] && grep -q "'installed' => true" "$NC_ROOT/config/config.php" 2>/dev/null; then
    log "Nextcloud already installed"
    return 0
  fi
  dbpass=$(secret_file db.pass)
  adminpass=$(secret_file admin.pass)
  occ maintenance:install \
    --database mysql \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$dbpass" \
    --database-host localhost \
    --data-dir "$NC_DATA" \
    --admin-user admin \
    --admin-pass "$adminpass"
}

lan_ips() {
  hostname -I 2>/dev/null || true
}

harden_config() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ occ config tweaks (trusted_domains, cache, cron, office, setup warnings)"
    return 0
  fi

  repair_mangled_memcache

  i=0
  occ config:system:set trusted_domains $i --value="$NC_HOST"
  i=$((i + 1))
  if [ "$NC_HOST" != localhost ]; then
    occ config:system:set trusted_domains $i --value=localhost
    i=$((i + 1))
  fi
  if [ "$NC_HOST" != 127.0.0.1 ]; then
    occ config:system:set trusted_domains $i --value=127.0.0.1
    i=$((i + 1))
  fi
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

  occ config:system:set overwrite.cli.url --value="http://${NC_HOST}${NC_URL_PATH}"
  occ config:system:set overwritehost --value="$NC_HOST"
  occ config:system:set overwriteprotocol --value=http
  occ config:system:set overwritewebroot --value="$NC_URL_PATH"
  occ config:system:set htaccess.RewriteBase --value="$NC_URL_PATH"

  if php_has_ext apcu; then
    config_php_set memcache.local '\OC\Memcache\APCu'
    log "memcache.local set via config.php (APCu)"
  else
    log "note: php-apcu not loaded — skip memcache.local (install php-apcu / phpenmod apcu)"
    config_php_delete memcache.local
  fi
  sock=$REDIS_SOCK
  [ -S "$sock" ] || sock=/run/redis/redis-server.sock
  if php_has_ext redis && [ -S "$sock" ]; then
    config_php_set memcache.distributed '\OC\Memcache\Redis'
    config_php_set memcache.locking '\OC\Memcache\Redis'
    occ config:system:set redis host --value="$sock"
    occ config:system:set redis port --value=0 --type=integer
    occ config:system:set redis timeout --value=1.5 --type=float
  elif php_has_ext redis && command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
    config_php_set memcache.distributed '\OC\Memcache\Redis'
    config_php_set memcache.locking '\OC\Memcache\Redis'
    occ config:system:set redis host --value=127.0.0.1
    occ config:system:set redis port --value=6379 --type=integer
  else
    log "note: Redis not reachable — APCu local cache only, file locking stays on DB"
    config_php_delete memcache.distributed
    config_php_delete memcache.locking
  fi
  occ config:system:set filelocking.enabled --value=true --type=boolean

  occ config:system:set mysql.utf8mb4 --value=true --type=boolean
  occ config:system:set default_phone_region --value="$PHONE_REGION"
  occ config:system:set default_timezone --value="$TZ_NAME"
  occ config:system:set maintenance_window_start --value="$MAINT_HOUR" --type=integer
  occ config:system:set loglevel --value=2 --type=integer
  occ config:system:set logfilemode --value=416 --type=integer
  occ config:system:set debug --value=false --type=boolean
  occ config:system:set upgrade.disable-web --value=true --type=boolean
  occ config:system:set updater.release.channel --value=stable
  occ config:system:set simpleSignUpLink.shown --value=false --type=boolean
  occ config:system:set knowledgebaseenabled --value=false --type=boolean
  occ config:system:set skeletondirectory --value=""
  occ config:system:set trashbin_retention_obligation --value='auto,30'
  occ config:system:set versions_retention_obligation --value='auto,30'
  occ config:system:set enable_previews --value=true --type=boolean
  occ config:system:set preview_max_x --value=2048 --type=integer
  occ config:system:set preview_max_y --value=2048 --type=integer
  occ config:system:set preview_max_memory --value=256 --type=integer
  occ config:system:set preview_max_filesize_image --value=50 --type=integer
  occ config:system:set auth.bruteforce.protection.enabled --value=true --type=boolean
  # SSRF guard blocks 127.0.0.1 by default; CODE on host net needs this.
  occ config:system:set allow_local_remote_servers --value=true --type=boolean
  occ config:system:set check_data_directory_permissions --value=true --type=boolean
  occ background:cron 2>/dev/null || true

  occ app:disable firstrunwizard 2>/dev/null || true
  occ app:disable survey_client 2>/dev/null || true
  occ app:disable nextcloud_announcements 2>/dev/null || true
  occ app:disable richdocumentscode 2>/dev/null || true
  occ app:disable richdocumentscode_arm64 2>/dev/null || true

  occ db:add-missing-indices 2>/dev/null || true
  occ db:add-missing-columns 2>/dev/null || true
  occ db:add-missing-primary-keys 2>/dev/null || true
  ensure_htaccess_writable
  occ maintenance:update:htaccess || log "note: occ could not update .htaccess"
}

install_cron() {
  f=/etc/cron.d/nextcloud
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $f"
    return 0
  fi
  cat > "$f" <<EOF
# Nextcloud background jobs. apc.enable_cli is required with memcache.local=APCu.
*/5 * * * * $HTTP_USER php -d apc.enable_cli=1 -f $NC_ROOT/cron.php
EOF
  chmod 0644 "$f"
}

install_logrotate() {
  f=/etc/logrotate.d/nextcloud
  if [ ! -d /etc/logrotate.d ]; then
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $f"
    return 0
  fi
  cat > "$f" <<EOF
$NC_DATA/nextcloud.log
$NC_DATA/audit.log
{
  weekly
  rotate 8
  missingok
  notifempty
  compress
  copytruncate
}
EOF
}

write_code_unit() {
  initd=/etc/init.d/collabora-nextcloud
  extra="--o:ssl.enable=false --o:ssl.termination=false --o:logging.level=warning --o:num_prespawn_children=2 --o:per_document.max_concurrency=4"
  aliases="http://${NC_HOST}|http://localhost|http://127.0.0.1|http://${NC_HOST}:80|http://127.0.0.1:80"
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ write $initd and podman run $CODE_NAME"
    return 0
  fi
  codepass=$(secret_file code-admin.pass)
  cat > /usr/local/sbin/collabora-nextcloud-run <<EOF
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
  chmod 0750 /usr/local/sbin/collabora-nextcloud-run

  cat > "$initd" <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          collabora-nextcloud
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Collabora CODE via Podman (Nextcloud)
### END INIT INFO
NAME=collabora-nextcloud
RUN=/usr/local/sbin/collabora-nextcloud-run
case "$1" in
  start) $RUN ;;
  stop) podman stop "$NAME" 2>/dev/null || true ;;
  restart) podman stop "$NAME" 2>/dev/null || true; $RUN ;;
  status) podman ps --filter name="$NAME" ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod 0755 "$initd"
  if command -v update-rc.d >/dev/null 2>&1; then
    run update-rc.d collabora-nextcloud defaults || true
  fi
}

start_code() {
  if ! command -v podman >/dev/null 2>&1; then
    die "podman not installed"
  fi
  write_code_unit
  if [ "$DRYRUN" -eq 1 ]; then
    return 0
  fi
  /usr/local/sbin/collabora-nextcloud-run
  log "CODE listening on 127.0.0.1:${CODE_PORT} (host network)"
}

wait_code() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ wait for /hosting/discovery"
    return 0
  fi
  n=0
  while [ "$n" -lt 30 ]; do
    if wget -q -O - "http://127.0.0.1:${CODE_PORT}/hosting/discovery" 2>/dev/null | grep -q -i wopi; then
      log "CODE discovery OK"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  log "WARN: CODE /hosting/discovery not ready yet; check: podman logs $CODE_NAME"
  return 0
}

configure_richdocuments() {
  if [ "$DRYRUN" -eq 1 ]; then
    log "+ enable richdocuments / wopi_url"
    return 0
  fi
  occ app:install richdocuments 2>/dev/null || occ app:enable richdocuments 2>/dev/null || \
    log "WARN: enable Nextcloud Office (richdocuments) from the app store if app:install is unavailable"
  occ app:enable richdocuments 2>/dev/null || true
  occ app:disable richdocumentscode 2>/dev/null || true
  occ app:disable richdocumentscode_arm64 2>/dev/null || true
  occ config:app:set richdocuments wopi_url --value="http://${NC_HOST}:${CODE_PORT}"
  occ config:app:set richdocuments public_wopi_url --value="http://${NC_HOST}:${CODE_PORT}"
  occ config:app:set richdocuments wopi_allowlist --value="127.0.0.1,::1,127.0.0.0/8,192.168.1.0/24,10.8.0.0/24"
  occ config:app:set richdocuments disable_certificate_verification --value=yes
  occ config:app:set richdocuments canonical_webroot --value="$NC_URL_PATH"
  occ config:app:set richdocuments doc_format --value=odf
  occ richdocuments:activate-config 2>/dev/null || true
}

print_summary() {
  adminpass=unset
  [ -f "$NC_SEC/admin.pass" ] && adminpass=$(cat "$NC_SEC/admin.pass")
  mkcert_bin=no
  command -v mkcert >/dev/null 2>&1 && mkcert_bin=yes
  caroot=""
  if [ "$mkcert_bin" = yes ]; then
    caroot=$(mkcert -CAROOT 2>/dev/null || true)
  fi
  lan=$(lan_ips)
  cat <<EOF

================================================================
Installation Completed Successfully
================================================================

What you just installed
  Nextcloud (files) + Collabora CODE (Office, via Podman).
  This is NOT a Stardust site. Do not stardust site-add it.

----------------------------------------------------------------
1. Log in (do this first)
----------------------------------------------------------------
  Open a browser ON THIS SERVER (or an SSH tunnel):

    http://${NC_HOST}${NC_URL_PATH}

  Username : admin
  Password : ${adminpass}

  That password is also stored at:
    ${NC_SEC}/admin.pass     (mode 0640, root:${HTTP_GROUP})
  Database password:
    ${NC_SEC}/db.pass
  Collabora admin password:
    ${NC_SEC}/code-admin.pass

  Change the Nextcloud admin password after first login
  (Settings → Personal → Security). The file in nextcloud-secrets
  is NOT updated when you change it in the UI.

----------------------------------------------------------------
2. What each path is
----------------------------------------------------------------
  ${NC_ROOT}
      Nextcloud PHP code. Apache DocumentRoot / Alias ${NC_URL_PATH}.
  ${NC_DATA}
      User files, versions, trash. NOT web-reachable. Back this up.
  ${NC_SEC}
      Generated secrets. Back this up. Mode 0640.
  ${VHOST}
      Apache vhost, bound to 127.0.0.1:80 only.
  /etc/cron.d/nextcloud
      Background jobs every 5 minutes (not AJAX).

----------------------------------------------------------------
3. Collabora CODE (Office)
----------------------------------------------------------------
  Container : ${CODE_NAME}   (image ${CODE_IMAGE})
  Listen    : 127.0.0.1:${CODE_PORT}  (Podman --network host --cap-add MKNOD)
  WOPI URL  : http://${NC_HOST}:${CODE_PORT}

  service collabora-nextcloud start|stop|status

  Test: log in, upload a .odt / .ods / .odp, click it. The editor
  should load from CODE. If it spins, check:
    curl -sS http://127.0.0.1:${CODE_PORT}/hosting/discovery | head
    podman logs ${CODE_NAME}

  Do NOT publish port ${CODE_PORT} on 0.0.0.0. Apache already
  proxies /browser and /cool on the Nextcloud vhost.

----------------------------------------------------------------
4. LAN users and HTTPS (no browser cert warning)
----------------------------------------------------------------
  HTTP on 127.0.0.1 is fine for admin on the box. Other machines
  on the LAN will see a certificate warning if you flip on a
  homemade self-signed cert. mkcert is the app that avoids that:
  it creates a tiny local Certificate Authority and issues certs
  browsers will trust AFTER the CA is installed on each client.

EOF
  if [ "$mkcert_bin" = yes ]; then
    cat <<EOF
  mkcert is installed on this server.
  CA directory: ${caroot:-$(mkcert -CAROOT 2>/dev/null)}

  On the SERVER (once):
    mkcert -install
    mkdir -p ${NC_SEC}/tls
    mkcert -cert-file ${NC_SEC}/tls/nextcloud.pem \\
           -key-file  ${NC_SEC}/tls/nextcloud-key.pem \\
           ${NC_HOST} localhost 127.0.0.1${lan:+ $lan}

  Copy ONLY the CA cert to each laptop/phone (never rootCA-key.pem):
    scp ${caroot:-/root/.local/share/mkcert}/rootCA.pem user@laptop:

  On a Debian/Devuan CLIENT:
    sudo cp rootCA.pem /usr/local/share/ca-certificates/mkcert-lan.crt
    sudo update-ca-certificates
    # Firefox: Settings → Privacy → Certificates → Import rootCA.pem
    #          tick "Trust this CA to identify websites"

  Then point an Apache SSL vhost at:
    SSLCertificateFile      ${NC_SEC}/tls/nextcloud.pem
    SSLCertificateKeyFile   ${NC_SEC}/tls/nextcloud-key.pem
  and set occ overwriteprotocol=https plus trusted_domains / CODE
  aliasgroup1 to the LAN name you used in mkcert.

EOF
  else
    cat <<EOF
  mkcert was not in this distro's apt repo. Install it later:
    apt-get install mkcert libnss3-tools
  then re-run the SERVER / CLIENT steps above (see NOTES.md).
  Until then, stay on http://127.0.0.1${NC_URL_PATH} or tunnel:

    ssh -N -L 8080:127.0.0.1:80 USER@THIS_HOST
    # browse http://127.0.0.1:8080${NC_URL_PATH}

EOF
  fi
  cat <<EOF
----------------------------------------------------------------
5. Day-2 operations
----------------------------------------------------------------
  Re-run this script any time. It is idempotent: it will not
  wipe the database, data dir, or secrets.

  Backups (both, or you cannot restore):
    mysqldump ${DB_NAME} > nextcloud.sql
    tar -C /srv/apps -czf nc-data.tgz nextcloud-data nextcloud/config

  Logs:
    ${NC_DATA}/nextcloud.log
    /var/log/apache2/nextcloud-*.log
    podman logs ${CODE_NAME}

  PHP:  occ is ${NC_ROOT}/occ — always as ${HTTP_USER}:
    su -s /bin/sh ${HTTP_USER} -c "cd ${NC_ROOT} && php -d apc.enable_cli=1 occ status"

----------------------------------------------------------------
6. Do not
----------------------------------------------------------------
  * stardust site-add nextcloud
  * put data under /srv/platforms
  * a2ensite this next to owncloud-localhost.conf without merging
  * expose ${CODE_PORT} on 0.0.0.0
  * share ${NC_SEC} or mkcert's rootCA-key.pem
  * wget the installer from GitHub main — use the devel branch
    until this script is marked stable

LAN addresses this host reported: ${lan:-none}
EOF
}

need_root
if [ "$OFFICE_ONLY" -eq 1 ]; then
  start_code
  wait_code
  [ -x "$NC_ROOT/occ" ] && configure_richdocuments
  print_summary
  exit 0
fi

pkg_install
php_ok
ensure_dirs
tune_mariadb
tune_php
tune_redis
tune_apache_mods
write_vhost
reload_services
setup_db
fetch_nextcloud
install_nextcloud
harden_config
install_cron
install_logrotate
reload_services
start_code
wait_code
configure_richdocuments
print_summary
