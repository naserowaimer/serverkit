# serverkit

Set up a server, home lab or workstation in one interactive run — safely, on
almost any Linux and on macOS.

```sh
curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh
```

It asks what the machine is for, preselects a sensible set of tools, lets you
change anything, shows exactly what it will do, and only then does it.

```
╭──────────────────────────────────────────────────────────╮
│ serverkit 0.1.0                                          │
│ Ubuntu 24.04 LTS · apt · systemd · amd64 — setting up ada │
╰──────────────────────────────────────────────────────────╯
What is this machine?
❯ personal  home server / dev box: security, Docker, remote access, ZFS, backups
  apps      multi-user live apps server: hardened, resource caps, nginx + tunnel
  desktop   laptop / workstation: terminal, editors, dev tools, apps
  minimal   just a good shell and everyday CLI tools
  custom    start from nothing and pick items yourself
```

## What it can set up

About 140 items in 15 groups — run `serverkit list` to see what your machine offers:

| Group | Examples |
|---|---|
| Security | firewall (ufw / firewalld / macOS), SSH hardening, fail2ban, automatic security updates, kernel hardening, per-user resource caps |
| Containers | Docker Engine + Compose (Colima on macOS), Podman, k3s, kubectl, Helm, k9s |
| Remote access | Tailscale, Cloudflare Tunnel, code-server, mosh, WireGuard |
| Web hosting | nginx with a safe catch-all |
| Storage | disk health (SMART + RAID), ZFS snapshots & scrub, restic backups, rclone |
| Users | team group, per-user directories, `serverkit-adduser` |
| Languages | mise (Node, Python, Go), Rust, uv, Bun, Deno, pnpm |
| Shell | zsh setup, Starship, tmux config, SSH auto-tmux, LazyVim, Nerd Font, atuin, zoxide |
| CLI essentials | ripgrep, fd, bat, fzf, eza, jq, btop, lazygit, delta, … |
| Dev & cloud | GitHub/GitLab CLIs, pre-commit, AWS/Azure/GCP CLIs, OpenTofu, Ansible |
| Databases | psql, pgcli, mycli, litecli, sqlite (clients only) |
| AI agents | Claude Code, opencode, aider, Codex, Gemini CLI, Copilot CLI |
| Desktop apps | VS Code, Zed, Ghostty, browsers, Obsidian, Slack… (Homebrew casks on macOS, Flathub on Linux) |

## Where it runs

| Platform | System items | Your tools |
|---|---|---|
| Debian, Ubuntu and derivatives (Mint, Pop!_OS, Zorin, elementary, Kali, Proxmox, Raspberry Pi OS…) | apt | Homebrew |
| Fedora, RHEL, Rocky, Alma, CentOS Stream, Oracle, Amazon Linux 2023 | dnf (+ EPEL where needed) | Homebrew |
| Arch, Manjaro, EndeavourOS, Garuda, CachyOS | pacman | Homebrew |
| openSUSE Leap / Tumbleweed, SLES | zypper | Homebrew |
| macOS 13+ (Apple silicon and Intel) | macOS firewall | Homebrew + casks |
| Image-based (Silverblue, Bazzite, MicroOS…), other glibc Linux | — | Homebrew + Flathub |

**Homebrew is the source of everyday tools on every platform**, so the same
names and versions land everywhere. The native package manager is used only for
system pieces (firewall, sshd, fail2ban, nginx, Docker Engine). Homebrew never
runs as root; run serverkit as your normal user and it asks for sudo once, only
if something needs it.

## Safety — what it will never do

- **Never overwrite a file it didn't write.** Your version is kept; serverkit's
  lands beside it as `file.new` and is listed at the end (`--force` adopts it,
  keeping a `.bak`).
- **Never edit your dotfiles.** Its config lives in `~/.config/serverkit/`; your
  `~/.zshrc` gets one marked line that sources it — delete the block and it's gone.
- **Never lock you out.** The firewall always admits every port sshd listens on
  and the one you're connected through; SSH changes are checked with `sshd -t`
  and rolled back if rejected; password login is only switched off when a key
  login already exists; `PermitRootLogin` is only tightened when root has a key
  or you have sudo.
- **Never take a running service down.** nginx, sshd, fail2ban and smartd
  configs are validated before reload and rolled back on failure; Docker is
  never restarted while containers run.
- **Never remove packages**, never partially upgrade Arch, never add a package
  repository twice.
- **Never pipe the internet into a shell.** Official installers are downloaded
  over HTTPS, saved, then run; `--dry-run` shows each one. The UI helper (gum)
  is pinned and checked against a SHA-256 in this repository.
- **Settings are parsed, never executed.**

Every step is idempotent: run it again any time; the second run changes nothing.
See [SECURITY.md](SECURITY.md) for the full trust model.

## Usage

```sh
serverkit                                   # interactive
serverkit apply --profile apps --dry-run    # preview exactly what would change
serverkit apply --profile apps              # do it
serverkit install docker tailscale lazygit  # just these (plus what they need)
serverkit list                              # everything available here
serverkit info backups                      # details and setup notes
serverkit health                            # status of this machine
serverkit status                            # past runs, files waiting for review
serverkit doctor                            # what it detected
serverkit update                            # update serverkit
```

Useful options: `--dry-run`, `--yes` (no questions; needed without a terminal),
`--only a,b` / `--skip a,b` with a profile, `--verbose`, `--plain`,
`--set NAME=VALUE`, `--user NAME` (when running as root).

### Unattended (cloud-init, CI, Ansible)

```sh
SERVERKIT_NO_RUN=1 sh -c "$(curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh)"
~/.local/bin/serverkit apply --profile apps --set DOMAIN=example.com --yes
```

### Settings

`serverkit config` lists every setting, its value and where it came from.
Precedence: built-in defaults < profile < `~/.config/serverkit/config.conf` < `--set`.

```sh
serverkit config set SSH_PASSWORD_AUTH=no
serverkit config set MISE_TOOLS="node@22 python@3.12"
```

### Other frontends

`serverkit list --json` describes every item and how it resolves on this machine;
`--events FILE` streams JSON-lines progress (`run_start`, `item_start`, `item_done`,
`run_done`). Together with the non-interactive flags, that's everything a
different UI (for example an Ink/React terminal app) needs to drive serverkit.

## Profiles

| | personal | apps | desktop | minimal |
|---|---|---|---|---|
| For | home server / dev box | live apps for several people | laptop / workstation | anywhere |
| Security | firewall, SSH, fail2ban, updates | + kernel hardening, per-user caps, escalating bans | — | — |
| Hosting | Docker, k3s, Tailscale, tunnel, code-server | Docker, Tailscale, tunnel → nginx | Docker | — |
| Storage | disk health, ZFS, backups | disk health, longer backups | — | — |
| Tools | full dev set + AI agents | lean set | dev set + apps | shell + basics |

Profiles are plain settings files in `profiles/` — copy one to make your own.

## Development

```sh
tests/check.sh --online      # lint, catalog integrity, every package name verified
bats tests/unit              # unit tests
tests/distro/run.sh          # 13 distros in containers
PHASE=full tests/distro/run.sh ubuntu:24.04 fedora:latest   # real installs, twice
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a tool is usually one line in
`catalog/apps.tsv`.

## License

MIT
