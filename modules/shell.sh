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

# A `run …tpm/tpm` line the person wrote themselves.
TMUX_TPM_RUN_RE='^[[:space:]]*run(-shell)?[[:space:]].*tpm/tpm'

# tpm keeps plugins next to the config it reads: ~/.config/tmux/plugins when
# ~/.config/tmux/tmux.conf exists, ~/.tmux/plugins otherwise.
tmux_plugin_dir() {
  if [[ -f $TARGET_HOME/.config/tmux/tmux.conf ]]; then printf '%s' "$TARGET_HOME/.config/tmux/plugins"
  else printf '%s' "$TARGET_HOME/.tmux/plugins"; fi
}

# resurrect saves to ~/.tmux/resurrect if it exists, else the XDG data dir.
tmux_resurrect_dir() {
  if [[ -d $TARGET_HOME/.tmux/resurrect ]]; then printf '%s' "$TARGET_HOME/.tmux/resurrect"
  else printf '%s' "$TARGET_HOME/.local/share/tmux/resurrect"; fi
}

tmux_running() { have tmux && as_user_q tmux list-sessions >/dev/null 2>&1; }
tmux_autosave_on() { grep -q continuum_save <<<"$(as_user_q tmux show-options -gv status-right 2>/dev/null)"; }

item_tmux_config() {
  brew_install tmux fzf || return 1
  safe_write "$(SK_USER_CONF_DIR)/tmux.conf" 0644 <"$SK_ROOT/files/tmux.conf" || return 1
  # tmux reads ~/.config/tmux/tmux.conf only when ~/.tmux.conf is absent —
  # never create ~/.tmux.conf over an XDG config.
  local target="$TARGET_HOME/.tmux.conf"
  [[ ! -e $target && -e $TARGET_HOME/.config/tmux/tmux.conf ]] && target="$TARGET_HOME/.config/tmux/tmux.conf"
  # At the top, so your own settings override ours, and always above a `run
  # tpm` line of yours: continuum's autosave hook must be added after our
  # status bar is set, never before.
  ensure_block "$target" serverkit "$TMUX_TPM_RUN_RE" <<'EOF' || return 1
source-file ~/.config/serverkit/tmux.conf
EOF
  local pdir tpm home='~'
  pdir=$(tmux_plugin_dir)
  tpm="${pdir/#"$TARGET_HOME"/$home}/tpm/tpm"
  if [[ -e $target ]] && grep -Eq "$TMUX_TPM_RUN_RE" <<<"$(_read "$target")"; then
    skip "your tmux config runs tpm itself"
  else
    ensure_block "$target" plugins <<EOF || return 1
# keep this last: plugins load after every other setting
if-shell "test -x $tpm" "run-shell '$tpm'"
EOF
  fi
  tmux_plugins "$pdir" || return 1
  tmux_live_load "$pdir"
}

# tpm, tmux-resurrect and tmux-continuum, cloned where tpm expects them, so
# nothing needs a running tmux (or tpm's install key) to get them.
tmux_plugins() {
  local pdir=$1 p rdir
  if ! have git; then
    $DRY_RUN && { log "would clone tpm, tmux-resurrect and tmux-continuum once git is installed"; return 0; }
    err "git is not installed (install 'essentials' first)"
    return 1
  fi
  for p in tpm tmux-resurrect tmux-continuum; do
    if [[ -d $pdir/$p ]]; then
      skip "tmux plugin $p present"
    else
      as_user mkdir -p "$pdir" && as_user git clone -q --depth 1 "https://github.com/tmux-plugins/$p" "$pdir/$p" || return 1
    fi
  done
  # Saved screen text can include secrets: only you may read the saves.
  rdir=$(tmux_resurrect_dir)
  if [[ ! -d $rdir ]]; then
    as_user mkdir -p "$(dirname "$rdir")" && as_user install -d -m 0700 "$rdir" || return 1
  elif [[ $(file_mode "$rdir") != 700 ]]; then
    as_user chmod 0700 "$rdir" || return 1
  fi
  return 0
}

# A tmux server that's already running picks the plugins up now: no restart,
# no pane touched. Sessions are only ever restored when a server starts.
tmux_live_load() {
  local pdir=$1 kv
  tmux_running || return 0
  if $DRY_RUN; then
    log "would load session saving into your running tmux (no restart, panes untouched)"
    return 0
  fi
  # your own values win: only fill in options the running server lacks
  for kv in "@resurrect-capture-pane-contents on" "@continuum-restore on" "@continuum-save-interval 15"; do
    [[ -n $(as_user_q tmux show-options -gqv "${kv%% *}") ]] || as_user tmux set-option -g "${kv%% *}" "${kv#* }"
  done
  if tmux_autosave_on; then
    skip "tmux autosave already on"
  else
    # tpm sets TMUX_PLUGIN_MANAGER_PATH and sources the plugins. They run as
    # if from inside tmux: continuum finds "its" server through $TMUX, and
    # without it counts that server as a second one and skips autosave.
    local t
    t=$(as_user_q tmux display-message -p '#{socket_path},#{pid},0' 2>/dev/null)
    as_user_q env TMUX="$t" "$pdir/tpm/tpm" >>"$LOG" 2>&1
    tmux_autosave_on || as_user_q env TMUX="$t" "$pdir/tmux-continuum/continuum.tmux" >>"$LOG" 2>&1
    if tmux_autosave_on; then
      ok "tmux saves your sessions every 15 minutes (prefix C-s saves now, prefix C-r restores)"
    else
      warn "tmux autosave is off: something sets status-right after tpm runs — set it above the 'run … tpm' line in your tmux config"
    fi
  fi
  if [[ ! -e $(tmux_resurrect_dir)/last ]]; then
    as_user_q "$pdir/tmux-resurrect/scripts/save.sh" quiet >>"$LOG" 2>&1 && ok "first tmux snapshot saved in $(tmux_resurrect_dir)"
  fi
  return 0
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
