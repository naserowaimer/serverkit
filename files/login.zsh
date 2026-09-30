# managed-by:serverkit — SSH auto-tmux + login banner (sourced by serverkit's zshrc)
#
#  ESCAPE HATCHES — none of these read this file, so they work even if your
#  shell config is broken:
#    ssh host -t bash -l             plain bash, no tmux, no zsh
#    ssh host -t 'NO_TMUX=1 zsh -l'  zsh without tmux
#    ssh host tmux kill-server       kill a stuck tmux from outside
#    ssh host touch .no-tmux         turn auto-tmux off   (rm .no-tmux: back on)

# ---------- auto-tmux on SSH ----------
# Never `exec tmux`: if tmux fails you get a normal shell, not a dropped connection.
if [[ -o interactive && -n $SSH_CONNECTION && -z $TMUX && -z $NO_TMUX && ! -f $HOME/.no-tmux ]] &&
  command -v tmux >/dev/null 2>&1; then
  if tmux new-session -A -s main; then
    exit
  else
    print -P "%F{yellow}tmux failed to start — continuing in plain zsh%f"
  fi
fi

# ---------- banner ----------
_sk_banner() {
  local D=$'\e[38;5;240m' B=$'\e[38;5;39m' R=$'\e[0m' ip up w rule
  w=$(tput cols 2>/dev/null || echo 40)
  (( w > 46 )) && w=46
  (( w < 16 )) && w=40
  if command -v figlet >/dev/null 2>&1 && (( w >= 30 )); then
    figlet -f small -w "$w" -- "$USER" 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' |
      while IFS= read -r line; do print -r -- $'\e[38;5;208m'"$line"$'\e[0m'; done
  else
    print -r -- $'\e[1;38;5;208m'"${(U)USER}"$'\e[0m'
  fi
  if [[ $OSTYPE == darwin* ]]; then
    ip=$(ipconfig getifaddr en0 2>/dev/null)
    up=$(uptime | sed -e 's/.*up *//' -e 's/, *[0-9]* user.*//')
  else
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
  fi
  rule=$(printf "%${w}s" "" | tr ' ' '-')
  print -r -- "${D}${rule}${R}"
  print -r -- " ${B}${HOST%%.*}${R} ${D}·${R} ${ip:-?} ${D}·${R} ${D}${up}${R}"
  print -r -- "${D}${rule}${R}"
}

# Once per tmux session (not per pane); without tmux, once per SSH login.
if [[ -n $TMUX ]] && ! tmux show-environment SK_MOTD_SHOWN >/dev/null 2>&1; then
  tmux set-environment SK_MOTD_SHOWN 1
  [[ -r /run/motd.dynamic ]] && cat /run/motd.dynamic
  [[ -s /etc/motd ]] && cat /etc/motd
  _sk_banner
elif [[ -z $TMUX && -n $SSH_CONNECTION && -o interactive ]]; then
  _sk_banner
fi
unfunction _sk_banner
