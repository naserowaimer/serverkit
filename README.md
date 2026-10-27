# serverkit

Set up a server, home lab or workstation in one interactive run — safely, on
almost any Linux, on macOS and on Windows.

```sh
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh
```
```powershell
# Windows (PowerShell, no administrator needed)
irm https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.ps1 | iex
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

About 170 items in 15 groups — run `serverkit list` to see what your machine offers:

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
| CLI essentials | ripgrep, fd, bat, fzf, eza, jq, btop, lazygit, delta, Neovim, GNU tools, … |
| Dev & cloud | GitHub/GitLab CLIs, pre-commit, AWS/Azure/GCP CLIs, OpenTofu, Ansible |
| Databases | psql, pgcli, mycli, litecli, sqlite (clients only) |
| AI agents | Claude Code, opencode, aider, Codex, Gemini CLI, Copilot CLI |
| Desktop apps | VS Code, Zed, browsers, Obsidian, KeePassXC, Wireshark, OBS, Slack… (Homebrew casks on macOS, Flathub on Linux, winget on Windows) |

## Where it runs

| Platform | System items | Your tools |
|---|---|---|
| Debian, Ubuntu and derivatives (Mint, Pop!_OS, Zorin, elementary, Kali, Proxmox, Raspberry Pi OS…) | apt | Homebrew |
| Fedora, RHEL, Rocky, Alma, CentOS Stream, Oracle, Amazon Linux 2023 | dnf (+ EPEL where needed) | Homebrew |
| Arch, Manjaro, EndeavourOS, Garuda, CachyOS | pacman | Homebrew |
| openSUSE Leap / Tumbleweed, SLES | zypper | Homebrew |
| macOS versions Homebrew supports — currently 15 and newer (Apple silicon and Intel) | macOS firewall | Homebrew + casks |
| Image-based (Silverblue, Bazzite, MicroOS…), other glibc Linux | — | Homebrew + Flathub |
| Windows 10 / 11, Windows Server 2022+ | winget, Windows features (administrator, one UAC prompt) | Scoop |

**Homebrew is the source of everyday tools on Linux and macOS, Scoop on
Windows** — both install per user, without administrator rights, with mostly
the same tool names. The native package manager is used only for
system pieces (firewall, sshd, fail2ban, nginx, Docker Engine). Homebrew never
runs as root; run serverkit as your normal user and it asks for sudo once, only
if something needs it.

**Root-only servers work too.** Run serverkit as root (no `--user`) on Linux
and every tool is set up for root. Homebrew itself runs as the account that
owns `/home/linuxbrew/.linuxbrew`. If nobody does yet, serverkit creates a
hidden system account, `linuxbrew` (no login shell, no password). If a person's
account already owns it, Homebrew keeps running as that account and nothing is
taken over. To use brew yourself as root:
`cd / && sudo -u linuxbrew -H brew upgrade`.

## Windows

The same catalog, profiles and settings drive a PowerShell version
(`serverkit.cmd`, Windows PowerShell 5.1 or PowerShell 7), and it installs the
same tools: every command-line tool in the list above that exists for Windows
(about 75 — ripgrep, fd, bat, fzf, eza, jq, lazygit, delta, Neovim, gh,
kubectl, k9s, Helm, OpenTofu, restic, GNU coreutils/grep/sed/make, …) comes from
**Scoop**; Python tools (pgcli, mycli, litecli, HTTPie, pre-commit, aider) from
**uv**; desktop apps from **winget**; Node, Python and Go from mise; Rust from
rustup. Only server-side pieces (fail2ban, nginx, ZFS, …) and macOS apps stay
off the menu. On top of that, Windows-specific items:

| Item | What it does |
|---|---|
| PowerShell setup | Starship prompt, predictive history (PSReadLine), zoxide, fzf (PSFzf), Terminal-Icons, mise, shortcuts — one marked line in your `profile.ps1` loads it |
| Windows Terminal setup | Nerd Font + color scheme through a *fragment*: your `settings.json` is never edited |
| Explorer tweaks | show file extensions and hidden files |
| Developer Mode, Long paths | symlinks without admin; paths over 260 characters (administrator) |
| WSL 2 | Linux on Windows; then run the Linux installer inside it |
| OpenSSH server | SSH into the PC, PowerShell as the shell, firewall rule added |
| Windows Firewall | makes sure it's on for every network type (rules untouched) |
| Visual Studio Build Tools | the C/C++ toolchain Rust and native modules need |
| Automatic app updates | weekly `scoop update *` + `winget upgrade --all` (scheduled task) |
| gsudo | `sudo` for Windows: run one command as administrator |
| Windows apps | PowerShell 7, Windows Terminal, PowerToys, Everything, ShareX, Notepad++, Sysinternals, UniGetUI, WinSCP, PuTTY, Ditto, WinDirStat, 7-Zip, Rufus — plus the cross-platform apps |

Run serverkit from a normal (non-administrator) PowerShell: items that need
administrator rights run together in one elevated window after a single UAC
prompt. Scoop needs scripts allowed for your user, so the Scoop item sets the
execution policy to `RemoteSigned` for your account only (what Scoop documents).

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
Invoke-Pester tests/win      # Windows unit tests (PowerShell 7 or 5.1, any OS)
tests/distro/run.sh          # 13 distros in containers
PHASE=full tests/distro/run.sh ubuntu:24.04 fedora:latest   # real installs, twice
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a tool is usually one line in
`catalog/apps.tsv`.

## License

MIT
