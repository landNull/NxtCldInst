# Contributing

This is a small script repo. One change per branch, one pull request.

## GitHub Flow (what most people do)

```sh
git checkout main
git pull
git checkout -b feature/short-name
# edit, then:
git add -p
git commit -m "Imperative summary of the change"
git push -u origin feature/short-name
```

Open a pull request: **feature/short-name → main**.

If this project is using git-flow instead, target **develop**, not `main`. `main` stays what you would run on a server.

## Commit messages

```
Fix sha256 verify to use the latest.tar.bz2 line only

Nextcloud's sidecar also lists latest.metadata. Taking every first
field made sha256sum check the metadata hash against the tarball.
```

- First line: imperative, ~50–72 characters, no trailing period
- Blank line, then why (not what — the diff is what)

## Checks before you push

```sh
sh -n nextcloud-install.sh
./nextcloud-install.sh -n
```

Do not commit tarballs, `/tmp` unpack trees, or anything from `/srv/apps/nextcloud-secrets`.
