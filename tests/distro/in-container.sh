#!/bin/sh
# Runs inside a fresh distro container (as root), with the repo at /sk (read-only).
# Prepares what a real machine has (sudo, a normal user), then drives serverkit
# as that user.  PHASE=quick: detection, catalog, dry runs, package-name probe.
#                PHASE=full:  also real installs, twice (the 2nd must change nothing).
set -eu
PHASE=${PHASE:-quick}
. /etc/os-release
step() { printf '\n=== %s\n' "$*"; }

step "prepare $PRETTY_NAME"
case " $ID ${ID_LIKE:-} " in
*" debian "* | *" ubuntu "*)
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo curl ca-certificates procps >/dev/null
  ;;
*" fedora "* | *" rhel "* | *" centos "* | *" amzn "*)
  dnf -y -q install sudo procps-ng findutils shadow-utils util-linux >/dev/null
  command -v curl >/dev/null || dnf -y -q install curl >/dev/null
  case $ID in rocky | almalinux | centos | ol) dnf -y -q install epel-release >/dev/null ;; esac
  dnf -q makecache >/dev/null
  ;;
*" arch "*)
  pacman -Syu --noconfirm --needed sudo curl >/dev/null
  ;;
*" suse "* | *" opensuse "*)
  zypper -n -q refresh >/dev/null
  zypper -n -q install sudo curl gzip tar >/dev/null
  ;;
esac
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
