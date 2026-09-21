# NxtCldInst

POSIX installer for a **localhost** Nextcloud + Collabora CODE stack.

**The installer is still in development.** It is not on `main`.

| Want | Branch |
| --- | --- |
| Something you would run on a server | `main` — empty of the script until it works |
| Current work | [`devel`](https://github.com/landNull/NxtCldInst/tree/devel) |
| Latest Grok edits | [`feature/grok-branch`](https://github.com/landNull/NxtCldInst/tree/feature/grok-branch) |

```sh
git clone -b devel https://github.com/landNull/NxtCldInst.git
# or, without switching the default:
git clone https://github.com/landNull/NxtCldInst.git
cd NxtCldInst
git checkout devel
```

Raw file while it stays unstable:

https://raw.githubusercontent.com/landNull/NxtCldInst/devel/nextcloud-install.sh

## Why `main` has no script

Typical git-flow:

```
feature/grok-branch ──merge──► devel ──(when stable)──► main
```

- `main` — default branch, what GitHub shows first. Treat it as releasable.
- `devel` — integration. Broken or half-finished work is allowed here.
- `feature/…` — one topic at a time.

Putting a half-working installer on `main` is how people wget a bad copy. Deleting the file from `main` (this commit) does **not** remove it from git history or from `devel`.

When it actually works, merge `devel` into `main`. If git keeps the deletion (delete vs unchanged file), restore it explicitly:

```sh
git checkout main
git merge devel
git checkout devel -- nextcloud-install.sh
git commit -m "Release nextcloud-install.sh onto main"
```

## Not in this repo

Stardust, ownCloud, public TLS, Docker. CODE is Collabora via **Podman**.

## License

MIT. See [LICENSE](LICENSE).
