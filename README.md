# NxtCldInst

POSIX installer for a **localhost** Nextcloud + Collabora CODE stack.

Written to behave like a Stardust installer: `#!/bin/sh`, `set -eu`, `-n` dry-run, idempotent, sysvinit-friendly. It is **not** a Stardust site. Do not drop it under `/srv/platforms` or `/srv/stardust`.

- Script: [`nextcloud-install.sh`](nextcloud-install.sh)
- Notes: [`NOTES.md`](NOTES.md)
- Git map: this README, section [Branches](#branches)

Target: Devuan (sysvinit) or Debian/Ubuntu (systemd). Reuses Apache, PHP, and MariaDB if they are already installed.

## Quick start

On the server, as **root** (do not wrap the whole file in `sudo`):

```sh
wget -O nextcloud-install.sh \
  https://raw.githubusercontent.com/landNull/NxtCldInst/devel/nextcloud-install.sh
chmod 0755 nextcloud-install.sh
./nextcloud-install.sh -n          # dry run: print what would happen
./nextcloud-install.sh             # install
./nextcloud-install.sh --office-only
```

Login: `admin` / password in `/srv/apps/nextcloud-secrets/admin.pass`  
URL: `http://127.0.0.1/nextcloud`

```
./nextcloud-install.sh -h
./nextcloud-install.sh -H 192.168.1.120
```

## Layout

| Path | Role |
| --- | --- |
| `/srv/apps/nextcloud` | code (DocumentRoot / Alias `/nextcloud`) |
| `/srv/apps/nextcloud-data` | data directory, not web-reachable |
| `/srv/apps/nextcloud-secrets` | generated passwords (`0640`) |
| `http://127.0.0.1/nextcloud` | Apache vhost, localhost only |
| `127.0.0.1:9980` | Collabora CODE via Podman `--network host` |

Do not `a2ensite` this next to `owncloud-localhost.conf` without merging vhosts. Both claim `127.0.0.1:80`. Do not run this CODE unit and ownCloud's `collabora-code` on port 9980 at the same time.

## Branches

This repo uses the two long-lived names you will see on most projects, plus short-lived feature branches.

| Branch | What it is | When to use it |
| --- | --- | --- |
| `main` | Default. Empty of the installer until it is stable. | Do not wget the script from here yet. |
| `devel` | Integration branch. Features merge here. | Daily work target. Easier to type than `develop`. |
| `feature/grok-branch` | Grok work branch. | Push edits here, then merge into `devel`. |
| `feature/…` | Short-lived. One change. | Daily work. Open a pull request into `devel`. |

**What most developers actually do (GitHub Flow):**

1. `git clone` the repo; `main` is what you start from.
2. `git checkout -b feature/short-name` for one change.
3. Commit locally. `git push -u origin feature/short-name`.
4. Open a **pull request** on GitHub: `feature/short-name` → `main`.
5. Review, merge, delete the feature branch.

This repo uses **`devel`** (not `develop`) as the integration branch. Merge features into `devel`. When the installer actually works, merge `devel` → `main`.

```
feature/grok-branch ──merge──► devel ──PR──► main
feature/…            ──merge──► devel ──┘
```

Or the simpler path most GitHub projects use:

```
feature/fix-checksum ──PR──► main
```

## Local git (the usual loop)

```sh
git clone https://github.com/landNull/NxtCldInst.git
cd NxtCldInst
git checkout devel
git pull

git checkout -b feature/my-change
# edit nextcloud-install.sh
git add nextcloud-install.sh
git status
git diff --staged
git commit -m "Fix occ quoting so APCu class names survive su -c"
git push -u origin feature/my-change
```

Then on GitHub: **Compare & pull request**. After it merges:

```sh
git checkout devel
git pull
git branch -d feature/my-change
```

`origin` is just a nickname for the GitHub URL. `main` is a branch (a moving pointer to a commit). A pull request is a GitHub page that says “please take these commits from my branch onto that branch.”

## Not in this repo

Stardust, ownCloud, public TLS, Docker, compiling Imagick. CODE is the Collabora image run with **Podman**.

## License

MIT. See [LICENSE](LICENSE).
