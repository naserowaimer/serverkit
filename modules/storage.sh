# shellcheck shell=bash
# ==============================================================================
#  storage — disk health, ZFS snapshots/scrub, restic backups
# ==============================================================================

item_disk_health() {
  { $IS_CONTAINER || $IS_VM; } && { na "virtual machine — the host watches the physical disks"; return; }
  $HAS_SYSTEMD || { na "needs systemd"; return; }
  pkg_install smartmontools || return 1

  # Our own config file, wired in with a systemd drop-in: the distro's
  # smartd.conf is never edited.
  local mail="" smartd unit
  have sendmail && mail=" -m root"
  safe_write /etc/serverkit/smartd.conf 0644 <<EOF
# $MARKER
# All disks: health, attributes, errors; short self-test nightly at 02:00,
# long self-test Saturdays at 03:00; warn at 45°C, critical at 55°C.
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,45,55$mail
EOF
  local conf_changed=$SW_CHANGED
  smartd=$(command -v smartd || echo /usr/sbin/smartd)
  if ! $DRY_RUN && ! as_root "$smartd" -q showtests -c /etc/serverkit/smartd.conf >/dev/null 2>&1; then
    restore_file /etc/serverkit/smartd.conf
    err "smartd rejected the configuration — rolled back"
    return 1
  fi
  unit=$(svc_id smartd)
  [[ -n $unit && $unit != smartd.service ]] || unit=$(svc_id smartmontools)
  [[ -n $unit ]] || unit=smartd.service
  safe_write "/etc/systemd/system/${unit}.d/serverkit.conf" 0644 <<EOF
# $MARKER — run smartd with serverkit's config
[Service]
ExecStart=
ExecStart=$smartd -n -q never -c /etc/serverkit/smartd.conf
EOF
  if $SW_CHANGED || $conf_changed; then daemon_reload && svc_enable "$unit" && svc_restart "$unit"; else svc_enable "$unit"; fi

  if grep -q '^md' /proc/mdstat 2>/dev/null; then
    pkg_install mdadm || return 1
    local mconf
    mconf=$(by_family debian=/etc/mdadm/mdadm.conf default=/etc/mdadm.conf)
    if grep -qE '^(MAILADDR|PROGRAM)' <<<"$(_read "$mconf")"; then
      svc_enable mdmonitor 2>/dev/null || true
    else
      hint "RAID found: add 'MAILADDR you@example.com' (or PROGRAM) to $mconf so a failing disk gets reported"
    fi
  fi
  hint "disk health: 'serverkit health' shows SMART status; failures are logged to the journal (journalctl -u $unit)"
}

item_zfs_care() {
  have zpool || { na "ZFS isn't installed$([[ $DISTRO_ID == ubuntu ]] && echo " (Ubuntu: sudo apt install zfsutils-linux)")"; return; }
  $HAS_SYSTEMD || { na "needs systemd"; return; }
  local pools="$ZFS_POOLS"
  [[ -n $pools ]] || pools=$(zpool list -H -o name 2>/dev/null | tr '\n' ' ')
  [[ -n ${pools// /} ]] || { na "no ZFS pools imported"; return; }

  if have zfs-auto-snapshot || have sanoid; then
    skip "zfs-auto-snapshot/sanoid already manages snapshots — ours not added"
  else
    # Only snapshots named @serverkit-* are ever pruned; yours are never touched.
    safe_write /usr/local/sbin/serverkit-zfs-snap 0755 <<EOF
#!/usr/bin/env bash
# $MARKER — hourly snapshots; keeps the newest \$1 serverkit-* per dataset
set -uo pipefail
KEEP="\${1:-$ZFS_SNAP_KEEP}"
TAG="serverkit-\$(date +%Y%m%d-%H%M)"
for pool in $pools; do
  for ds in \$(zfs list -H -o name -r "\$pool"); do
    zfs snapshot "\${ds}@\${TAG}" || continue
    zfs list -H -t snapshot -o name -s creation -d 1 "\$ds" | grep -F "\${ds}@serverkit-" |
      head -n -"\$KEEP" | while read -r s; do zfs destroy "\$s"; done
  done
done
EOF
    safe_write /etc/systemd/system/serverkit-zfs-snap.service 0644 <<EOF
# $MARKER
[Unit]
Description=Rolling ZFS snapshots ($pools)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/serverkit-zfs-snap $ZFS_SNAP_KEEP
EOF
    safe_write /etc/systemd/system/serverkit-zfs-snap.timer 0644 <<EOF
# $MARKER
[Unit]
Description=Hourly ZFS snapshots
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF
    daemon_reload && svc_enable serverkit-zfs-snap.timer || return 1
    ok "hourly snapshots of $pools, newest $ZFS_SNAP_KEEP kept"
  fi

  if [[ -e /etc/cron.d/zfsutils-linux ]] || grep -q . <<<"$(systemctl list-unit-files 'zfs-scrub-monthly@*' --no-legend 2>/dev/null)"; then
    skip "your ZFS packages already schedule scrubs"
  else
    safe_write /etc/systemd/system/serverkit-zfs-scrub.service 0644 <<EOF
# $MARKER
[Unit]
Description=ZFS scrub ($pools)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for p in $pools; do zpool scrub "\$p"; done'
EOF
    safe_write /etc/systemd/system/serverkit-zfs-scrub.timer 0644 <<EOF
# $MARKER
[Unit]
Description=Monthly ZFS scrub
[Timer]
OnCalendar=monthly
Persistent=true
[Install]
WantedBy=timers.target
EOF
    daemon_reload && svc_enable serverkit-zfs-scrub.timer || return 1
  fi
}

item_backups() {
  $HAS_SYSTEMD || { na "needs systemd for the backup timer"; return; }
  ensure_epel || true
  pkg_install restic || return 1
  have restic || $DRY_RUN || { err "restic is not available on $DISTRO_NAME"; return 1; }
  local env=/etc/serverkit/restic.env
  safe_write /usr/local/sbin/serverkit-backup 0755 <<EOF
#!/usr/bin/env bash
# $MARKER — restic backup + prune. Repository and password live in $env
set -euo pipefail
set -a; . $env; set +a
restic backup $BACKUP_PATHS --exclude-caches --exclude='/home/*/.cache'
restic forget --prune $BACKUP_KEEP
EOF
  safe_write /etc/systemd/system/serverkit-backup.service 0644 <<EOF
# $MARKER
[Unit]
Description=restic backup
ConditionPathExists=$env
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/serverkit-backup
EOF
  safe_write /etc/systemd/system/serverkit-backup.timer 0644 <<EOF
# $MARKER
[Unit]
Description=restic backup ($BACKUP_ONCALENDAR)
[Timer]
OnCalendar=$BACKUP_ONCALENDAR
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  daemon_reload && svc_enable serverkit-backup.timer || return 1
  if as_root_q test -f "$env"; then
    ok "backups run $BACKUP_ONCALENDAR: $BACKUP_PATHS"
  else
    hint "backups are installed but off until you create $env — see 'serverkit info backups'"
  fi
}
