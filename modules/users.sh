# shellcheck shell=bash
# ==============================================================================
#  users — a team group, one private directory per person, and a helper to
#  add people: serverkit-adduser <name> [public-key-file] [--docker]
# ==============================================================================

# For a fresh server where only root exists: Homebrew and per-user tools need a
# normal account, and logging in as root is best avoided anyway.
item_admin_user() {
  [[ $TARGET_USER == root ]] || { na "you already work as $TARGET_USER"; return; }
  [[ -n $ADMIN_USER ]] || { na "no name given (set ADMIN_USER)"; return; }
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "invalid user name: $ADMIN_USER"; return 1; }
  local u=$ADMIN_USER admins h
  admins=$(by_family debian=sudo default=wheel)
  if id "$u" >/dev/null 2>&1; then
    skip "user $u exists"
  else
    as_root useradd -m -U -s /bin/bash "$u" || return 1
  fi
  getent group "$admins" >/dev/null 2>&1 || as_root groupadd "$admins"
  in_group "$u" "$admins" || as_root usermod -aG "$admins" "$u" || return 1
  h=$(home_of "$u")
  $DRY_RUN && h=${h:-/home/$u}
  if as_root_q test -s /root/.ssh/authorized_keys || $DRY_RUN; then
    as_root install -d -m 0700 -o "$u" -g "$u" "$h/.ssh" &&
      as_root install -m 0600 -o "$u" -g "$u" /root/.ssh/authorized_keys "$h/.ssh/authorized_keys" || return 1
    ok "$u can log in with the same SSH key(s) as root"
  else
    hint "root has no SSH keys to copy — add yours to $h/.ssh/authorized_keys"
  fi
  # wheel/sudo membership only helps with a password (or a sudoers rule)
  hint "give $u a password for sudo:  passwd $u   — then log in as $u and run serverkit again for your own tools"
}

item_shared_users() {
  local g=$SHARED_GROUP
  if ! getent group "$g" >/dev/null 2>&1; then as_root groupadd "$g" || return 1; fi
  if [[ $TARGET_USER != root ]] && ! in_group "$TARGET_USER" "$g"; then
    as_root usermod -aG "$g" "$TARGET_USER" || return 1
    hint "log out and back in so group '$g' applies to $TARGET_USER"
  fi
  # setgid: files created inside stay owned by the group
  [[ -d $SHARED_ROOT ]] || as_root install -d -m 2775 -g "$g" "$SHARED_ROOT" || return 1

  local pw_note="Password login stays enabled — you will be asked to set one."
  [[ $SSH_PASSWORD_AUTH == no ]] && pw_note="SSH passwords are OFF here — give a public key file or they cannot log in."
  safe_write /usr/local/sbin/serverkit-adduser 0755 <<EOF
#!/usr/bin/env bash
# $MARKER
# serverkit-adduser <username> [public-key-file] [--docker]
# $pw_note
set -euo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
U="\${1:?usage: serverkit-adduser <username> [public-key-file] [--docker]}"; shift
[[ \$U =~ ^[a-z_][a-z0-9_-]{0,31}\$ ]] || { echo "invalid username: \$U" >&2; exit 1; }
KEY=""; DOCKER=false
for a in "\$@"; do
  case "\$a" in
    --docker) DOCKER=true ;;
    *) [ -f "\$a" ] && KEY="\$a" || { echo "no such key file: \$a" >&2; exit 1; } ;;
  esac
done
if id "\$U" >/dev/null 2>&1; then
  echo "= \$U already exists"
else
  useradd -m -U -s /bin/bash "\$U"
  chmod 0750 "/home/\$U"
  $([[ $SSH_PASSWORD_AUTH == no ]] && echo ': # passwords are off; key only' || echo 'passwd "$U"')
fi
usermod -aG $g "\$U"
if \$DOCKER; then usermod -aG docker "\$U"; echo "! \$U can use docker = root-equivalent"; fi
if [ -n "\$KEY" ]; then
  install -d -m 0700 -o "\$U" -g "\$U" "/home/\$U/.ssh"
  touch "/home/\$U/.ssh/authorized_keys"
  grep -qxF "\$(cat "\$KEY")" "/home/\$U/.ssh/authorized_keys" || cat "\$KEY" >>"/home/\$U/.ssh/authorized_keys"
  chown "\$U:\$U" "/home/\$U/.ssh/authorized_keys"; chmod 0600 "/home/\$U/.ssh/authorized_keys"
  echo "+ key installed"
fi
install -d -m 2750 -o "\$U" -g $g "$SHARED_ROOT/\$U"
echo "+ \$U ready: $SHARED_ROOT/\$U (theirs; the team can read it). They can set up their own tools with: serverkit"
EOF
  ok "group '$g', shared root $SHARED_ROOT, helper: sudo serverkit-adduser <name> [key.pub] [--docker]"
}
