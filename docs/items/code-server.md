code-server listens on 127.0.0.1 only. When Tailscale is connected, and HTTPS
certificates are on for your tailnet, serverkit also serves it to your tailnet
only (tailscale serve, never funnel):

    https://<this-machine>.<tailnet>.ts.net:8447

Pick another port with --set CODE_SERVER_TAILNET_PORT=8448, or turn it off
with --set CODE_SERVER_TAILNET_PORT=off. A port already in use is left alone.
Without Tailscale, use an SSH tunnel:

    ssh -L 8080:localhost:8080 you@host   then open http://localhost:8080

The password is in ~/.config/code-server/config.yaml. serverkit never edits an
existing config, but warns if it listens on anything other than localhost.
