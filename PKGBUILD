# Maintainer: ShedOS <https://github.com/theshedman/shedos>
#
# Root-owned system payload: the unified `shedman` CLI (plus Git-style
# subcommand binaries under /usr/libexec/shedman/), systemd units, and /etc
# drop-ins. Legacy `shedos-*` names survive as silent back-compat shims in
# /usr/bin/. Anything DE-specific (hyprland bindings, waybar launchers)
# lives in shedos-hyprland, not here.

pkgname=shedos-system
pkgver=2026.04.24
pkgrel=7
pkgdesc='ShedOS system utilities (shedman CLI), systemd units, and /etc drop-ins'
arch=('any')
url='https://github.com/theshedman/shedos'
license=('GPL-3.0-or-later')
depends=(
    'bash'
    'systemd'
    'pacman-contrib'   # checkupdates
    'coreutils'        # sha256sum, install
    'diffutils'        # diff for `shedman config --sync --list-diffs`
    'sudo'
    'python'           # shedman config --review, shedman doctor
    'python-textual'   # merge TUI framework
    'python-rich'      # transitive dep of textual, declared for clarity
    'snapper'          # pre/post btrfs snapshots + --rollback (Phase 3 B#1)
    'btrfs-progs'      # shedman rollback calls `btrfs subvolume`
    'lm_sensors'       # shedman health CPU-temp metric (Phase 4 B#1)
    'python-tomlkit'   # format-preserving system.toml writes for Phase 6A
                       # bidirectional adoption (network.firewall, …)
    'ufw'              # `[network.firewall]` reconciler shells out to it
                       # (Phase 6A B#1)
)
optdepends=(
    'postgresql: shedos-pg-initdb.service initializes a cluster on first boot'
    'yay: AUR updates in `shedman update` and the first-boot apps installer'
    'kitty: default terminal for `shedman update` and the apps installer'
    'yad: GUI dialogs for `shedman welcome` and the apps installer'
    'networkmanager: connectivity check in the apps installer'
    'nm-connection-editor: launched by the apps installer when offline'
    'bash-completion: tab-complete subcommands and flags in bash'
    'zsh: tab-complete subcommands and flags in zsh (via /usr/share/zsh/site-functions/_shedman)'
)
backup=(
    'etc/sudoers.d/wheel'
    'etc/sddm.conf.d/theme.conf'
    'etc/NetworkManager/conf.d/20-connection-defaults.conf'
    'etc/NetworkManager/conf.d/wifi_backend.conf'
    'etc/os-release'
    'etc/shedos/system.toml'
)
install=shedos-system.install

package() {
    cd "$startdir"

    # Unified dispatcher + Git-style subcommand binaries. Users type
    # `shedman <cmd>`; the dispatcher execs /usr/libexec/shedman/<cmd>.
    install -Dm755 tree/usr/bin/shedman \
        "$pkgdir/usr/bin/shedman"

    install -d "$pkgdir/usr/libexec/shedman"
    local _libexec_shedman=(
        apply config conflicts db doctor health install logs rollback
        services status update updates upgrade-history welcome
        _config-sync _config-review
    )
    local _name
    for _name in "${_libexec_shedman[@]}"; do
        install -Dm755 "tree/usr/libexec/shedman/$_name" \
            "$pkgdir/usr/libexec/shedman/$_name"
    done

    # Silent back-compat shims at the legacy /usr/bin/shedos-* paths.
    # Pre-built in tree/; just copy with +x so `shedos-update` etc. keep
    # working indefinitely for muscle memory and third-party scripts.
    local _shims=(
        shedos-apply shedos-apps-installer shedos-check-conflicts
        shedos-check-health shedos-check-services shedos-check-updates
        shedos-doctor shedos-logs shedos-pg-user-bootstrap
        shedos-review-configs shedos-rollback shedos-sync-configs
        shedos-update shedos-upgrade-history shedos-welcome
    )
    for _name in "${_shims[@]}"; do
        install -Dm755 "tree/usr/bin/$_name" "$pkgdir/usr/bin/$_name"
    done

    # shedos-user-session isn't shedman-dispatched (internal hyprland
    # autostart helper), so it stays as a plain /usr/bin/ binary.
    install -Dm755 tree/usr/bin/shedos-user-session \
        "$pkgdir/usr/bin/shedos-user-session"

    # Shared plan engine — both `shedman apply` and `shedman doctor` add
    # /usr/lib/shedos to sys.path and `import apply_core`.
    install -Dm644 tree/usr/lib/shedos/apply_core.py \
        "$pkgdir/usr/lib/shedos/apply_core.py"

    # Declarative system state. /etc/shedos/system.toml is in backup=() so
    # user edits become .pacnew on upgrade; the example template is a
    # read-only reference under /usr/share/shedos/.
    install -Dm644 tree/etc/shedos/system.toml \
        "$pkgdir/etc/shedos/system.toml"
    install -Dm644 tree/usr/share/shedos/system.toml.example \
        "$pkgdir/usr/share/shedos/system.toml.example"

    # Snapper config template — copied to /etc/snapper/configs/root by the
    # install scriptlet on first install. Kept out of /etc itself so we
    # don't collide with the snapper package's ownership of that directory.
    install -Dm644 tree/usr/share/shedos/snapper/root.conf \
        "$pkgdir/usr/share/shedos/snapper/root.conf"

    # Shared data + app launcher entry for the apps installer.
    install -Dm644 tree/usr/share/shedos/apps-catalog.tsv \
        "$pkgdir/usr/share/shedos/apps-catalog.tsv"
    install -Dm644 tree/usr/share/applications/shedos-apps.desktop \
        "$pkgdir/usr/share/applications/shedos-apps.desktop"

    # Example user exclude list for `shedman config --sync`. Users copy
    # this to ~/.config/shedos/sync-exclude to opt out of specific files.
    install -Dm644 tree/usr/share/shedos/sync-exclude.example \
        "$pkgdir/usr/share/shedos/sync-exclude.example"

    # Systemd (system-scope)
    install -Dm644 tree/usr/lib/systemd/system/shedos-pg-initdb.service \
        "$pkgdir/usr/lib/systemd/system/shedos-pg-initdb.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-pg-user-bootstrap.service \
        "$pkgdir/usr/lib/systemd/system/shedos-pg-user-bootstrap.service"

    # Systemd (user-scope): update-check timer
    install -Dm644 tree/usr/lib/systemd/user/shedos-update-check.service \
        "$pkgdir/usr/lib/systemd/user/shedos-update-check.service"
    install -Dm644 tree/usr/lib/systemd/user/shedos-update-check.timer \
        "$pkgdir/usr/lib/systemd/user/shedos-update-check.timer"
    install -Dm644 tree/usr/lib/systemd/user/shedos-check-health.service \
        "$pkgdir/usr/lib/systemd/user/shedos-check-health.service"
    install -Dm644 tree/usr/lib/systemd/user/shedos-check-health.timer \
        "$pkgdir/usr/lib/systemd/user/shedos-check-health.timer"
    install -Dm644 tree/usr/lib/systemd/user/shedos-doctor.service \
        "$pkgdir/usr/lib/systemd/user/shedos-doctor.service"
    install -Dm644 tree/usr/lib/systemd/user/shedos-doctor.timer \
        "$pkgdir/usr/lib/systemd/user/shedos-doctor.timer"

    # /etc drop-ins. These go in backup=() so user edits become .pacnew on
    # upgrade rather than being silently clobbered.
    install -Dm440 tree/etc/sudoers.d/wheel \
        "$pkgdir/etc/sudoers.d/wheel"
    install -Dm644 tree/etc/sddm.conf.d/theme.conf \
        "$pkgdir/etc/sddm.conf.d/theme.conf"
    install -Dm644 tree/etc/NetworkManager/conf.d/20-connection-defaults.conf \
        "$pkgdir/etc/NetworkManager/conf.d/20-connection-defaults.conf"
    install -Dm644 tree/etc/NetworkManager/conf.d/wifi_backend.conf \
        "$pkgdir/etc/NetworkManager/conf.d/wifi_backend.conf"
    install -Dm644 tree/etc/os-release \
        "$pkgdir/etc/os-release"

    # Shell completions. Dispatcher-level discovery at completion time,
    # with per-subcommand flag completion via `--complete-{bash,zsh}`.
    install -Dm644 tree/usr/share/zsh/site-functions/_shedman \
        "$pkgdir/usr/share/zsh/site-functions/_shedman"
    install -Dm644 tree/etc/bash_completion.d/shedman \
        "$pkgdir/etc/bash_completion.d/shedman"
}
