Nextcloud localhost installer (starhq.knarr)
===========================================

Separate from Stardust. Stardust stays Backdrop-only
(/srv/platforms, /srv/stardust, Bee). This script installs
Nextcloud under /srv/apps and Collabora CODE with Podman.

Counterpart to owncloud-install.sh. Pick one files app per
localhost vhost; CODE container names differ so both can
coexist on 9980 only if you change a port.

  ./nextcloud-install.sh              # full localhost stack
  ./nextcloud-install.sh -n           # dry run
  ./nextcloud-install.sh --office-only
  ./nextcloud-install.sh -H 192.168.1.120

Layout
------
  /srv/apps/nextcloud           DocumentRoot + Alias /nextcloud
  /srv/apps/nextcloud-data      data (denied in Apache)
  /srv/apps/nextcloud-secrets   generated passwords (0640)
  http://127.0.0.1/nextcloud
  127.0.0.1:9980                CODE (container collabora-nextcloud)

PHP line
--------
  PHP >= 8.1 required (8.3 recommended for current Nextcloud).
  PHP 8.0 and below is rejected.

What Stardust behaviour means here
----------------------------------
  POSIX sh, set -eu, -n dry run, idempotent.
  Run as root; do not wrap the whole file in sudo.
  Detects sysvinit (service / update-rc.d). Reuses Apache +
  PHP + MariaDB if Stardust already put them there.
  Secrets persist under 0640 and are reused on re-run.
  Drop-ins (PHP/MariaDB/vhost/cron/init) are rewritten each
  run; Nextcloud core and data are left alone if present.
  No GitHub/GitLab CLI, no certbot, no compiling Imagick,
  no catch-all public vhost, no 0.0.0.0:9980.

Speed / security applied
------------------------
  MariaDB  READ-COMMITTED, ROW binlog, utf8mb4_bin, 512M buffer
  PHP      512M memory/upload, output_buffering Off, OPcache+JIT,
           APCu 128M, apc.enable_cli=1 (required for occ/cron)
  Redis    unix socket 0770, www-data in redis group
  Apache   KeepAlive 3/200, HostnameLookups Off, Dav off,
           security headers, data dir denied, CODE proxy
  Nextcloud
           APCu local + Redis distributed/locking
           cron every 5 minutes (not AJAX)
           default_phone_region, maintenance_window_start
           trash/versions 30 days, brute-force on
           allow_local_remote_servers (CODE on 127.0.0.1)
           firstrunwizard / survey / announcements off
           built-in richdocumentscode off (external CODE)
           upgrade.disable-web, stable channel
  Data     outside the web root
  Bind     vhost on 127.0.0.1 only

LibreOffice Online
------------------
  Product is Collabora CODE (collabora/code OCI image).
  Nextcloud app: richdocuments (Nextcloud Office).

  wopi_url / public_wopi_url  http://HOST:9980
  wopi_allowlist              127.0.0.1, ::1, LAN, WireGuard
  aliasgroup1                 http://HOST|localhost|127.0.0.1
  extra_params                ssl.enable=false (localhost HTTP)
  dictionaries                en_US en_GB
  doc_format                  odf
  canonical_webroot           /nextcloud

Podman instead of Docker
------------------------
  Yes. Same image. This script uses rootful Podman:

    --network host     so CODE can WOPI-callback to
                       http://127.0.0.1/nextcloud
                       (container-localhost is otherwise itself)
    --cap-add MKNOD    CODE jail still wants this on many tags
    extra_params       ssl.enable=false for localhost
    aliasgroup1        127.0.0.1|localhost|HOST

  Init: /etc/init.d/collabora-nextcloud
        service collabora-nextcloud start|stop|status

  Container name is collabora-nextcloud so it does not clobber
  ownCloud's collabora-code. Port 9980 is still shared — do
  not run both CODE units at once without changing CODE_PORT.

After install
-------------
  Login: admin / password in /srv/apps/nextcloud-secrets/admin.pass
  Open a .odt in the web UI to test CODE.
  To publish later: TLS vhost, trusted_domains, aliasgroup1,
  overwriteprotocol=https, and drop --network host only if you
  add extra_hosts so CODE can still reach Nextcloud.

Do not
------
  stardust site-add nextcloud
  put data under /srv/platforms
  expose 9980 on 0.0.0.0
  point wopi_url at the Apache proxy path and the container
  port at the same time without checking /hosting/discovery
