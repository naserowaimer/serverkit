Copy mode works like vim's normal mode, yanks reach your local clipboard over
SSH (OSC 52), and `prefix f` fuzzy-searches the scrollback. The full key list
is at the top of ~/.config/serverkit/tmux.conf.

Sessions survive a reboot: tmux-resurrect and tmux-continuum (via tpm, in
~/.tmux/plugins) save windows, panes, folders and screen text every 15 minutes
to ~/.local/share/tmux/resurrect/ (only you can read it), and restore them when
the tmux server starts again. Programs aren't restarted, only their panes.

    prefix C-s      save now
    prefix C-r      restore the last save
    serverkit health    shows whether autosave is on and when it last saved

Re-running this on a machine with tmux already open is safe: it loads the
plugins into the running server and saves once. It never restarts tmux or
touches a pane.

Autosave rides on status-right. If you set status-right yourself, do it above
the serverkit blocks in ~/.tmux.conf (or above your own `run tpm` line);
setting it later silently turns autosave off.
