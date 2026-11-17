Writes /etc/ssh/sshd_config.d/10-serverkit.conf, checks it with `sshd -t`, and
rolls it back if sshd rejects it. Password logins stay on unless you set
SSH_PASSWORD_AUTH=no, and even then only once you have a key login.

It also reads your existing sshd config and warns (never fixes) about:
- a commented-out `#Match` whose indented lines are still live. sshd applies
  those lines to every user, not just the one the Match named.
- TCP forwarding turned off for you, which makes VS Code Remote-SSH hang and
  breaks `ssh -L` tunnels. A client-side workaround for VS Code:
  "remote.SSH.remoteServerListenOnSocket": true

`serverkit health` runs the same check.

