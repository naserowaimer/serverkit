Use it with tmux:  mosh host -- tmux new -A -s phone

mosh redraws the screen instead of streaming it, so it has no scrollback of its
own: scroll in tmux's copy mode (scroll up, or prefix [ ). Some key chords may
not get through either; tmux's prefix keys do.

Firewall: over Tailscale nothing extra is needed. On a public interface mosh
needs UDP 60000-61000:  sudo ufw allow 60000:61000/udp
(or: sudo firewall-cmd --permanent --add-port=60000-61000/udp && sudo firewall-cmd --reload)
