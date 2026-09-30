# shellcheck shell=bash
# ==============================================================================
#  main — commands, the setup wizard, and the executor.
# ==============================================================================

usage() {
  cat <<EOF
${C_BOLD}serverkit $SK_VERSION${C_RESET} — set up a server, home lab or workstation, safely.

${C_BOLD}Usage${C_RESET}
  serverkit                          interactive setup
  serverkit install ITEM...          install items (and what they need)
  serverkit apply --profile NAME     install a profile's items
  serverkit list [--all] [--json]    everything installable here
  serverkit info ITEM                details about one item
  serverkit profiles                 the ready-made selections
  serverkit config [show|edit|set NAME=VALUE]
  serverkit health                   status snapshot of this machine
  serverkit status                   past runs and files waiting for review
  serverkit doctor                   what serverkit detected, and whether it can run
  serverkit update                   update serverkit itself
  serverkit version

${C_BOLD}Options${C_RESET}
  -p, --profile NAME   personal | apps | desktop | minimal
      --only A,B       with a profile: just these of its items
      --skip A,B       leave these out
  -n, --dry-run        show exactly what would change; change nothing
  -y, --yes            don't ask; accept the plan (needed without a terminal)
  -v, --verbose        stream command output instead of spinners
      --force          adopt config files serverkit didn't write (a .bak is kept)
      --set NAME=VALUE override a setting for this run (see: serverkit config)
      --user NAME      set up NAME's tools when running as root
      --plain          plain prompts instead of the full-screen UI
      --events FILE    write JSON-lines progress events (for other frontends)

${C_BOLD}Examples${C_RESET}
  serverkit apply --profile apps --dry-run
  serverkit install docker tailscale lazygit
  curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh
EOF
}

# ------------------------------------------------------------------------------
# Settings: parsed, never executed. NAME=value lines; a value in "…" may span
# lines. Only names defined in profiles/_defaults.conf are accepted.
# ------------------------------------------------------------------------------
declare -gA SETTING_SRC=()
SETTING_NAMES=()

settings_parse() { # file label [strict]
  local file="$1" label="$2" line key val
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
    if [[ ! $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      warn "$file: ignoring line: $line"
      continue
    fi
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    val=${val%%[[:space:]]#*} # strip trailing comment
    val=${val%"${val##*[![:space:]]}"}
    if [[ $val == \"* && $val != *\" || $val == \" ]]; then # multi-line "…"
      while IFS= read -r line; do
        val+=" ${line}"
        [[ $line == *\" ]] && break
      done
    fi
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
    val=$(printf '%s' "$val" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    if [[ $label != defaults && -z ${SETTING_SRC[$key]+x} ]]; then
      warn "$file: unknown setting $key (typo?) — ignored"
      continue
    fi
    [[ $label == defaults ]] && SETTING_NAMES+=("$key")
    printf -v "$key" '%s' "$val"
    SETTING_SRC[$key]=$label
  done <"$file"
}

settings_load() { # [profile]
  SETTING_NAMES=()
  SETTING_SRC=()
  settings_parse "$SK_ROOT/profiles/_defaults.conf" defaults
  [[ -n ${1:-} ]] && settings_parse "$SK_ROOT/profiles/$1.conf" "profile:$1"
  settings_parse "$CONFIG_DIR/config.conf" config
  local kv
  for kv in "${OPT_SET[@]}"; do
    [[ $kv =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "--set expects NAME=VALUE, got: $kv"
    [[ -n ${SETTING_SRC[${BASH_REMATCH[1]}]+x} ]] || die "unknown setting: ${BASH_REMATCH[1]} (see: serverkit config)"
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    SETTING_SRC[${BASH_REMATCH[1]}]=--set
  done
}

config_set() { # NAME VALUE — saved to the user's config file
  local key="$1" val="$2" f="$CONFIG_DIR/config.conf" cur=""
  [[ -n ${SETTING_SRC[$key]+x} ]] || die "unknown setting: $key"
  [[ $val != *$'\n'* ]] || die "values can't contain newlines"
  $DRY_RUN && return 0
  as_user mkdir -p "$CONFIG_DIR"
  [[ -e $f ]] && cur=$(grep -v "^${key}=" "$f")
  [[ -n $cur ]] || cur="# serverkit settings — NAME=value. All names and defaults: serverkit config"
  _install_content user "$f" 0644 "$cur"$'\n'"${key}=\"${val//\"/}\""
  printf -v "$key" '%s' "$val"
  SETTING_SRC[$key]=config
}

# ------------------------------------------------------------------------------
# Context
# ------------------------------------------------------------------------------
init_context() {
  detect_platform
  if [[ -n $OPT_USER ]]; then
    is_root || [[ $OPT_USER == "$(id -un)" ]] || die "--user needs root (run with sudo)"
    id "$OPT_USER" >/dev/null 2>&1 || die "no such user: $OPT_USER"
    TARGET_USER=$OPT_USER
  elif is_root && [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    TARGET_USER=$SUDO_USER
  else
    TARGET_USER=$(id -un)
  fi
  TARGET_HOME=$(home_of "$TARGET_USER")
  [[ -d $TARGET_HOME ]] || die "home directory of $TARGET_USER not found"
  STATE_DIR="$TARGET_HOME/.local/state/serverkit"
  CONFIG_DIR="$TARGET_HOME/.config/serverkit"
  SK_DATA="$TARGET_HOME/.local/share/serverkit"
  catalog_load
  catalog_resolve
}

# Files created while running as root inside the user's home go back to them.
fix_ownership() {
  is_root && [[ $TARGET_USER != root ]] || return 0
  local d
  for d in "$STATE_DIR" "$CONFIG_DIR" "$SK_DATA"; do
    [[ -e $d ]] && chown -R "$TARGET_USER" "$d" 2>/dev/null
  done
  return 0
}

on_interrupt() {
  local j
  for j in $(jobs -p); do kill "$j" 2>/dev/null; done
  tput cnorm 2>/dev/null || true
  printf '\n'
  err "interrupted — every step is safe to repeat; run serverkit again to finish"
  fix_ownership
  exit 130
}

# ------------------------------------------------------------------------------
# Executing a plan
# ------------------------------------------------------------------------------
install_item() {
  local s kind arg
  s=$(item_spec "$1")
  kind=${s%%:*} arg=${s#*:}
  case "$kind" in
  brew) brew_install ${arg//,/ } ;;
  cask) brew_cask ${arg//,/ } ;;
  flatpak) flatpak_install "$arg" ;;
  npm) npm_install "$arg" ;;
  pkg)
    local p any=false
    $DRY_RUN || pkg_refresh || true # a fresh machine may have no package index yet
    for p in ${arg//,/ }; do pkg_installed "$p" || pkg_available "$p" || $DRY_RUN && any=true; done
    $any || { na "not packaged for $DISTRO_NAME"; return; }
    pkg_install ${arg//,/ }
    ;;
  sys | fn) "item_$arg" ;;
  builtin) skip "$arg comes with $DISTRO_NAME" ;;
  *)
    err "don't know how to install $1 ($s)"
    return 1
    ;;
  esac
}

# Needs sudo: system items, a first-time Homebrew install (its installer uses
# sudo on macOS and for /home/linuxbrew on Linux), and macOS casks (some ship
# .pkg installers that ask for it).
plan_needs_sudo() {
  local id
  for id in "${PLAN[@]}"; do
    is_system_item "$id" && return 0
    [[ $id == homebrew ]] && ! brew_find && return 0
    [[ ${I_RES[$id]%%:*} == cask ]] && return 0
  done
  return 1
}

execute_plan() {
  local id rc system=false start
  plan_needs_sudo && system=true

  if ! $DRY_RUN; then
    mkdir -p "$STATE_DIR/runs"
    RUN_DIR="$STATE_DIR/runs/$STAMP"
    mkdir -p "$RUN_DIR"
    LOG="$RUN_DIR/serverkit.log"
    : >"$LOG"
    {
      echo "serverkit $SK_VERSION — $(date)"
      echo "platform: $(platform_line) — user $TARGET_USER"
      echo "items: ${PLAN[*]}"
    } >>"$LOG"
  else
    RUN_DIR=$(sk_tmpdir)/run
    mkdir -p "$RUN_DIR"
  fi
  if $system && ! is_root; then
    if ! $DRY_RUN; then
      if ! sudo_begin; then
        local keep=() id2
        if [[ $UI != none ]] && ui_confirm "No sudo, so system items can't run. Continue with only your own tools?" yes; then
          for id2 in "${PLAN[@]}"; do is_system_item "$id2" || keep+=("$id2"); done
          PLAN=("${keep[@]}")
          [[ ${#PLAN[@]} -gt 0 ]] || die "nothing left to install without sudo"
        else
          die "system items need sudo — nothing was changed (leave them out with --skip, or run as an admin)"
        fi
      fi
    elif ! sudo -n true 2>/dev/null; then
      if [[ $UI != none ]] && have sudo && ui_confirm "Let the preview read root-only settings (firewall, sshd…) with sudo? It changes nothing." yes; then
        sudo -v || true
      else
        ui_note "Preview without sudo: root-only state is assumed to be the distro default."
      fi
    fi
  fi

  ui_title "$($DRY_RUN && echo "Dry run — nothing will change" || echo "Installing ${#PLAN[@]} items")"
  $DRY_RUN || printf '%s\n' "${C_DIM}  log: $LOG${C_RESET}"
  event run_start count "${#PLAN[@]}" dry_run "$DRY_RUN"
  start=$(date +%s)
  local -A status=()
  local d blocked
  for id in "${PLAN[@]}"; do
    CURRENT_ITEM=$id
    blocked=""
    for d in $(item_deps "$id"); do [[ ${status[$d]:-ok} == failed || ${status[$d]:-ok} == blocked ]] && blocked=$d; done
    if [[ -n $blocked ]]; then
      status[$id]=blocked
      printf '  %s %s %s\n' "${C_YELLOW}–${C_RESET}" "${I_NAME[$id]}" "${C_DIM}(skipped: needs $blocked)${C_RESET}"
      event item_done id "$id" status blocked
      continue
    fi
    event item_start id "$id" name "${I_NAME[$id]}"
    ui_task "${I_NAME[$id]}" install_item "$id"
    rc=$?
    case $rc in
    0) status[$id]=ok ;;
    "$NA") status[$id]=na ;;
    *) status[$id]=failed ;;
    esac
    event item_done id "$id" status "${status[$id]}"
  done
  CURRENT_ITEM=""

  # ---- report ----
  local n_ok=0 n_na=0 n_fail=0 el
  for id in "${PLAN[@]}"; do
    case ${status[$id]} in ok) ((n_ok++)) ;; na | blocked) ((n_na++)) ;; failed) ((n_fail++)) ;; esac
  done
  el=$(($(date +%s) - start))
  $DRY_RUN && {
    printf '\n%s\n' "${C_DIM}Dry run finished — nothing was changed. Run again without --dry-run to apply.${C_RESET}"
    return 0
  }
  ui_title "Summary"
  printf '  %s done   %s skipped   %s failed   %s\n' "${C_GREEN}$n_ok${C_RESET}" "${C_CYAN}$n_na${C_RESET}" \
    "$([[ $n_fail -gt 0 ]] && echo "${C_RED}$n_fail${C_RESET}" || echo 0)" "${C_DIM}($((el / 60))m$((el % 60))s)${C_RESET}"
  for id in "${PLAN[@]}"; do
    case ${status[$id]} in
    failed) printf '  %s %s\n' "${C_RED}✗${C_RESET}" "${I_NAME[$id]} — see the log" ;;
    na) printf '  %s %s\n' "${C_CYAN}–${C_RESET}" "${I_NAME[$id]}: $(cat "$RUN_DIR/.na-$id" 2>/dev/null)" ;;
    esac
  done
  if [[ -s $RUN_DIR/warnings ]]; then
    ui_title "Warnings"
    awk -F'\t' '{printf "  ! %s: %s\n", $1, $2}' "$RUN_DIR/warnings"
  fi
  if [[ -s $RUN_DIR/hints ]]; then
    ui_title "Next steps"
    awk '{printf "  %d. %s\n", NR, $0}' "$RUN_DIR/hints"
  fi
  local pending
  pending=$(pending_reviews)
  if [[ -n $pending ]]; then
    ui_title "Your files were kept"
    ui_note "  serverkit's version is beside each one as .new — compare, or re-run with --force to adopt:"
    printf '%s\n' "$pending"
  fi
  printf '\n%s\n' "${C_DIM}log: $LOG${C_RESET}"
  printf '%s  profile=%s  ok=%s skipped=%s failed=%s  items=[%s]\n' "$(date '+%F %T')" "${PROFILE:-custom}" \
    "$n_ok" "$n_na" "$n_fail" "${PLAN[*]}" >>"$STATE_DIR/runs.log"
  event run_done ok "$n_ok" skipped "$n_na" failed "$n_fail"
  [[ $n_fail -eq 0 ]]
}

pending_reviews() {
  local p
  [[ -r $STATE_DIR/managed.list ]] || return 0
  while read -r p; do [[ -e $p.new ]] && echo "    $p.new"; done <"$STATE_DIR/managed.list"
}

wrap_names() { # names... -> comma list wrapped at the terminal width, never inside a name
  local width line="" n
  width=$(($(tput cols 2>/dev/null || echo 80) - 6))
  ((width > 100)) && width=100
  for n in "$@"; do
    if [[ -n $line && $((${#line} + ${#n} + 2)) -gt $width ]]; then
      printf '    %s,\n' "$line"
      line=$n
    else
      line=${line:+$line, }$n
    fi
  done
  [[ -z $line ]] || printf '    %s\n' "$line"
}

# Show the plan, confirm, run.
confirm_and_run() {
  local id sys=() usr=()
  for id in "${PLAN[@]}"; do
    if is_system_item "$id"; then sys+=("${I_NAME[$id]}"); else usr+=("${I_NAME[$id]}"); fi
  done
  [[ ${#PLAN[@]} -gt 0 ]] || die "nothing to install here"
  ui_title "Plan — ${#PLAN[@]} items for $TARGET_USER on $(uname -n | cut -d. -f1)"
  if [[ ${#sys[@]} -gt 0 ]]; then
    printf '  %s\n' "${C_BOLD}System${C_RESET} ${C_DIM}(uses sudo)${C_RESET}"
    wrap_names "${sys[@]}"
  fi
  if [[ ${#usr[@]} -gt 0 ]]; then
    printf '  %s\n' "${C_BOLD}Your account${C_RESET} ${C_DIM}(no sudo)${C_RESET}"
    wrap_names "${usr[@]}"
  fi
  if [[ ${#PLAN_SKIPPED[@]} -gt 0 ]]; then
    printf '  %s\n' "${C_BOLD}Not possible here${C_RESET}"
    for id in "${PLAN_SKIPPED[@]}"; do
      printf '    %s — %s\n' "${I_NAME[$id]}" "$(item_unavailable_reason "$id" || true)$(item_available "$id" && echo "a dependency can't be installed")"
    done
  fi
  echo
  if ! $DRY_RUN && ! $ASSUME_YES; then
    [[ $UI == none ]] && die "no terminal to confirm on — add --yes to proceed (or --dry-run to preview)"
    ui_confirm "Go ahead?" yes || {
      ui_note "Nothing was changed."
      return 0
    }
  fi
  local k
  for k in "${PENDING_SAVE[@]}"; do config_set "$k" "${!k}"; done
  execute_plan
}

# ------------------------------------------------------------------------------
# Wizard
# ------------------------------------------------------------------------------
wizard() {
  [[ $UI != none ]] || die "no terminal: use 'serverkit apply --profile NAME --yes' or 'serverkit install ITEM... --yes'"
  ui_banner "$(platform_line) — setting up ${C_BOLD}$TARGET_USER${C_RESET}"
  if ! system_supported; then
    ui_note "System items aren't available on $DISTRO_NAME$($IS_IMMUTABLE && echo " (image-based OS)"); your own tools still are."
  fi
  local want_admin=""
  if [[ $TARGET_USER == root ]]; then
    ui_note "Running as root: most tools come from Homebrew, which needs a normal user account."
    if [[ $OS == linux ]] && system_supported && ui_confirm "Create an admin (sudo) user now, with root's SSH keys?" yes; then
      local name
      name=$(ui_input "Name for the new admin user" "" "e.g. ada")
      [[ -n $name ]] && wizard_set ADMIN_USER "$name" && want_admin=admin-user
    fi
  fi

  # 1. profile
  local p opts=()
  for p in personal apps desktop minimal; do
    [[ -f $SK_ROOT/profiles/$p.conf ]] || continue
    opts+=("$(printf '%-9s %s' "$p" "$(settings_parse_desc "$p")")"$'\t'"$p")
  done
  opts+=("$(printf '%-9s %s' custom "start from nothing and pick items yourself")"$'\t'custom)
  p=$(ui_choose "What is this machine?" "${opts[@]}") || exit 130
  [[ -n $p ]] || exit 130
  PROFILE=""
  [[ $p == custom ]] || PROFILE=$p
  settings_load "$PROFILE"

  # 2. items
  local id pre="" label items=() cat desc cols room tag
  if [[ -n $PROFILE ]]; then pre=$(printf '%s' "$ITEMS" | tr -s '[:space:]' ','); fi
  cols=$(tput cols 2>/dev/null || echo 100)
  for cat in "${CAT_ORDER[@]}"; do
    for id in "${ITEM_ORDER[@]}"; do
      [[ ${I_CAT[$id]} == "$cat" ]] || continue
      item_available "$id" || continue
      tag=""
      is_system_item "$id" && tag="  [sudo]"
      # keep one line per item: shorten the description, never the tag
      room=$((cols - 4 - 13 - 27 - ${#tag}))
      desc=${I_DESC[$id]}
      ((room < 10)) && room=10
      ((${#desc} > room)) && desc="${desc:0:room-1}…"
      label=$(printf '%-12s %-26s %s%s' "${CAT_TITLE[$cat]%% *}" "${I_NAME[$id]}" "$desc" "$tag")
      items+=("$label"$'\t'"$id")
    done
  done
  if [[ $UI == gum ]]; then
    ui_note "x or tab: select · ctrl+a: all · ↑↓: move · enter: done — the profile's picks are preselected"
  fi
  local chosen
  chosen=$(ui_multi "Pick what to install" "$pre" "${items[@]}") || exit 130
  local sel=()
  while IFS= read -r id; do [[ -n $id ]] && sel+=("$id"); done <<<"$chosen"
  [[ ${#sel[@]} -gt 0 || -n $want_admin ]] || {
    ui_note "Nothing selected — nothing changed."
    exit 0
  }
  resolve_plan "${sel[@]}" ${want_admin:+"$want_admin"}

  # 3. the few questions that matter for what was picked
  wizard_settings
  confirm_and_run
}

settings_parse_desc() { # profile -> PROFILE_DESC without loading it
  sed -n 's/^PROFILE_DESC="\(.*\)"$/\1/p' "$SK_ROOT/profiles/$1.conf"
}

in_plan() { [[ " ${PLAN[*]} " == *" $1 "* ]]; }

# Wizard answers apply to this run now and are saved only once you confirm.
PENDING_SAVE=()
wizard_set() { # NAME VALUE
  printf -v "$1" '%s' "$2"
  PENDING_SAVE+=("$1")
}

wizard_settings() {
  if in_plan ssh-hardening && [[ $SSH_PASSWORD_AUTH != no && $TARGET_USER != root && -s $TARGET_HOME/.ssh/authorized_keys ]]; then
    if ui_confirm "You log in with an SSH key. Turn off SSH password logins?" no; then
      wizard_set SSH_PASSWORD_AUTH no
    fi
  fi
  if { in_plan cloudflared || in_plan nginx; } && [[ -z $DOMAIN ]]; then
    local d
    d=$(ui_input "Domain for your sites (optional, e.g. example.com)" "" "example.com")
    [[ -n $d ]] && wizard_set DOMAIN "$d"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Other commands
# ------------------------------------------------------------------------------
cmd_list() {
  if $OPT_JSON; then
    catalog_json
    return
  fi
  local cat id mark reason shown
  for cat in "${CAT_ORDER[@]}"; do
    [[ -n $OPT_CATEGORY && $OPT_CATEGORY != "$cat" ]] && continue
    shown=false
    for id in "${ITEM_ORDER[@]}"; do
      [[ ${I_CAT[$id]} == "$cat" ]] || continue
      reason=${I_WHY[$id]}
      [[ -n $reason ]] && ! $OPT_ALL && continue
      $shown || printf '\n%s\n' "${C_BOLD}${CAT_TITLE[$cat]}${C_RESET}"
      shown=true
      mark="  "
      is_system_item "$id" && mark="${C_YELLOW}⚑${C_RESET} "
      if [[ -n $reason ]]; then
        printf '  %s%-16s %s\n' "$mark" "$id" "${C_DIM}${I_DESC[$id]} — ${reason}${C_RESET}"
      else
        printf '  %s%-16s %s\n' "$mark" "$id" "${I_DESC[$id]}"
      fi
    done
  done
  printf '\n%s\n' "${C_DIM}⚑ = changes the system (uses sudo)$($OPT_ALL || echo " · --all also shows items not offered here")${C_RESET}"
}

cmd_info() {
  local id=${ARGS[0]:-}
  [[ -n $id ]] || die "usage: serverkit info ITEM"
  is_item "$id" || die "unknown item '$id' — see: serverkit list"
  printf '%s — %s\n' "${C_BOLD}${I_NAME[$id]}${C_RESET}" "${I_DESC[$id]}"
  printf '  category   %s\n' "${CAT_TITLE[${I_CAT[$id]}]}"
  printf '  here       %s\n' "$(item_spec "$id" || true)$(item_available "$id" || echo " — unavailable: $(item_unavailable_reason "$id")")"
  printf '  scope      %s\n' "$(item_scope "$id")"
  local deps
  read -ra deps <<<"$(item_deps "$id")"
  [[ ${#deps[@]} -gt 0 ]] && printf '  needs      %s\n' "${deps[*]}"
  printf '  all specs  %s\n' "${I_SPEC[$id]}"
  [[ -f $SK_ROOT/docs/items/$id.md ]] && { echo; cat "$SK_ROOT/docs/items/$id.md"; }
  return 0
}

cmd_profiles() {
  local f p
  for f in "$SK_ROOT"/profiles/[!_]*.conf; do
    p=$(basename "$f" .conf)
    (
      settings_load "$p" 2>/dev/null
      local n=0 id
      for id in $ITEMS; do item_available "$id" && ((n++)); done
      printf '\n%s — %s\n  %s\n' "${C_BOLD}$p${C_RESET}" "$PROFILE_DESC" "${C_DIM}$n items here: $ITEMS${C_RESET}"
    )
  done
  printf '\n%s\n' "${C_DIM}preview one: serverkit apply --profile NAME --dry-run${C_RESET}"
}

cmd_config() {
  local sub=${ARGS[0]:-show} k
  case "$sub" in
  show)
    printf '%s\n' "${C_DIM}settings in force ($([[ -n $PROFILE ]] && echo "profile $PROFILE" || echo "no profile")); saved ones live in $CONFIG_DIR/config.conf${C_RESET}"
    for k in "${SETTING_NAMES[@]}"; do
      [[ $k == ITEMS || $k == PROFILE_DESC ]] && continue
      printf '  %-20s %-40s %s\n' "$k" "${!k}" "${C_DIM}${SETTING_SRC[$k]}${C_RESET}"
    done
    ;;
  set)
    local kv=${ARGS[1]:-}
    [[ $kv =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "usage: serverkit config set NAME=VALUE"
    config_set "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    ok "saved ${BASH_REMATCH[1]} in $CONFIG_DIR/config.conf"
    ;;
  edit)
    as_user mkdir -p "$CONFIG_DIR"
    [[ -e $CONFIG_DIR/config.conf ]] || config_set SSH_PASSWORD_AUTH "$SSH_PASSWORD_AUTH"
    "${EDITOR:-vi}" "$CONFIG_DIR/config.conf"
    ;;
  *) die "usage: serverkit config [show|set NAME=VALUE|edit]" ;;
  esac
}

cmd_status() {
  printf '%s\n' "${C_BOLD}Recent runs${C_RESET}"
  if [[ -s $STATE_DIR/runs.log ]]; then tail -n 5 "$STATE_DIR/runs.log" | sed 's/^/  /'; else echo "  none yet"; fi
  local pending
  pending=$(pending_reviews)
  printf '\n%s\n' "${C_BOLD}Files waiting for your review${C_RESET}"
  if [[ -n $pending ]]; then printf '%s\n' "$pending"; else echo "  none"; fi
}

cmd_doctor() {
  printf '%s\n' "${C_BOLD}serverkit $SK_VERSION${C_RESET}  ($SK_ROOT)"
  printf '  %-18s %s\n' platform "$(platform_line)" family "$FAMILY" "package manager" "$PM" \
    user "$TARGET_USER ($TARGET_HOME)" bash "$BASH_VERSION"
  printf '  %-18s %s\n' "system items" "$(system_supported && echo yes || echo "no — $DISTRO_NAME isn't a supported family or is image-based")"
  printf '  %-18s %s\n' "Homebrew" "$(brew_supported && { brew_find && echo "yes: $BREW" || echo "supported, not installed yet"; } || echo "no — $([[ $TARGET_USER == root ]] && echo "running as root" || echo "unsupported CPU/libc")")"
  printf '  %-18s %s\n' "sudo" "$(is_root && echo "running as root" || { can_sudo && echo "yes (cached)" || { have sudo && echo "will ask for your password" || echo "not installed"; }; })"
  printf '  %-18s %s\n' "systemd" "$($HAS_SYSTEMD && echo yes || echo "no — service items will be skipped")"
  printf '  %-18s %s\n' "terminal UI" "$UI$([[ $UI == gum ]] && echo " ($GUM)")"
  printf '  %-18s %s\n' "config" "$CONFIG_DIR/config.conf$([[ -e $CONFIG_DIR/config.conf ]] || echo " (not created yet)")"
  local n=0 id
  for id in "${ITEM_ORDER[@]}"; do item_available "$id" && ((n++)); done
  printf '  %-18s %s of %s\n' "items offered" "$n" "${#ITEM_ORDER[@]}"
}

cmd_health() {
  _h() { printf '\n%s\n' "${C_BOLD}${C_MAGENTA}── $1${C_RESET}"; }
  _h "$(uname -n) · $(platform_line)"
  uptime
  if [[ $OS == mac ]]; then
    _h memory
    memory_pressure 2>/dev/null | tail -n 1
    _h disks
    df -h / /System/Volumes/Data 2>/dev/null
  else
    _h memory
    free -h
    _h disks
    df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null
    grep -q '^md' /proc/mdstat 2>/dev/null && { _h RAID; cat /proc/mdstat; }
    have zpool && { _h ZFS; zpool status -x; zpool list; }
    if have smartctl && ! $IS_VM && ! $IS_CONTAINER && can_sudo; then
      _h "SMART health"
      local d
      for d in /dev/sd? /dev/nvme?; do
        [[ -e $d ]] || continue
        printf '  %-14s %s\n' "$d" "$(as_root_q smartctl -H "$d" 2>/dev/null | grep -iE 'overall-health|SMART Health' | cut -d: -f2- | sed 's/^ *//')"
      done
    fi
    if $HAS_SYSTEMD; then
      _h services
      local s
      for s in ssh sshd nginx docker tailscaled cloudflared fail2ban firewalld ufw k3s; do
        svc_exists "$s" && printf '  %-14s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
      done
      _h "failed units"
      systemctl --failed --no-legend 2>/dev/null | sed 's/^/  /'
      [[ -e /var/run/reboot-required ]] && { _h reboot; echo "  a reboot is required (updates installed)"; }
    fi
  fi
  have docker && docker ps >/dev/null 2>&1 && { _h containers; docker ps --format 'table {{.Names}}\t{{.Status}}'; }
  return 0
}

cmd_update() {
  if [[ -d $SK_ROOT/.git ]]; then
    git -C "$SK_ROOT" pull --ff-only && ok "serverkit updated to $(cat "$SK_ROOT/VERSION")"
  else
    ui_note "This copy wasn't installed from git. Re-run the installer to update:"
    echo "  curl -fsSL https://raw.githubusercontent.com/naserowaimer/serverkit/main/install.sh | sh"
  fi
}

# Core tools serverkit itself needs. Real installs always have them, but
# stripped-down images can lack one (minimal openSUSE has no awk): install
# them first, with consent, instead of failing halfway.
bootstrap_basics() {
  local t missing=() pkgs=()
  for t in awk sed grep tr cut head tail mktemp install stat date uname id curl; do have "$t" || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  detect_platform
  if [[ $OS != linux || $PM == none ]] || $IS_IMMUTABLE; then
    die "missing basic commands: ${missing[*]} — install them with your package manager, then run serverkit again"
  fi
  for t in "${missing[@]}"; do
    case $t in
    awk) pkgs+=(gawk) ;; sed | grep | curl) pkgs+=("$t") ;;
    *) pkgs+=(coreutils) ;;
    esac
  done
  printf 'serverkit needs %s, which this system lacks (package: %s).\n' "${missing[*]}" "${pkgs[*]}"
  if ! $ASSUME_YES; then
    [[ -t 0 ]] || die "run again with --yes to install them, or install them yourself"
    local ans
    read -r -p "Install now with $PM? [Y/n] " ans </dev/tty
    [[ ${ans:-y} =~ ^[Yy] ]] || die "nothing was changed"
  fi
  local ok=false
  case $PM in
  apt) as_root env DEBIAN_FRONTEND=noninteractive apt-get update -q && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" && ok=true ;;
  dnf) as_root dnf -y -q install "${pkgs[@]}" && ok=true ;;
  pacman) as_root pacman -S --needed --noconfirm "${pkgs[@]}" && ok=true ;;
  zypper) as_root zypper --non-interactive install "${pkgs[@]}" && ok=true ;;
  esac
  $ok || die "could not install ${pkgs[*]} — install them yourself, then run serverkit again"
  hash -r
}

# ------------------------------------------------------------------------------
OPT_PROFILE="" OPT_ONLY="" OPT_SKIP="" OPT_USER="" OPT_CATEGORY=""
OPT_JSON=false OPT_ALL=false
OPT_SET=() ARGS=()

sk_main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --profile) OPT_PROFILE=${2:?--profile needs a name}; shift ;;
    --profile=*) OPT_PROFILE=${1#*=} ;;
    --only) OPT_ONLY=${2:?}; shift ;;
    --skip) OPT_SKIP=${2:?}; shift ;;
    --set) OPT_SET+=("${2:?--set needs NAME=VALUE}"); shift ;;
    --user) OPT_USER=${2:?}; shift ;;
    --category) OPT_CATEGORY=${2:?}; shift ;;
    --events) EVENTS_FILE=${2:?}; shift ;;
    -n | --dry-run) DRY_RUN=true ;;
    -y | --yes) ASSUME_YES=true ;;
    -v | --verbose) VERBOSE=true ;;
    -q | --quiet) QUIET=true ;;
    --force) FORCE=true ;;
    --plain) SERVERKIT_UI=plain ;;
    --json) OPT_JSON=true ;;
    --all) OPT_ALL=true ;;
    -h | --help) cmd=help ;;
    --version) cmd=version ;;
    -*) die "unknown option: $1 (see: serverkit --help)" ;;
    *) if [[ -z $cmd ]]; then cmd=$1; else ARGS+=("$1"); fi ;;
    esac
    shift
  done

  case "$cmd" in
  help) usage; return 0 ;;
  version) echo "serverkit $SK_VERSION"; return 0 ;;
  esac

  # Core tools serverkit itself needs (present on every supported system, but
  # stripped-down images sometimes lack one): say which, instead of failing oddly.
  bootstrap_basics

  trap on_interrupt INT TERM
  trap 'sk_cleanup; fix_ownership' EXIT
  sk_tmp_init
  init_context
  [[ -n $OPT_PROFILE && ! -f $SK_ROOT/profiles/$OPT_PROFILE.conf ]] &&
    die "no profile '$OPT_PROFILE' — have: $(for f in "$SK_ROOT"/profiles/[!_]*.conf; do basename "$f" .conf; done | paste -sd' ' -)"
  PROFILE=$OPT_PROFILE
  settings_load "$PROFILE"
  case "$cmd" in
  "" | setup | install | apply | plan) ui_init ;;
  esac
  [[ $cmd == plan ]] && DRY_RUN=true

  case "$cmd" in
  "" | setup)
    if [[ -n $PROFILE ]]; then cmd=apply; else
      wizard
      return
    fi
    ;;
  esac

  case "$cmd" in
  install | apply | plan)
    local sel=() id
    if [[ ${#ARGS[@]} -gt 0 ]]; then
      sel=("${ARGS[@]}")
    elif [[ -n $PROFILE ]]; then
      read -ra sel <<<"$ITEMS"
      if [[ -n $OPT_ONLY ]]; then
        local only=() o
        for o in ${OPT_ONLY//,/ }; do
          [[ " ${sel[*]} " == *" $o "* ]] || die "'$o' isn't in profile $PROFILE"
          only+=("$o")
        done
        sel=("${only[@]}")
      fi
    else
      [[ $cmd == install ]] && die "usage: serverkit install ITEM... (see: serverkit list)"
      wizard
      return
    fi
    if [[ -n $OPT_SKIP ]]; then
      local keep=()
      for id in "${sel[@]}"; do [[ ",$OPT_SKIP," == *",$id,"* ]] || keep+=("$id"); done
      sel=("${keep[@]}")
    fi
    [[ ${#sel[@]} -gt 0 ]] || die "nothing selected"
    for id in "${sel[@]}"; do is_item "$id" || die "unknown item '$id' — see: serverkit list"; done
    resolve_plan "${sel[@]}"
    [[ -z $OPT_SKIP ]] || {
      local keep=()
      for id in "${PLAN[@]}"; do [[ ",$OPT_SKIP," == *",$id,"* ]] || keep+=("$id"); done
      PLAN=("${keep[@]}")
    }
    confirm_and_run
    ;;
  list) cmd_list ;;
  info) cmd_info ;;
  profiles) cmd_profiles ;;
  config) cmd_config ;;
  status) cmd_status ;;
  doctor) ui_init; cmd_doctor ;;
  health) cmd_health ;;
  update) cmd_update ;;
  *) die "unknown command '$cmd' — see: serverkit --help" ;;
  esac
}
