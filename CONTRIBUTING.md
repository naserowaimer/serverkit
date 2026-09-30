# Contributing

## Add a tool (one line)

Most additions are one line in `catalog/apps.tsv`:

```
id|category|Name|what it's for, briefly|install spec|needs
lazysql|db|lazysql|terminal UI for SQL databases|all=brew:lazysql|
```

Install specs: `TARGET=KIND:ARG`, space-separated; the most specific target wins
(`debian rhel arch suse` > `linux mac` > `all`). Kinds: `brew`, `cask` (macOS),
`flatpak` (Linux), `npm`, `pkg` (native, per family), `sys`/`fn` (a function in
`modules/`), `builtin`. Prefer `brew` for command-line tools — it's identical on
every platform. Then run `tests/check.sh --online`: it verifies the name exists
in Homebrew/Flathub and isn't deprecated.

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

## Before a pull request

```sh
tests/check.sh --online
bats tests/unit
tests/distro/run.sh                       # all distros, quick phase
PHASE=full tests/distro/run.sh <images>   # real installs for what you touched
```

CI also runs the full phase on every distro, a real run on an Ubuntu VM with
systemd, and a real run on macOS.
