#!/bin/sh
# Runs inside a fresh distro container (as root), with the repo at /sk (read-only).
# Prepares what a real machine has (sudo, a normal user), then drives serverkit
# as that user.  PHASE=quick: detection, catalog, dry runs, package-name probe.
#                PHASE=full:  also real installs, twice (the 2nd must change nothing).
#                PHASE=root:  a root-only machine (no sudo, no other user): real
#                             installs as root; Homebrew runs as the hidden
#                             linuxbrew account, the tools are set up for root.
set -eu
PHASE=${PHASE:-quick}
SUDO=sudo
[ "$PHASE" = root ] && SUDO=
. /etc/os-release
step() { printf '\n=== %s\n' "$*"; }

step "prepare $PRETTY_NAME"
case " $ID ${ID_LIKE:-} " in
*" debian "* | *" ubuntu "*)
  apt-get update -qq || { sleep 10; apt-get update -qq; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $SUDO curl ca-certificates procps >/dev/null
  ;;
*" fedora "* | *" rhel "* | *" centos "* | *" amzn "*)
  dnf -y -q install $SUDO procps-ng findutils shadow-utils util-linux >/dev/null
  command -v curl >/dev/null || dnf -y -q install curl >/dev/null
  case $ID in rocky | almalinux | centos | ol) dnf -y -q install epel-release >/dev/null ;; esac
  dnf -q makecache >/dev/null
  ;;
*" arch "*)
  pacman -Syu --noconfirm --needed $SUDO curl >/dev/null
  ;;
*" suse "* | *" opensuse "*)
  # mirrors hiccup now and then: retry, and carry on with what refreshed
  zypper -n -q refresh >/dev/null 2>&1 || { sleep 10; zypper -n -q refresh >/dev/null 2>&1; } || true
  zypper -n -q install $SUDO curl gzip tar >/dev/null
  ;;
esac

if [ "$PHASE" = root ]; then
  ITEMS=${ITEMS:-"essentials ripgrep jq starship zsh-setup tmux-config ssh-autotmux git-defaults lazyvim"}
  cp -r /sk /root/serverkit
  cd /root/serverkit
  step "doctor (as root)"
  ./serverkit doctor --yes | tee /tmp/doctor.log
  grep -q 'runs as the linuxbrew account' /tmp/doctor.log
  step "dry run as root: Homebrew items are offered"
  ./serverkit apply --profile personal --dry-run --yes >/tmp/dry.log 2>&1 || { cat /tmp/dry.log; exit 1; }
  if grep -q "can't run as root\|✗" /tmp/dry.log; then cat /tmp/dry.log; exit 1; fi
  step "real install as root: $ITEMS"
  ./serverkit install $ITEMS --yes --plain || { find /root/.local/state/serverkit/runs -name serverkit.log -exec tail -n 80 {} \;; exit 1; }
  step "second run must change nothing"
  ./serverkit install $ITEMS --yes --plain --verbose >/tmp/second.log 2>&1 || { cat /tmp/second.log; exit 1; }
  if grep -E '(created|updated): ' /tmp/second.log; then echo "!! second run changed files"; exit 1; fi
  step "linuxbrew: a hidden account that owns Homebrew"
  getent passwd linuxbrew
  case $(getent passwd linuxbrew | cut -d: -f7) in */nologin | */false) ;; *) echo "!! linuxbrew has a login shell"; exit 1 ;; esac
  case $(getent shadow linuxbrew | cut -d: -f2) in '!'* | '*'*) ;; *) echo "!! linuxbrew has a usable password"; exit 1 ;; esac
  [ "$(stat -c %U /home/linuxbrew/.linuxbrew)" = linuxbrew ] || { echo "!! prefix not owned by linuxbrew"; exit 1; }
  if [ -n "$(find /home/linuxbrew -user root -print -quit)" ]; then echo "!! root wrote inside Homebrew:"; find /home/linuxbrew -user root | head; exit 1; fi
  step "root's shells find the tools"
  bash -ic 'rg --version && jq --version && starship --version' </dev/null
  zsh -lic 'rg --version && command -v nvim' </dev/null
  case $(getent passwd root | cut -d: -f7) in */zsh) ;; *) echo "!! root's login shell is not zsh"; exit 1 ;; esac
  [ "$(git config --global init.defaultBranch)" = main ]
  [ -f /root/.config/nvim/init.lua ]
  step "root phase passed"
  exit 0
fi

useradd -m -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/tester
chmod 0440 /etc/sudoers.d/tester
cp -r /sk /home/tester/serverkit
chown -R tester /home/tester/serverkit
as_tester() { su - tester -c "cd ~/serverkit && $*"; }

step doctor
as_tester './serverkit doctor --yes'
step "list"
as_tester './serverkit list >/dev/null && ./serverkit list --json >/tmp/catalog.json && ./serverkit profiles >/dev/null'
step "package names"
as_tester 'bash tests/distro/pkgprobe.bash'
for p in personal apps desktop minimal; do
  step "dry run: $p"
  as_tester "./serverkit apply --profile $p --dry-run --yes >/tmp/dry-$p.log 2>&1" || { cat "/tmp/dry-$p.log"; exit 1; }
  if grep -q 'failed — details\|✗' "/tmp/dry-$p.log"; then cat "/tmp/dry-$p.log"; exit 1; fi
done

[ "$PHASE" = full ] || { step "quick phase passed"; exit 0; }

ITEMS=${ITEMS:-"essentials fail2ban auto-updates nginx backups sqlite mosh wireguard mtr podman shared-users git-defaults"}
step "real install: $ITEMS"
as_tester "./serverkit install $ITEMS --yes --plain" || { find /home/tester/.local/state/serverkit/runs -name serverkit.log -exec tail -n 60 {} \;; exit 1; }
step "second run must change nothing"
as_tester "./serverkit install $ITEMS --yes --plain --verbose" >/tmp/second.log 2>&1 || { cat /tmp/second.log; exit 1; }
if grep -E '(created|updated): ' /tmp/second.log; then echo "!! second run changed files"; exit 1; fi
step "files serverkit wrote"
cat /home/tester/.local/state/serverkit/managed.list
step "full phase passed"
