# Changelog

## Unreleased
- Root-only Linux servers: running as root (no `--user`), every item works,
  Homebrew tools included. brew runs as the owner of `/home/linuxbrew/.linuxbrew`:
  an existing account, or a hidden `linuxbrew` system account (no login, no
  password) that serverkit creates. Tools and dotfiles are set up for root.
  Behaviour for normal users and `--user` is unchanged.

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
