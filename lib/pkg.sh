# shellcheck shell=bash
# ==============================================================================
#  pkg — the native package manager (apt, dnf, pacman, zypper) and systemd.
#
#  Used only for system pieces: firewall, sshd, fail2ban, nginx, docker engine…
#  Everyday tools come from Homebrew (lib/brew.sh) so they match on every OS.
# ==============================================================================

# Per-run flags live in files: items run in subshells, variables don't survive.
flag_set() { [[ -n $RUN_DIR ]] && touch "$RUN_DIR/.flag-$1"; }
flag_has() { [[ -n $RUN_DIR && -e $RUN_DIR/.flag-$1 ]]; }

APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none)

pkg_refresh() {
  flag_has pkg-refreshed && return 0
  case "$PM" in
  apt) as_root "${APT_ENV[@]}" apt-get update -q || return 1 ;;
  zypper) as_root zypper --non-interactive --quiet refresh || return 1 ;;
  # dnf refreshes stale metadata by itself. pacman: never -Sy on its own —
  # a partial upgrade breaks Arch; see pkg_install.
  esac
  flag_set pkg-refreshed
}

pkg_installed() {
  case "$PM" in
  apt) grep -q 'install ok installed' <<<"$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" ;;
  dnf | zypper) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
  pacman) pacman -Qi "$1" >/dev/null 2>&1 || pacman -Qg "$1" >/dev/null 2>&1 ;;
  *) return 1 ;;
  esac
}

pkg_available() {
  case "$PM" in
  apt) grep -q 'Candidate: [^(]' <<<"$(apt-cache policy "$1" 2>/dev/null)" ;;
  dnf) [[ -n $(dnf -q repoquery "$1" 2>/dev/null) ]] ;;
  pacman) pacman -Si "$1" >/dev/null 2>&1 || pacman -Sg "$1" >/dev/null 2>&1 ;;
  zypper) zypper --non-interactive --quiet search --match-exact "$1" >/dev/null 2>&1 ;;
  *) return 1 ;;
  esac
}

# pkg_install NAME... — installs what is missing; names this distro doesn't
# carry are reported and skipped. Returns non-zero only if the install failed.
pkg_install() {
  local p missing=() unavailable=()
  for p in "$@"; do [[ -z $p ]] || pkg_installed "$p" || missing+=("$p"); done
  if [[ ${#missing[@]} -eq 0 ]]; then
    [[ -z ${*// /} ]] || skip "already installed: $*"
    return 0
  fi
  pkg_refresh || warn "package index refresh failed — trying anyway"
  local want=()
  for p in "${missing[@]}"; do
    if $DRY_RUN || pkg_available "$p"; then want+=("$p"); else unavailable+=("$p"); fi
  done
  [[ ${#unavailable[@]} -eq 0 ]] || warn "not available on $DISTRO_NAME, skipped: ${unavailable[*]}"
  [[ ${#want[@]} -gt 0 ]] || return 0
  log "installing: ${want[*]}"
  case "$PM" in
  apt) as_root "${APT_ENV[@]}" apt-get install -y -q --no-install-recommends "${want[@]}" ;;
  dnf) as_root dnf -y -q install --setopt=install_weak_deps=False "${want[@]}" ;;
  zypper) as_root zypper --non-interactive install --no-recommends "${want[@]}" ;;
  pacman)
    as_root pacman -S --needed --noconfirm "${want[@]}" || {
      err "pacman could not install ${want[*]} — if it reported 404s, your package database is stale."
      hint "update Arch first (never partially): sudo pacman -Syu   then re-run serverkit"
      return 1
    }
    ;;
  *)
    err "no supported package manager"
    return 1
    ;;
  esac
}

# pkg_install_for_cmds CMD:PKG... — install PKG only when CMD is missing.
# Avoids fights like Amazon Linux's curl-minimal vs curl.
pkg_install_for_cmds() {
  local pair want=()
  for pair in "$@"; do
    have "${pair%%:*}" || want+=("${pair#*:}")
  done
  [[ ${#want[@]} -eq 0 ]] || pkg_install "${want[@]}"
}

# ------------------------------------------------------------------------------
# Vendor repositories. Never added twice: if any existing source already points
# at the same host, that one is used (a second copy with a different signing
# key makes `apt update` fail outright).
# ------------------------------------------------------------------------------
repo_apt() { # name key_url "deb [signed-by=__KEY__] https://… suite component"
  local name="$1" key_url="$2" line="$3" host key tmp
  host=$(printf '%s' "$line" | grep -oE 'https://[^/ ]+' | head -n 1)
  if grep -Rqs --exclude="serverkit-$name.list" -F "$host" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    skip "a $host repository is already configured — using it"
    return 0
  fi
  tmp="$(sk_tmpdir)/key.$name"
  if ! $DRY_RUN; then
    fetch "$key_url" "$tmp" || {
      err "could not download the $name signing key"
      return 1
    }
  fi
  key="/etc/apt/keyrings/serverkit-$name.gpg"
  if $DRY_RUN || grep -q 'BEGIN PGP' <<<"$(head -c 40 "$tmp")"; then key="/etc/apt/keyrings/serverkit-$name.asc"; fi
  as_root install -d -m 0755 /etc/apt/keyrings || return 1
  as_root install -m 0644 "$tmp" "$key" || return 1
  safe_write "/etc/apt/sources.list.d/serverkit-$name.list" 0644 <<EOF
# $MARKER
${line//__KEY__/$key}
EOF
  rm -f "$RUN_DIR/.flag-pkg-refreshed" 2>/dev/null
  return 0
}

repo_rpm() { # name https://…/file.repo
  local name="$1" url="$2" host
  host=$(printf '%s' "$url" | grep -oE 'https://[^/]+')
  case "$PM" in
  dnf)
    if grep -RqsF "${host#https://}" /etc/yum.repos.d/; then
      skip "a ${host#https://} repository is already configured — using it"
      return 0
    fi
    local tmp
    tmp="$(sk_tmpdir)/$name.repo"
    $DRY_RUN || fetch "$url" "$tmp" || {
      err "could not download $url"
      return 1
    }
    as_root install -m 0644 "$tmp" "/etc/yum.repos.d/serverkit-$name.repo"
    ;;
  zypper)
    if grep -qF "${host#https://}" <<<"$(zypper --non-interactive lr -u 2>/dev/null)"; then
      skip "a ${host#https://} repository is already configured — using it"
      return 0
    fi
    as_root zypper --non-interactive addrepo --refresh "$url" &&
      as_root zypper --non-interactive --gpg-auto-import-keys refresh
    ;;
  *) return 1 ;;
  esac
}

# EPEL: extra packages (fail2ban, restic…) for RHEL, Rocky, Alma, CentOS, Oracle.
# Fedora doesn't need it; Amazon Linux 2023 doesn't support it.
ensure_epel() {
  case "$DISTRO_ID" in rhel | centos | rocky | almalinux | ol | eurolinux | circle | navy) ;; *) return 0 ;; esac
  pkg_installed epel-release && return 0
  pkg_installed oracle-epel-release-el"$VERSION_MAJOR" && return 0
  log "enabling EPEL (Extra Packages for Enterprise Linux)"
  case "$DISTRO_ID" in
  rhel) as_root dnf -y -q install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${VERSION_MAJOR}.noarch.rpm" ;;
  ol) as_root dnf -y -q install "oracle-epel-release-el${VERSION_MAJOR}" ;;
  *) as_root dnf -y -q install epel-release ;;
  esac
}

# ------------------------------------------------------------------------------
# Services (systemd). Without systemd (containers, some WSL) these report and
# return 1; callers treat that as "configured, not started".
# ------------------------------------------------------------------------------
svc_exists() { $HAS_SYSTEMD && grep -q . <<<"$(systemctl list-unit-files "${1%.service}.service" --no-legend 2>/dev/null)"; }
svc_active() { $HAS_SYSTEMD && systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { $HAS_SYSTEMD && systemctl is-enabled --quiet "$1" 2>/dev/null; }
# The real unit behind an alias (Debian: smartd -> smartmontools).
svc_id() { systemctl show -p Id --value "$1" 2>/dev/null; }

svc_enable() { # name... — enable at boot and start now
  if ! $HAS_SYSTEMD; then
    # Configured but not started: no systemd (a container, or WSL without it).
    hint "no systemd here, so $* won't start by itself — start it the way this system runs services"
    return 0
  fi
  as_root systemctl enable --now "$@"
}
svc_restart() { $HAS_SYSTEMD || return 0; as_root systemctl restart "$@"; }
svc_reload() { $HAS_SYSTEMD || return 0; as_root systemctl reload "$@" 2>/dev/null || as_root systemctl try-restart "$@"; }
daemon_reload() { $HAS_SYSTEMD || return 0; as_root systemctl daemon-reload; }
