# shellcheck shell=bash
# ==============================================================================
#  dev — runtimes (mise), Rust, Claude Code, PostgreSQL client
# ==============================================================================

# Add a line to both bash and zsh startup files, as a marked block.
ensure_shell_block() { # id line
  local rc_bash="$TARGET_HOME/.bashrc"
  [[ $OS == mac ]] && rc_bash="$TARGET_HOME/.bash_profile"
  ensure_block "$rc_bash" "$1" <<<"$2" || return 1
  if have zsh; then ensure_block "$(zsh_dotdir)/.zshrc" "$1" <<<"$2"; fi
}

item_runtimes() {
  brew_install mise || return 1
  local mise spec
  mise="$(brew_prefix)/bin/mise"
  for spec in $MISE_TOOLS; do
    as_user "$mise" use --global --yes "$spec" || {
      err "mise could not install $spec"
      return 1
    }
  done
  # bash: activate here. zsh: serverkit's zshrc activates mise when present;
  # otherwise add it (MISE_SHELL guards against activating twice).
  local rc_bash="$TARGET_HOME/.bashrc"
  [[ $OS == mac ]] && rc_bash="$TARGET_HOME/.bash_profile"
  ensure_block "$rc_bash" mise <<<'command -v mise >/dev/null && eval "$(mise activate bash)"'
  have zsh && ensure_block "$(zsh_dotdir)/.zshrc" mise <<<'[ -z "$MISE_SHELL" ] && command -v mise >/dev/null && eval "$(mise activate zsh)"'
  ok "runtimes: $MISE_TOOLS (change per project with: mise use node@22)"
}

item_rustup() {
  if [[ -x $TARGET_HOME/.cargo/bin/rustup ]]; then
    skip "rustup present"
  else
    run_script https://sh.rustup.rs as_user -- -y --no-modify-path || return 1
  fi
  ensure_shell_block cargo '[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"'
}

item_claude_code() {
  if [[ -x $TARGET_HOME/.local/bin/claude ]] || as_user_q sh -c 'command -v claude' >/dev/null 2>&1; then
    skip "Claude Code present"
  else
    run_script https://claude.ai/install.sh as_user || return 1
  fi
  ensure_shell_block localbin 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  hint "start Claude Code in any project with: claude"
}

item_psql() {
  brew_install libpq || return 1
  # libpq is keg-only (it would clash with a full PostgreSQL), so add its bin.
  ensure_shell_block libpq "export PATH=\"$(brew_prefix)/opt/libpq/bin:\$PATH\""
}
