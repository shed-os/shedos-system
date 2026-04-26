# Maintainer: ShedOS <https://github.com/theshedman/shedos>
#
# Root-owned system payload: the unified `shedman` CLI (plus its
# subcommand binaries under /usr/libexec/shedman/), systemd units, and /etc
# drop-ins. Legacy `shedos-*` names survive as silent back-compat shims in
# /usr/bin/. Anything DE-specific (hyprland bindings, waybar launchers)
# lives in shedos-hyprland, not here.

pkgname=shedos-system
pkgver=2026.04.25
pkgrel=6
pkgdesc='ShedOS system utilities (shedman CLI), systemd units, and /etc drop-ins'
arch=('any')
url='https://github.com/theshedman/shedos'
license=('GPL-3.0-or-later')
makedepends=(
    'scdoc'            # renders man/*.scd → /usr/share/man/man1/*.1
)
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
    'snapper'          # pre/post btrfs snapshots + shedman rollback
    'btrfs-progs'      # shedman rollback calls `btrfs subvolume`
    'lm_sensors'       # shedman health CPU-temp metric
    'python-tomlkit'   # format-preserving system.toml writes for
                       # bidirectional adoption (network.firewall, …)
    'ufw'              # `[network.firewall]` reconciler shells out to it
    'zram-generator'   # compressed swap-in-RAM via
                       # /etc/systemd/zram-generator.conf
    'tlp'              # canonical power manager (CPU + disk + radio +
                       # charge thresholds); install scriptlet enables
                       # tlp.service
    'ananicy-cpp'      # auto-renicer; install scriptlet enables
                       # ananicy-cpp.service
)
# Hard conflict with power-profiles-daemon: it competes with tlp for
# CPU governor ownership. `replaces=` lets pacman do a transactional
# swap on existing systems instead of erroring with "conflicting
# packages" on every upgrade.
conflicts=('power-profiles-daemon')
replaces=('power-profiles-daemon')
optdepends=(
    'postgresql: shedos-pg-initdb.service initializes a cluster on first boot'
    'yay: AUR updates in `shedman update` and the first-boot apps installer'
    'kitty: default terminal for `shedman update` and the apps installer'
    'yad: GUI dialogs for `shedman welcome` and the apps installer'
    'networkmanager: connectivity check in the apps installer'
    'nm-connection-editor: launched by the apps installer when offline'
    'bash-completion: tab-complete subcommands and flags in bash'
    'zsh: tab-complete subcommands and flags in zsh (via /usr/share/zsh/site-functions/_shedman)'
    'fish: tab-complete subcommands and flags in fish (via /usr/share/fish/vendor_completions.d/shedman.fish)'
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

prepare() {
    # Render scdoc-format man-page sources to groff (.1) files. Source
    # of truth lives at man/*.scd; the rendered .1 files land in
    # man/build/ and are installed by package() below. Keeping the
    # render step out of package() means a malformed .scd surfaces
    # before the real install happens.
    cd "$startdir"
    install -d man/build
    for src in man/*.scd; do
        out=man/build/$(basename "${src%.scd}")
        scdoc < "$src" > "$out"
    done
}

package() {
    cd "$startdir"

    # The shedman dispatcher and its subcommand binaries. Users type
    # `shedman <cmd>`; the dispatcher execs /usr/libexec/shedman/<cmd>.
    install -Dm755 tree/usr/bin/shedman \
        "$pkgdir/usr/bin/shedman"

    install -d "$pkgdir/usr/libexec/shedman"
    local _libexec_shedman=(
        apply config conflicts db doctor health install kernel logs rollback
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

    # Limine multi-kernel renderer + the pacman hook that fires it on
    # every kernel install/upgrade/remove.
    install -Dm755 tree/usr/lib/shedos/render-limine-config.sh \
        "$pkgdir/usr/lib/shedos/render-limine-config.sh"
    install -Dm644 tree/usr/share/libalpm/hooks/95-shedos-limine-update.hook \
        "$pkgdir/usr/share/libalpm/hooks/95-shedos-limine-update.hook"

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

    # System tuning drop-ins. Not in backup=() because they're
    # ShedOS policy: editing them in /etc isn't supported, the canonical
    # surface is `[kernel.cmdline]` / future `[sysctl]` reconcilers in
    # /etc/shedos/system.toml. Users who need a one-off override drop
    # their own file with a higher number under /etc/sysctl.d/ etc.
    install -Dm644 tree/etc/sysctl.d/99-shedos-tuning.conf \
        "$pkgdir/etc/sysctl.d/99-shedos-tuning.conf"
    install -Dm644 tree/etc/udev/rules.d/50-shedos-usb-autosuspend.rules \
        "$pkgdir/etc/udev/rules.d/50-shedos-usb-autosuspend.rules"
    install -Dm644 tree/etc/udev/rules.d/60-shedos-ioschedulers.rules \
        "$pkgdir/etc/udev/rules.d/60-shedos-ioschedulers.rules"
    install -Dm644 tree/etc/udev/rules.d/61-shedos-hdd-readahead.rules \
        "$pkgdir/etc/udev/rules.d/61-shedos-hdd-readahead.rules"
    install -Dm644 tree/etc/modprobe.d/shedos-blacklist.conf \
        "$pkgdir/etc/modprobe.d/shedos-blacklist.conf"
    install -Dm644 tree/etc/systemd/zram-generator.conf \
        "$pkgdir/etc/systemd/zram-generator.conf"
    install -Dm644 tree/etc/systemd/oomd.conf.d/shedos.conf \
        "$pkgdir/etc/systemd/oomd.conf.d/shedos.conf"
    install -Dm644 tree/etc/security/limits.d/30-shedos-realtime.conf \
        "$pkgdir/etc/security/limits.d/30-shedos-realtime.conf"

    # Shell completions. Dispatcher-level discovery at completion time,
    # with per-subcommand flag completion via
    # `--complete-{bash,zsh,fish}`.
    install -Dm644 tree/usr/share/zsh/site-functions/_shedman \
        "$pkgdir/usr/share/zsh/site-functions/_shedman"
    install -Dm644 tree/etc/bash_completion.d/shedman \
        "$pkgdir/etc/bash_completion.d/shedman"
    install -Dm644 tree/usr/share/fish/vendor_completions.d/shedman.fish \
        "$pkgdir/usr/share/fish/vendor_completions.d/shedman.fish"

    # Man pages — rendered from man/*.scd by prepare() above; install
    # the rendered .1 files. `shedman help` is the primary discovery
    # surface; man pages are the secondary path for `man <cmd>`.
    install -d "$pkgdir/usr/share/man/man1"
    for _name in shedman shedman-update shedman-apply shedman-doctor \
                 shedman-rollback shedman-config shedman-status; do
        install -Dm644 "man/build/${_name}.1" \
            "$pkgdir/usr/share/man/man1/${_name}.1"
    done
}
