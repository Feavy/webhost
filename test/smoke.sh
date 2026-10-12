#!/bin/sh
#
# Smoke test for docker-entrypoint.sh.
#
# Runs the real deploy engine with DEPLOY_ONCE=1 against a throwaway local
# repository (file:// remote), so it needs only git and a POSIX sh -- no Docker.
#
#   sh test/smoke.sh
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT/docker-entrypoint.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nginx-git-static.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
is() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi
}
section() { printf '\n== %s\n' "$1"; }

# Keep git config (and ssh material) inside the sandbox.
HOME="$WORK/home"
export HOME
mkdir -p "$HOME"

SRC="$WORK/origin.git"
SEED="$WORK/seed"
STATE="$WORK/state"

git init --quiet --bare "$SRC"
git init --quiet "$SEED"
git -C "$SEED" config user.email "test@example.com"
git -C "$SEED" config user.name "Smoke Test"
git -C "$SEED" checkout --quiet -b main
git -C "$SEED" remote add origin "$SRC"
mkdir -p "$SEED/assets"
printf 'body { margin: 0 }\n' > "$SEED/assets/app.css"

commit() {
  printf '%s\n' "$1" > "$SEED/index.html"
  git -C "$SEED" add -A
  git -C "$SEED" commit --quiet -m "$1"
  git -C "$SEED" push --quiet origin main
}

# Three commits of history: a depth-1 deploy must keep only the last one.
commit v1
commit v2
commit v3

run_deploy() {
  env \
    REPOSITORY="file://$SRC" \
    BRANCH=main \
    DEPLOY_ONCE=1 \
    SSH_KEYS_SCAN=0 \
    PULL_INTERVAL=1s \
    WORK_DIR="$STATE/repo" \
    RELEASES_DIR="$STATE/releases" \
    CURRENT_LINK="$STATE/current" \
    BOOTSTRAP_DIR="$STATE/bootstrap" \
    BOOTSTRAP_SRC="$ROOT/bootstrap" \
    ROUTING_CONF="$STATE/routing.conf" \
    "$@" \
    sh "$ENTRYPOINT"
}

section "first deploy (shallow, bare, atomic)"
if run_deploy > "$WORK/log1" 2>&1; then
  ok "entrypoint exits 0"
else
  bad "entrypoint exits 0"
  cat "$WORK/log1"
fi

case "$(readlink "$STATE/current")" in
  "$STATE"/releases/*) ok "current symlink points into releases" ;;
  *) bad "current symlink points into releases" ;;
esac

is "served content is HEAD of the branch" "$(cat "$STATE/current/index.html")" "v3"
[ -f "$STATE/current/assets/app.css" ] && ok "subdirectories are deployed" || bad "subdirectories are deployed"
[ ! -e "$STATE/current/.git" ] && ok "no git metadata in the served tree" || bad "no git metadata in the served tree"
is "state is a bare repository" "$(git -C "$STATE/repo" rev-parse --is-bare-repository)" "true"
[ -f "$STATE/repo/shallow" ] && ok "state is shallow" || bad "state is shallow"
is "history limited to one commit" "$(git -C "$STATE/repo" rev-list --count refs/remotes/origin/main)" "1"
is "the watched branch is a ref (gc root)" "$(git -C "$STATE/repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null && echo yes || echo no)" "yes"
# gc runs on every deploy: the deployed tree must survive it.
git -C "$STATE/repo" cat-file -e "refs/remotes/origin/main^{tree}" 2>/dev/null && ok "the deployed tree survives gc" || bad "the deployed tree survives gc"
git -C "$STATE/repo" archive refs/remotes/origin/main > /dev/null 2>&1 && ok "the state can still archive the deployed commit" || bad "the state can still archive the deployed commit"
is "deployed files are world readable" "$(ls -l "$STATE/current/index.html" | cut -c1-10)" "-rw-r--r--"

leftover=0
for f in "$STATE/current.swap."*; do
  [ -e "$f" ] && leftover=1
done
is "no swap symlink left behind" "$leftover" "0"

# The bootstrap page must be readable by the nginx worker user, not just root.
[ -f "$STATE/bootstrap/index.html" ] && ok "the bootstrap page is installed" || bad "the bootstrap page is installed"
is "the bootstrap page is world readable" "$(ls -l "$STATE/bootstrap/index.html" | cut -c1-10)" "-rw-r--r--"

section "no change"
if run_deploy > "$WORK/log2" 2>&1; then
  ok "second run exits 0"
else
  bad "second run exits 0"
fi
is "no extra release created" "$(ls -1 "$STATE/releases" | wc -l | tr -d ' ')" "1"

section "new commit is picked up"
BEFORE="$(readlink "$STATE/current")"
commit v4
if run_deploy > "$WORK/log3" 2>&1; then
  ok "third run exits 0"
else
  bad "third run exits 0"
  cat "$WORK/log3"
fi
AFTER="$(readlink "$STATE/current")"
is "content updated" "$(cat "$STATE/current/index.html")" "v4"
[ "$BEFORE" != "$AFTER" ] && ok "a new release was published" || bad "a new release was published"
[ -d "$BEFORE" ] && ok "previous release kept on disk (safe for in-flight requests)" || bad "previous release kept on disk"
grep -q "deployed main@" "$WORK/log3" && ok "deploy is logged" || bad "deploy is logged"

section "old releases are pruned"
commit v5
run_deploy KEEP_RELEASES=1 > "$WORK/log4" 2>&1 || bad "pruning run exits 0"
is "only the newest release is kept" "$(ls -1d "$STATE"/releases/*/ | wc -l | tr -d ' ')" "1"
is "served content still correct" "$(cat "$STATE/current/index.html")" "v5"

section "watch loop keeps serving while releases are swapped"
STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/nginx" <<'STUB_EOF'
#!/bin/sh
case "${1:-}" in
  -t) echo "stub nginx: configuration ok"; exit 0 ;;
esac
echo "stub nginx: serving"
exec sleep 600
STUB_EOF
chmod +x "$STUB/nginx"

WATCH="$WORK/watch"
timeout --kill-after=2 30 env \
  REPOSITORY="file://$SRC" \
  BRANCH=main \
  SSH_KEYS_SCAN=0 \
  PULL_INTERVAL=1s \
  WORK_DIR="$WATCH/repo" \
  RELEASES_DIR="$WATCH/releases" \
  CURRENT_LINK="$WATCH/current" \
  BOOTSTRAP_DIR="$WATCH/bootstrap" \
  BOOTSTRAP_SRC="$ROOT/bootstrap" \
  ROUTING_CONF="$WATCH/routing.conf" \
  PATH="$STUB:$PATH" \
  sh "$ENTRYPOINT" > "$WORK/watch.log" 2>&1 &
WATCH_PID=$!

i=0
while [ "$i" -lt 40 ] && [ ! -f "$WATCH/current/index.html" ]; do
  i=$((i + 1))
  sleep 0.25
done
[ -f "$WATCH/current/index.html" ] && ok "the loop published a first release" || bad "the loop published a first release"
grep -q "starting nginx on port 8080" "$WORK/watch.log" && ok "nginx starts while the loop keeps pulling" || bad "nginx starts while the loop keeps pulling"

# Read through the served symlink while three commits land underneath it.
misses=0
i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  body="$(cat "$WATCH/current/index.html" 2>/dev/null || echo MISSING)"
  case "$body" in
    MISSING|"") misses=$((misses + 1)) ;;
  esac
  case "$i" in
    10) commit v6 ;;
    25) commit v7 ;;
    40) commit v8 ;;
  esac
  sleep 0.2
done

is "every read succeeded during the churn" "$misses" "0"
is "the loop converged on the newest commit" "$(cat "$WATCH/current/index.html")" "v8"

kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
COUNT_BEFORE="$(ls -1 "$WATCH/releases" | wc -l | tr -d ' ')"
sleep 3
is "the loop stops when the container stops" "$(ls -1 "$WATCH/releases" | wc -l | tr -d ' ')" "$COUNT_BEFORE"

section "validation"
OUT="$(run_deploy PULL_INTERVAL=bogus 2>&1 || true)"
printf '%s' "$OUT" | grep -q "falling back to 30s" && ok "bad PULL_INTERVAL falls back to 30s" || bad "bad PULL_INTERVAL falls back to 30s"

if REPOSITORY="" DEPLOY_ONCE=1 sh "$ENTRYPOINT" > "$WORK/log5" 2>&1; then
  bad "missing REPOSITORY is rejected"
else
  grep -q "REPOSITORY is required" "$WORK/log5" && ok "missing REPOSITORY is rejected" || bad "missing REPOSITORY error message"
fi

if run_deploy \
     REPOSITORY="file://$WORK/does-not-exist.git" \
     WORK_DIR="$WORK/bad/repo" \
     RELEASES_DIR="$WORK/bad/releases" \
     CURRENT_LINK="$WORK/bad/current" \
     BOOTSTRAP_DIR="$WORK/bad/bootstrap" \
     > "$WORK/log6" 2>&1; then
  bad "an unreachable remote is a failure"
else
  ok "an unreachable remote is a failure"
fi

section "spa routing"
# The default (SPA unset) must keep returning 404 for unknown paths.
grep -Fq 'try_files $uri $uri/ =404;' "$STATE/routing.conf" \
  && ok "the default routing snippet 404s unknown paths" || bad "the default routing snippet 404s unknown paths"
grep -Fq 'include /etc/nginx/webhost/routing.conf;' "$ROOT/nginx/default.conf" \
  && ok "default.conf includes the generated routing snippet" || bad "default.conf includes the generated routing snippet"

if run_deploy SPA=1 ROUTING_CONF="$STATE/spa/routing.conf" > "$WORK/log-spa1" 2>&1; then
  ok "a deploy with SPA=1 exits 0"
else
  bad "a deploy with SPA=1 exits 0"
  cat "$WORK/log-spa1"
fi
grep -Fq 'try_files $uri $uri/ /index.html;' "$STATE/spa/routing.conf" \
  && ok "SPA=1 falls back to /index.html" || bad "SPA=1 falls back to /index.html"
grep -q "SPA=1" "$WORK/log-spa1" && ok "the SPA fallback is logged" || bad "the SPA fallback is logged"

run_deploy SPA=0 ROUTING_CONF="$STATE/plain/routing.conf" > "$WORK/log-spa0" 2>&1 \
  || bad "a deploy with SPA=0 exits 0"
grep -Fq 'try_files $uri $uri/ =404;' "$STATE/plain/routing.conf" \
  && ok "SPA=0 keeps 404 for unknown paths" || bad "SPA=0 keeps 404 for unknown paths"

# Booleans are accepted in the usual spellings, case-insensitively.
for value in true TRUE Yes on; do
  run_deploy SPA="$value" ROUTING_CONF="$STATE/bool/routing.conf" > /dev/null 2>&1 || true
  grep -Fq '/index.html;' "$STATE/bool/routing.conf" \
    && ok "SPA=$value enables the fallback" || bad "SPA=$value enables the fallback"
done

if run_deploy SPA=maybe ROUTING_CONF="$STATE/bad/routing.conf" > "$WORK/log-spabad" 2>&1; then
  ok "an invalid SPA value is tolerated"
else
  bad "an invalid SPA value is tolerated"
fi
grep -q "invalid SPA" "$WORK/log-spabad" && ok "an invalid SPA value warns" || bad "an invalid SPA value warns"
grep -Fq 'try_files $uri $uri/ =404;' "$STATE/bad/routing.conf" \
  && ok "an invalid SPA value falls back to 404" || bad "an invalid SPA value falls back to 404"

section "changing REPOSITORY is honoured"
SRC2="$WORK/other.git"
SEED2="$WORK/seed2"
git init --quiet --bare "$SRC2"
git init --quiet "$SEED2"
git -C "$SEED2" config user.email "test@example.com"
git -C "$SEED2" config user.name "Smoke Test"
git -C "$SEED2" checkout --quiet -b main
printf 'other-project\n' > "$SEED2/index.html"
git -C "$SEED2" add -A
git -C "$SEED2" commit --quiet -m other
git -C "$SEED2" remote add origin "$SRC2"
git -C "$SEED2" push --quiet origin main

SWITCH_ENV="WORK_DIR=$WORK/switch/repo RELEASES_DIR=$WORK/switch/releases CURRENT_LINK=$WORK/switch/current BOOTSTRAP_DIR=$WORK/switch/bootstrap"
# shellcheck disable=SC2086
run_deploy REPOSITORY="file://$SRC2" $SWITCH_ENV > "$WORK/log8" 2>&1 || bad "deploy from a second repository exits 0"
is "content comes from the second repository" "$(cat "$WORK/switch/current/index.html")" "other-project"
# shellcheck disable=SC2086
run_deploy REPOSITORY="file://$SRC" $SWITCH_ENV > "$WORK/log9" 2>&1 || bad "switching back exits 0"
is "content follows the repository change" "$(cat "$WORK/switch/current/index.html")" "v8"

section "ssh deploy key handling"
run_deploy \
  SSH_PRIVATE_KEY='-----BEGIN OPENSSH PRIVATE KEY-----\nSAMPLEKEYBODY\n-----END OPENSSH PRIVATE KEY-----' \
  > "$WORK/log7" 2>&1 || bad "run with an ssh key exits 0"
KEY="$HOME/.ssh/id_deploy"
if [ -f "$KEY" ]; then
  ok "the key is installed under \$HOME/.ssh"
  is "literal \\n escapes are unfolded" "$(wc -l < "$KEY" | tr -d ' ')" "3"
  is "the key is not group/world readable" "$(ls -l "$KEY" | cut -c1-10)" "-rw-------"
  grep -q "^-----END OPENSSH PRIVATE KEY-----$" "$KEY" && ok "the key body is intact" || bad "the key body is intact"
else
  bad "the key is installed under \$HOME/.ssh"
fi

# A key supplied by a read-only mount instead of the environment.
OUT="$(run_deploy 2>&1 || true)"
printf '%s' "$OUT" | grep -q "using the deploy key already present at" && ok "a mounted key is picked up" || bad "a mounted key is picked up"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
