# shellcheck shell=bash
# ==============================================================================
#  security — firewall, SSH, fail2ban, updates, kernel, per-user limits
#
#  Rule zero: nothing here may lock the owner out. The firewall always admits
#  every port sshd listens on (plus the one you're connected through), sshd
#  changes are validated with `sshd -t` and rolled back if rejected, and
#  password login is only turned off when a key login already exists.
# ==============================================================================

# Ports sshd listens on, plus the port of the current SSH session.
ssh_ports() {
  local p
  p=$(as_root_q sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
  [[ -n $p ]] || p=$(_read /etc/ssh/sshd_config 2>/dev/null | awk 'tolower($1) == "port" {print $2}')
  [[ -n ${SSH_CONNECTION:-} ]] && p+=$'\n'"$(awk '{print $4}' <<<"$SSH_CONNECTION")"
  printf '%s\n' "${p:-22}" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
}

firewall_backend() { # the one already in charge wins; never run two
  if svc_active firewalld; then echo firewalld
  elif have ufw && grep -q 'Status: active' <<<"$(as_root_q ufw status 2>/dev/null)"; then echo ufw
  else by_family rhel=firewalld suse=firewalld default=ufw; fi
}

item_firewall() {
  $IS_CONTAINER && { na "containers use the host's firewall"; return; }
  local backend ports p
  backend=$(firewall_backend)
  ports=$(ssh_ports)
  case "$backend" in
  ufw)
    pkg_install ufw || return 1
    if grep -q 'Status: active' <<<"$(as_root_q ufw status 2>/dev/null)"; then
      skip "ufw is already active — your rules are left as they are"
    else
      as_root ufw default deny incoming && as_root ufw default allow outgoing || return 1
      for p in $ports; do as_root ufw allow "$p/tcp" comment ssh || return 1; done
      for p in $FIREWALL_ALLOW; do as_root ufw allow "$p" || return 1; done
      as_root ufw --force enable || return 1
      ok "ufw on: inbound allowed only to SSH ($ports)${FIREWALL_ALLOW:+ and $FIREWALL_ALLOW}"
    fi
    svc_enable ufw >/dev/null 2>&1 || true
    ;;
  firewalld)
    pkg_install firewalld || return 1
    if svc_active firewalld; then
      skip "firewalld is already running — your zones are left as they are"
    else
      # Configure offline BEFORE starting, so a custom SSH port is open the
      # moment the firewall comes up.
      as_root firewall-offline-cmd --add-service=ssh >/dev/null || return 1
      for p in $ports; do
        [[ $p == 22 ]] || as_root firewall-offline-cmd --add-port="$p/tcp" >/dev/null || return 1
      done
      for p in $FIREWALL_ALLOW; do as_root firewall-offline-cmd --add-port="$p" >/dev/null || return 1; done
      svc_enable firewalld || return 1
      ok "firewalld on: inbound allowed only to SSH ($ports)${FIREWALL_ALLOW:+ and $FIREWALL_ALLOW}"
    fi
    ;;
  esac
  have docker && [[ $backend == ufw ]] &&
    hint "Docker publishes ports around ufw — bind containers to 127.0.0.1 (\"127.0.0.1:8080:80\") unless they should be public"
  hint "if this is a cloud server, its provider may have a separate firewall too"
  return 0
}

item_mac_firewall() {
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  if grep -qi enabled <<<"$("$fw" --getglobalstate 2>/dev/null)"; then
    skip "macOS firewall already on"
  else
    as_root "$fw" --setglobalstate on || return 1
    ok "macOS application firewall on"
  fi
}

# ------------------------------------------------------------------------------
item_ssh_hardening() {
  local sshd main=/etc/ssh/sshd_config
  sshd=$(command -v sshd || echo /usr/sbin/sshd)
  [[ -x $sshd ]] || { na "no SSH server installed"; return; }
  if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' <<<"$(_read "$main")"; then
    warn "$main doesn't include /etc/ssh/sshd_config.d — your main config is not edited"
    hint "add 'Include /etc/ssh/sshd_config.d/*.conf' as the first line of $main, then re-run: serverkit install ssh-hardening"
    return 1
  fi

  # PermitRootLogin prohibit-password only if nobody who logs in as root with a
  # password would be stranded: root has a key, or the admin is a sudoer.
  local root_line="# PermitRootLogin unchanged: root has no SSH key and no sudo user was found"
  if as_root_q test -s /root/.ssh/authorized_keys ||
    { [[ $TARGET_USER != root ]] && { in_group "$TARGET_USER" sudo || in_group "$TARGET_USER" wheel || in_group "$TARGET_USER" admin; }; }; then
    root_line="PermitRootLogin prohibit-password"
  fi

  local pw_line="# PasswordAuthentication unchanged (SSH_PASSWORD_AUTH=keep)"
  if [[ $SSH_PASSWORD_AUTH == no ]]; then
    if [[ $TARGET_USER != root && -s $TARGET_HOME/.ssh/authorized_keys ]]; then
      local kbd=KbdInteractiveAuthentication ver
      ver=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1\2/p')
      [[ -n $ver && $ver -lt 87 ]] && kbd=ChallengeResponseAuthentication
      pw_line="PasswordAuthentication no"$'\n'"$kbd no"
    else
      warn "SSH_PASSWORD_AUTH=no ignored: $TARGET_USER has no ~/.ssh/authorized_keys — that would lock you out"
    fi
  fi

  safe_write /etc/ssh/sshd_config.d/10-serverkit.conf 0644 <<EOF
# $MARKER — first match wins in sshd, so this file (10-) beats later ones.
$root_line
$pw_line
MaxAuthTries $SSH_MAX_AUTH_TRIES
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
EOF
  $SW_CHANGED && ! $DRY_RUN || return 0
  if as_root "$sshd" -t; then
    if svc_exists ssh; then svc_reload ssh; else svc_reload sshd; fi
    ok "sshd reloaded — existing sessions are unaffected"
  else
    restore_file /etc/ssh/sshd_config.d/10-serverkit.conf
    err "sshd rejected the new settings — rolled back, sshd untouched"
    return 1
  fi
}

# ------------------------------------------------------------------------------
item_fail2ban() {
  ensure_epel || warn "EPEL could not be enabled"
  # journal support (backend = systemd); openSUSE's fail2ban already requires it
  pkg_install fail2ban "$(by_family arch=python-systemd suse="" default=python3-systemd)" || return 1
  have fail2ban-client || $DRY_RUN || {
    err "fail2ban is not available on $DISTRO_NAME"
    return 1
  }
  local banaction=iptables-multiport
  if svc_active firewalld; then banaction=firewallcmd-rich-rules
  elif grep -q 'Status: active' <<<"$(as_root_q ufw status 2>/dev/null)"; then banaction=ufw
  elif have nft; then banaction=nftables-multiport; fi

  local escalate=""
  [[ $FAIL2BAN_ESCALATE == true ]] &&
    escalate=$'\n# repeat offenders: each new ban lasts longer, up to a week\nbantime.increment = true\nbantime.maxtime = 1w'
  # Behind a Cloudflare tunnel every web request comes from 127.0.0.1, so web
  # jails can't ban anyone — use Cloudflare's WAF for that. SSH is covered.
  safe_write /etc/fail2ban/jail.d/serverkit.local 0644 <<EOF
# $MARKER
[DEFAULT]
bantime  = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY
backend  = systemd
banaction = $banaction
ignoreip = $FAIL2BAN_IGNOREIP$escalate

[sshd]
enabled = true
EOF
  if $SW_CHANGED && ! $DRY_RUN; then
    if ! as_root fail2ban-client -t >/dev/null 2>&1; then
      restore_file /etc/fail2ban/jail.d/serverkit.local
      err "fail2ban rejected the configuration — rolled back"
      return 1
    fi
    svc_enable fail2ban && svc_restart fail2ban
  else
    svc_enable fail2ban
  fi
}

# ------------------------------------------------------------------------------
item_auto_updates() {
  case "$FAMILY" in
  debian)
    pkg_install unattended-upgrades || return 1
    safe_write /etc/apt/apt.conf.d/21serverkit-periodic 0644 <<EOF
// $MARKER
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    safe_write /etc/apt/apt.conf.d/52serverkit-unattended 0644 <<EOF
// $MARKER — which updates: the distro's security origins (its own default).
Unattended-Upgrade::Automatic-Reboot "$AUTO_REBOOT";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
    svc_enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    ;;
  rhel | suse)
    local cmd
    if [[ $FAMILY == rhel ]]; then
      cmd="/usr/bin/dnf -y --refresh upgrade --security"
    else
      [[ $DISTRO_ID == opensuse-tumbleweed || $DISTRO_ID == opensuse-slowroll ]] &&
        { na "Tumbleweed is rolling — update it with 'sudo zypper dup' rather than unattended patches"; return; }
      cmd="/usr/bin/zypper --non-interactive patch --category security --auto-agree-with-licenses"
    fi
    $HAS_SYSTEMD || { na "needs systemd for the update timer"; return; }
    safe_write /etc/systemd/system/serverkit-security-updates.service 0644 <<EOF
# $MARKER
[Unit]
Description=Install security updates
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=$cmd
EOF
    safe_write /etc/systemd/system/serverkit-security-updates.timer 0644 <<EOF
# $MARKER
[Unit]
Description=Daily security updates
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    daemon_reload && svc_enable serverkit-security-updates.timer || return 1
    [[ $AUTO_REBOOT == true ]] && warn "AUTO_REBOOT applies to Debian/Ubuntu only — reboot this machine yourself after kernel updates"
    ;;
  *) na "automatic updates aren't set up on $DISTRO_NAME"; return ;;
  esac
  [[ $AUTO_REBOOT == true ]] || hint "security updates never reboot by themselves — reboot after kernel updates"
  return 0
}

# ------------------------------------------------------------------------------
item_kernel_hardening() {
  $IS_CONTAINER && { na "containers share the host kernel"; return; }
  local f=/etc/sysctl.d/60-serverkit-hardening.conf
  safe_write "$f" 0644 <<EOF
# $MARKER
# IP forwarding and rp_filter are left alone — Docker, k3s and Tailscale need them.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
EOF
  # -e: skip keys this kernel lacks (e.g. IPv6 disabled) instead of failing
  $SW_CHANGED && { as_root sysctl -q -e -p "$f" || warn "some kernel settings could not be applied now; they apply at boot"; }
  return 0
}

# ------------------------------------------------------------------------------
item_user_limits() {
  $HAS_SYSTEMD || { na "needs systemd"; return; }
  [[ -n $USER_MEMORY_MAX$USER_TASKS_MAX$USER_CPU_QUOTA ]] ||
    { na "no caps configured (USER_MEMORY_MAX / USER_TASKS_MAX / USER_CPU_QUOTA)"; return; }
  # Applies to everything a login user starts. Docker containers are started
  # by dockerd, not the user, so cap those in compose (mem_limit / cpus).
  safe_write /etc/systemd/system/user-.slice.d/50-serverkit.conf 0644 < <(
    echo "# $MARKER — caps for every login user (the admin is exempt, see user-UID.slice.d)"
    echo "[Slice]"
    [[ -z $USER_MEMORY_MAX ]] || echo "MemoryMax=$USER_MEMORY_MAX"
    [[ -z $USER_TASKS_MAX ]] || echo "TasksMax=$USER_TASKS_MAX"
    [[ -z $USER_CPU_QUOTA ]] || echo "CPUQuota=$USER_CPU_QUOTA"
  )
  local changed=$SW_CHANGED
  if [[ $TARGET_USER != root ]]; then
    safe_write "/etc/systemd/system/user-$(id -u "$TARGET_USER").slice.d/60-serverkit-admin.conf" 0644 <<EOF
# $MARKER — $TARGET_USER administers this machine: no caps
[Slice]
MemoryMax=infinity
TasksMax=infinity
CPUQuota=
EOF
    $SW_CHANGED && changed=true
  fi
  $changed && daemon_reload
  ok "per-user caps: memory ${USER_MEMORY_MAX:-unlimited}, tasks ${USER_TASKS_MAX:-unlimited}, CPU ${USER_CPU_QUOTA:-unlimited} ($TARGET_USER exempt)"
}
