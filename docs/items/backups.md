Backups are installed but stay **off** until you tell restic where to store them:

    openssl rand -hex 32 | sudo tee /root/.restic-pass >/dev/null
    sudo chmod 600 /root/.restic-pass
    sudo tee /etc/serverkit/restic.env >/dev/null <<'ENV'
    RESTIC_REPOSITORY=sftp:user@other-host:/backups/this-host
    RESTIC_PASSWORD_FILE=/root/.restic-pass
    ENV
    sudo chmod 600 /etc/serverkit/restic.env
    sudo sh -c 'set -a; . /etc/serverkit/restic.env; restic init'
    sudo systemctl start serverkit-backup      # first backup now

RESTIC_REPOSITORY can also be `s3:…`, `b2:…`, `rclone:…` or a local path.
Keep a copy of the password somewhere else: without it the backups can't be read.
Paths and retention: BACKUP_PATHS, BACKUP_KEEP, BACKUP_ONCALENDAR (serverkit config).
