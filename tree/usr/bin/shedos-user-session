#!/bin/bash
# Ensure Bluetooth/Audio services
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
systemctl --user restart pipewire-pulse wireplumber

# Disable blueman notification daemon (user preference)
gsettings set org.blueman.general notification-daemon false
