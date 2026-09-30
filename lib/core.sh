# shellcheck shell=bash
# ==============================================================================
#  core — logging, command execution (dry-run aware), privilege helpers,
#  safe file writes, and small portability shims for GNU vs BSD/macOS tools.
#
#  Every command that changes the machine goes through run_cmd / as_root / as_user
#  or safe_write / ensure_block, so --dry-run is exact: it prints what would
#  happen and changes nothing.
# ==============================================================================

MARKER="managed-by:serverkit"
STAMP=$(date +%Y%m%d-%H%M%S)

DRY_RUN=false
ASSUME_YES=false
VERBOSE=false
FORCE=false
QUIET=false

LOG=/dev/null
RUN_DIR=""
STATE_DIR=""
CONFIG_DIR=""
EVENTS_FILE=""

# ------------------------------------------------------------------------------
# Output. Colours only on a terminal, and never when NO_COLOR is set.
# ------------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_BLUE=$'\e[34m' C_GREEN=$'\e[32m' C_CYAN=$'\e[36m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_MAGENTA=$'\e[35m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_BLUE="" C_GREEN="" C_CYAN="" C_YELLOW="" C_RED="" C_MAGENTA=""
fi

_emit() { # colour symbol message...
  local c="$1" s="$2"
  shift 2
  printf '%s %s\n' "${c}${s}${C_RESET}" "$*"
  [[ $LOG == /dev/null ]] || printf '%s %s %s\n' "$(date '+%T')" "$s" "$*" >>"$LOG"
}
log() { $QUIET || _emit "$C_BLUE" "•" "$*"; }
ok() { if $DRY_RUN; then _emit "$C_DIM" "○" "would then be: $*"; else _emit "$C_GREEN" "✓" "$*"; fi; }
skip() { $QUIET || _emit "$C_CYAN" "=" "$*"; }
warn() {
  _emit "$C_YELLOW" "!" "$*"
  [[ -z $RUN_DIR ]] || printf '%s\t%s\n' "${CURRENT_ITEM:-serverkit}" "$*" >>"$RUN_DIR/warnings"
}
err() { _emit "$C_RED" "✗" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

# Follow-ups the person must do by hand. Stored in a file, not a variable,
# because items run in a background subshell while the spinner draws.
hint() {
  if [[ -n $RUN_DIR ]]; then
    grep -qxF "$*" "$RUN_DIR/hints" 2>/dev/null || printf '%s\n' "$*" >>"$RUN_DIR/hints"
  else
    _emit "$C_MAGENTA" "→" "$*"
  fi
}

# Machine-readable progress for other frontends: --events FILE writes JSON lines.
json_str() { json_q "$1"; printf '%s' "$REPLY"; }
# json_q TEXT -> REPLY = TEXT as a JSON string (no subshell; used in loops)
json_q() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  REPLY="\"$s\""
}
event() { # type [key value]...
  [[ -n $EVENTS_FILE ]] || return 0
  local out
  out="{\"event\":$(json_str "$1"),\"ts\":$(date +%s)"
  shift
  while [[ $# -ge 2 ]]; do
    out+=",$(json_str "$1"):$(json_str "$2")"
    shift 2
  done
  printf '%s}\n' "$out" >>"$EVENTS_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# Running commands
# ------------------------------------------------------------------------------
quote_cmd() {
  local a out=""
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "; else out+="$(printf '%q' "$a") "; fi
  done
  printf '%s' "${out% }"
}

# run_cmd CMD... — the only way modules execute something that changes the machine.
run_cmd() {
  if $DRY_RUN; then
    printf '    %swould run:%s %s\n' "$C_DIM" "$C_RESET" "$(quote_cmd "$@")"
    return 0
  fi
  [[ $LOG == /dev/null ]] || printf '%s $ %s\n' "$(date '+%T')" "$(quote_cmd "$@")" >>"$LOG"
  "$@"
}

is_root() { [[ $EUID -eq 0 ]]; }

# as_root CMD... — sudo when needed. sudo resets the environment, so pass any
# variables explicitly:  as_root env DEBIAN_FRONTEND=noninteractive apt-get ...
as_root() {
  if is_root; then run_cmd "$@"; else run_cmd sudo "$@"; fi
}

# as_user CMD... — run as the person being set up (never root when avoidable).
# Homebrew refuses to run as root, and dotfiles must be owned by their user.
as_user() {
  if ! is_root || [[ $TARGET_USER == root ]]; then
    run_cmd "$@"
  elif have sudo; then
    run_cmd sudo -u "$TARGET_USER" -H "$@"
  else # minimal systems ship without sudo; runuser is part of util-linux
    run_cmd runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
  fi
}

# Read-only variants: they run even under --dry-run, for checks like
# "is this installed?". Never use them for anything that changes the machine.
as_root_q() {
  if is_root; then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else return 1; fi
}
as_user_q() {
  if ! is_root || [[ $TARGET_USER == root ]]; then "$@"
  elif have sudo; then sudo -u "$TARGET_USER" -H "$@"
  else runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; fi
}

can_sudo() { is_root || sudo -n true 2>/dev/null; }

SUDO_KEEPALIVE_PID=""
# Ask for the password once, up front, then keep the timestamp fresh so no
# prompt ever appears behind a spinner.
sudo_begin() {
  is_root && return 0
  $DRY_RUN && return 0
  have sudo || return 1
  if ! sudo -n true 2>/dev/null; then
    printf '%s\n' "${C_BOLD}Some items change the system; sudo will ask for your password once.${C_RESET}"
    sudo -v || return 1
  fi
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null
      sleep 45
    done
  ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}
sudo_end() { [[ -z $SUDO_KEEPALIVE_PID ]] || kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# Downloads — HTTPS only, TLS 1.2+, fail on HTTP errors. Never piped into a
# shell: scripts are saved, then executed, so --dry-run can show them.
# ------------------------------------------------------------------------------
fetch() { # URL DEST
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
}
fetch_stdout() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 "$1"; }

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# gh_latest OWNER/REPO -> newest release tag without a leading "v". Empty on failure.
gh_latest() {
  fetch_stdout "https://api.github.com/repos/$1/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1
}

# run_script URL [as_user|as_root] [ENV=val...] [-- args...]
# Download an official installer to a private temp dir, then run it.
run_script() {
  local url="$1" who="$2" f
  shift 2
  if $DRY_RUN; then
    printf '    %swould download and run:%s %s %s\n' "$C_DIM" "$C_RESET" "$url" "$*"
    return 0
  fi
  f=$(umask 077 && mktemp "$(sk_tmpdir)/installer.XXXXXX") || return 1
  fetch "$url" "$f" || {
    err "download failed: $url"
    return 1
  }
  chmod 0755 "$f"
  if is_root && [[ $who == as_user && $TARGET_USER != root ]]; then chown "$TARGET_USER" "$f"; fi
  local envs=() args=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  [[ ${1:-} == -- ]] && shift
  args=("$@")
  local interp=sh
  grep -q bash <<<"$(head -n 1 "$f")" && interp=bash
  "$who" env "${envs[@]}" "$interp" "$f" "${args[@]}"
}

# One private temp dir per run, created up front by sk_tmp_init in the main
# shell (a $(...) or background subshell can't hand a new one back). Files in
# it are created owner-only; the dir is traversable so a file chown'd to the
# target user is reachable by them.
SK_TMP=""
sk_tmp_init() {
  [[ -n $SK_TMP ]] && return 0
  SK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/serverkit.XXXXXX") || die "cannot create a temp directory"
  chmod 0711 "$SK_TMP"
}
sk_tmpdir() {
  [[ -n $SK_TMP ]] || sk_tmp_init
  printf '%s' "$SK_TMP"
}
sk_cleanup() {
  sudo_end
  [[ -z $SK_TMP ]] || rm -rf "$SK_TMP"
}

# ------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------
_owner_of_path() { # user for paths in the target home, root otherwise
  if [[ $1 == "$TARGET_HOME"/* ]]; then echo user; else echo root; fi
}
_as_owner() { # user|root CMD...
  local o="$1"
  shift
  if [[ $o == user ]]; then as_user "$@"; else as_root "$@"; fi
}
# Read a file even when only root can.
_read() {
  cat "$1" 2>/dev/null && return 0
  $DRY_RUN && return 1
  is_root || sudo -n cat "$1" 2>/dev/null
}

is_ours() { grep -qF "$MARKER" <<<"$(_read "$1")"; }

track() {
  [[ -n $STATE_DIR ]] || return 0
  $DRY_RUN && return 0
  mkdir -p "$STATE_DIR"
  grep -qxF "$1" "$STATE_DIR/managed.list" 2>/dev/null || echo "$1" >>"$STATE_DIR/managed.list"
}

# Put CONTENT at PATH with MODE, owned by the right account.
_install_content() { # owner path mode content
  local o="$1" path="$2" mode="$3" content="$4" tmp
  if $DRY_RUN; then return 0; fi
  tmp=$(umask 077 && mktemp "$(sk_tmpdir)/write.XXXXXX") || return 1
  printf '%s\n' "$content" >"$tmp"
  if [[ $o == user ]] && is_root && [[ $TARGET_USER != root ]]; then chown "$TARGET_USER" "$tmp"; fi
  # install -m creates the file with its final mode: no world-readable window
  _as_owner "$o" mkdir -p "$(dirname "$path")" &&
    _as_owner "$o" install -m "$mode" "$tmp" "$path"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# safe_write PATH [MODE] < content
#
# Writes a file only if it is absent or serverkit wrote it before (it carries
# the marker). A file someone else wrote is never touched: ours is left beside
# it as PATH.new. --force adopts it anyway, keeping PATH.bak.<time>.
# Sets SW_CHANGED so callers restart a service only when its config changed.
# Feed it a heredoc or `< <(...)` — never a pipe (a pipe runs it in a subshell
# and SW_CHANGED would be lost).
SW_CHANGED=false
safe_write() {
  local path="$1" mode="${2:-0644}" content cur o
  content=$(cat)
  SW_CHANGED=false
  o=$(_owner_of_path "$path")
  track "$path"
  if [[ -e $path ]]; then
    cur=$(_read "$path") || cur="<unreadable>"
    if [[ $content == "$cur" ]]; then
      skip "unchanged: $path"
      return 0
    fi
    if is_ours "$path" || $FORCE; then
      if $DRY_RUN; then
        log "would update: $path"
      else
        _as_owner "$o" cp -p "$path" "${path}.bak.${STAMP}" || return 1
        _install_content "$o" "$path" "$mode" "$content" || return 1
        ok "updated: $path  (previous: ${path}.bak.${STAMP})"
      fi
      SW_CHANGED=true
    else
      if $DRY_RUN; then
        log "would keep your $path and write ours as ${path}.new"
      else
        _install_content "$o" "${path}.new" "$mode" "$content" || return 1
        warn "kept your $path — ours is ${path}.new (review it, or re-run with --force to adopt)"
      fi
    fi
  else
    if $DRY_RUN; then log "would create: $path"; else
      _install_content "$o" "$path" "$mode" "$content" || return 1
      ok "created: $path"
    fi
    SW_CHANGED=true
  fi
  return 0
}

# Undo a safe_write that turned out to be bad (e.g. `sshd -t` rejected it).
restore_file() { # path
  local path="$1" o
  o=$(_owner_of_path "$path")
  $DRY_RUN && return 0
  if [[ -e ${path}.bak.${STAMP} ]]; then
    _as_owner "$o" mv -f "${path}.bak.${STAMP}" "$path"
  else
    _as_owner "$o" rm -f "$path"
  fi
}

# ensure_block FILE ID < content
# Keeps one marked block inside a file the person owns (e.g. ~/.zshrc), so we
# can add a line without owning the whole file. Re-running replaces the block
# in place; everything outside it is left exactly as it was.
ensure_block() {
  local file="$1" id="$2" body begin end cur new o
  body=$(cat)
  begin="# >>> serverkit:$id >>>"
  end="# <<< serverkit:$id <<<"
  o=$(_owner_of_path "$file")
  cur=""
  [[ -e $file ]] && cur=$(_read "$file")
  if [[ $cur == *"$begin"* ]]; then
    # body via ENVIRON: awk -v would interpret backslashes in it
    new=$(printf '%s\n' "$cur" | SK_BODY="$body" awk -v b="$begin" -v e="$end" '
      $0 == b { print; print ENVIRON["SK_BODY"]; skipping = 1; next }
      $0 == e { skipping = 0 }
      !skipping { print }')
  else
    new="$cur"
    [[ -n $cur ]] && new+=$'\n'
    new+="$begin"$'\n'"$body"$'\n'"$end"
  fi
  if [[ $new == "$cur" ]]; then
    skip "unchanged: $file ($id)"
    return 0
  fi
  if $DRY_RUN; then
    log "would add the '$id' block to $file"
    return 0
  fi
  [[ -e $file ]] && _as_owner "$o" cp -p "$file" "${file}.bak.${STAMP}"
  local mode=0644
  [[ -e $file ]] && mode=$(file_mode "$file")
  _install_content "$o" "$file" "$mode" "$new" && ok "updated: $file ($id)"
}

# ------------------------------------------------------------------------------
# Portability: GNU (Linux) vs BSD (macOS)
# ------------------------------------------------------------------------------
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"; }
home_of() { # user -> home directory
  local h=""
  if have getent; then h=$(getent passwd "$1" | cut -d: -f6); fi
  if [[ -z $h ]] && have dscl; then h=$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'); fi
  [[ -n $h ]] || h=$(eval echo "~$1")
  printf '%s' "$h"
}
in_group() { grep -qxF "$2" <<<"$(id -nG "$1" 2>/dev/null | tr ' ' '\n')"; }
