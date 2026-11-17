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
  local cfg="$TARGET_HOME/.config/code-server/config.yaml" bind port
  if [[ -e $cfg ]]; then
    skip "code-server config exists — untouched"
  else
    # bound to localhost: reach it through Tailscale, an SSH tunnel, or a Cloudflare tunnel with Access
    safe_write "$cfg" 0600 <<EOF
# $MARKER
bind-addr: 127.0.0.1:$CODE_SERVER_PORT
auth: password
password: $(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
cert: false
EOF
  fi
  svc_enable "code-server@$TARGET_USER" || return 1
  bind=$(_read "$cfg" 2>/dev/null | sed -n 's/^bind-addr:[[:space:]]*//p' | tr -d "\"'" | head -n 1)
  bind=${bind:-127.0.0.1:$CODE_SERVER_PORT}
  port=${bind##*:}
  case ${bind%:*} in
  127.0.0.1 | localhost | "[::1]" | ::1) ;;
  *) warn "code-server listens on $bind: anyone who can reach this machine gets its login page. Set bind-addr: 127.0.0.1:$port in $cfg" ;;
  esac
  code_server_tailnet "$port" ||
    hint "code-server: ssh -L $port:localhost:$port $TARGET_USER@<this-host>, open http://localhost:$port — password in $cfg"
}

# HTTPS for code-server on your tailnet only (tailscale serve; never funnel,
# never a public domain). Fails quietly when Tailscale can't do it yet.
code_server_tailnet() {
  local port=$1 https=$CODE_SERVER_TAILNET_PORT st host cur target
  target="http://127.0.0.1:$port"
  [[ $https != off ]] || return 1
  if ! have tailscale || ! st=$(tailscale status --json 2>/dev/null) || ! grep -q '"BackendState": *"Running"' <<<"$st"; then
    hint "once Tailscale is connected, re-run: serverkit install code-server  (it then serves code-server to your tailnet only)"
    return 1
  fi
  # tailnet HTTPS certificates are off until the admin turns them on
  host=$(tr -d ' \n' <<<"$st" | sed -n 's/.*"CertDomains":\["\([^"]*\)".*/\1/p')
  if [[ -z $host ]]; then
    hint "turn on HTTPS certificates in the Tailscale admin console (DNS page), then re-run: serverkit install code-server"
    return 1
  fi
  # what this HTTPS port already proxies to, if anything
  local serve
  serve=$(tailscale serve status --json 2>/dev/null) || serve=$(as_root_q tailscale serve status --json 2>/dev/null) || {
    warn "couldn't read Tailscale's serve settings — code-server was not put on your tailnet"
    return 1
  }
  cur=$(printf '%s\n' "$serve" | awk -v k=":$https\": {" '
    index($0, k) { inport = 1; next }
    inport && /"Proxy"/ { gsub(/.*"Proxy": *"|".*/, ""); print; exit }
    inport && /^    "[^"]*": \{/ { inport = 0 }')
  if [[ $cur == "$target" ]]; then
    skip "code-server is on your tailnet: https://$host:$https"
  elif [[ -n $cur ]] || grep -q "\"$https\": {" <<<"$serve"; then
    warn "tailnet port $https already serves ${cur:-something else} — left alone. Pick another: serverkit install code-server --set CODE_SERVER_TAILNET_PORT=8448"
    return 1
  else
    as_root tailscale serve --bg --https="$https" "$target" || return 1
    ok "code-server is on your tailnet only: https://$host:$https"
  fi
  hint "code-server password: in $TARGET_HOME/.config/code-server/config.yaml"
  return 0
}
