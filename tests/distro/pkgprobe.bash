# shellcheck shell=bash
# Checks, on a real distro, that every native package serverkit would install
# exists in its repositories: catalog pkg: specs and the packages each system
# item's code asks for (found by running the items in dry-run with pkg_install
# swapped for an availability check).
set -uo pipefail
SK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SK_VERSION=probe
for f in core platform pkg brew ui catalog main; do . "$SK_ROOT/lib/$f.sh"; done
for f in "$SK_ROOT"/modules/*.sh; do . "$f"; done
OPT_SET=()
init_context
settings_load
DRY_RUN=true
QUIET=true
RUN_DIR=$(mktemp -d)
# Force every code path: pretend to be a real machine with systemd.
IS_CONTAINER=false IS_VM=false HAS_SYSTEMD=true
# From vendor repositories that a dry run doesn't add; real runs cover them.
VENDOR=" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin cloudflared "

missing=()
check_pkg() {
  local p
  for p in "$@"; do
    [[ -z $p || $VENDOR == *" $p "* ]] && continue
    pkg_installed "$p" || pkg_available "$p" || missing+=("$p (${CURRENT_ITEM:-?})")
  done
}
pkg_install() { check_pkg "$@"; return 0; }
pkg_install_for_cmds() { local pair; for pair in "$@"; do check_pkg "${pair#*:}"; done; return 0; }
ensure_epel() { return 0; }
brew_install() { return 0; }
brew_cask() { return 0; }
ensure_brew() { return 0; }

n=0
for id in "${ITEM_ORDER[@]}"; do
  item_available "$id" || continue
  s=${I_RES[$id]}
  CURRENT_ITEM=$id
  case ${s%%:*} in
  pkg) n=$((n + 1)); arg=${s#*:}; check_pkg ${arg//,/ } ;;
  sys) n=$((n + 1)); "item_${s#*:}" >/dev/null 2>&1 || true ;;
  esac
done
# Homebrew's prerequisites on Linux
CURRENT_ITEM=homebrew
check_pkg curl file git "$(by_family rhel=procps-ng arch=procps-ng default=procps)"
read -ra build <<<"$(by_family debian="build-essential" rhel="gcc gcc-c++ make" arch="base-devel" suse="gcc gcc-c++ make")"
check_pkg "${build[@]}"

if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'MISSING on %s: %s\n' "$DISTRO_NAME" "${missing[*]}"
  exit 1
fi
echo "all native package names exist on $DISTRO_NAME ($n system/native items checked)"
