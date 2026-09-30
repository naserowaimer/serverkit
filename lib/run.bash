# shellcheck shell=bash
# Entry point, started by ./serverkit under bash >= 4.4.
set -uo pipefail
SK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SK_VERSION=$(cat "$SK_ROOT/VERSION" 2>/dev/null || echo dev)
SK_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/serverkit"
for _f in core platform pkg brew ui catalog main; do
  # shellcheck source=/dev/null
  . "$SK_ROOT/lib/$_f.sh"
done
for _f in "$SK_ROOT"/modules/*.sh; do
  # shellcheck source=/dev/null
  . "$_f"
done
unset _f
sk_main "$@"
