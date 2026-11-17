#!/bin/sh
# Runs inside a fresh distro container (as root), with the repo at /sk (read-only).
# Prepares what a real machine has (sudo, a normal user), then drives serverkit
# as that user.  PHASE=quick: detection, catalog, dry runs, package-name probe.
#                PHASE=full:  also real installs, twice (the 2nd must change nothing).
#                PHASE=tmux:  tmux-config on a tmux server that's already running.
set -eu
PHASE=${PHASE:-quick}
. /etc/os-release
step() { printf '\n=== %s\n' "$*"; }

step "prepare $PRETTY_NAME"
case " $ID ${ID_LIKE:-} " in
*" debian "* | *" ubuntu "*)
  apt-get update -qq || { sleep 10; apt-get update -qq; }
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
  # mirrors hiccup now and then: retry, and carry on with what refreshed
  zypper -n -q refresh >/dev/null 2>&1 || { sleep 10; zypper -n -q refresh >/dev/null 2>&1; } || true
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

if [ "$PHASE" = tmux ]; then
  # A tmux that's been running for a while, with a hand-made config that
  # already runs tpm (never installed), like the one this was written for.
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux git >/dev/null
  cat >/home/tester/.tmux.conf <<'EOF'
set -g mouse on
set -g status-right "%H:%M"
source-file -q ~/agentdeck/agentdeck.conf   # agentdeck
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
# Initialize TMUX plugin manager (keep this line at the very bottom)
run '~/.tmux/plugins/tpm/tpm'
EOF
  chown tester /home/tester/.tmux.conf
  as_tester 'tmux new -d -s main -c /tmp "sleep 100000" && tmux new-window -t main -c /var "sleep 100000"'
  before=$(as_tester 'tmux display -p "#{pid}"; tmux list-panes -a -F "#{pane_id} #{pane_pid}"')
  sleep 11 # older than continuum's "just started" window
  step "tmux-config on the live server"
  as_tester "./serverkit install essentials homebrew tmux-config --yes --plain" || { find /home/tester/.local/state/serverkit/runs -name serverkit.log -exec tail -n 60 {} \;; exit 1; }
  after=$(as_tester 'tmux display -p "#{pid}"; tmux list-panes -a -F "#{pane_id} #{pane_pid}"')
  [ "$before" = "$after" ] || { echo "!! tmux server or panes changed"; echo "$before"; echo "$after"; exit 1; }
  as_tester 'tmux show -gv status-right' | grep -q continuum_save || { echo "!! autosave hook missing"; exit 1; }
  [ -e /home/tester/.local/share/tmux/resurrect/last ] || { echo "!! no first save"; exit 1; }
  [ "$(stat -c %a /home/tester/.local/share/tmux/resurrect)" = 700 ] || { echo "!! save folder is not private"; exit 1; }
  grep -q 'agentdeck.conf' /home/tester/.tmux.conf || { echo "!! lost a line of the user's config"; exit 1; }
  ! grep -q 'serverkit:plugins' /home/tester/.tmux.conf || { echo "!! second tpm run line"; exit 1; }
  [ "$(head -n 1 /home/tester/.tmux.conf)" = "# >>> serverkit:serverkit >>>" ] ||
    { echo "!! serverkit block isn't first (your settings must override it)"; cat /home/tester/.tmux.conf; exit 1; }
  ls /home/tester/.tmux.conf.bak.* >/dev/null || { echo "!! no backup of ~/.tmux.conf"; exit 1; }
  cat /home/tester/.tmux.conf
  step "second run must change nothing"
  as_tester "./serverkit install tmux-config --yes --plain --verbose" >/tmp/second.log 2>&1 || { cat /tmp/second.log; exit 1; }
  if grep -E '(created|updated): ' /tmp/second.log; then echo "!! second run changed files"; exit 1; fi
  step "health"
  as_tester './serverkit health' | sed -n '/── tmux/,/last save/p' | tee /tmp/health.log
  grep -q 'autosave *on' /tmp/health.log || exit 1
  step "a new tmux server restores the sessions, with autosave on"
  as_tester 'tmux kill-server; sleep 1; tmux new -d -s scratch; sleep 8; tmux ls'
  as_tester 'tmux list-windows -t main -F "#{pane_current_path}"' | grep -qx /var || { echo "!! session main was not restored"; exit 1; }
  as_tester 'tmux show -gv status-right' | grep -q continuum_save || { echo "!! autosave off after a fresh start"; exit 1; }
  as_tester 'tmux show -gv status-right' | grep -q '%H:%M"\{0,1\}$' || { echo "!! the user's own status-right was overridden"; exit 1; }
  step "tmux phase passed"
  exit 0
fi

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
