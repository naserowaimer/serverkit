# Security

serverkit changes system configuration, so it is built to be predictable,
reversible and reviewable. This page says exactly what it trusts and changes.

## Reporting a vulnerability

Please report privately via GitHub's **Report a vulnerability** (Security tab)
rather than a public issue. You'll get a reply within a few days.

## What it trusts

| Source | How it's fetched | Verification |
|---|---|---|
| serverkit itself | git clone / tarball from this repository over HTTPS | pin a release: `SERVERKIT_VERSION=v0.1.0` |
| gum (terminal UI) | GitHub release, fixed version | SHA-256 stored in `lib/ui.sh` must match |
| Homebrew | official installer from `github.com/Homebrew/install` | HTTPS; Homebrew verifies its own bottles |
| Docker Engine | Docker's apt/rpm repositories | vendor signing key (apt `signed-by`, rpm gpgcheck) |
| cloudflared | Cloudflare's apt/rpm repositories | vendor signing key |
| Tailscale, k3s, code-server, rustup, Claude Code | each vendor's official install script | HTTPS; saved to a private temp dir, then run |
| JetBrains Mono Nerd Font | GitHub release | SHA-256 from the release's `SHA-256.txt` |
| Flathub apps | `flatpak install --user` | Flatpak's own signature checks |
| Distro packages | apt / dnf / pacman / zypper | the distro's signing keys |

On openSUSE, a vendor `.repo` is added with `--gpg-auto-import-keys` (trust on
first use, over HTTPS). Remote scripts are never piped into a shell; `--dry-run`
lists every download it would run.

## What it changes

Only what you select, and only these places:

- **Your home:** `~/.config/serverkit/` (its config), marked blocks in
  `~/.zshrc`, `~/.bashrc`/`~/.bash_profile`, `~/.zprofile`, `~/.tmux.conf`;
  `~/.local/state/serverkit/` (logs); `~/.local/share/serverkit/` (gum).
- **System (with sudo):** files it names `serverkit` — `/etc/ssh/sshd_config.d/10-serverkit.conf`,
  `/etc/fail2ban/jail.d/serverkit.local`, `/etc/sysctl.d/60-serverkit-hardening.conf`,
  `/etc/nginx/conf.d/00-serverkit-*.conf`, `/etc/apt/apt.conf.d/*serverkit*`,
  `/etc/systemd/system/serverkit-*`, `/etc/serverkit/`, `/usr/local/sbin/serverkit-*` —
  plus `/etc/docker/daemon.json` if absent, and packages/services you chose.

Every file it writes carries `managed-by:serverkit`; a file without that marker
is never modified (serverkit writes `file.new` beside it instead). Each run's
log is in `~/.local/state/serverkit/runs/`, and `serverkit status` lists files
waiting for your review.

## Guarantees against lock-out and outages

- Firewall rules always include every sshd port and the current SSH session's
  port, and are set up *before* the firewall is enabled (firewalld: offline).
- `sshd -t`, `nginx -t`, `fail2ban-client -t` and smartd's parser validate new
  config before reload; on failure the change is rolled back automatically.
- SSH password login is only disabled when you ask and your user has an
  authorized key; `PermitRootLogin prohibit-password` only when root has a key
  or you're a sudoer.
- Docker's daemon is not restarted while containers run.
- The `docker` group is root-equivalent; serverkit says so when it adds you.
