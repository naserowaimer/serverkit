# shellcheck shell=bash
# ==============================================================================
#  brew — Homebrew, the source of user tools on macOS AND Linux, so every
#  machine gets the same names and versions. Homebrew refuses root, so brew
#  runs as the target user — or, when serverkit runs as root on Linux, as the
#  account that owns the Homebrew prefix: whoever already owns it, else a hidden
#  system account "linuxbrew" (no login shell, no password). The tools it
#  installs are then set up for root, as for anyone else.
# ==============================================================================

BREW=""
LINUXBREW_PREFIX=/home/linuxbrew/.linuxbrew
BREW_OWNER="" BREW_OWNER_HOME="" BREW_OWNER_WHY=""

# Decide who runs brew when the target is root on Linux. Read-only: the
# account is created by ensure_brew, and only when Homebrew gets installed.
brew_owner_detect() {
  BREW_OWNER="" BREW_OWNER_HOME="" BREW_OWNER_WHY=""
  is_root && [[ $TARGET_USER == root && $OS == linux ]] || return 0
  local o=linuxbrew
  if [[ -e $LINUXBREW_PREFIX ]]; then
    o=$(stat -c %U "$LINUXBREW_PREFIX" 2>/dev/null)
    case $o in
    root)
      BREW_OWNER_WHY="$LINUXBREW_PREFIX belongs to root"
      return 0
      ;;
    "" | UNKNOWN)
      BREW_OWNER_WHY="$LINUXBREW_PREFIX belongs to an account that no longer exists"
      return 0
      ;;
    esac
  elif ! id linuxbrew >/dev/null 2>&1 && ! have useradd; then
    BREW_OWNER_WHY="useradd is missing, so the linuxbrew account can't be created"
    return 0
  fi
  BREW_OWNER=$o
  if id "$o" >/dev/null 2>&1; then BREW_OWNER_HOME=$(home_of "$o"); else BREW_OWNER_HOME=/home/linuxbrew; fi
}

# The hidden account that owns Homebrew when serverkit runs as root.
ensure_brew_owner() {
  [[ $BREW_OWNER == linuxbrew ]] || return 0
  if ! id linuxbrew >/dev/null 2>&1; then
    local nologin
    for nologin in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do [[ -x $nologin ]] && break; done
    log "creating the hidden 'linuxbrew' account that owns Homebrew (no login, no password)"
    as_root useradd --system --user-group --no-create-home --home-dir /home/linuxbrew \
      --shell "$nologin" --comment "Homebrew owner (serverkit)" linuxbrew || return 1
  fi
  # its home holds Homebrew's cache; the prefix lives inside it
  if [[ ! -d $BREW_OWNER_HOME ]]; then
    as_root install -d -m 0755 -o linuxbrew -g linuxbrew "$BREW_OWNER_HOME" || return 1
  fi
}
BREW_ENV=(env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1)

brew_prefix() { printf '%s' "${BREW%/bin/brew}"; }

brew_find() {
  if $DRY_RUN && flag_has brew-planned; then
    BREW=$(cat "$RUN_DIR/.flag-brew-planned-path")
    return 0
  fi
  local p
  local where=(/opt/homebrew/bin/brew /usr/local/bin/brew "$LINUXBREW_PREFIX/bin/brew")
  [[ $TARGET_USER == root ]] || where+=("$TARGET_HOME/.linuxbrew/bin/brew")
  for p in "${where[@]}"; do
    if [[ -x $p ]]; then
      BREW=$p
      return 0
    fi
  done
  return 1
}

# Queries run even in --dry-run; changes go through `brew_run`.
brew_q() { as_brew_q "${BREW_ENV[@]}" "$BREW" "$@"; }
brew_run() { as_brew "${BREW_ENV[@]}" "$BREW" "$@"; }

brew_update_once() {
  flag_has brew-updated && return 0
  brew_run update --quiet || warn "brew update failed — continuing with the current formulae"
  flag_set brew-updated
}

ensure_brew() {
  brew_supported || {
    err "$(brew_unsupported_reason)"
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
    fi
    if [[ $OS == linux ]] && { [[ -n $BREW_OWNER ]] || system_supported; }; then
      ensure_brew_owner || return 1
      # Pre-create the prefix for its owner, so the installer needs no sudo of its own.
      if [[ ! -d $LINUXBREW_PREFIX ]]; then
        as_root install -d -m 0755 -o "${BREW_OWNER:-$TARGET_USER}" "$LINUXBREW_PREFIX" || return 1
      fi
    fi
    log "installing Homebrew (official installer)${BREW_OWNER:+ as the $BREW_OWNER account}"
    run_script https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh as_brew NONINTERACTIVE=1 || {
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
  if [[ -n $BREW_OWNER ]]; then
    hint "Homebrew runs as the '$BREW_OWNER' account; to use brew yourself:  cd / && $(have sudo && echo "sudo -u $BREW_OWNER -H" || echo "runuser -u $BREW_OWNER --") brew upgrade"
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
