#!/usr/bin/env bash
# ==============================================================================
#  tests/check.sh — static checks. Run before every commit (CI runs it too).
#
#    tests/check.sh            syntax, shellcheck, catalog + profile integrity
#    tests/check.sh --online   also verify every Homebrew formula/cask name and
#                              Flathub app id against the live indexes
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
fail=0
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  fail=1
}
good() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

echo "syntax"
for f in lib/*.sh lib/run.bash modules/*.sh tests/*.sh tests/distro/*.sh tests/distro/*.bash; do
  [[ -e $f ]] || continue
  bash -n "$f" || bad "bash -n $f"
done
sh -n serverkit || bad "sh -n serverkit"
sh -n install.sh || bad "sh -n install.sh"
[[ $fail -eq 0 ]] && good "all scripts parse"

echo "shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck -x -S warning lib/*.sh lib/run.bash modules/*.sh tests/*.sh tests/distro/*.sh tests/distro/*.bash && shellcheck -s sh -S warning serverkit install.sh; then
    good "no warnings"
  else
    bad "shellcheck reported problems (above)"
  fi
else
  bad "shellcheck is not installed"
fi

echo "pipefail hazards"
# `cmd | grep -q` under pipefail: grep exits at the first match, cmd dies of
# SIGPIPE, and the check randomly reports "not found". Use grep … <<<"$(cmd)".
if grep -nE '(^|[^|])\|[[:space:]]*grep (-q|[^|]*>[[:space:]]*/dev/null)' lib/*.sh modules/*.sh tests/distro/*.bash; then
  bad "pipe into grep -q (above) — use: grep -q PATTERN <<<\"\$(cmd)\""
else
  good "no pipe-into-grep -q"
fi

echo "portability"
# Not on every minimal system (xargs, hostname) — use bash / uname -n instead.
if grep -nE '(^|[^a-z_-])(xargs|hostname -s)([^a-z_-]|$)' lib/*.sh modules/*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
  bad "uses a command minimal systems may lack (above)"
else
  good "no xargs / hostname -s"
fi

# grep -r skips symlinked files (nginx sites-enabled/*): always use -R
if grep -nE 'grep -r[a-zA-Z]*[[:space:]]' lib/*.sh modules/*.sh; then bad "use grep -R, not grep -r (above)"; fi

echo "workflows"
if python3 -c 'import yaml' 2>/dev/null; then
  for f in .github/workflows/*.yml; do
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null || bad "$f is not valid YAML"
  done
  [[ $fail -eq 0 ]] && good "workflow files parse"
else
  echo "  (python3-yaml not installed — skipped)"
fi

echo "catalog"
# Load the real parser so the checks see exactly what serverkit sees.
SK_ROOT=$ROOT
# shellcheck source=/dev/null
for f in core platform pkg brew ui catalog main; do . "lib/$f.sh"; done
# shellcheck source=/dev/null
for f in modules/*.sh; do . "$f"; done
catalog_load
declare -A seen=()
n=0
for id in "${ITEM_ORDER[@]}"; do
  n=$((n + 1))
  [[ -n ${seen[$id]+x} ]] && bad "duplicate id: $id"
  seen[$id]=1
  [[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]] || bad "$id: ids are lowercase letters, digits and dashes"
  [[ -n ${CAT_TITLE[${I_CAT[$id]}]+x} ]] || bad "$id: unknown category '${I_CAT[$id]}'"
  [[ -n ${I_NAME[$id]} && -n ${I_DESC[$id]} ]] || bad "$id: missing name or description"
  [[ -n ${I_SPEC[$id]} ]] || bad "$id: no install spec"
  for tok in ${I_SPEC[$id]}; do
    [[ $tok =~ ^[a-z][a-z0-9-]*=(brew|cask|flatpak|npm|uv|pkg|sys|fn|builtin|none|scoop|winget|ps|psadmin):[^[:space:]]+$ ]] ||
      bad "$id: malformed spec '$tok'"
    kind=${tok#*=}
    kind=${kind%%:*}
    arg=${tok#*:}
    target=${tok%%=*}
    case "$kind" in
    sys | fn) declare -F "item_$arg" >/dev/null || bad "$id: function item_$arg does not exist" ;;
    ps | psadmin)
      [[ $target == win ]] || bad "$id: $kind is Windows-only (target '$target')"
      grep -qE "^function item_${arg}([[:space:]]|\{|\(|$)" win/modules/*.ps1 2>/dev/null || bad "$id: Windows function item_$arg does not exist in win/modules/"
      ;;
    scoop | winget) [[ $target == win ]] || bad "$id: $kind is Windows-only (target '$target')" ;;
    cask) [[ $target == mac ]] || bad "$id: casks are macOS-only (target '$target')" ;;
    none) [[ $target =~ ^(all|linux|mac)$ ]] && bad "$id: 'none' is for a specific family or distro, not '$target'" ;;
    flatpak) [[ $target == linux || $target =~ ^(debian|rhel|arch|suse)$ ]] || bad "$id: flatpak is Linux-only" ;;
    esac
  done
  for d in ${I_NEEDS[$id]}; do
    [[ -n ${I_CAT[$d]+x} ]] || bad "$id: needs unknown item '$d'"
    [[ -n ${seen[$d]+x} ]] || bad "$id: needs '$d', which comes later in the catalog (order = install order)"
  done
done
for need in homebrew flatpak runtimes uv scoop winget; do
  [[ -n ${seen[$need]+x} ]] || bad "implicit dependency '$need' is missing from the catalog"
done
# implied dependencies must also come first
for id in "${ITEM_ORDER[@]}"; do
  for tok in ${I_SPEC[$id]}; do
    kind=${tok#*=}
    kind=${kind%%:*}
    case $kind in brew | cask) dep=homebrew ;; flatpak) dep=flatpak ;; npm) dep=runtimes ;; uv) dep=uv ;; scoop) dep=scoop ;; winget) dep=winget ;; *) continue ;; esac
    [[ $id == "$dep" ]] && continue
    pos_i=0 pos_d=0 k=0
    for x in "${ITEM_ORDER[@]}"; do
      k=$((k + 1))
      [[ $x == "$id" ]] && pos_i=$k
      [[ $x == "$dep" ]] && pos_d=$k
    done
    ((pos_d < pos_i)) || bad "$id uses $kind, so it must come after '$dep'"
  done
done
[[ $fail -eq 0 ]] && good "$n items, specs well-formed, functions exist, dependency order ok"

echo "profiles"
for f in profiles/*.conf; do
  # NAME=value lines, comments, blank lines, and continuation lines of a "…" value
  awk '
    /^[[:space:]]*(#|$)/ { next }
    inq { if ($0 ~ /"[[:space:]]*(#.*)?$/) inq = 0; next }
    /^[A-Z_][A-Z0-9_]*=/ {
      v = $0; sub(/^[^=]*=/, "", v); sub(/[[:space:]]+#.*$/, "", v)
      if (v ~ /^"/ && v !~ /^".*"$/) inq = 1
      next
    }
    { print FILENAME ":" NR ": not a setting: " $0; bad = 1 }
    END { exit bad }' "$f" || bad "$f has lines that aren't settings"
done
for f in profiles/[!_]*.conf; do
  p=$(basename "$f" .conf)
  out=$(
    OPT_SET=()
    settings_load "$p" 2>&1 >/dev/null
    for id in $ITEMS; do [[ -n ${I_CAT[$id]+x} ]] || echo "unknown item '$id'"; done
    [[ -n $PROFILE_DESC ]] || echo "PROFILE_DESC is empty"
  )
  [[ -z $out ]] || bad "profile $p: $out"
done
[[ $fail -eq 0 ]] && good "profiles parse; every item they name exists"

echo "files"
for f in files/* files/win/*; do
  [[ -f $f && $f != *.json ]] || continue   # JSON can't hold a comment: tracked by checksum
  grep -qF "managed-by:serverkit" "$f" || bad "$f lacks the managed-by:serverkit marker (it would never be updated)"
done
# Windows PowerShell 5.1 reads BOM-less files as ANSI and garbles ✓ — … in them
for f in win/*.ps1 win/lib/*.ps1 win/modules/*.ps1 files/win/*.ps1; do
  [[ $(head -c 3 "$f" | od -An -tx1 | tr -d ' ') == efbbbf ]] || bad "$f needs a UTF-8 BOM (Windows PowerShell 5.1)"
done
# install.ps1 runs as `irm ... | iex`: text, not a file, so a BOM would reach
# the parser as a stray character. Keep it plain ASCII instead.
LC_ALL=C grep -q '[^ -~[:space:]]' install.ps1 && bad "install.ps1 must be plain ASCII (it runs through irm | iex)"
[[ $fail -eq 0 ]] && good "dotfile templates carry the marker"

if [[ ${1:-} == --online ]]; then
  echo "online: Homebrew + Flathub names"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL https://formulae.brew.sh/api/formula.json -o "$tmp/f.json" &&
    curl -fsSL https://formulae.brew.sh/api/cask.json -o "$tmp/c.json" || bad "could not download Homebrew's index"
  # names, plus renamed/aliased ones; flag deprecated/disabled
  jq -r '.[] | [.name, (if .deprecated or .disabled then "deprecated" else "" end), ((.bottle.stable.files // {}) | keys | map(select(test("linux"))) | length | tostring), ((.bottle.stable.files // {}) | has("all") | tostring)] | @tsv' "$tmp/f.json" >"$tmp/formulae"
  jq -r '.[] | [.token, (if .deprecated or .disabled then "deprecated" else "" end)] | @tsv' "$tmp/c.json" >"$tmp/casks"
  for id in "${ITEM_ORDER[@]}"; do
    for tok in ${I_SPEC[$id]}; do
      target=${tok%%=*} kind=${tok#*=}
      kind=${kind%%:*}
      arg=${tok#*:}
      case $kind in
      brew)
        for n in ${arg//,/ }; do
          row=$(awk -F'\t' -v n="$n" '$1 == n' "$tmp/formulae")
          if [[ -z $row ]]; then bad "$id: no Homebrew formula '$n'"; continue; fi
          [[ $(cut -f2 <<<"$row") == deprecated ]] && bad "$id: formula '$n' is deprecated or disabled"
          if [[ $target != mac && $(cut -f3 <<<"$row") == 0 && $(cut -f4 <<<"$row") != true ]]; then
            bad "$id: formula '$n' has no Linux bottle (it would compile from source)"
          fi
        done
        ;;
      cask)
        row=$(awk -F'\t' -v n="$arg" '$1 == n' "$tmp/casks")
        [[ -n $row ]] || bad "$id: no Homebrew cask '$arg'"
        [[ $(cut -f2 <<<"$row") == deprecated ]] && bad "$id: cask '$arg' is deprecated or disabled"
        ;;
      uv)
        code=$(curl -s -o /dev/null -w '%{http_code}' "https://pypi.org/pypi/$arg/json")
        [[ $code == 200 ]] || bad "$id: PyPI has no package '$arg' (HTTP $code)"
        ;;
      flatpak)
        code=$(curl -s -o /dev/null -w '%{http_code}' "https://flathub.org/api/v2/appstream/$arg")
        [[ $code == 200 ]] || bad "$id: Flathub has no app '$arg' (HTTP $code)"
        ;;
      scoop)
        for n in ${arg//,/ }; do
          b=main
          [[ $n == */* ]] && b=${n%%/*} n=${n#*/}
          case $b in
          main) url="https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/$n.json" ;;
          extras) url="https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/$n.json" ;;
          nerd-fonts) url="https://raw.githubusercontent.com/matthewjberger/scoop-nerd-fonts/master/bucket/$n.json" ;;
          *) bad "$id: unknown Scoop bucket '$b' (main, extras, nerd-fonts)"; continue ;;
          esac
          code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
          [[ $code == 200 ]] || bad "$id: Scoop bucket '$b' has no '$n' (HTTP $code)"
        done
        ;;
      winget)
        # manifests/<first letter>/<Publisher>/<Name…>/ in microsoft/winget-pkgs
        wpath="manifests/$(tr 'A-Z' 'a-z' <<<"${arg:0:1}")/${arg//.//}"
        code=$(curl -s -o /dev/null -w '%{http_code}' ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "https://api.github.com/repos/microsoft/winget-pkgs/contents/$wpath")
        case $code in
        200) ;;
        403 | 429) [[ -n ${rate_noted:-} ]] || bad "GitHub API rate limit hit — run with GITHUB_TOKEN set to check winget names"; rate_noted=1 ;;
        *) bad "$id: winget has no package '$arg' (HTTP $code)" ;;
        esac
        ;;
      esac
    done
  done
  # formulae used directly by modules
  for n in colima docker docker-compose docker-buildx zsh-autosuggestions zsh-syntax-highlighting zsh-completions tmux fzf neovim ripgrep fd mise libpq; do
    grep -q "^${n}"$'\t' "$tmp/formulae" || bad "modules use formula '$n', which doesn't exist"
  done
  [[ $fail -eq 0 ]] && good "every Homebrew, cask, Flathub, PyPI, Scoop and winget name exists and is maintained"
fi

echo
if [[ $fail -eq 0 ]]; then echo "check passed"; else
  echo "check FAILED"
  exit 1
fi
