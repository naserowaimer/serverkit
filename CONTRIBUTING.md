# Contributing

## Add a tool (one line)

Most additions are one line in `catalog/apps.tsv`:

```
id|category|Name|what it's for, briefly|install spec|needs
lazysql|db|lazysql|terminal UI for SQL databases|all=brew:lazysql|
```

Install specs: `TARGET=KIND:ARG`, space-separated; the most specific target wins
(distro id > `debian rhel arch suse` > `linux mac win` > `all`). Kinds: `brew`,
`cask` (macOS), `flatpak` (Linux), `npm`, `pkg` (native, per family), `sys`/`fn`
(a function in `modules/`), `scoop`/`winget`/`ps`/`psadmin` (Windows; functions
in `win/modules/`), `builtin`, `none`. On Windows `all=` only counts for npm,
builtin and none, so give tools an explicit `win=scoop:…` (or `win=winget:…`).
Prefer `brew` (Linux, macOS) and `scoop` (Windows) for command-line tools: per
user, and the same everywhere. Then run `tests/check.sh --online`: it verifies
every Homebrew, Flathub, Scoop and winget name exists and isn't deprecated.

## Add a system item (a function)

Write `item_<name>` in the right `modules/*.sh` and point a catalog line at it
with `sys:<name>` (needs sudo) or `fn:<name>` (user level). Rules:

- Change the machine only through `run_cmd`, `as_root`, `as_user`, `safe_write`,
  `ensure_block`, `pkg_install`, `svc_enable`. That's what makes `--dry-run`
  exact and ownership correct.
- Use `as_root_q` / `as_user_q` for read-only checks (they run in dry-run too).
- Check before changing; a second run must change nothing.
- Validate config with the service's own checker before reloading, and call
  `restore_file` if it fails.
- Return `0` done, `1` failed, or `na "reason"` when it doesn't apply here.
- Things the person must do by hand: `hint "…"` (shown once, at the end).
- Branch on `FAMILY` (`by_family debian=… rhel=… arch=… suse=…`), not on distro
  names, unless a distro really differs (and then say why in a comment).

## Windows code

`win/` is PowerShell that must run on Windows PowerShell 5.1: no ternary
operator, no `??`, no `&&`/`||` between commands. Save `.ps1` files as UTF-8
**with** a BOM (5.1 reads BOM-less files as ANSI; `tests/check.sh` enforces it).
A function's every output is its return value, so capture or `[void]` calls you
don't need, and return `0`, `1` or `Skip-SkNA "why"` last.

## Before a pull request

```sh
tests/check.sh --online
bats tests/unit
pwsh -c 'Invoke-Pester tests/win'           # Windows logic, runs on any OS
tests/distro/run.sh                       # all distros, quick phase
PHASE=full tests/distro/run.sh <images>   # real installs for what you touched
```

CI also runs the full phase on every distro, a real run on an Ubuntu VM with
systemd, and a real run on macOS.
