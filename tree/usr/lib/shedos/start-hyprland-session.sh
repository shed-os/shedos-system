#!/bin/bash
# Launch the user's Hyprland session via uwsm with all output captured
# into the journal. Invoked by shedos-greeter after greetd authenticates
# the user.
#
# Why systemd-cat: greetd execs the session command with stdin/stdout/
# stderr inherited from its TTY. Without the redirect, uwsm's status
# logs and Hyprland's startup banner land on the bare framebuffer
# console during the gap between cage exiting and Hyprland claiming
# DRM; visible as a brief flash of text. Routing them through
# journald keeps the screen clean and preserves the logs for
# `journalctl -t hyprland-session`.

exec systemd-cat -t hyprland-session -- \
    /usr/bin/uwsm start -g -1 -e -D Hyprland Hyprland
