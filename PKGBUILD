# Maintainer: ShedOS <https://github.com/theshedman/shedos>
#
# Root-owned system payload: /usr/bin/shedos-* utilities, systemd units, and
# /etc drop-ins. Anything DE-specific (hyprland bindings, waybar launchers)
# lives in shedos-hyprland, not here.

pkgname=shedos-system
pkgver=2026.04.23
pkgrel=1
pkgdesc='ShedOS system utilities, systemd units, and /etc drop-ins'
arch=('any')
url='https://github.com/theshedman/shedos'
license=('GPL-3.0-or-later')
depends=(
    'bash'
    'systemd'
    'pacman-contrib'   # checkupdates
    'coreutils'        # sha256sum, install
    'diffutils'        # diff for shedos-sync-configs --list-diffs
    'sudo'
    'python'           # shedos-review-configs
    'python-textual'   # shedos-review-configs TUI framework
    'python-rich'      # transitive dep of textual, declared for clarity
)
optdepends=(
    'postgresql: shedos-pg-initdb.service initializes a cluster on first boot'
    'yay: AUR update checks in shedos-check-updates / shedos-update'
    'kitty: default terminal the waybar indicator opens for shedos-update'
)
backup=(
    'etc/sudoers.d/wheel'
    'etc/sddm.conf.d/theme.conf'
    'etc/NetworkManager/conf.d/20-connection-defaults.conf'
    'etc/NetworkManager/conf.d/wifi_backend.conf'
    'etc/os-release'
)
install=shedos-system.install

package() {
    cd "$startdir"

    # Scripts
    install -d "$pkgdir/usr/bin"
    install -Dm755 tree/usr/bin/shedos-check-services \
        "$pkgdir/usr/bin/shedos-check-services"
    install -Dm755 tree/usr/bin/shedos-welcome \
        "$pkgdir/usr/bin/shedos-welcome"
    install -Dm755 tree/usr/bin/shedos-user-session \
        "$pkgdir/usr/bin/shedos-user-session"
    install -Dm755 tree/usr/bin/shedos-check-updates \
        "$pkgdir/usr/bin/shedos-check-updates"
    install -Dm755 tree/usr/bin/shedos-check-conflicts \
        "$pkgdir/usr/bin/shedos-check-conflicts"
    install -Dm755 tree/usr/bin/shedos-update \
        "$pkgdir/usr/bin/shedos-update"
    install -Dm755 tree/usr/bin/shedos-sync-configs \
        "$pkgdir/usr/bin/shedos-sync-configs"
    install -Dm755 tree/usr/bin/shedos-review-configs \
        "$pkgdir/usr/bin/shedos-review-configs"
    install -Dm755 tree/usr/bin/shedos-pg-user-bootstrap \
        "$pkgdir/usr/bin/shedos-pg-user-bootstrap"

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
}
