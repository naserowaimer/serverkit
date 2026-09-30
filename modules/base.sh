# shellcheck shell=bash
# ==============================================================================
#  base — essentials, Homebrew, Flatpak
# ==============================================================================

# Items return 0 = done, 1 = failed, 3 = not applicable here (with a reason).
NA=3
na() {
  skip "$*"
  [[ -z $RUN_DIR ]] || printf '%s\n' "$*" >"$RUN_DIR/.na-${CURRENT_ITEM:-item}"
  return $NA
}

item_essentials() {
  pkg_install_for_cmds curl:curl git:git zsh:zsh tmux:tmux unzip:unzip zip:zip rsync:rsync \
    file:file less:less \
    "gpg:$(by_family debian=gnupg rhel=gnupg2 arch=gnupg suse=gpg2)" \
    "hostname:$(by_family arch=inetutils default=hostname)" \
    "ps:$(by_family rhel=procps-ng arch=procps-ng default=procps)" \
    "xz:$(by_family debian=xz-utils default=xz)" || return 1
  pkg_install ca-certificates || return 1

  # Time sync: TLS, logs and 2FA all break when the clock drifts.
  if $HAS_SYSTEMD && ! $IS_CONTAINER && have timedatectl; then
    if [[ $(timedatectl show -p NTP --value 2>/dev/null) != yes ]]; then
      # Arch ships timesyncd inside systemd itself
      pkg_install "$(by_family rhel=chrony suse=chrony arch="" default=systemd-timesyncd)" || true
      as_root timedatectl set-ntp true || warn "could not enable network time sync"
    else
      skip "network time sync already on"
    fi
  fi
  return 0
}

item_homebrew() { ensure_brew; }

item_flatpak() {
  if ! have flatpak; then
    system_supported || na "Flatpak isn't installed and this system's packages can't be managed here" || return
    pkg_install flatpak || return 1
  fi
  as_user flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
  hint "log out and back in once so apps installed with Flatpak appear in your menu"
}

flatpak_install() { # app-id
  if as_user_q flatpak info --user "$1" >/dev/null 2>&1 || flatpak info --system "$1" >/dev/null 2>&1; then
    skip "$1 already installed"
    return 0
  fi
  as_user flatpak install --user -y --noninteractive flathub "$1"
}

# Global npm packages through mise's Node, so no sudo and no system npm.
npm_install() { # package
  local mise
  mise="$(brew_prefix)/bin/mise"
  $DRY_RUN && mise=${mise:-mise}
  [[ -x $mise ]] || $DRY_RUN || {
    err "mise not found — the 'runtimes' item provides Node for npm packages"
    return 1
  }
  if as_user_q "$mise" exec -- npm ls -g --depth=0 "$1" >/dev/null 2>&1; then
    skip "$1 already installed"
    return 0
  fi
  as_user "$mise" exec -- npm install -g --no-fund --no-audit "$1" && as_user "$mise" reshim
}
