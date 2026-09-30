# shellcheck shell=bash
# ==============================================================================
#  brew — Homebrew, the source of user tools on macOS AND Linux, so every
#  machine gets the same names and versions. Always runs as the target user
#  (Homebrew refuses root).
# ==============================================================================

BREW=""
BREW_ENV=(env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1)

brew_prefix() { printf '%s' "${BREW%/bin/brew}"; }

brew_find() {
  if $DRY_RUN && flag_has brew-planned; then
    BREW=$(cat "$RUN_DIR/.flag-brew-planned-path")
    return 0
  fi
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew "$TARGET_HOME/.linuxbrew/bin/brew"; do
    if [[ -x $p ]]; then
      BREW=$p
      return 0
    fi
  done
  return 1
}

# Queries run even in --dry-run; changes go through `brew_run`.
brew_q() { as_user_q "${BREW_ENV[@]}" "$BREW" "$@"; }
brew_run() { as_user "${BREW_ENV[@]}" "$BREW" "$@"; }

brew_update_once() {
  flag_has brew-updated && return 0
  brew_run update --quiet || warn "brew update failed — continuing with the current formulae"
  flag_set brew-updated
}

ensure_brew() {
  brew_supported || {
    err "Homebrew can't run here ($( [[ $TARGET_USER == root ]] && echo "as root — pass --user NAME" || echo "unsupported platform"))"
    return 1
  }
  if brew_find; then
    skip "Homebrew present: $BREW"
  else
    if [[ $OS == linux ]] && system_supported; then
      # Homebrew's own prerequisites (https://docs.brew.sh/Homebrew-on-Linux)
      pkg_install_for_cmds curl:curl file:file git:git ps:"$(by_family rhel=procps-ng arch=procps-ng default=procps)" || return 1
      local build
      read -ra build <<<"$(by_family debian="build-essential" rhel="gcc gcc-c++ make" arch="base-devel" suse="gcc gcc-c++ make")"
      pkg_install "${build[@]}" || return 1
      # Pre-create the prefix for the user, so the installer needs no sudo of its own.
      if [[ ! -d /home/linuxbrew/.linuxbrew ]]; then
        as_root install -d -m 0755 -o "$TARGET_USER" /home/linuxbrew/.linuxbrew || return 1
      fi
    fi
    log "installing Homebrew (official installer)"
    run_script https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh as_user NONINTERACTIVE=1 || {
      err "Homebrew installation failed — see the log"
      return 1
    }
    if $DRY_RUN; then
      BREW=$(by_family mac="$([[ $ARCH == arm64 ]] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew)" default=/home/linuxbrew/.linuxbrew/bin/brew)
      flag_set brew-planned && printf '%s' "$BREW" >"$RUN_DIR/.flag-brew-planned-path"
    fi
    $DRY_RUN || brew_find || {
      err "Homebrew installed but brew was not found"
      return 1
    }
    ok "Homebrew installed: $BREW"
  fi
  brew_shellenv
}

# Make brew available in new shells (zsh and bash) and in this process.
brew_shellenv() {
  local line="eval \"\$($BREW shellenv)\""
  ensure_block "$TARGET_HOME/.zprofile" homebrew <<<"$line"
  if [[ $OS == mac ]]; then
    [[ -e $TARGET_HOME/.bash_profile ]] && ensure_block "$TARGET_HOME/.bash_profile" homebrew <<<"$line"
  else
    ensure_block "$TARGET_HOME/.bashrc" homebrew <<<"$line"
  fi
  $DRY_RUN || eval "$("$BREW" shellenv 2>/dev/null)" || true
}

# brew_install NAME... — formulae; already-installed ones are skipped.
brew_install() {
  brew_find || ensure_brew || return 1
  local f want=()
  for f in "$@"; do
    if brew_q list --formula --versions "$f" >/dev/null 2>&1; then skip "$f already installed"; else want+=("$f"); fi
  done
  [[ ${#want[@]} -gt 0 ]] || return 0
  brew_update_once
  log "brew install ${want[*]}"
  $DRY_RUN && {
    brew_run install --formula "${want[@]}"
    return 0
  }
  local out rc
  out=$(brew_run install --formula "${want[@]}" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  [[ $rc -eq 0 ]] && return 0
  brew_explain "$out"
  return 1
}

# Show Homebrew's own reason and advice, not just "see the log".
brew_explain() {
  local why
  why=$(grep -E '^Error:|Could not symlink|is a symlink belonging to|brew unlink|We do not provide support|No available formula' <<<"$1" | head -n 4)
  err "Homebrew failed${why:+: }$(printf '%s' "$why" | tr '\n' ' ')"
}

# brew_cask NAME... — macOS apps. An app already in /Applications counts as done.
brew_cask() {
  [[ $OS == mac ]] || {
    err "casks are macOS-only"
    return 1
  }
  brew_find || ensure_brew || return 1
  local c out
  for c in "$@"; do
    if brew_q list --cask "$c" >/dev/null 2>&1; then
      skip "$c already installed"
      continue
    fi
    brew_update_once
    log "brew install --cask $c"
    $DRY_RUN && {
      run_cmd brew install --cask "$c"
      continue
    }
    if ! out=$(brew_run install --cask "$c" 2>&1); then
      printf '%s\n' "$out" >>"$LOG"
      if grep -q "already an App at" <<<"$out"; then
        skip "$c: the app is already installed (outside Homebrew)"
      else
        brew_explain "$out"
        return 1
      fi
    fi
  done
}
