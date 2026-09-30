The tunnel publishes local services with no open ports; Cloudflare terminates TLS.

Easiest: Cloudflare dashboard → Zero Trust → Networks → Tunnels → Create a
tunnel, then run the `sudo cloudflared service install <token>` it shows.

- TUNNEL_MODE=single: route `app.example.com` → `http://localhost:3000`
- TUNNEL_MODE=wildcard (apps profile): route `*.example.com` → `http://localhost:80`
  and let nginx pick the site by hostname.

Protect admin tools (code-server, dashboards) with Cloudflare Access.
