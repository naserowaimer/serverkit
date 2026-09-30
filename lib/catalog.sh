# shellcheck shell=bash
# ==============================================================================
#  catalog — load catalog/apps.tsv and decide, for each item, how (and
#  whether) it installs on this machine.
# ==============================================================================

CAT_ORDER=()   # category ids in display order
ITEM_ORDER=()  # item ids in install order
declare -gA CAT_TITLE=() I_CAT=() I_NAME=() I_DESC=() I_SPEC=() I_NEEDS=()

catalog_load() {
  local line id cat name desc spec needs
  CAT_ORDER=() ITEM_ORDER=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    if [[ $line == @cat\ * ]]; then
      line=${line#@cat }
      CAT_ORDER+=("${line%%|*}")
      CAT_TITLE[${line%%|*}]=${line#*|}
      continue
    fi
    IFS='|' read -r id cat name desc spec needs <<<"$line"
    ITEM_ORDER+=("$id")
    I_CAT[$id]=$cat I_NAME[$id]=$name I_DESC[$id]=$desc I_SPEC[$id]=$spec I_NEEDS[$id]=${needs//,/ }
  done <"$SK_ROOT/catalog/apps.tsv"
}

is_item() { [[ -n ${I_CAT[$1]+x} ]]; }

# Resolution for this machine, computed once by catalog_resolve (no subshells:
# the UI lists ~140 items and must stay instant).
declare -gA I_RES=() I_WHY=()

_resolve_spec() { # id -> REPLY = "kind:arg" (most specific target wins), or ""
  local tok r t rank=0
  REPLY=""
  for tok in ${I_SPEC[$1]}; do
    t=${tok%%=*}
    case "$t" in
    "$DISTRO_ID") r=4 ;;
    "$FAMILY") r=3 ;;
    "$OS") r=2 ;;
    all) r=1 ;;
    *) r=0 ;;
    esac
    if ((r > rank)); then
      rank=$r
      REPLY=${tok#*=}
    fi
  done
}

_resolve_why() { # id spec -> REPLY = reason it can't install here, or ""
  local kind=${2%%:*}
  REPLY=""
  if [[ -z $2 ]]; then
    REPLY="not offered on $DISTRO_NAME"
    return
  fi
  if [[ $kind == none ]]; then
    REPLY="not packaged for $DISTRO_NAME"
    return
  fi
  [[ $1 == homebrew ]] && kind=brew
  case "$kind" in
  brew | cask | npm)
    brew_supported || REPLY="needs Homebrew, which can't run here$([[ $TARGET_USER == root ]] && echo " as root (use --user NAME)")"
    ;;
  flatpak) have flatpak || system_supported || REPLY="needs Flatpak" ;;
  sys | pkg)
    system_supported || REPLY="system packages can't be managed on $DISTRO_NAME$($IS_IMMUTABLE && echo " (image-based OS)")"
    ;;
  esac
}

catalog_resolve() { # call again whenever platform or user changes
  local id
  for id in "${ITEM_ORDER[@]}"; do
    _resolve_spec "$id"
    I_RES[$id]=$REPLY
    _resolve_why "$id" "$REPLY"
    I_WHY[$id]=$REPLY
  done
}

item_spec() { printf '%s' "${I_RES[$1]}"; }
item_kind() { printf '%s' "${I_RES[$1]%%:*}"; }
item_unavailable_reason() { printf '%s' "${I_WHY[$1]}"; }
item_available() { [[ -z ${I_WHY[$1]} ]]; }

# system = needs root (native packages, system config); user = the person's own.
item_scope() {
  case "${I_RES[$1]%%:*}" in sys | pkg) echo system ;; *) echo user ;; esac
}
is_system_item() { case "${I_RES[$1]%%:*}" in sys | pkg) return 0 ;; *) return 1 ;; esac; }

# Dependencies declared in the catalog plus the implied ones.
item_deps() {
  local d=${I_NEEDS[$1]}
  case "${I_RES[$1]%%:*}" in
  brew | cask) d+=" homebrew" ;;
  flatpak) d+=" flatpak" ;;
  npm) d+=" runtimes" ;;
  esac
  printf '%s' "$d"
}

# resolve_plan ID... -> PLAN (array): the items plus their dependencies,
# available here, in catalog order. Unavailable ones land in PLAN_SKIPPED.
PLAN=() PLAN_SKIPPED=()
resolve_plan() {
  local -A want=()
  local queue=("$@") id d
  while [[ ${#queue[@]} -gt 0 ]]; do
    id=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -n ${want[$id]+x} ]] && continue
    is_item "$id" || die "unknown item '$id' — see: serverkit list"
    want[$id]=1
    for d in $(item_deps "$id"); do queue+=("$d"); done
  done
  PLAN=() PLAN_SKIPPED=()
  local -A skipped=()
  local blocked
  for id in "${ITEM_ORDER[@]}"; do
    [[ -n ${want[$id]+x} ]] || continue
    blocked=""
    for d in $(item_deps "$id"); do [[ -n ${skipped[$d]+x} ]] && blocked=$d; done
    if [[ -z $blocked ]] && item_available "$id"; then
      PLAN+=("$id")
    else
      PLAN_SKIPPED+=("$id")
      skipped[$id]=1
    fi
  done
}

catalog_json() { # every item with its resolution on this machine
  local id out f v deps
  json_q "$OS"; out="{\"platform\":{\"os\":$REPLY"
  json_q "$FAMILY"; out+=",\"family\":$REPLY"
  json_q "$DISTRO_NAME"; out+=",\"distro\":$REPLY"
  json_q "$ARCH"; out+=",\"arch\":$REPLY},\"categories\":["
  for id in "${CAT_ORDER[@]}"; do
    json_q "$id"; out+="{\"id\":$REPLY"
    json_q "${CAT_TITLE[$id]}"; out+=",\"title\":$REPLY},"
  done
  out="${out%,}],\"items\":["
  for id in "${ITEM_ORDER[@]}"; do
    deps=$(item_deps "$id")
    read -ra deps <<<"$deps"
    out+="{"
    for f in id category name description method scope reason needs; do
      case $f in
      id) v=$id ;; category) v=${I_CAT[$id]} ;; name) v=${I_NAME[$id]} ;;
      description) v=${I_DESC[$id]} ;; method) v=${I_RES[$id]} ;; reason) v=${I_WHY[$id]} ;;
      scope) if is_system_item "$id"; then v=system; else v=user; fi ;;
      needs) v="${deps[*]}" ;;
      esac
      json_q "$v"
      out+="\"$f\":$REPLY,"
    done
    if [[ -z ${I_WHY[$id]} ]]; then out+="\"available\":true},"; else out+="\"available\":false},"; fi
  done
  printf '%s]}\n' "${out%,}"
}
