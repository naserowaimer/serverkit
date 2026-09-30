# shellcheck shell=bash
# ==============================================================================
#  remote — Tailscale, Cloudflare Tunnel, code-server
# ==============================================================================

item_tailscale() {
  if have tailscale; then
    skip "Tailscale present"
  else
    run_script https://tailscale.com/install.sh as_root || return 1
  fi
  svc_enable tailscaled || true
  if tailscale status >/dev/null 2>&1; then
    skip "already connected to a tailnet"
  else
    hint "connect this machine to your tailnet:  sudo tailscale up --ssh"
  fi
}

item_cloudflared() {
  if have cloudflared; then
    skip "cloudflared present: $(cloudflared --version 2>/dev/null | head -n 1)"
  else
    case "$FAMILY" in
    debian)
      # Cloudflare publishes one suite, "any", for every Debian/Ubuntu release.
      repo_apt cloudflare https://pkg.cloudflare.com/cloudflare-main.gpg \
        "deb [signed-by=__KEY__] https://pkg.cloudflare.com/cloudflared any main" || return 1
      ;;
    rhel | suse) repo_rpm cloudflared https://pkg.cloudflare.com/cloudflared-ascii.repo || return 1 ;;
    esac
    pkg_install cloudflared || return 1
  fi
  if svc_active cloudflared; then
    ok "tunnel connector is running"
    return 0
  fi
  local host service
  if [[ $TUNNEL_MODE == wildcard ]]; then
    host="*.${DOMAIN:-example.com}" service="http://localhost:80"
  else
    host="app.${DOMAIN:-example.com}" service="http://localhost:3000"
  fi
  hint "connect the tunnel (easiest: Cloudflare dashboard → Zero Trust → Networks → Tunnels → create, then run the 'cloudflared service install <token>' command it shows). Route $host → $service"
}

item_code_server() {
  $HAS_SYSTEMD || { na "needs systemd to run as a service"; return; }
  [[ $TARGET_USER != root ]] || { na "code-server should run as a normal user — pass --user NAME"; return; }
  if have code-server; then
    skip "code-server present"
  elif [[ $FAMILY == arch ]]; then
    # Arch has no official package; use the standalone release.
    run_script https://code-server.dev/install.sh as_root -- --method=standalone --prefix=/usr/local || return 1
  else
    run_script https://code-server.dev/install.sh as_root || return 1
  fi
  if ! svc_exists code-server@; then
    local bin
    bin=$(command -v code-server || echo /usr/local/bin/code-server)
    safe_write /etc/systemd/system/code-server@.service 0644 <<EOF
# $MARKER
[Unit]
Description=code-server for %i
After=network.target
[Service]
Type=exec
User=%i
ExecStart=$bin
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    daemon_reload
  fi
  local cfg="$TARGET_HOME/.config/code-server/config.yaml"
  if [[ -e $cfg ]]; then
    skip "code-server config exists — untouched"
  else
    # bound to localhost: reach it through an SSH tunnel, Tailscale, or a Cloudflare tunnel with Access
    safe_write "$cfg" 0600 <<EOF
# $MARKER
bind-addr: 127.0.0.1:$CODE_SERVER_PORT
auth: password
password: $(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
cert: false
EOF
  fi
  svc_enable "code-server@$TARGET_USER" || return 1
  hint "code-server: ssh -L $CODE_SERVER_PORT:localhost:$CODE_SERVER_PORT $TARGET_USER@<this-host>, open http://localhost:$CODE_SERVER_PORT — password in $cfg"
}
