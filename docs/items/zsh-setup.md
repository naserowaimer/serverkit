Your ~/.zshrc gets one marked line that loads ~/.config/serverkit/zshrc; your
own settings go after it. zsh becomes your login shell only if it's listed in
/etc/shells and starts cleanly.

If perl or apt prints "Setting locale failed" after you SSH in from a Mac:
macOS Terminal sends LC_CTYPE=UTF-8, which isn't a Linux locale. This zshrc
swaps it for en_US.UTF-8 (or C.UTF-8). To stop the Mac sending it at all:
Terminal > Settings > Profiles > Advanced, untick "Set locale environment
variables on startup".
