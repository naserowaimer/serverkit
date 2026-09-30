#!/usr/bin/env bash
# ==============================================================================
#  tests/distro/run.sh — run serverkit in fresh containers of many distros.
#
#    tests/distro/run.sh                 quick phase on every image, in parallel
#    PHASE=full tests/distro/run.sh ubuntu:24.04 fedora:latest
#
#  Containers are unprivileged and disposable (--rm). They have no systemd, so
#  service items are configured but not started there; CI runs the systemd
#  tests on throwaway VMs.
# ==============================================================================
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PHASE=${PHASE:-quick}
JOBS=${JOBS:-6}
IMAGES=("$@")
if [[ ${#IMAGES[@]} -eq 0 ]]; then
  IMAGES=(ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:12 debian:13
    fedora:latest rockylinux/rockylinux:9 almalinux:10 amazonlinux:2023
    archlinux:latest manjarolinux/base:latest opensuse/leap:15.6 opensuse/tumbleweed:latest)
fi
OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT"
echo "logs: $OUT"

one() {
  local img=$1 log
  log="$OUT/$(echo "$img" | tr '/:' '__').log"
  if docker run --rm --pull=missing -e PHASE="$PHASE" -e ITEMS="${ITEMS:-}" -v "$ROOT:/sk:ro" "$img" \
    sh /sk/tests/distro/in-container.sh >"$log" 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$img"
  else
    printf '  \033[31m✗\033[0m %s  (%s)\n' "$img" "$log"
    return 1
  fi
}
export -f one
export OUT PHASE ROOT ITEMS
printf '%s\n' "${IMAGES[@]}" | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {}
