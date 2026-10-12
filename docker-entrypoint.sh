#!/bin/sh
#
# nginx-git-static :: zero-downtime static deployment from a git branch
# ---------------------------------------------------------------------
# Keeps a lightweight, single-branch view of a repository in sync and serves it
# with nginx. Nothing is ever served from the git state itself: every successful
# pull is extracted into an immutable release directory, then published by
# atomically renaming the "current" symlink (rename(2) is atomic, so a request
# sees either the old release or the new one -- never a half-written tree).
#
# Light by design:
#   * bare object store (no working copy at all)
#   * --depth=1, one branch, no tags; the branch head is kept as a single
#     remote-tracking ref (the gc root, and what makes later fetches incremental)
#   * objects unreachable from the freshly deployed commit are pruned each cycle
#
# Environment:
#   REPOSITORY       (required) e.g. git@github.com:Feavy/CloudDesktop.git
#   SSH_PRIVATE_KEY  (optional) deploy key for ssh remotes
#   BRANCH           (default: main)
#   PULL_INTERVAL    (default: 30s) accepts 30, 30s, 5m, 1h
#   WORK_DIR         (default: /var/www/repo)     bare git state, never served
#   RELEASES_DIR     (default: /var/www/releases) immutable releases
#   CURRENT_LINK     (default: /var/www/current)  atomically swapped symlink
#   BOOTSTRAP_DIR    (default: /var/www/bootstrap) page served until 1st deploy
#   KEEP_RELEASES    (default: 3)                 old releases kept on disk
#   GIT_DEPTH        (default: 1)
#   SSH_KEY_PATH     (default: $HOME/.ssh/id_deploy)
#   SSH_KEYS_SCAN    (default: 1) set 0 to skip ssh-keyscan
#   MAX_FAILURES_BEFORE_RESET (default: 5) rebuild the git state after N failures
#   DEPLOY_ONCE      if set to 1, run one cycle and exit (no nginx) -- for tests
#
set -eu

umask 022

log()  { printf '%s [deploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { log "WARN: $*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- environment

REPOSITORY="${REPOSITORY:-}"
PULL_INTERVAL="${PULL_INTERVAL:-30s}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-/var/www/repo}"
RELEASES_DIR="${RELEASES_DIR:-/var/www/releases}"
CURRENT_LINK="${CURRENT_LINK:-/var/www/current}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/var/www/bootstrap}"
BOOTSTRAP_SRC="${BOOTSTRAP_SRC:-/usr/share/webhost/bootstrap}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"
GIT_DEPTH="${GIT_DEPTH:-1}"
MAX_FAILURES_BEFORE_RESET="${MAX_FAILURES_BEFORE_RESET:-5}"
HOME="${HOME:-/root}"
export HOME
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_deploy}"

strip_trailing_slash() {
  _v="$1"
  while [ "$_v" != "/" ] && [ "${_v%/}" != "$_v" ]; do _v="${_v%/}"; done
  printf '%s' "$_v"
}

require_abs_path() {
  [ -n "$1" ] || die "$2 must not be empty"
  case "$1" in
    /*) ;;
    *) die "$2 must be an absolute path (got '$1')" ;;
  esac
  [ "$1" != "/" ] || die "$2 must not be the filesystem root"
}

WORK_DIR="$(strip_trailing_slash "$WORK_DIR")"
RELEASES_DIR="$(strip_trailing_slash "$RELEASES_DIR")"
CURRENT_LINK="$(strip_trailing_slash "$CURRENT_LINK")"
BOOTSTRAP_DIR="$(strip_trailing_slash "$BOOTSTRAP_DIR")"

require_abs_path "$WORK_DIR" WORK_DIR
require_abs_path "$RELEASES_DIR" RELEASES_DIR
require_abs_path "$CURRENT_LINK" CURRENT_LINK
require_abs_path "$BOOTSTRAP_DIR" BOOTSTRAP_DIR
[ -n "$REPOSITORY" ] || die "REPOSITORY is required, e.g. -e REPOSITORY=git@github.com:Feavy/CloudDesktop.git"

# The branch is always watched through one deterministic remote-tracking ref:
# it is what keeps the deployed objects alive against `git gc` and what lets a
# later fetch negotiate incrementally instead of re-downloading the whole tree.
BRANCH="${BRANCH#refs/heads/}"
[ -n "$BRANCH" ] || die "BRANCH must not be empty"
TRACK_REF="refs/remotes/origin/$BRANCH"

parse_interval() {
  _raw="$1"
  _mult=1
  _num="$_raw"
  case "$_raw" in
    *[sS]) _num="${_raw%?}" ;;
    *[mM]) _num="${_raw%?}"; _mult=60 ;;
    *[hH]) _num="${_raw%?}"; _mult=3600 ;;
  esac
  case "$_num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$_num" -ge 1 ] || return 1
  printf '%s' $((_num * _mult))
}

if SLEEP_SECONDS="$(parse_interval "$PULL_INTERVAL")"; then
  :
else
  warn "invalid PULL_INTERVAL '$PULL_INTERVAL', falling back to 30s"
  SLEEP_SECONDS=30
fi

case "$KEEP_RELEASES" in
  ''|*[!0-9]*) warn "invalid KEEP_RELEASES '$KEEP_RELEASES', falling back to 3"; KEEP_RELEASES=3 ;;
esac
[ "$KEEP_RELEASES" -ge 1 ] || KEEP_RELEASES=1

case "$GIT_DEPTH" in
  ''|*[!0-9]*) GIT_DEPTH=1 ;;
esac
[ "$GIT_DEPTH" -ge 1 ] || GIT_DEPTH=1

# ------------------------------------------------------------------ git setup

remote_host() {
  case "$REPOSITORY" in
    ssh://*)
      _rest="${REPOSITORY#ssh://}"
      _rest="${_rest%%/*}"
      _rest="${_rest##*@}"
      printf '%s' "${_rest%%:*}"
      ;;
    *://*) return 0 ;;
    *:*)
      _rest="${REPOSITORY%%:*}"
      printf '%s' "${_rest##*@}"
      ;;
    *) return 0 ;;
  esac
}

setup_git() {
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/true
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  # The state directory may be a mounted volume owned by another uid.
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$WORK_DIR"; then
    git config --global --add safe.directory "$WORK_DIR" 2>/dev/null || true
  fi
}

setup_ssh() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  : >> "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"

  if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
    log "installing the deploy key into $SSH_KEY_PATH"
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    # Accept keys pasted either with real newlines or with literal \n escapes
    # (printf %b is POSIX and understood identically by busybox ash).
    printf '%b' "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
    if [ -n "$(tail -c 1 "$SSH_KEY_PATH" 2>/dev/null || true)" ]; then
      printf '\n' >> "$SSH_KEY_PATH"
    fi
    chmod 600 "$SSH_KEY_PATH"
  elif [ -f "$SSH_KEY_PATH" ]; then
    log "using the deploy key already present at $SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH" 2>/dev/null \
      || warn "could not tighten permissions on $SSH_KEY_PATH (mount it with mode 0600)"
  else
    log "no SSH deploy key: assuming the repository is public or reachable anonymously"
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    return 0
  fi

  export GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  _host="$(remote_host)"
  if [ -n "$_host" ] && [ "${SSH_KEYS_SCAN:-1}" = "1" ]; then
    ssh-keyscan -T 5 "$_host" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
      || warn "ssh-keyscan '$_host' failed, relying on accept-new"
  fi
}

# ------------------------------------------------------------ deploy pipeline

reset_workdir() {
  log "initializing a bare, single-branch state ($REPOSITORY, branch $BRANCH, depth $GIT_DEPTH)"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -C "$WORK_DIR" init --quiet --bare
  git -C "$WORK_DIR" remote add origin "$REPOSITORY"
}

fetch_remote() {
  [ -d "$WORK_DIR" ] || reset_workdir
  if ! git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    reset_workdir
  fi
  # A persisted WORK_DIR may hold an older remote: keep it in sync.
  _origin="$(git -C "$WORK_DIR" remote get-url origin 2>/dev/null || true)"
  if [ "$_origin" != "$REPOSITORY" ]; then
    if [ -z "$_origin" ]; then
      git -C "$WORK_DIR" remote add origin "$REPOSITORY"
    else
      log "origin changed, updating it to $REPOSITORY"
      git -C "$WORK_DIR" remote set-url origin "$REPOSITORY"
    fi
  fi
  git -C "$WORK_DIR" fetch --quiet --depth="$GIT_DEPTH" --no-tags --prune \
    origin "+refs/heads/$BRANCH:$TRACK_REF"
}

# Publish by renaming a fresh symlink over the current one: atomic, no reload.
publish() {
  _target="$1"
  _tmp_link="${CURRENT_LINK}.swap.$$"
  rm -f "$_tmp_link"
  ln -s "$_target" "$_tmp_link"
  if mv -T "$_tmp_link" "$CURRENT_LINK" 2>/dev/null; then
    return 0
  fi
  # Fallback when GNU mv is unavailable (busybox mv has no -T).
  if [ -L "$CURRENT_LINK" ] || [ ! -e "$CURRENT_LINK" ]; then
    rm -f "$CURRENT_LINK"
    ln -s "$_target" "$CURRENT_LINK"
    return 0
  fi
  rm -f "$_tmp_link"
  die "$CURRENT_LINK exists and is not a symlink; remove it or set CURRENT_LINK"
}

prune_releases() {
  _current="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
  _kept=0
  for _dir in $(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null || true); do
    _dir="${_dir%/}"
    _kept=$((_kept + 1))
    if [ "$_kept" -gt "$KEEP_RELEASES" ] && [ "$_dir" != "$_current" ]; then
      log "pruning old release ${_dir##*/}"
      rm -rf "$_dir"
    fi
  done
}

# Drop objects that are no longer needed, keeping the state at ~one tree.
compact_repo() {
  git -C "$WORK_DIR" reflog expire --expire=now --all >/dev/null 2>&1 || true
  git -C "$WORK_DIR" gc --prune=now --quiet >/dev/null 2>&1 || true
}

# 0 = deployed, 2 = already up to date, 1 = failure
deploy_once() {
  fetch_remote || return 1

  _sha="$(git -C "$WORK_DIR" rev-parse --verify --quiet "$TRACK_REF")" \
    || { warn "could not resolve $TRACK_REF after fetching branch '$BRANCH'"; return 1; }

  _release="$RELEASES_DIR/$_sha"
  if [ "$(readlink "$CURRENT_LINK" 2>/dev/null || true)" = "$_release" ]; then
    return 2
  fi

  mkdir -p "$RELEASES_DIR"
  if [ ! -d "$_release" ]; then
    _staging="$RELEASES_DIR/.staging.$$"
    _archive="$RELEASES_DIR/.staging.$$.tar"
    rm -rf "$_staging"
    mkdir -p "$_staging"
    if ! git -C "$WORK_DIR" archive --format=tar -o "$_archive" "$_sha"; then
      warn "failed to archive $_sha"
      rm -rf "$_staging" "$_archive"
      return 1
    fi
    if ! tar -xf "$_archive" -C "$_staging"; then
      warn "failed to extract $_sha"
      rm -rf "$_staging" "$_archive"
      return 1
    fi
    rm -f "$_archive"
    chmod -R a+rX "$_staging"
    mv "$_staging" "$_release"
  fi

  publish "$_release"

  _short="$(printf '%s' "$_sha" | cut -c1-10)"
  log "deployed $BRANCH@$_short -> $_release"
  prune_releases
  compact_repo
  return 0
}

prepare_bootstrap() {
  mkdir -p "$RELEASES_DIR"
  if [ -L "$CURRENT_LINK" ]; then
    return 0
  fi
  [ ! -e "$CURRENT_LINK" ] || die "$CURRENT_LINK exists and is not a symlink"
  log "serving the bootstrap page until the first release is published"
  mkdir -p "$BOOTSTRAP_DIR"
  if [ -f "$BOOTSTRAP_SRC/index.html" ]; then
    cp "$BOOTSTRAP_SRC/index.html" "$BOOTSTRAP_DIR/index.html"
    chmod 0644 "$BOOTSTRAP_DIR/index.html"
  fi
  ln -s "$BOOTSTRAP_DIR" "$CURRENT_LINK"
}

run_loop() {
  _failures=0
  while :; do
    if deploy_once; then
      _failures=0
    else
      _rc=$?
      if [ "$_rc" -eq 2 ]; then
        _failures=0
      else
        _failures=$((_failures + 1))
        warn "deploy cycle failed ($_failures in a row), retrying in ${SLEEP_SECONDS}s"
        if [ "$_failures" -ge "$MAX_FAILURES_BEFORE_RESET" ]; then
          warn "resetting the local git state at $WORK_DIR"
          rm -rf "$WORK_DIR"
          _failures=0
        fi
      fi
    fi
    sleep "$SLEEP_SECONDS"
  done
}

main() {
  setup_git
  setup_ssh
  prepare_bootstrap

  if [ "${DEPLOY_ONCE:-0}" = "1" ]; then
    log "DEPLOY_ONCE=1: running a single deploy cycle"
    if deploy_once; then
      exit 0
    else
      _rc=$?
    fi
    if [ "$_rc" -eq 2 ]; then
      log "already up to date"
      exit 0
    fi
    exit 1
  fi

  log "watching $REPOSITORY branch '$BRANCH' every ${SLEEP_SECONDS}s"
  run_loop &

  nginx -t
  log "starting nginx on port 8080 (serving $CURRENT_LINK)"
  exec nginx -g 'daemon off;'
}

main "$@"
