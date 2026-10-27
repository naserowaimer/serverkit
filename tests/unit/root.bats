#!/usr/bin/env bats
# Running as root on Linux: Homebrew runs as the prefix's owner account
# (an existing one, else a hidden "linuxbrew" account); tools are set up for root.

setup() {
  load helper
  load_sk
  SK_OS_RELEASE="$BATS_TEST_DIRNAME/fixtures/os-release/ubuntu-24.04" detect_platform
  IS_MUSL=false ARCH=amd64
  LINUXBREW_PREFIX="$BATS_TEST_TMPDIR/linuxbrew/.linuxbrew"
  is_root() { return 0; }
  TARGET_USER=root
}

@test "a normal user: nobody else runs brew" {
  is_root() { return 1; }
  TARGET_USER=$(id -un)
  brew_owner_detect
  [ -z "$BREW_OWNER" ]
  brew_supported
}

@test "root with --user: brew runs as that user, as before" {
  TARGET_USER=someone
  brew_owner_detect
  [ -z "$BREW_OWNER" ]
}

@test "root, no Homebrew yet: the hidden linuxbrew account will own it" {
  have() { [ "$1" = useradd ] || command -v "$1" >/dev/null 2>&1; }
  id() { [ "$1" != linuxbrew ] && command id "$@"; }
  brew_owner_detect
  [ "$BREW_OWNER" = linuxbrew ]
  [ "$BREW_OWNER_HOME" = /home/linuxbrew ]
  brew_supported
}

@test "root, Homebrew already owned by a person: brew runs as them, nothing is taken over" {
  mkdir -p "$LINUXBREW_PREFIX"
  brew_owner_detect
  [ "$BREW_OWNER" = "$(id -un)" ]
  [ "$BREW_OWNER_HOME" = "$(home_of "$(id -un)")" ]
}

@test "root, Homebrew prefix owned by root: refused with the reason" {
  mkdir -p "$LINUXBREW_PREFIX"
  stat() { echo root; }
  brew_owner_detect
  [ -z "$BREW_OWNER" ]
  ! brew_supported
  [[ $(brew_unsupported_reason) == *"belongs to root"* ]]
}

@test "root without useradd and no account: refused with the reason" {
  have() { [ "$1" != useradd ] && command -v "$1" >/dev/null 2>&1; }
  id() { [ "$1" != linuxbrew ] && command id "$@"; }
  brew_owner_detect
  ! brew_supported
  [[ $(brew_unsupported_reason) == *useradd* ]]
}

@test "root on macOS stays refused" {
  OS=mac
  brew_owner_detect
  [ -z "$BREW_OWNER" ]
  ! brew_supported
}

@test "brew commands run as the owner, from /, never as root" {
  BREW_OWNER=linuxbrew BREW_OWNER_HOME=/home/linuxbrew DRY_RUN=true
  have() { [ "$1" = sudo ]; }
  run as_brew brew install jq
  [[ $output == *"would run: sudo -u linuxbrew -H brew install jq"* ]]
  have() { return 1; }
  run as_brew brew install jq
  [[ $output == *"runuser -u linuxbrew -- env HOME=/home/linuxbrew brew install jq"* ]]
  cd "$BATS_TEST_TMPDIR"
  run_cmd() { pwd; }
  run as_brew brew list
  [ "$output" = / ]
}

@test "everything else still runs as root, in root's home" {
  BREW_OWNER=linuxbrew BREW_OWNER_HOME=/home/linuxbrew DRY_RUN=true
  run as_user git config --global init.defaultBranch main
  [[ $output == *"would run: git config --global init.defaultBranch main"* ]]
  [[ $output != *sudo* ]]
}

@test "the catalog offers Homebrew tools to root" {
  have() { [ "$1" = useradd ] || command -v "$1" >/dev/null 2>&1; }
  id() { [ "$1" != linuxbrew ] && command id "$@"; }
  brew_owner_detect
  catalog_load
  catalog_resolve
  item_available ripgrep
  item_available starship
}

@test "dry run as root: creates the account, then installs as it" {
  have() { case "$1" in useradd | sudo) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  id() { [ "$1" != linuxbrew ] && command id "$@"; }
  system_supported() { return 1; }
  brew_owner_detect
  DRY_RUN=true TARGET_HOME="$BATS_TEST_TMPDIR/root"
  mkdir -p "$TARGET_HOME"
  BREW_ENV=()
  brew_find() { return 1; }
  run ensure_brew
  [[ $output == *"useradd --system --user-group --no-create-home --home-dir /home/linuxbrew"* ]]
  [[ $output == *"install -d -m 0755 -o linuxbrew"* ]]
  [[ $output == *"as the linuxbrew account"* ]]
}

@test "a shell found through a merged-/usr symlink counts as registered" {
  d="$BATS_TEST_TMPDIR/usr"
  mkdir -p "$d/bin"
  ln -s bin "$d/sbin"
  printf '#!/bin/sh\n' >"$d/bin/zsh" && chmod +x "$d/bin/zsh"
  printf '%s\n' "$d/bin/zsh" >"$BATS_TEST_TMPDIR/shells"
  # point the function at the fake /etc/shells
  eval "$(declare -f registered_shell | sed "s|/etc/shells|$BATS_TEST_TMPDIR/shells|g")"
  [ "$(registered_shell "$d/sbin/zsh")" = "$d/bin/zsh" ]
  [ "$(registered_shell "$d/bin/zsh")" = "$d/bin/zsh" ]
  [ "$(registered_shell /nonexistent/zsh)" = /nonexistent/zsh ]
}
