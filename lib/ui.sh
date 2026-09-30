# shellcheck shell=bash
# ==============================================================================
#  ui — terminal UI. Uses gum (https://github.com/charmbracelet/gum) when it
#  can, plain prompts otherwise. gum is downloaded once, pinned, and checked
#  against the SHA-256 recorded below before it is ever executed.
#
#  UI=gum | plain | none   (none = no terminal: every answer must come from flags)
# ==============================================================================

UI=plain
GUM=""
GUM_VERSION=2.0.2
declare -gA GUM_SHA256=(
  [Linux_x86_64]=d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2
  [Linux_arm64]=8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5
  [Darwin_x86_64]=5374966c7c7199ea879fcaa525ddc6d447a098d3d35496e430a9a1ef38d30485
  [Darwin_arm64]=4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890
)
ACCENT=212

ui_init() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    UI=none
    return 0
  fi
  UI=plain
  [[ ${SERVERKIT_UI:-} == plain ]] && return 0
  local local_gum="$SK_DATA/bin/gum"
  if [[ -x $local_gum ]] && grep -q "v$GUM_VERSION" <<<"$("$local_gum" --version 2>/dev/null)"; then
    GUM=$local_gum
  elif have gum && grep -qE 'v(0\.1[4-9]|0\.[2-9][0-9]|[1-9])' <<<"$(gum --version 2>/dev/null)"; then
    GUM=$(command -v gum)
  else
    ui_fetch_gum && GUM=$local_gum
  fi
  [[ -n $GUM ]] && UI=gum
  return 0
}

ui_fetch_gum() {
  local key tmp tarball want got
  key="$(uname -s)_$UNAME_ARCH"
  want=${GUM_SHA256[$key]:-}
  [[ -n $want ]] || return 1
  have curl && have tar || return 1
  tmp=$(sk_tmpdir)
  tarball="gum_${GUM_VERSION}_${key}.tar.gz"
  printf '%s' "${C_DIM}fetching the terminal UI (gum $GUM_VERSION)…${C_RESET}"
  if ! fetch "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${tarball}" "$tmp/$tarball"; then
    printf '\r\033[K'
    return 1
  fi
  got=$(sha256_of "$tmp/$tarball")
  if [[ $got != "$want" ]]; then
    printf '\r\033[K'
    warn "gum download failed its checksum — using plain prompts instead"
    return 1
  fi
  tar -xzf "$tmp/$tarball" -C "$tmp" || return 1
  mkdir -p "$SK_DATA/bin"
  install -m 0755 "$tmp/gum_${GUM_VERSION}_${key}/gum" "$SK_DATA/bin/gum" || return 1
  printf '\r\033[K'
}

# ------------------------------------------------------------------------------
# Display
# ------------------------------------------------------------------------------
ui_banner() { # subtitle
  if [[ $UI == gum ]]; then
    "$GUM" style --border rounded --border-foreground "$ACCENT" --padding "0 2" --margin "1 0 0 0" \
      "$("$GUM" style --bold --foreground "$ACCENT" "serverkit $SK_VERSION")" "$1"
  else
    printf '\n%s\n%s\n\n' "${C_BOLD}${C_MAGENTA}serverkit $SK_VERSION${C_RESET}" "$1"
  fi
}

ui_title() {
  if [[ $UI == gum ]]; then
    "$GUM" style --bold --foreground "$ACCENT" --margin "1 0 0 0" "$1"
  else
    printf '\n%s\n' "${C_BOLD}${C_MAGENTA}$1${C_RESET}"
  fi
}

ui_note() {
  if [[ $UI == gum ]]; then "$GUM" style --foreground 245 "$@"; else printf '%s\n' "${C_DIM}$*${C_RESET}"; fi
}

# ------------------------------------------------------------------------------
# Prompts. Options are "LABEL<TAB>VALUE" lines; the value is returned.
# gum separates --selected entries with commas, so labels swap ASCII commas
# for a look-alike (U+201A) to stay intact.
# ------------------------------------------------------------------------------
_ui_label() { local l=${1%%$'\t'*}; printf '%s' "${l//,/‚}"; }
_ui_value() { printf '%s' "${1#*$'\t'}"; }

# ui_choose HEADER OPTION... -> one value
ui_choose() {
  local header="$1" o i=1 opts=() ans
  shift
  for o in "$@"; do opts+=("$(_ui_label "$o")"$'\t'"$(_ui_value "$o")"); done
  if [[ $UI == gum ]]; then
    "$GUM" choose --header "$header" --label-delimiter=$'\t' --cursor "❯ " \
      --header.foreground "$ACCENT" --cursor.foreground "$ACCENT" "${opts[@]}"
    return
  fi
  printf '%s\n' "${C_BOLD}$header${C_RESET}" >&2
  for o in "${opts[@]}"; do printf '  %2d) %s\n' $((i++)) "$(_ui_label "$o")" >&2; done
  while true; do
    read -r -p "  choose [1-$#]: " ans </dev/tty
    if [[ $ans =~ ^[0-9]+$ && $ans -ge 1 && $ans -le $# ]]; then
      _ui_value "${opts[ans - 1]}"
      echo
      return 0
    fi
  done
}

# ui_multi HEADER "VALUE,VALUE" OPTION... -> chosen values, one per line
ui_multi() {
  local header="$1" pre=",$2," o opts=() sel=() i
  shift 2
  for o in "$@"; do
    opts+=("$(_ui_label "$o")"$'\t'"$(_ui_value "$o")")
    [[ $pre == *",$(_ui_value "$o"),"* ]] && sel+=("$(_ui_label "$o")")
  done
  if [[ $UI == gum ]]; then
    local joined
    joined=$(IFS=,; printf '%s' "${sel[*]:-}")
    "$GUM" choose --no-limit --header "$header" --label-delimiter=$'\t' --height 20 \
      --selected "$joined" --cursor "❯ " --selected-prefix "◉ " --unselected-prefix "○ " \
      --header.foreground "$ACCENT" --cursor.foreground "$ACCENT" --selected.foreground "$ACCENT" \
      "${opts[@]}"
    return
  fi
  # plain: numbered checklist; toggle by number or range
  local on=() n=${#opts[@]} ans tok a b
  for ((i = 0; i < n; i++)); do
    on[i]=0
    [[ $pre == *",$(_ui_value "${opts[i]}"),"* ]] && on[i]=1
  done
  while true; do
    printf '%s\n' "${C_BOLD}$header${C_RESET}" >&2
    for ((i = 0; i < n; i++)); do
      printf '  %3d [%s] %s\n' $((i + 1)) "$([[ ${on[i]} == 1 ]] && echo x || echo ' ')" "$(_ui_label "${opts[i]}")" >&2
    done
    read -r -p "  toggle numbers/ranges (e.g. 2 5-7), a=all, n=none, Enter=done: " ans </dev/tty
    [[ -z $ans ]] && break
    for tok in $ans; do
      case "$tok" in
      a) for ((i = 0; i < n; i++)); do on[i]=1; done ;;
      n) for ((i = 0; i < n; i++)); do on[i]=0; done ;;
      *-*)
        a=${tok%-*} b=${tok#*-}
        [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || continue
        for ((i = a; i <= b && i <= n; i++)); do ((i >= 1)) && on[i - 1]=$((1 - on[i - 1])); done
        ;;
      *) [[ $tok =~ ^[0-9]+$ && $tok -ge 1 && $tok -le $n ]] && on[tok - 1]=$((1 - on[tok - 1])) ;;
      esac
    done
  done
  for ((i = 0; i < n; i++)); do [[ ${on[i]} == 1 ]] && _ui_value "${opts[i]}" && echo; done
  return 0
}

# ui_confirm QUESTION [yes|no] -> exit status
ui_confirm() {
  local q="$1" def="${2:-yes}" ans
  $ASSUME_YES && return 0
  [[ $UI == none ]] && [[ $def == yes ]] && return 0
  [[ $UI == none ]] && return 1
  if [[ $UI == gum ]]; then
    if [[ $def == yes ]]; then "$GUM" confirm --default=true "$q"; else "$GUM" confirm --default=false "$q"; fi
    return
  fi
  local hint="[Y/n]"
  [[ $def == no ]] && hint="[y/N]"
  read -r -p "$q $hint " ans </dev/tty
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy] ]]
}

# ui_input HEADER DEFAULT [PLACEHOLDER] -> text
ui_input() {
  local header="$1" def="$2" ph="${3:-}" ans
  if [[ $UI == gum ]]; then
    "$GUM" input --header "$header" --value "$def" --placeholder "$ph" --header.foreground "$ACCENT"
    return
  fi
  read -r -p "$header [$def]: " ans </dev/tty
  printf '%s\n' "${ans:-$def}"
}

# ------------------------------------------------------------------------------
# Progress. ui_task LABEL FUNCTION ARGS… runs a shell function with a spinner
# (so it keeps access to every helper), output going to the log. --verbose
# streams it instead. Returns the function's exit status.
# ------------------------------------------------------------------------------
ui_task() {
  local label="$1" start rc
  shift
  start=$(date +%s)
  if $VERBOSE || $DRY_RUN || [[ $UI == none ]]; then
    printf '%s\n' "${C_BOLD}▸ $label${C_RESET}"
    "$@"
    rc=$?
  else
    ("$@") >>"$LOG" 2>&1 </dev/null &
    local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 el
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      el=$(($(date +%s) - start))
      printf '\r  %s %s %s' "${C_MAGENTA}${frames:i++%10:1}${C_RESET}" "$label" "${C_DIM}${el}s${C_RESET}"
      sleep 0.1
    done
    wait "$pid"
    rc=$?
    tput cnorm 2>/dev/null || true
    printf '\r\033[K'
  fi
  local el=$(($(date +%s) - start))
  if [[ $rc -eq 0 ]]; then
    printf '  %s %s %s\n' "${C_GREEN}✓${C_RESET}" "$label" "${C_DIM}${el}s${C_RESET}"
  elif [[ $rc -eq 3 ]]; then # not applicable here
    printf '  %s %s %s\n' "${C_CYAN}–${C_RESET}" "$label" "${C_DIM}($(cat "$RUN_DIR/.na-${CURRENT_ITEM:-}" 2>/dev/null || echo "not applicable"))${C_RESET}"
  else
    printf '  %s %s %s\n' "${C_RED}✗${C_RESET}" "$label" "${C_DIM}(failed — details in the log)${C_RESET}"
  fi
  return $rc
}
