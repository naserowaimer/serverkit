# shellcheck shell=bash
# ==============================================================================
#  containers — Docker (Linux engine / macOS via Colima) and k3s
# ==============================================================================

item_docker() {
  $IS_CONTAINER && { na "already inside a container — install Docker on the host"; return; }
  # The engine is dockerd; a lone `docker` command may be a CLI or Podman's shim.
  if have dockerd || [[ -x /usr/bin/dockerd ]]; then
    skip "Docker Engine present: $(docker --version 2>/dev/null)"
  elif have docker; then
    na "a 'docker' command exists without Docker Engine (Podman's shim?) — not installing over it"
    return
  else
    _docker_install || return 1
  fi

  local swarm=false
  grep -q active <<<"$(as_root_q docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" && swarm=true
  safe_write /etc/docker/daemon.json 0644 < <(
    echo "{"
    echo "  \"_comment\": \"$MARKER\","
    echo "  \"log-driver\": \"json-file\","
    echo "  \"log-opts\": { \"max-size\": \"$DOCKER_LOG_MAX_SIZE\", \"max-file\": \"$DOCKER_LOG_MAX_FILE\" },"
    [[ -n $DOCKER_ADDRESS_POOL ]] && echo "  \"default-address-pools\": [ { \"base\": \"$DOCKER_ADDRESS_POOL\", \"size\": 24 } ],"
    # live-restore keeps containers up across daemon restarts; Swarm forbids it
    if $swarm; then echo "  \"live-restore\": false"; else echo "  \"live-restore\": true"; fi
    echo "}"
  )
  local changed=$SW_CHANGED
  svc_enable docker || return 1
  if $changed && ! $DRY_RUN; then
    if [[ -n $(as_root_q docker ps -q 2>/dev/null) ]]; then
      svc_reload docker
      hint "Docker's daemon.json changed while containers were running — log settings apply after 'sudo systemctl restart docker' (briefly restarts them)"
    else
      svc_restart docker
    fi
  fi

  if [[ $DOCKER_GROUP_ADD == true && $TARGET_USER != root ]]; then
    if in_group "$TARGET_USER" docker; then
      skip "$TARGET_USER is already in the docker group"
    else
      as_root usermod -aG docker "$TARGET_USER" || return 1
      warn "$TARGET_USER can now run docker without sudo — the docker group is equivalent to root"
      hint "log out and back in so the docker group applies"
    fi
  fi
}

_docker_install() {
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  case "$FAMILY" in
  debian)
    local base cn
    read -r base cn <<<"$(debian_base)"
    if ! $DRY_RUN && ! fetch_stdout "https://download.docker.com/linux/$base/dists/$cn/Release" >/dev/null 2>&1; then
      err "Docker publishes no packages for $base '$cn' yet — nothing was changed"
      return 1
    fi
    repo_apt docker "https://download.docker.com/linux/$base/gpg" \
      "deb [arch=$ARCH signed-by=__KEY__] https://download.docker.com/linux/$base $cn stable" || return 1
    pkg_install "${pkgs[@]}"
    ;;
  rhel)
    case "$DISTRO_ID" in
    amzn)
      pkg_install docker || return 1
      hint "Amazon Linux's docker has no compose plugin — see https://docs.docker.com/compose/install/linux/"
      return 0
      ;;
    fedora) repo_rpm docker https://download.docker.com/linux/fedora/docker-ce.repo || return 1 ;;
    rhel) repo_rpm docker https://download.docker.com/linux/rhel/docker-ce.repo || return 1 ;;
    *) repo_rpm docker https://download.docker.com/linux/centos/docker-ce.repo || return 1 ;;
    esac
    pkg_install "${pkgs[@]}" || {
      hint "if dnf reported conflicts, remove podman-docker/runc yourself first (serverkit never removes packages)"
      return 1
    }
    ;;
  arch) pkg_install docker docker-compose docker-buildx ;;
  suse) pkg_install docker docker-compose docker-buildx ;;
  *) return 1 ;;
  esac
}

item_docker_mac() {
  brew_install colima docker docker-compose docker-buildx || return 1
  # Let the Docker CLI find Homebrew's compose/buildx plugins.
  local plugdir cfg="$TARGET_HOME/.docker/config.json"
  plugdir="$(brew_prefix)/lib/docker/cli-plugins"
  if [[ ! -e $cfg ]]; then
    safe_write "$cfg" 0600 <<EOF
{
  "_comment": "$MARKER",
  "cliPluginsExtraDirs": ["$plugdir"]
}
EOF
  elif ! grep -q cliPluginsExtraDirs "$cfg"; then
    hint "add \"cliPluginsExtraDirs\": [\"$plugdir\"] to $cfg so 'docker compose' works"
  fi
  hint "start the Docker VM with: colima start   (or at login: brew services start colima)"
}

item_k3s() {
  $IS_CONTAINER && { na "k3s needs a real machine or VM"; return; }
  $HAS_SYSTEMD || { na "k3s needs systemd"; return; }
  if have k3s; then
    skip "k3s present"
  else
    run_script https://get.k3s.io as_root INSTALL_K3S_EXEC="--write-kubeconfig-mode=0640" || return 1
  fi
  # Pods and services must be reachable through the host firewall.
  if svc_active firewalld; then
    as_root firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 >/dev/null &&
      as_root firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 >/dev/null &&
      as_root firewall-cmd --reload >/dev/null
  elif grep -q 'Status: active' <<<"$(as_root_q ufw status 2>/dev/null)"; then
    as_root ufw allow from 10.42.0.0/16 to any comment k3s-pods >/dev/null &&
      as_root ufw allow from 10.43.0.0/16 to any comment k3s-services >/dev/null
  fi
  # A private kubeconfig for the admin, so kubectl works without sudo.
  if [[ $TARGET_USER != root ]] && { $DRY_RUN || as_root_q test -f /etc/rancher/k3s/k3s.yaml; }; then
    if [[ -e $TARGET_HOME/.kube/config ]]; then
      skip "$TARGET_HOME/.kube/config exists — not replaced"
    else
      as_user mkdir -p "$TARGET_HOME/.kube" &&
        as_root install -m 0600 -o "$TARGET_USER" /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config" &&
        ok "kubeconfig -> ~/.kube/config"
    fi
  fi
}
