# shellcheck shell=bash
# ==============================================================================
#  platform — what are we running on?
#
#  OS         linux | mac
#  FAMILY     debian | rhel | arch | suse | mac | unknown
#  PM         apt | dnf | pacman | zypper | brew | none
#  DISTRO_ID  os-release ID (ubuntu, rocky, manjaro…) or "macos"
#  ARCH       amd64 | arm64 | …            UNAME_ARCH  x86_64 | arm64 | …
#  flags      HAS_SYSTEMD IS_CONTAINER IS_WSL IS_VM IS_IMMUTABLE IS_MUSL
# ==============================================================================

OS="" FAMILY="unknown" PM="none" DISTRO_ID="" DISTRO_LIKE="" DISTRO_NAME=""
DISTRO_VERSION="" VERSION_MAJOR="" CODENAME="" UBUNTU_CODENAME=""
ARCH="" UNAME_ARCH=""
HAS_SYSTEMD=false IS_CONTAINER=false IS_WSL=false IS_VM=false IS_IMMUTABLE=false IS_MUSL=false

# Map an os-release ID or ID_LIKE word to a family.
_family_of() {
  case "$1" in
  debian | ubuntu | raspbian | linuxmint | pop | elementary | zorin | kali | neon | pureos | \
    deepin | mx | parrot | peppermint | tuxedo | pika | lmde) echo debian ;;
  fedora | rhel | centos | rocky | almalinux | ol | amzn | nobara | ultramarine | eurolinux | \
    circle | navy | miraclelinux) echo rhel ;;
  arch | manjaro | endeavouros | garuda | cachyos | arcolinux | archarm | manjaro-arm | biglinux) echo arch ;;
  opensuse* | sles | sled | suse | sle-micro) echo suse ;;
  *) echo "" ;;
  esac
}

detect_platform() {
  local m
  m=$(uname -m)
  case "$m" in
  x86_64 | amd64) ARCH=amd64 UNAME_ARCH=x86_64 ;;
  aarch64 | arm64) ARCH=arm64 UNAME_ARCH=arm64 ;;
  armv7l | armv7*) ARCH=armhf UNAME_ARCH=armv7 ;;
  *) ARCH=$m UNAME_ARCH=$m ;;
  esac

  if [[ $(uname -s) == Darwin ]]; then
    OS=mac FAMILY=mac PM=brew DISTRO_ID=macos
    DISTRO_VERSION=$(sw_vers -productVersion 2>/dev/null)
    VERSION_MAJOR=${DISTRO_VERSION%%.*}
    DISTRO_NAME="macOS $DISTRO_VERSION"
    grep -q 1 <<<"$(sysctl -n kern.hv_vmm_present 2>/dev/null)" && IS_VM=true
    return 0
  fi

  OS=linux
  local osr=${SK_OS_RELEASE:-/etc/os-release} # overridable for tests
  if [[ -r $osr ]]; then
    # Read in a subshell: os-release defines NAME, VERSION… which must not leak.
    local fields
    fields=$(
      # shellcheck disable=SC1091
      . "$osr"
      printf '%s\n' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-${NAME:-Linux}}" \
        "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${UBUNTU_CODENAME:-}" end
    )
    {
      read -r DISTRO_ID
      read -r DISTRO_LIKE
      read -r DISTRO_NAME
      read -r DISTRO_VERSION
      read -r CODENAME
      read -r UBUNTU_CODENAME
    } <<<"$fields"
  fi
  VERSION_MAJOR=${DISTRO_VERSION%%.*}

  local w f
  FAMILY=$(_family_of "$DISTRO_ID")
  if [[ -z $FAMILY ]]; then
    for w in $DISTRO_LIKE; do
      f=$(_family_of "$w")
      [[ -n $f ]] && {
        FAMILY=$f
        break
      }
    done
  fi
  [[ -n $FAMILY ]] || FAMILY=unknown
  case "$FAMILY" in
  debian) have apt-get && PM=apt ;;
  rhel) have dnf && PM=dnf ;; # yum-only systems (EL7) are end-of-life: unsupported
  arch) have pacman && PM=pacman ;;
  suse) have zypper && PM=zypper ;;
  esac
  [[ $PM == none && $FAMILY != unknown ]] && FAMILY=unknown

  [[ -d /run/systemd/system ]] && HAS_SYSTEMD=true
  if [[ -f /.dockerenv || -f /run/.containerenv ]] || { have systemd-detect-virt && systemd-detect-virt -cq 2>/dev/null; }; then
    IS_CONTAINER=true
  fi
  if have systemd-detect-virt && systemd-detect-virt -vq 2>/dev/null; then IS_VM=true; fi
  grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && IS_WSL=true
  # Image-based systems (Silverblue, Bazzite, MicroOS, SteamOS…): /usr is read-only
  # and packages go through rpm-ostree / transactional-update, not dnf/zypper.
  if [[ -e /run/ostree-booted ]] || have transactional-update || [[ $DISTRO_ID == steamos ]]; then
    IS_IMMUTABLE=true
  fi
  if grep -qi musl <<<"$(ldd --version 2>&1)"; then IS_MUSL=true; fi
  return 0
}

# Debian-family codename for vendor repos (docker…), resolving derivatives:
# Mint/Pop/Zorin -> their Ubuntu base; Proxmox/MX/Kali -> their Debian base.
debian_base() { # prints "ubuntu CODENAME" or "debian CODENAME"
  if [[ $DISTRO_ID == ubuntu || -n $UBUNTU_CODENAME ]]; then
    echo "ubuntu ${UBUNTU_CODENAME:-$CODENAME}"
    return
  fi
  local cn="" v
  [[ $DISTRO_ID == debian ]] && cn=$CODENAME
  if [[ -z $cn && -r /etc/debian_version ]]; then
    v=$(cut -d. -f1 /etc/debian_version)
    case "$v" in
    11) cn=bullseye ;; 12) cn=bookworm ;; 13) cn=trixie ;; 14) cn=forky ;;
    *) cn=${v%%/*} ;; # "trixie/sid" on testing
    esac
  fi
  echo "debian $cn"
}

# by_family debian=X rhel=Y arch=Z suse=W mac=V default=D  -> value for this machine
by_family() {
  local kv def=""
  for kv in "$@"; do
    case "$kv" in
    "$FAMILY="*) printf '%s' "${kv#*=}" && return 0 ;;
    default=*) def=${kv#*=} ;;
    esac
  done
  printf '%s' "$def"
}

# System packages can be managed here (not on image-based or unknown distros).
system_supported() {
  [[ $OS == mac ]] && return 0
  [[ $FAMILY != unknown && $IS_IMMUTABLE == false ]]
}

# Homebrew runs on macOS and on glibc Linux (x86_64, arm64), never as root.
brew_supported() {
  [[ $TARGET_USER != root ]] || return 1
  [[ $OS == mac ]] && return 0
  [[ $IS_MUSL == false && ($ARCH == amd64 || $ARCH == arm64) ]]
}

platform_line() {
  local bits=("$DISTRO_NAME")
  [[ $PM != none ]] && bits+=("$PM")
  $HAS_SYSTEMD && bits+=(systemd)
  bits+=("$ARCH")
  $IS_CONTAINER && bits+=(container)
  $IS_WSL && bits+=(WSL)
  $IS_VM && ! $IS_CONTAINER && bits+=(VM)
  $IS_IMMUTABLE && bits+=(immutable)
  local out="" b
  for b in "${bits[@]}"; do out+="${out:+ · }$b"; done
  printf '%s' "$out"
}
