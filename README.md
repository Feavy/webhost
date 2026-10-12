# nginx-git-static

An nginx image that continuously deploys a static site from one branch of a git
repository. It polls the branch, extracts every new commit into an immutable
release directory, and atomically swaps the directory nginx is serving — so
updates go live on **port 8080** with no downtime and no nginx reload.

## How it works

```
        poll every PULL_INTERVAL                          atomic rename
  git ────────────────────────▶ bare state ──▶ releases/<sha> ──▶ /var/www/current
  (depth=1, one branch)          (no worktree)    (immutable)        (symlink, served)
```

* **Light**: the local git state is a *bare* object store — no working copy, no
  full history. It fetches `--depth=1 --no-tags` from a single branch, and each
  successful deploy prunes objects that are no longer reachable, so the state
  stays at roughly "one tree" instead of growing with every commit.
* **No downtime**: a commit is extracted into `releases/<sha>` first, then
  `/var/www/current` is repointed with `rename(2)` (`mv -T`), which is atomic.
  A request sees either the complete old release or the complete new one, never
  a partial tree. nginx resolves the symlink per request, so no reload is needed
  and in-flight requests keep reading the previous release, which is kept on disk.
* **Never wedged**: nginx starts immediately (with a bootstrap page) while the
  first fetch happens in the background; failed fetches are retried, and after
  five consecutive failures the local git state is rebuilt from scratch.

## Quick start

```sh
docker build -t nginx-git-static .

docker run -d --name site -p 8080:8080 \
  -e REPOSITORY=git@github.com:Feavy/CloudDesktop.git \
  -e BRANCH=main \
  -e PULL_INTERVAL=30s \
  -e SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
  nginx-git-static

curl -sS localhost:8080 | head
```

Or with Compose:

```sh
REPOSITORY=git@github.com:Feavy/CloudDesktop.git \
BRANCH=main \
SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
docker compose up --build
```

## Published image

`.github/workflows/docker-publish.yml` builds this image and pushes it to the
project's GitHub Container Registry namespace, `ghcr.io/feavy/webhost`. It
authenticates with the workflow's own `GITHUB_TOKEN` (`packages: write`), so no
extra secrets are required.

| Event | Result |
| --- | --- |
| Push to `main` | Build (amd64 + arm64) and push, tagged `main`, `latest`, `sha-<commit>` |
| Push of a `v*` tag | Push, tagged `v1.2.3`, `1.2.3`, `1.2`, `latest`, `sha-<commit>` |
| Pull request | Build only — never logs in or pushes |
| Manual dispatch | Same as a push to the selected ref |

The Docker-free smoke test (`test/smoke.sh`) runs first and gates the publish.

```sh
docker pull ghcr.io/feavy/webhost:latest

docker run -d -p 8080:8080 \
  -e REPOSITORY=git@github.com:Feavy/CloudDesktop.git \
  -e SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
  ghcr.io/feavy/webhost:latest
```

Packages pushed with `GITHUB_TOKEN` start out **private**. To allow anonymous
pulls, set the package to public under the repository's Packages → *webhost* →
Package settings → Danger zone → Change visibility. On a private package, pull
with a token that has `read:packages`:

```sh
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

The repository variable `NGINX_IMAGE` can override the base image without
editing the workflow; it defaults to `nginx:stable-alpine`.

If a push is rejected with `403 Forbidden`, check Settings → Actions → General →
Workflow permissions: the workflow already requests `packages: write`, but an
organization-level policy can restrict whether a workflow may request it.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `REPOSITORY` | *(required)* | Repository to pull, e.g. `git@github.com:Feavy/CloudDesktop.git` |
| `BRANCH` | `main` | Branch to watch and serve |
| `PULL_INTERVAL` | `30s` | Poll period: `30`, `30s`, `5m`, `1h` |
| `SSH_PRIVATE_KEY` | – | Deploy key for private/SSH remotes |
| `WORK_DIR` | `/var/www/repo` | Bare git state (never served) |
| `RELEASES_DIR` | `/var/www/releases` | Immutable release directories |
| `CURRENT_LINK` | `/var/www/current` | Symlink nginx serves from |
| `BOOTSTRAP_DIR` | `/var/www/bootstrap` | Page served until the first release |
| `SPA` | `0` | `1` serves `index.html` for paths that match no file (client-side routing) |
| `ROUTING_CONF` | `/etc/nginx/webhost/routing.conf` | `try_files` snippet included by `location /`; rewritten from `SPA` at startup |
| `KEEP_RELEASES` | `3` | Releases kept on disk (newest first) |
| `GIT_DEPTH` | `1` | Fetch depth |
| `SSH_KEY_PATH` | `$HOME/.ssh/id_deploy` | Where `SSH_PRIVATE_KEY` is written / read from |
| `MAX_FAILURES_BEFORE_RESET` | `5` | Consecutive failures before rebuilding the git state |
| `SSH_KEYS_SCAN` | `1` | Set to `0` to skip `ssh-keyscan` of the remote host |
| `DEPLOY_ONCE` | – | `1` runs a single deploy cycle and exits (used by tests) |

## Credentials

**SSH deploy key (recommended).** Generate a passphrase-less key and register its
public half as a *read-only deploy key* on the repository
(Settings → Deploy keys → Add deploy key, leave "Allow write access" off):

```sh
ssh-keygen -t ed25519 -C "deploy@webhost" -f ./deploy_key -N ""
# add ./deploy_key.pub to the repository, then either:

docker run -d -p 8080:8080 \
  -e REPOSITORY=git@github.com:Feavy/CloudDesktop.git \
  -e SSH_PRIVATE_KEY="$(cat ./deploy_key)" \
  nginx-git-static

# ... or mount it (must be mode 0600 on the host):
chmod 600 ./deploy_key
docker run -d -p 8080:8080 \
  -v "$PWD/deploy_key:/root/.ssh/id_deploy:ro" \
  -e REPOSITORY=git@github.com:Feavy/CloudDesktop.git \
  nginx-git-static
```

A key supplied in `SSH_PRIVATE_KEY` may contain real newlines or literal `\n`
escapes. It must not have a passphrase (the pull runs non-interactively).

**Public or token-based HTTPS** needs no key at all:

```sh
-e REPOSITORY=https://github.com/Feavy/CloudDesktop.git
-e REPOSITORY=https://x-access-token:<token>@github.com/owner/private.git
```

## Operations

* **Port**: `8080`. **Health**: `GET /healthz` → `200 ok` (used by `HEALTHCHECK`).
* **Logs**: `docker logs -f site` prints one line per deploy and per failure.
* **Persistence** (optional): mount `-v webhost-state:/var/www` to keep the git
  state and old releases across container recreation; otherwise everything is
  fetched again on start.
* **Changing `REPOSITORY` or `BRANCH`** takes effect on restart; the stored
  remote URL is reconciled automatically.

## Verifying

`test/smoke.sh` drives the real entrypoint (`DEPLOY_ONCE=1`) against throwaway
local repositories using only git and a POSIX shell — no Docker needed:

```sh
sh test/smoke.sh
```

It covers: depth-1/bare state, subdirectory extraction, absence of git metadata
in the served tree, publish + prune of releases, atomic swaps while 60 reads run
against three commits landing underneath, `PULL_INTERVAL` parsing, rejection of a
missing `REPOSITORY`, failure on an unreachable remote, remote URL changes, SPA
routing snippet generation (including invalid boolean values), and SSH key
installation from both the environment and a mount.

## Notes and limits

* **Static files only** — the branch must already contain the built site. Build in
  CI and push the output to a branch (for example `gh-pages`) if you need a build
  step; this image deliberately has no toolchain.
* **Polling, not webhooks** — propagation is bounded by `PULL_INTERVAL`.
* **SPA routing** — with `SPA=1`, a path that matches no file serves
  `index.html` (HTTP 200), so deep links into a client-side router work:

  ```sh
  docker run -d -p 8080:8080 -e SPA=1 ... nginx-git-static
  ```

  A missing *asset* (a path ending in `.css`, `.js`, `.png`, …) still returns
  `404`, so a stale bundle reference does not silently hide behind the shell.
  The fallback is compiled into `ROUTING_CONF` at startup; to customise routing
  further, mount your own config over `/etc/nginx/conf.d/default.conf`:

  ```sh
  docker run -d -p 8080:8080 \
    -v "$PWD/spa.conf:/etc/nginx/conf.d/default.conf:ro" ... nginx-git-static
  ```

  ```nginx
  location / { try_files $uri $uri/ /index.html; }
  ```

* **Caching** — `index.html` is sent `no-cache`, other assets `1h`. Assets are
  not assumed to be content-hashed, so a deploy becomes visible quickly.
* **Base image** — `nginx:stable-alpine`, overridable at build time with
  `--build-arg NGINX_IMAGE=nginx:1.27-alpine`.
