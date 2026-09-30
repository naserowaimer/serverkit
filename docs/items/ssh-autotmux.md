Every SSH login opens (or re-attaches) the tmux session "main", so a dropped
connection never kills your work. Escape hatches — none read your shell config:

    ssh host -t bash -l              plain bash, no tmux
    ssh host -t 'NO_TMUX=1 zsh -l'   zsh without tmux
    ssh host tmux kill-server        kill a stuck tmux
    ssh host touch .no-tmux          turn it off (rm .no-tmux to turn it back on)
