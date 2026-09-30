#!/bin/sh
# ==============================================================================
#  serverkit installer
#
#    curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh
#
#  Prefer reading it first?  curl -fsSLO …/install.sh && less install.sh && sh install.sh
#
#  Puts serverkit in ~/.local/share/serverkit/src (root: /opt/serverkit) and
#  links the `serverkit` command into ~/.local/bin (root: /usr/local/bin).
#  Changes nothing else, then starts the interactive setup — which asks before
#  it does anything.
#
#  Environment:
#    SERVERKIT_VERSION=v0.1.0   install this tag (default: the latest release)
#    SERVERKIT_NO_RUN=1         install only; don't start the setup
#    SERVERKIT_REPO=owner/name  install from a fork
# ==============================================================================
set -eu

REPO=${SERVERKIT_REPO:-naserowaimer/serverkit}
if [ "$(id -u)" -eq 0 ]; then
  DEST=/opt/serverkit BIN=/usr/local/bin
else
  DEST=${XDG_DATA_HOME:-$HOME/.local/share}/serverkit/src BIN=$HOME/.local/bin
fi

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  exit 1
}
fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$@"; }

command -v curl >/dev/null 2>&1 || die "curl is required"

version=${SERVERKIT_VERSION:-}
if [ -z "$version" ]; then
  version=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || true
  [ -n "$version" ] || version=main
fi

# Never overwrite a directory that isn't a serverkit checkout.
if [ -e "$DEST" ] && [ ! -f "$DEST/lib/run.bash" ]; then
  die "$DEST exists and is not serverkit — move it away or set XDG_DATA_HOME"
fi

if [ -d "$DEST/.git" ] && command -v git >/dev/null 2>&1; then
  say "updating serverkit in $DEST to $version"
  git -C "$DEST" fetch --quiet --depth 1 origin "$version"
  git -C "$DEST" checkout --quiet FETCH_HEAD
elif command -v git >/dev/null 2>&1; then
  say "installing serverkit $version into $DEST"
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST.tmp"
  git clone --quiet --depth 1 --branch "$version" "https://github.com/$REPO.git" "$DEST.tmp"
  rm -rf "$DEST"
  mv "$DEST.tmp" "$DEST"
else
  say "installing serverkit $version into $DEST (tarball)"
  command -v tar >/dev/null 2>&1 || die "tar or git is required"
  mkdir -p "$(dirname "$DEST")"
  tmp=$(mktemp -d)
  case $version in
  main) url="https://github.com/$REPO/archive/refs/heads/main.tar.gz" ;;
  *) url="https://github.com/$REPO/archive/refs/tags/$version.tar.gz" ;;
  esac
  fetch "$url" | tar -xzf - -C "$tmp"
  rm -rf "$DEST"
  mv "$tmp"/*/ "$DEST"
  rm -rf "$tmp"
fi

mkdir -p "$BIN"
ln -sf "$DEST/serverkit" "$BIN/serverkit"
say "serverkit command: $BIN/serverkit"

case ":$PATH:" in
*":$BIN:"*) ;;
*) say "add $BIN to your PATH (e.g. in ~/.profile):  export PATH=\"$BIN:\$PATH\"" ;;
esac

if [ -z "${SERVERKIT_NO_RUN:-}" ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
  say "starting the setup (nothing changes until you confirm)"
  exec "$BIN/serverkit" </dev/tty
fi
say "run 'serverkit' to start the setup"
