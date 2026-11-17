#!/usr/bin/env bats
# tmux session saving, the sshd lint, and code-server on the tailnet.

setup() {
  load helper
  load_sk
  F="$TARGET_HOME/conf"
  TS_STATUS='{ "BackendState": "Running", "CertDomains": [ "box.tail1.ts.net" ] }'
  TS_SERVE='{}'
  tailscale() {
    case "$1 $2" in
    "status --json") printf '%s\n' "$TS_STATUS" ;;
    "serve status") printf '%s\n' "$TS_SERVE" ;;
    *) echo "tailscale $*" >>"$BATS_TEST_TMPDIR/ts.log" ;;
    esac
  }
  have() { [[ $1 == tailscale ]] || command -v "$1" >/dev/null 2>&1; }
  CODE_SERVER_TAILNET_PORT=8447
}

# ---- ensure_block with an anchor ----
@test "with an anchor, a new block goes at the top, under your settings" {
  printf 'set -g mouse on\n# keep this at the very bottom\nrun "~/.tmux/plugins/tpm/tpm"\n' >"$F"
  ensure_block "$F" demo "$TMUX_TPM_RUN_RE" <<<"ours"
  [ "$(sed -n 1p "$F")" = "# >>> serverkit:demo >>>" ]
  [ "$(sed -n 2p "$F")" = ours ]
  [ "$(sed -n 4p "$F")" = "set -g mouse on" ]
  [ "$(tail -n 1 "$F")" = 'run "~/.tmux/plugins/tpm/tpm"' ]
}

@test "a block below the anchor moves to the top, then stays put" {
  printf 'a\nrun-shell ~/.tmux/plugins/tpm/tpm\n# >>> serverkit:demo >>>\nours\n# <<< serverkit:demo <<<\n' >"$F"
  ensure_block "$F" demo "$TMUX_TPM_RUN_RE" <<<"ours"
  [ "$(sed -n 1p "$F")" = "# >>> serverkit:demo >>>" ]
  [ "$(tail -n 1 "$F")" = "run-shell ~/.tmux/plugins/tpm/tpm" ]
  [ "$(grep -c 'serverkit:demo' "$F")" = 2 ]
  run ensure_block "$F" demo "$TMUX_TPM_RUN_RE" <<<"ours"
  [[ $output == *unchanged* ]]
}

@test "a block already above the anchor is updated where it is" {
  printf 'a\n# >>> serverkit:demo >>>\nold\n# <<< serverkit:demo <<<\nb\nrun ~/.tmux/plugins/tpm/tpm\n' >"$F"
  ensure_block "$F" demo "$TMUX_TPM_RUN_RE" <<<"new"
  [ "$(sed -n 1p "$F")" = a ]
  [ "$(sed -n 3p "$F")" = new ]
}

@test "without an anchor, a new block is appended as before" {
  printf 'a\n' >"$F"
  ensure_block "$F" demo <<<"ours"
  [ "$(tail -n 1 "$F")" = "# <<< serverkit:demo <<<" ]
}

# ---- tmux-config ----
tmux_item() {
  brew_install() { :; }
  tmux_plugins() { :; }
  tmux_live_load() { :; }
  item_tmux_config
}

@test "tmux-config adds its own tpm run line last" {
  echo 'set -g mouse on' >"$TARGET_HOME/.tmux.conf"
  tmux_item
  grep -q 'source-file ~/.config/serverkit/tmux.conf' "$TARGET_HOME/.tmux.conf"
  [ "$(tail -n 2 "$TARGET_HOME/.tmux.conf" | head -n 1)" = "if-shell \"test -x ~/.tmux/plugins/tpm/tpm\" \"run-shell '~/.tmux/plugins/tpm/tpm'\"" ]
  grep -q "@plugin 'tmux-plugins/tmux-continuum'" "$TARGET_HOME/.config/serverkit/tmux.conf"
}

@test "tmux-config goes above your own tpm line and adds no second one" {
  printf 'source-file -q ~/x/agentdeck.conf\nset -g @plugin tmux-plugins/tpm\nrun "~/.tmux/plugins/tpm/tpm"\n' >"$TARGET_HOME/.tmux.conf"
  tmux_item
  [ "$(sed -n 2p "$TARGET_HOME/.tmux.conf")" = "source-file ~/.config/serverkit/tmux.conf" ]
  [ "$(sed -n 4p "$TARGET_HOME/.tmux.conf")" = "source-file -q ~/x/agentdeck.conf" ]
  [ "$(tail -n 1 "$TARGET_HOME/.tmux.conf")" = 'run "~/.tmux/plugins/tpm/tpm"' ]
  ! grep -q 'serverkit:plugins' "$TARGET_HOME/.tmux.conf"
  ls "$TARGET_HOME"/.tmux.conf.bak.*
}

@test "tmux-config twice changes nothing" {
  tmux_item
  run tmux_item
  [[ $output != *updated* && $output != *created* ]]
}

@test "the save folder is private" {
  git() { mkdir -p "${@: -1}"; }
  as_user() { "$@"; }
  tmux_plugins "$(tmux_plugin_dir)"
  [ "$(file_mode "$(tmux_resurrect_dir)")" = 700 ]
  [ -d "$TARGET_HOME/.tmux/plugins/tmux-continuum" ]
}

@test "plugins live under ~/.config/tmux when that's the config tpm reads" {
  mkdir -p "$TARGET_HOME/.config/tmux" && touch "$TARGET_HOME/.config/tmux/tmux.conf"
  [ "$(tmux_plugin_dir)" = "$TARGET_HOME/.config/tmux/plugins" ]
}

# ---- sshd lint ----
@test "sshd lint: a commented #Match with live indented lines is flagged" {
  printf 'Port 22\n#Match User ghactions\n    AllowTcpForwarding no\n\tPasswordAuthentication yes\nX11Forwarding no\n' >"$F"
  run sshd_lint "$F"
  [[ $output == *"$F:2:"*"#Match User ghactions"*"2 indented line(s)"*"AllowTcpForwarding no"* ]]
}

@test "sshd lint: the stock commented example and real Match blocks pass" {
  printf '#Match User anoncvs\n#\tX11Forwarding no\n#\tAllowTcpForwarding no\nMatch User git\n    AllowTcpForwarding no\n' >"$F"
  run sshd_lint "$F"
  [ -z "$output" ]
}

@test "sshd lint: an unindented line ends the commented block" {
  printf '#Match User x\nPasswordAuthentication yes\n    UsePAM yes\n' >"$F"
  run sshd_lint "$F"
  [ -z "$output" ]
}

# ---- code-server on the tailnet ----
@test "code-server is served to the tailnet when the port is free" {
  DRY_RUN=true
  run code_server_tailnet 8080
  [ "$status" = 0 ]
  [[ $output == *"tailscale serve --bg --https=8447 http://127.0.0.1:8080"* ]]
  [[ $output == *"https://box.tail1.ts.net:8447"* ]]
}

@test "code-server: an HTTPS port already serving something else is left alone" {
  TS_SERVE='{
  "TCP": {
    "8447": {
      "HTTPS": true
    }
  },
  "Web": {
    "box.tail1.ts.net:8447": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:3000"
        }
      }
    }
  }
}'
  run code_server_tailnet 8080
  [ "$status" = 1 ]
  [[ $output == *"already serves http://127.0.0.1:3000"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ts.log" ]
}

@test "code-server: already on the tailnet is a no-op" {
  TS_SERVE='{ "Web": {
    "box.tail1.ts.net:8447": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } } }
  } }'
  TS_SERVE=$(sed 's/{ "Handlers"/{\n      "Handlers"/; s/{ "Proxy"/{\n "Proxy"/' <<<"$TS_SERVE")
  run code_server_tailnet 8080
  [ "$status" = 0 ]
  [[ $output == *"is on your tailnet"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ts.log" ]
}

@test "code-server: no tailnet HTTPS certificates, no serve" {
  TS_STATUS='{ "BackendState": "Running", "CertDomains": null }'
  run code_server_tailnet 8080
  [ "$status" = 1 ]
  grep -q "HTTPS certificates" "$RUN_DIR/hints"
}

@test "code-server: CODE_SERVER_TAILNET_PORT=off skips Tailscale" {
  CODE_SERVER_TAILNET_PORT=off
  run code_server_tailnet 8080
  [ "$status" = 1 ]
  [ -z "$output" ]
}
