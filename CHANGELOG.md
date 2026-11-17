# Changelog

## Unreleased
- tmux sessions survive a reboot: `tmux-config` installs tpm, tmux-resurrect
  and tmux-continuum (saves every 15 minutes to a private folder, restores on
  start). On a machine with tmux already running it loads them into the live
  server and takes a first save, with no restart and no pane touched. Its
  `~/.tmux.conf` block goes above your own `run tpm` line, if any, so
  continuum's autosave hook isn't overwritten. `serverkit health` shows
  autosave state and the last save.
- code-server is also served to your tailnet only (`tailscale serve`, HTTPS
  port `CODE_SERVER_TAILNET_PORT`, default 8447, or `off`) once Tailscale is
  connected; a port that's already in use is left alone. It warns when an
  existing config listens beyond localhost.
- `ssh-hardening` and `serverkit health` warn (read-only) about a commented-out
  `#Match` whose indented lines still apply to everyone, and about TCP
  forwarding being off for you (VS Code Remote-SSH hangs).
- zsh-setup swaps macOS's `LC_CTYPE=UTF-8` for a real locale, which silences
  perl/apt "Setting locale failed".
- The personal profile includes mosh; `serverkit info mosh` covers scrolling
  (tmux copy mode) and the UDP ports.

## 0.1.0 — 2026-10-10
- Windows installs the tools, not only the setup: every cross-platform
  command-line tool with a Windows build comes from Scoop, Python tools
  (pgcli, mycli, litecli, HTTPie, pre-commit, aider) from the new `uv:` kind,
  plus Windows apps (UniGetUI, WinSCP, PuTTY, Ditto, WinDirStat, 7-Zip, Rufus)
  and new cross-platform items (Neovim, gping, KeePassXC, Wireshark, OBS).
  Profiles preselect gsudo, Windows Terminal setup and app updates on Windows.
- Windows support: PowerShell version (5.1 and 7) sharing the catalog and
  profiles; Scoop for tools, winget for apps; PowerShell profile, Windows
  Terminal fragment, WSL, OpenSSH server, Developer Mode, long paths and more;
  one UAC prompt per run; `irm …/install.ps1 | iex`.
- First public version: interactive setup (gum UI with plain fallback), ~140
  items across Debian/RHEL/Arch/SUSE families and macOS, four profiles,
  dry-run, JSON catalog and progress events, unit + multi-distro tests.
