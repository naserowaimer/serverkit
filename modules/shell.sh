# shellcheck shell=bash
# ==============================================================================
#  shell — zsh, tmux, SSH login, Neovim, git, fonts
#
#  Your own dotfiles are never replaced. serverkit keeps its config in
#  ~/.config/serverkit/ and adds one marked `source` line to ~/.zshrc or
#  ~/.tmux.conf; delete that block and it's gone.
# ==============================================================================

SK_USER_CONF_DIR() { printf '%s' "$TARGET_HOME/.config/serverkit"; }

# Where zsh reads .zshrc for this user (respects ZDOTDIR set in ~/.zshenv).
zsh_dotdir() {
  local d=""
  have zsh && d=$(as_user_q zsh -c 'printf %s "${ZDOTDIR:-$HOME}"' 2>/dev/null)
  printf '%s' "${d:-$TARGET_HOME}"
}

login_shell_of() {
  if have getent; then getent passwd "$TARGET_USER" | cut -d: -f7
  else dscl . -read "/Users/$TARGET_USER" UserShell 2>/dev/null | awk '{print $2}'; fi
}

item_zsh_setup() {
  if ! have zsh; then
    [[ $OS == linux ]] && system_supported || { err "zsh is not installed"; return 1; }
    pkg_install zsh || return 1
  fi
  brew_install zsh-autosuggestions zsh-syntax-highlighting zsh-completions || return 1
  safe_write "$(SK_USER_CONF_DIR)/zshrc" 0644 <"$SK_ROOT/files/zshrc" || return 1
  ensure_block "$(zsh_dotdir)/.zshrc" serverkit <<'EOF'
[ -f "$HOME/.config/serverkit/zshrc" ] && . "$HOME/.config/serverkit/zshrc"
EOF

  # Make zsh the login shell — only when it's registered and starts cleanly.
  local zp cur
  zp=$(command -v zsh)
  cur=$(login_shell_of)
  if [[ $cur == */zsh ]]; then
    skip "login shell is already zsh"
  elif ! grep -qx "$zp" /etc/shells 2>/dev/null; then
    hint "$zp isn't listed in /etc/shells, so your login shell was not changed"
  elif ! as_user_q zsh -i -c 'exit 0' </dev/null >/dev/null 2>&1; then
    warn "zsh did not start cleanly — not making it your login shell"
  elif [[ $OS == linux ]] && can_sudo; then
    as_root usermod -s "$zp" "$TARGET_USER" && hint "log out and back in to start using zsh"
  else
    hint "make zsh your login shell:  chsh -s $zp"
  fi
}

item_tmux_config() {
  brew_install tmux fzf || return 1
  safe_write "$(SK_USER_CONF_DIR)/tmux.conf" 0644 <"$SK_ROOT/files/tmux.conf" || return 1
  # tmux reads ~/.config/tmux/tmux.conf only when ~/.tmux.conf is absent —
  # never create ~/.tmux.conf over an XDG config.
  local target="$TARGET_HOME/.tmux.conf"
  [[ ! -e $target && -e $TARGET_HOME/.config/tmux/tmux.conf ]] && target="$TARGET_HOME/.config/tmux/tmux.conf"
  ensure_block "$target" serverkit <<'EOF'
source-file ~/.config/serverkit/tmux.conf
EOF
}

item_login_banner() {
  safe_write "$(SK_USER_CONF_DIR)/login.zsh" 0644 <"$SK_ROOT/files/login.zsh" || return 1
  hint "SSH logins now open tmux. Escape hatches: 'ssh host -t bash -l' (plain shell), 'touch ~/.no-tmux' (turn off)"
}

item_lazyvim() {
  brew_install neovim ripgrep fd || return 1
  local cfg="$TARGET_HOME/.config/nvim"
  if [[ -e $cfg ]]; then
    na "you already have a Neovim config in ~/.config/nvim — not replacing it"
    return
  fi
  as_user git clone -q --depth=1 https://github.com/LazyVim/starter "$cfg" && as_user rm -rf "$cfg/.git" || return 1
  hint "open nvim once and let LazyVim finish installing its plugins"
}

item_git_defaults() {
  if ! have git; then
    $DRY_RUN && { log "would set git defaults once git is installed"; return 0; }
    err "git is not installed"
    return 1
  fi
  _git_set() { as_user_q git config --global --get "$1" >/dev/null 2>&1 || as_user git config --global "$1" "$2"; }
  _git_set init.defaultBranch main
  _git_set pull.rebase true
  _git_set push.autoSetupRemote true
  _git_set fetch.prune true
  _git_set rerere.enabled true
  _git_set diff.colorMoved default
  if as_user_q sh -c 'command -v delta' >/dev/null 2>&1 || [[ -x "$(brew_prefix)/bin/delta" ]]; then
    _git_set core.pager delta
    _git_set interactive.diffFilter "delta --color-only"
    _git_set delta.navigate true
  fi
  as_user_q git config --global --get user.name >/dev/null 2>&1 || hint "set your git name:  git config --global user.name \"Your Name\""
  as_user_q git config --global --get user.email >/dev/null 2>&1 || hint "set your git email:  git config --global user.email you@example.com"
  return 0
}

item_nerd_font() { # Linux; macOS uses the Homebrew cask
  local dir="$TARGET_HOME/.local/share/fonts/JetBrainsMonoNerd" v tmp
  if [[ -d $dir ]]; then
    skip "JetBrains Mono Nerd Font already installed"
    return 0
  fi
  v=$(gh_latest ryanoasis/nerd-fonts)
  [[ -n $v ]] || $DRY_RUN || {
    err "could not look up the latest Nerd Fonts release (GitHub rate limit?)"
    return 1
  }
  local base="https://github.com/ryanoasis/nerd-fonts/releases/download/v${v:-latest}"
  if $DRY_RUN; then
    run_cmd fetch "$base/JetBrainsMono.tar.xz"
    return 0
  fi
  tmp=$(sk_tmpdir)
  fetch "$base/JetBrainsMono.tar.xz" "$tmp/font.tar.xz" && fetch "$base/SHA-256.txt" "$tmp/sums" || return 1
  local want
  want=$(awk '$2 == "JetBrainsMono.tar.xz" {print $1}' "$tmp/sums")
  if [[ -z $want || $(sha256_of "$tmp/font.tar.xz") != "$want" ]]; then
    err "font download failed its checksum — not installed"
    return 1
  fi
  [[ $TARGET_USER != root ]] && is_root && chown "$TARGET_USER" "$tmp/font.tar.xz"
  as_user mkdir -p "$dir" && as_user tar -xJf "$tmp/font.tar.xz" -C "$dir" || return 1
  have fc-cache && as_user fc-cache -f "$dir" >/dev/null 2>&1
  ok "JetBrains Mono Nerd Font $v installed — pick it in your terminal's settings"
}
