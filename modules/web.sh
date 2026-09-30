# shellcheck shell=bash
# ==============================================================================
#  web — nginx, safely. Every change is checked with `nginx -t` and rolled
#  back if nginx rejects it, so a running site is never taken down.
# ==============================================================================

item_nginx_web() {
  pkg_install nginx || return 1
  svc_enable nginx || true

  local main=/etc/nginx/nginx.conf
  if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf' "$main" 2>/dev/null; then
    warn "$main doesn't include /etc/nginx/conf.d/*.conf — not editing your main config"
    hint "add 'include /etc/nginx/conf.d/*.conf;' inside the http { } block of $main, then re-run: serverkit install nginx"
    return 0
  fi

  local written=()
  # -R, not -r: sites-enabled/* are symlinks, and -r skips them
  if ! grep -RqsE '^[[:space:]]*server_tokens' "$main" /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ --exclude=00-serverkit-hardening.conf; then
    safe_write /etc/nginx/conf.d/00-serverkit-hardening.conf 0644 <<EOF
# $MARKER
server_tokens off;
EOF
    $SW_CHANGED && written+=(/etc/nginx/conf.d/00-serverkit-hardening.conf)
  fi

  # A catch-all, so a request for a host nobody serves gets 404 instead of
  # whichever site nginx happens to list first.
  local ours=/etc/nginx/conf.d/00-serverkit-default.conf
  if [[ ! -e $ours ]] && grep -Rqs 'default_server' /etc/nginx/sites-enabled /etc/nginx/conf.d "$main"; then
    skip "a default server already exists — left alone"
    [[ -e /etc/nginx/sites-enabled/default ]] &&
      hint "nginx's stock welcome page answers unknown hosts; for a 404 instead: sudo rm /etc/nginx/sites-enabled/default && serverkit install nginx"
  else
    local v6=""
    [[ -e /proc/net/if_inet6 ]] && v6="  listen [::]:80 default_server;"
    safe_write "$ours" 0644 <<EOF
# $MARKER — hosts no site claims get 404
server {
  listen 80 default_server;
$v6
  server_name _;
  return 404;
}
EOF
    $SW_CHANGED && written+=("$ours")
  fi

  if [[ ${#written[@]} -gt 0 ]] && ! $DRY_RUN; then
    local out
    if out=$(as_root nginx -t 2>&1); then
      svc_reload nginx
    else
      local f
      for f in "${written[@]}"; do restore_file "$f"; done
      printf '%s\n' "$out" >>"$LOG"
      err "nginx rejected the new files — rolled back, nginx untouched: $(grep -m1 -E 'emerg|error' <<<"$out")"
      return 1
    fi
  fi

  if [[ $WEB_PUBLIC == true ]]; then
    if svc_active firewalld; then
      as_root firewall-cmd --permanent --add-service=http --add-service=https >/dev/null && as_root firewall-cmd --reload >/dev/null
    elif have ufw; then
      as_root ufw allow 80/tcp && as_root ufw allow 443/tcp
    fi
    hint "ports 80/443 are open; for HTTPS certificates look at certbot or a Cloudflare tunnel"
  else
    hint "nginx listens on port 80 but the firewall stays closed — publish sites through a Cloudflare tunnel to http://localhost:80, or set WEB_PUBLIC=true"
  fi
}
