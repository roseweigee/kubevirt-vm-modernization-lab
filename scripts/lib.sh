#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/manifests"
NS=vm-lab
PASS=0

say()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

# body <client-deployment>  – GET http://legacy-app/ from that client; prints body, or "" if unreachable
body() {
  kubectl exec -n "$NS" "deploy/$1" -c curl -- \
    curl -s -m 5 "http://legacy-app.$NS.svc.cluster.local/" 2>/dev/null || true
}

# expect_body <client> <substring> <description>   (retries up to ~3 min)
expect_body() {
  local client=$1 want=$2 desc=$3 got=""
  for _ in $(seq 1 60); do
    got="$(body "$client")"
    [[ "$got" == *"$want"* ]] && { ok "$desc → \"$(echo "$got" | tr -d '\n')\""; return 0; }
    sleep 3
  done
  fail "$desc → expected \"$want\", got \"$got\""
}

# expect_blocked <client> <description>   (retries until the request fails)
expect_blocked() {
  local client=$1 desc=$2 got=""
  for _ in $(seq 1 30); do
    got="$(body "$client")"
    [[ -z "$got" ]] && { ok "$desc → no response (blocked)"; return 0; }
    sleep 3
  done
  fail "$desc → still answered: \"$got\""
}

boot_no() { body frontend | sed -n 's/.*boot #\([0-9]*\).*/\1/p'; }
