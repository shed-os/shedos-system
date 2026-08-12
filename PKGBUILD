# Maintainer: ShedOS <https://github.com/Theshedman/shedos>
#
# Root-owned system payload: boot and UKI assembly, the Limine renderer,
# full-disk encryption, Secure Boot and TPM2, the session and login wiring,
# systemd units and /etc drop-ins. The eight verbs it adds to shedman ship
# with declarations beside them. Legacy `shedos-*` names survive as silent
# back-compat shims in /usr/bin/. Anything DE-specific (hyprland bindings,
# waybar launchers) lives in shedos-hyprland, not here.

pkgname=shedos-system
pkgver=2026.08.09
pkgrel=3
pkgdesc='ShedOS system utilities (shedman CLI), systemd units, and /etc drop-ins'
arch=('any')
url='https://github.com/shed-os/shedos-system'
license=('GPL-3.0-or-later')
makedepends=(
    'scdoc'            # renders man/*.scd → /usr/share/man/man1/*.1
)
# Carried whole from the package this was split out of. Several entries below
# belong to verbs that ship from shedman or the theme engine now, and they stay
# until the cutover reconciles the whole set: a bootstrap package that declares
# one dependency too few breaks boxes, and one too many costs disk.
depends=(
    'bash'
    'shedman'          # the dispatcher the eight verbs here plug into, and
                       # apply_core, which the recovery UI and mount-report
                       # import
    'systemd'
    'pacman-contrib'   # checkupdates
    'coreutils'        # sha256sum, install
    'diffutils'        # diff for the `list-diffs` answer at the sync prompt
    'sudo'
    'python'           # shedman config --review, shedman doctor
    'python-dbus'      # shedman fingerprint delete holds a D-Bus connection
                       # across Claim+DeleteEnrolledFinger+Release; gdbus
                       # closes the connection per call and loses the claim
    'python-textual'   # merge TUI framework
    'python-rich'      # transitive dep of textual, declared for clarity
    'python-pygments'  # syntax highlighting in merge TUI hunk panes
    'snapper'          # pre/post btrfs snapshots + shedman rollback
    'btrfs-progs'      # shedman rollback calls `btrfs subvolume`
    'lm_sensors'       # shedman health CPU-temp metric
    'smartmontools'    # shedos-smart-check.timer caches disk verdicts
                       # for the health SMART metric
    'python-tomlkit'   # format-preserving system.toml writes for
                       # bidirectional adoption (network.firewall, …)
    'ufw'              # `[network.firewall]` reconciler shells out to it
    'zram-generator'   # compressed swap-in-RAM via
                       # /etc/systemd/zram-generator.conf
    'tlp'              # canonical power manager (CPU + disk + radio +
                       # charge thresholds); install scriptlet enables
                       # tlp.service
    'ananicy-cpp-git'  # auto-renicer; install scriptlet enables
                       # ananicy-cpp.service. -git tracks post-1.2.0;
                       # tagged 1.1.1 fails on glibc 2.41+. See
                       # packages/aur.txt for the upstream context.
    'yay'              # shedman update + shedman install AUR path
    'kitty'            # shedman update runs interactively
    'libnotify'         # notify-send fallbacks
    'reflector'        # shedos-reflector.{service,timer} refresh mirrorlist
    'imagemagick'      # theme_renderer.py shells out to `magick` to
                       # generate wallpaper-blurred.png when a user-set
                       # wallpaper has no shipped -blurred companion
    'sbctl'            # secureboot verb manages the SB key set + verifies
    'tpm2-tools'       # tpm2 verb's TPM2 unlock primitives
    'libfido2'         # key add-key --fido2 enrollment, and the sd-encrypt
                       # initramfs hook only bundles it for boot unlock when
                       # it is present on the box at build time
    'systemd-ukify'    # single UKI signer (sbsign + PCR-11 .pcrsig, one pass)
    'sbsigntools'      # sbverify gates each UKI placement onto the ESP
)
# Hard conflict with power-profiles-daemon: it competes with tlp for
# CPU governor ownership. `replaces=` lets pacman do a transactional
# swap on existing systems instead of erroring with "conflicting
# packages" on every upgrade.
conflicts=('power-profiles-daemon')
replaces=('power-profiles-daemon')
optdepends=(
    'postgresql: shedos-pg-initdb.service initializes a cluster on first boot'
    'code: opt-in GUI merge backend for shedman config --review --gui (satisfied by code from extra or visual-studio-code-bin from AUR)'
)
backup=(
    'etc/sudoers.d/wheel'
    'etc/NetworkManager/conf.d/20-connection-defaults.conf'
    'etc/NetworkManager/conf.d/wifi_backend.conf'
    'etc/os-release'
    'etc/shedos/system.toml'
    'etc/shedos/review-exclude.toml'
    'etc/kernel/uki.conf'
    'etc/kernel/cmdline'
    'etc/kernel/cmdline-fallback'
)
install=shedos-system.install

source=("git+https://github.com/shed-os/shedos-system.git#tag=$pkgver")
sha256sums=('SKIP')

prepare() {
    # Render scdoc-format man-page sources to groff files. Source of truth
    # lives at man/*.scd; the rendered pages land in man/build/ and are
    # installed by package() below. Keeping the render step out of package()
    # means a malformed .scd surfaces before the real install happens.
    cd "$srcdir/shedos-system"
    install -d man/build
    for src in man/*.scd; do
        out=man/build/$(basename "${src%.scd}")
        scdoc < "$src" > "$out"
    done
}

package() {
    cd "$srcdir/shedos-system"

    # The verbs this package adds to shedman. The declarations are the
    # manifest: a verb ships because one names it, so a verb added without
    # its declaration does not ship silently — it does not ship at all, and
    # the pipeline's completeness check says which way round the mistake was.
    local _decl _name
    for _decl in tree/usr/share/shedman/verbs.d/*.toml; do
        _name=$(sed -n 's/^name = "\(.*\)"$/\1/p' "$_decl")
        install -Dm755 "tree/usr/libexec/shedman/$_name" \
            "$pkgdir/usr/libexec/shedman/$_name"
        install -Dm644 "$_decl" \
            "$pkgdir/usr/share/shedman/verbs.d/$(basename "$_decl")"
    done

    # Silent back-compat shims at the legacy /usr/bin/shedos-* paths.
    # Pre-built in tree/; just copy with +x so `shedos-update` etc. keep
    # working indefinitely for muscle memory and third-party scripts.
    local _shims=(
        shedos-apply shedos-apps-installer shedos-check-conflicts
        shedos-check-health shedos-check-services shedos-check-updates
        shedos-doctor shedos-logs shedos-pg-user-bootstrap
        shedos-review-configs shedos-rollback shedos-sync-configs
        shedos-update shedos-upgrade-history
    )
    for _name in "${_shims[@]}"; do
        install -Dm755 "tree/usr/bin/$_name" "$pkgdir/usr/bin/$_name"
    done

    # shedos-user-session isn't shedman-dispatched (internal hyprland
    # autostart helper), so it stays as a plain /usr/bin/ binary.
    install -Dm755 tree/usr/bin/shedos-user-session \
        "$pkgdir/usr/bin/shedos-user-session"

    # Orchestration state lib for in-place encryption; sourced by the reencrypt
    # driver and the encrypt subcommand. usr/lib/shedos installs file-by-file,
    # so a new lib needs its own line here or it does not ship.
    install -Dm644 tree/usr/lib/shedos/esp-state.sh \
        "$pkgdir/usr/lib/shedos/esp-state.sh"

    # Cross-kernel DKMS coverage check, shared by retire-shedos-kernel and the
    # shedman doctor DKMS audit.
    install -Dm755 tree/usr/lib/shedos/dkms-coverage \
        "$pkgdir/usr/lib/shedos/dkms-coverage"

    # The reencrypt driver (the initramfs one-shot ExecStart) plus its unit and
    # mkinitcpio install hook. The arm step builds a transient initramfs that
    # stages the hook; without these lines none of the machinery ships.
    install -Dm755 tree/usr/lib/shedos/reencrypt-driver.sh \
        "$pkgdir/usr/lib/shedos/reencrypt-driver.sh"
    install -Dm755 tree/usr/lib/shedos/tpm2-pin-boot.sh \
        "$pkgdir/usr/lib/shedos/tpm2-pin-boot.sh"
    install -Dm755 tree/usr/lib/shedos/shedos-unlock \
        "$pkgdir/usr/lib/shedos/shedos-unlock"
    install -Dm644 tree/usr/lib/systemd/system/shedos-unlock.service \
        "$pkgdir/usr/lib/systemd/system/shedos-unlock.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-unlock-disarm.service \
        "$pkgdir/usr/lib/systemd/system/shedos-unlock-disarm.service"
    install -Dm644 tree/usr/lib/systemd/system/systemd-cryptsetup@.service.d/10-shedos-unlock.conf \
        "$pkgdir/usr/lib/systemd/system/systemd-cryptsetup@.service.d/10-shedos-unlock.conf"
    install -Dm644 tree/usr/lib/systemd/system/shedos-reencrypt.service \
        "$pkgdir/usr/lib/systemd/system/shedos-reencrypt.service"
    install -Dm755 tree/usr/lib/initcpio/install/shedos-reencrypt \
        "$pkgdir/usr/lib/initcpio/install/shedos-reencrypt"

    # First-boot finalisation of an in-place encryption, all userspace-only
    # (mkinitcpio/ukify and the interactive recovery-key ceremony cannot run in
    # the headless reencrypt initramfs). encrypt-enroll.sh enrols the recovery
    # key; encrypt-finalize.sh runs encrypt-reconfigure.sh to rebuild the normal
    # sd-encrypt boot path and advances the conversion to flip-pending. The
    # .install scriptlet enables the enrol + finalize units; all self-gate to a
    # no-op on any box that never ran `shedman encrypt`.
    install -Dm755 tree/usr/lib/shedos/encrypt-enroll.sh \
        "$pkgdir/usr/lib/shedos/encrypt-enroll.sh"
    install -Dm644 tree/usr/lib/systemd/system/shedos-encrypt-enroll.service \
        "$pkgdir/usr/lib/systemd/system/shedos-encrypt-enroll.service"
    install -Dm755 tree/usr/lib/shedos/encrypt-reconfigure.sh \
        "$pkgdir/usr/lib/shedos/encrypt-reconfigure.sh"
    install -Dm755 tree/usr/lib/shedos/encrypt-finalize.sh \
        "$pkgdir/usr/lib/shedos/encrypt-finalize.sh"
    install -Dm644 tree/usr/lib/systemd/system/shedos-encrypt-finalize.service \
        "$pkgdir/usr/lib/systemd/system/shedos-encrypt-finalize.service"

    # The one writer of the ShedOS blocks in /etc/pacman.conf: the install
    # scriptlet here and `shedman migrate` both ask it for the text.
    install -Dm755 tree/usr/lib/shedos/pacman-fence \
        "$pkgdir/usr/lib/shedos/pacman-fence"

    # The NVIDIA driver stack, written down once. nvidia-reap reads it and
    # the installer generates its own copy from it.
    install -Dm644 tree/usr/share/shedos/nvidia-driver-stack \
        "$pkgdir/usr/share/shedos/nvidia-driver-stack"

    # Single source of truth for the reflector flag set, exec'd by
    # shedos-mirrorlist.service (live ISO), shedos-reflector.service
    # (installed system), and the shedos_mirrors Calamares module.
    install -Dm755 tree/usr/lib/shedos/refresh-mirrorlist.sh \
        "$pkgdir/usr/lib/shedos/refresh-mirrorlist.sh"

    # Greetd → Hyprland session launcher: redirects uwsm + Hyprland
    # output to journald so the post-auth transition doesn't flash
    # text on the framebuffer console. Invoked by shedos-greeter via
    # greetd's IPC.
    install -Dm755 tree/usr/lib/shedos/start-hyprland-session.sh \
        "$pkgdir/usr/lib/shedos/start-hyprland-session.sh"
    install -Dm755 tree/usr/lib/shedos/record-last-login \
        "$pkgdir/usr/lib/shedos/record-last-login"

    # Limine multi-kernel renderer + the pacman hook that fires it on
    # every kernel install/upgrade/remove.
    install -Dm755 tree/usr/lib/shedos/render-limine-config.sh \
        "$pkgdir/usr/lib/shedos/render-limine-config.sh"

    # Live-ISO recovery for a box whose ESP overflowed and bricked the
    # default kernel: clears the ESP, rebuilds slim, re-syncs, verifies.
    install -Dm755 tree/usr/lib/shedos/recover-esp.sh \
        "$pkgdir/usr/lib/shedos/recover-esp.sh"

    # Rebuilds every kernel's initramfs, incl. the preset-less shedos-kernel
    # during migration. Shared by the regen hook and recover-esp.sh.
    install -Dm755 tree/usr/lib/shedos/rebuild-initramfs.sh \
        "$pkgdir/usr/lib/shedos/rebuild-initramfs.sh"

    # First-boot one-shot that retires the legacy shedos-kernel once
    # linux-zen is confirmed booting (see shedos-retire-kernel.service).
    install -Dm755 tree/usr/lib/shedos/retire-shedos-kernel \
        "$pkgdir/usr/lib/shedos/retire-shedos-kernel"
    install -Dm644 tree/usr/share/libalpm/hooks/95-shedos-limine-update.hook \
        "$pkgdir/usr/share/libalpm/hooks/95-shedos-limine-update.hook"

    # FDE Phase 2 UKI pipeline: the keyless ukify signer config (enrollment
    # rewrites it with the per-box keys), the cmdline files the installer
    # overwrites, the placer + its shared atomic-place lib, the recovery-image
    # builder, and the hook that runs them between mkinitcpio and the menu.
    install -Dm644 tree/etc/kernel/uki.conf \
        "$pkgdir/etc/kernel/uki.conf"
    install -Dm644 tree/etc/kernel/cmdline \
        "$pkgdir/etc/kernel/cmdline"
    install -Dm644 tree/etc/kernel/cmdline-fallback \
        "$pkgdir/etc/kernel/cmdline-fallback"
    install -Dm644 tree/usr/lib/shedos/uki-place.sh \
        "$pkgdir/usr/lib/shedos/uki-place.sh"
    install -Dm755 tree/usr/lib/shedos/build-uki.sh \
        "$pkgdir/usr/lib/shedos/build-uki.sh"
    install -Dm755 tree/usr/lib/shedos/build-recovery-uki.sh \
        "$pkgdir/usr/lib/shedos/build-recovery-uki.sh"
    install -Dm644 tree/usr/share/libalpm/hooks/94-shedos-uki-build.hook \
        "$pkgdir/usr/share/libalpm/hooks/94-shedos-uki-build.hook"
    # Mask sbctl's mkinitcpio post-hook signer — ukify (uki.conf) is the single
    # signer, so sbctl must not also sign (a second signature is sbverify-dirty).
    # Found first on mkinitcpio's post-hook path, so this no-op wins.
    install -Dm755 tree/etc/initcpio/post/sbctl \
        "$pkgdir/etc/initcpio/post/sbctl"

    install -Dm755 tree/usr/lib/shedos/migrate-mkinitcpio-hooks.sh \
        "$pkgdir/usr/lib/shedos/migrate-mkinitcpio-hooks.sh"
    install -Dm644 tree/usr/share/libalpm/hooks/05-shedos-mkinitcpio-migration.hook \
        "$pkgdir/usr/share/libalpm/hooks/05-shedos-mkinitcpio-migration.hook"

    # Rebuilds the initramfs when the migration above changes HOOKS in a
    # transaction that wouldn't otherwise trigger mkinitcpio (e.g. a
    # shedos-system-only upgrade).
    install -Dm755 tree/usr/lib/shedos/ensure-initramfs-current.sh \
        "$pkgdir/usr/lib/shedos/ensure-initramfs-current.sh"
    install -Dm644 tree/usr/share/libalpm/hooks/96-shedos-mkinitcpio-regen.hook \
        "$pkgdir/usr/share/libalpm/hooks/96-shedos-mkinitcpio-regen.hook"

    # Cross-kernel hibernation guard: the check + the ExecCondition
    # drop-ins that skip a hibernate when the running kernel isn't the
    # default boot kernel (a resume image is read by whatever boots next).
    install -Dm755 tree/usr/lib/shedos/hibernate-guard-check \
        "$pkgdir/usr/lib/shedos/hibernate-guard-check"
    install -Dm644 tree/usr/lib/systemd/system/systemd-hibernate.service.d/shedos-cross-kernel-guard.conf \
        "$pkgdir/usr/lib/systemd/system/systemd-hibernate.service.d/shedos-cross-kernel-guard.conf"
    install -Dm644 tree/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/shedos-cross-kernel-guard.conf \
        "$pkgdir/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/shedos-cross-kernel-guard.conf"
    install -Dm644 tree/usr/lib/systemd/system/systemd-hybrid-sleep.service.d/shedos-cross-kernel-guard.conf \
        "$pkgdir/usr/lib/systemd/system/systemd-hybrid-sleep.service.d/shedos-cross-kernel-guard.conf"

    # Guided emergency recovery: drop-ins make the emergency/rescue shell
    # reachable and hand it to the guided tool; the tool + its fail-open
    # entrypoint; and the post-boot reporter that names a disk which
    # silently didn't mount this boot.
    install -Dm755 tree/usr/lib/shedos/emergency-recovery \
        "$pkgdir/usr/lib/shedos/emergency-recovery"
    install -Dm644 tree/usr/lib/shedos/emergency-recovery-ui.py \
        "$pkgdir/usr/lib/shedos/emergency-recovery-ui.py"
    install -Dm644 tree/usr/lib/systemd/system/emergency.service.d/50-shedos-guided.conf \
        "$pkgdir/usr/lib/systemd/system/emergency.service.d/50-shedos-guided.conf"
    install -Dm644 tree/usr/lib/systemd/system/rescue.service.d/50-shedos-guided.conf \
        "$pkgdir/usr/lib/systemd/system/rescue.service.d/50-shedos-guided.conf"
    install -Dm755 tree/usr/lib/shedos/mount-report \
        "$pkgdir/usr/lib/shedos/mount-report"
    install -Dm644 tree/usr/lib/systemd/system/shedos-mount-report.service \
        "$pkgdir/usr/lib/systemd/system/shedos-mount-report.service"

    install -Dm755 tree/usr/lib/shedos/run-with-pause.sh \
        "$pkgdir/usr/lib/shedos/run-with-pause.sh"

    # mkinitcpio preset forcing both default and fallback images for
    # linux-zen. Without it, mkinitcpio's hook template auto-generates a
    # default-only preset and the limine renderer's "(Fallback)" recovery
    # entry has no initramfs to load. The stock linux fallback kernel
    # keeps the auto-generated default-only preset; the renderer omits a
    # fallback entry when its initramfs is absent.
    install -Dm644 tree/etc/mkinitcpio.d/linux-zen.preset \
        "$pkgdir/etc/mkinitcpio.d/linux-zen.preset"

    # Declarative system state. /etc/shedos/system.toml is in backup=() so
    # user edits become .pacnew on upgrade; the example template is a
    # read-only reference under /usr/share/shedos/.
    install -Dm644 tree/etc/shedos/system.toml \
        "$pkgdir/etc/shedos/system.toml"
    install -Dm644 tree/usr/share/shedos/system.toml.example \
        "$pkgdir/usr/share/shedos/system.toml.example"

    # Exclude list for the .shedosnew conflict reviewer (shedman config
    # --review). Users overlay at ~/.config/shedos/review-exclude.toml;
    # see shedos-review-exclude(5).
    install -Dm644 tree/etc/shedos/review-exclude.toml \
        "$pkgdir/etc/shedos/review-exclude.toml"

    # XDG Base Directory defaults exported system-wide so sudoers
    # env_keep can preserve them across `sudo` for any user, shell,
    # or rc state.
    install -Dm644 tree/etc/profile.d/shedos-xdg.sh \
        "$pkgdir/etc/profile.d/shedos-xdg.sh"

    # Snapper config template; copied to /etc/snapper/configs/root by the
    # install scriptlet on first install. Kept out of /etc itself so we
    # don't collide with the snapper package's ownership of that directory.
    install -Dm644 tree/usr/share/shedos/snapper/root.conf \
        "$pkgdir/usr/share/shedos/snapper/root.conf"

    install -Dm644 tree/usr/share/polkit-1/rules.d/49-shedos-timedate.rules \
        "$pkgdir/usr/share/polkit-1/rules.d/49-shedos-timedate.rules"

    # Lock-screen fast user switching: the root helper, its polkit action
    # + grant, and the tmpfiles dir for the preselect handoff.
    install -Dm755 tree/usr/lib/shedos/switch-user \
        "$pkgdir/usr/lib/shedos/switch-user"
    install -Dm755 tree/usr/lib/shedos/switch-greetd-once \
        "$pkgdir/usr/lib/shedos/switch-greetd-once"
    install -Dm644 tree/usr/share/polkit-1/actions/org.shedos.switch-user.policy \
        "$pkgdir/usr/share/polkit-1/actions/org.shedos.switch-user.policy"
    install -Dm644 tree/usr/share/polkit-1/rules.d/49-shedos-switch-user.rules \
        "$pkgdir/usr/share/polkit-1/rules.d/49-shedos-switch-user.rules"
    install -Dm644 tree/usr/lib/tmpfiles.d/shedos-switch-user.conf \
        "$pkgdir/usr/lib/tmpfiles.d/shedos-switch-user.conf"

    # Example user exclude list for `shedman config --sync`. Users copy
    # this to ~/.config/shedos/sync-exclude to opt out of specific files.
    install -Dm644 tree/usr/share/shedos/sync-exclude.example \
        "$pkgdir/usr/share/shedos/sync-exclude.example"

    # VS Code extension for the --gui merge backend. Synced into the
    # user's ~/.vscode/extensions/ on every `shedman config --review
    # --gui` run; activates only for workspaces with a .shedman/
    # marker (i.e. shedman-created merge sessions) and focuses the
    # Source Control panel so the user lands on the conflict list
    # instead of an empty Explorer.
    install -Dm644 tree/usr/share/shedos-system/vscode-merge-helper/package.json \
        "$pkgdir/usr/share/shedos-system/vscode-merge-helper/package.json"
    install -Dm644 tree/usr/share/shedos-system/vscode-merge-helper/extension.js \
        "$pkgdir/usr/share/shedos-system/vscode-merge-helper/extension.js"

    install -Dm644 tree/etc/skel/.local/share/keyrings/default \
        "$pkgdir/etc/skel/.local/share/keyrings/default"

    # One-shot heal for pre-rc4 installs whose locale/man/doc/info
    # files were stripped from the squashfs. Reinstalls only the
    # affected packages and writes a done-marker; gated by
    # ConditionPathExists on the service.
    install -Dm755 tree/usr/libexec/shedos-system/locale-restore \
        "$pkgdir/usr/libexec/shedos-system/locale-restore"

    # Systemd (system-scope)
    install -Dm644 tree/usr/lib/systemd/system/shedos-pg-initdb.service \
        "$pkgdir/usr/lib/systemd/system/shedos-pg-initdb.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-firstboot-mirrors.service \
        "$pkgdir/usr/lib/systemd/system/shedos-firstboot-mirrors.service"

    # Boot-failure auto-recovery: initrd script + unit (shipped into
    # the initramfs by the shedos-recovery initcpio hook), the
    # counter-reset unit for successful boots, and the hook itself.
    install -Dm755 tree/usr/lib/shedos/initrd-recovery.sh \
        "$pkgdir/usr/lib/shedos/initrd-recovery.sh"
    install -Dm755 tree/usr/lib/shedos/boot-success.sh \
        "$pkgdir/usr/lib/shedos/boot-success.sh"
    install -Dm644 tree/usr/lib/systemd/system/shedos-initrd-recovery.service \
        "$pkgdir/usr/lib/systemd/system/shedos-initrd-recovery.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-boot-success.service \
        "$pkgdir/usr/lib/systemd/system/shedos-boot-success.service"
    install -Dm755 tree/usr/lib/initcpio/install/shedos-recovery \
        "$pkgdir/usr/lib/initcpio/install/shedos-recovery"

    # SMART verdict cache for shedman health (smartctl needs root;
    # health runs unprivileged and reads the cache).
    install -Dm755 tree/usr/lib/shedos/smart-check.sh \
        "$pkgdir/usr/lib/shedos/smart-check.sh"

    # Hibernation retrofit: adds resume=UUID=<disk swap> to
    # system.toml on machines installed before the installer baked it.
    install -Dm755 tree/usr/lib/shedos/backfill-resume.py \
        "$pkgdir/usr/lib/shedos/backfill-resume.py"
    install -Dm755 tree/usr/lib/shedos/backfill-uki-cmdline.py \
        "$pkgdir/usr/lib/shedos/backfill-uki-cmdline.py"
    install -Dm755 tree/usr/lib/shedos/backfill-default-wallpaper.py \
        "$pkgdir/usr/lib/shedos/backfill-default-wallpaper.py"
    install -Dm644 tree/usr/lib/systemd/system/shedos-smart-check.service \
        "$pkgdir/usr/lib/systemd/system/shedos-smart-check.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-smart-check.timer \
        "$pkgdir/usr/lib/systemd/system/shedos-smart-check.timer"
    install -Dm644 tree/usr/lib/systemd/system/shedos-pg-user-bootstrap.service \
        "$pkgdir/usr/lib/systemd/system/shedos-pg-user-bootstrap.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-reflector.service \
        "$pkgdir/usr/lib/systemd/system/shedos-reflector.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-reflector.timer \
        "$pkgdir/usr/lib/systemd/system/shedos-reflector.timer"
    install -Dm644 tree/usr/lib/systemd/system/shedos-locale-restore.service \
        "$pkgdir/usr/lib/systemd/system/shedos-locale-restore.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-retire-kernel.service \
        "$pkgdir/usr/lib/systemd/system/shedos-retire-kernel.service"
    install -Dm755 tree/usr/lib/shedos/nvidia-reap \
        "$pkgdir/usr/lib/shedos/nvidia-reap"
    install -Dm755 tree/usr/lib/shedos/shell-migrate \
        "$pkgdir/usr/lib/shedos/shell-migrate"
    install -Dm644 tree/usr/lib/systemd/system/shedos-shell-migrate.service \
        "$pkgdir/usr/lib/systemd/system/shedos-shell-migrate.service"
    install -Dm644 tree/usr/lib/systemd/system/shedos-nvidia-reap.service \
        "$pkgdir/usr/lib/systemd/system/shedos-nvidia-reap.service"
    # First match wins across preset files: keeps first-boot preset-all from
    # enabling networkd on a NetworkManager system.
    install -Dm644 tree/usr/lib/systemd/system-preset/00-shedos.preset \
        "$pkgdir/usr/lib/systemd/system-preset/00-shedos.preset"

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
    install -Dm755 tree/usr/lib/shedos/seed-claude \
        "$pkgdir/usr/lib/shedos/seed-claude"
    install -Dm644 tree/usr/lib/systemd/user/shedos-claude-seed.service \
        "$pkgdir/usr/lib/systemd/user/shedos-claude-seed.service"

    # /etc drop-ins. These go in backup=() so user edits become .pacnew on
    # upgrade rather than being silently clobbered.
    install -Dm440 tree/etc/sudoers.d/wheel \
        "$pkgdir/etc/sudoers.d/wheel"
    install -Dm440 tree/etc/sudoers.d/shedos-locale \
        "$pkgdir/etc/sudoers.d/shedos-locale"
    install -Dm644 tree/usr/share/shedos/greetd/config.toml \
        "$pkgdir/usr/share/shedos/greetd/config.toml"
    install -Dm644 tree/usr/share/shedos/greetd/greetd.pam \
        "$pkgdir/usr/share/shedos/greetd/greetd.pam"
    install -Dm644 tree/usr/lib/systemd/system/greetd.service.d/10-shedos.conf \
        "$pkgdir/usr/lib/systemd/system/greetd.service.d/10-shedos.conf"
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
    install -Dm644 tree/etc/sysctl.d/95-shedos-dev.conf \
        "$pkgdir/etc/sysctl.d/95-shedos-dev.conf"
    install -Dm644 tree/etc/makepkg.conf.d/shedos-parallel.conf \
        "$pkgdir/etc/makepkg.conf.d/shedos-parallel.conf"
    install -Dm644 tree/etc/udev/rules.d/50-shedos-usb-autosuspend.rules \
        "$pkgdir/etc/udev/rules.d/50-shedos-usb-autosuspend.rules"
    install -Dm644 tree/etc/udev/rules.d/60-shedos-ioschedulers.rules \
        "$pkgdir/etc/udev/rules.d/60-shedos-ioschedulers.rules"
    install -Dm644 tree/etc/udev/rules.d/61-shedos-hdd-readahead.rules \
        "$pkgdir/etc/udev/rules.d/61-shedos-hdd-readahead.rules"
    install -Dm644 tree/etc/udev/rules.d/99-shedos-pcie-runtime-pm.rules \
        "$pkgdir/etc/udev/rules.d/99-shedos-pcie-runtime-pm.rules"
    install -Dm644 tree/etc/tlp.d/00-shedos.conf \
        "$pkgdir/etc/tlp.d/00-shedos.conf"
    install -Dm644 tree/etc/modprobe.d/shedos-blacklist.conf \
        "$pkgdir/etc/modprobe.d/shedos-blacklist.conf"

    # systemd config drop-ins: ShowStatus=no at both system and user
    # scopes silences "[ OK ] Started/Stopped foo" chatter that would
    # otherwise reach /dev/console = /dev/tty1, land in vcs1, and be
    # painted by fbcon during DRM-master gaps at compositor handoffs.
    install -Dm644 tree/etc/systemd/system.conf.d/shedos-quiet-status.conf \
        "$pkgdir/etc/systemd/system.conf.d/shedos-quiet-status.conf"
    install -Dm644 tree/etc/systemd/user.conf.d/shedos-quiet-status.conf \
        "$pkgdir/etc/systemd/user.conf.d/shedos-quiet-status.conf"

    # RebootWatchdogSec=0 matches the `nowatchdog` kernel cmdline so
    # systemd doesn't try to arm a shutdown watchdog the kernel
    # refuses, which would otherwise spam "Watchdog did not stop"
    # to /dev/console under the Plymouth splash.
    install -Dm644 tree/etc/systemd/system.conf.d/shedos-no-shutdown-watchdog.conf \
        "$pkgdir/etc/systemd/system.conf.d/shedos-no-shutdown-watchdog.conf"

    # Plymouth ships plymouth-{poweroff,halt,reboot}.service without
    # an [Install] section; the systemd shutdown units don't pull
    # them in by default, so the splash never appears at shutdown.
    # These three drop-ins add the Wants/After wiring.
    install -Dm644 tree/etc/systemd/system/systemd-poweroff.service.d/shedos-plymouth.conf \
        "$pkgdir/etc/systemd/system/systemd-poweroff.service.d/shedos-plymouth.conf"
    install -Dm644 tree/etc/systemd/system/systemd-halt.service.d/shedos-plymouth.conf \
        "$pkgdir/etc/systemd/system/systemd-halt.service.d/shedos-plymouth.conf"
    install -Dm644 tree/etc/systemd/system/systemd-reboot.service.d/shedos-plymouth.conf \
        "$pkgdir/etc/systemd/system/systemd-reboot.service.d/shedos-plymouth.conf"

    # user@.service drop-in: pin stderr to journal at the root of the
    # inheritance chain. Every user service that uses the default
    # StandardError=inherit then lands in journald instead of /dev/console.
    install -Dm644 tree/etc/systemd/system/user@.service.d/journal-only.conf \
        "$pkgdir/etc/systemd/system/user@.service.d/journal-only.conf"

    # Clear-VT defense-in-depth service: wipes vcs1..6 with ESC c so
    # fbcon paints empty during DRM-master gaps. Fires after
    # plymouth-quit-wait + systemd-user-sessions, before greetd.
    install -Dm755 tree/usr/lib/shedos/clear-vt-text.sh \
        "$pkgdir/usr/lib/shedos/clear-vt-text.sh"
    install -Dm644 tree/usr/lib/systemd/system/shedos-clear-vt.service \
        "$pkgdir/usr/lib/systemd/system/shedos-clear-vt.service"
    install -Dm644 tree/etc/modules-load.d/shedos-net.conf \
        "$pkgdir/etc/modules-load.d/shedos-net.conf"
    install -Dm644 tree/etc/systemd/zram-generator.conf \
        "$pkgdir/etc/systemd/zram-generator.conf"
    install -Dm644 tree/etc/systemd/oomd.conf.d/shedos.conf \
        "$pkgdir/etc/systemd/oomd.conf.d/shedos.conf"
    install -Dm644 tree/etc/security/limits.d/30-shedos-realtime.conf \
        "$pkgdir/etc/security/limits.d/30-shedos-realtime.conf"

    # Man pages; rendered from man/*.scd by prepare() above; install
    # the rendered .1 files. `shedman help` is the primary discovery
    # surface; man pages are the secondary path for `man <cmd>`.
    # Glob, not an allowlist: the old explicit name list silently
    # dropped any page added to man/ without a matching edit here.
    install -d "$pkgdir/usr/share/man/man1"
    local _page
    for _page in man/build/*.1; do
        install -Dm644 "$_page" \
            "$pkgdir/usr/share/man/man1/$(basename "$_page")"
    done

    # man5 pages, same glob-not-allowlist rule as man1.
    install -d "$pkgdir/usr/share/man/man5"
    for _page in man/build/*.5; do
        install -Dm644 "$_page" \
            "$pkgdir/usr/share/man/man5/$(basename "$_page")"
    done
}
