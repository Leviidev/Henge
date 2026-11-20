#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Makes an Ubuntu machine for Henge's Linux machine (docs/linux-machine.md): a
# folder holding the kernel (Image), the root disk (disk.img, or packed as
# disk.img.hvsparse) and machine.json. Everything comes from Ubuntu as it is:
# the arm64 cloud root file system and the stock generic kernel, its modules
# indexed (depmod) since nothing installs them as packages here.
#
#   sudo tools/linux/make-ubuntu-disk.sh OUTDIR [--size 60G] [--desktop | --gnome] [--pack] [--release noble] [--kernel-dir DIR]
#
# --kernel-dir takes the kernel tools/linux/build-kernel.sh built (16 KB pages,
# what HengeVM runs fastest: see henge-kernel.config) instead of Ubuntu's own
# 4 KB generic kernel.
#
# --desktop installs Xfce with LightDM signing in on its own; --gnome installs
# Ubuntu's own desktop (GNOME Shell with Ubuntu's dock and theme) with GDM signing
# in on its own. Either runs apt
# inside the image, so it needs a host that runs arm64 programs: an arm64
# machine (GitHub's ubuntu-24.04-arm runners) or qemu-user registered with
# binfmt_misc. --pack writes disk.img.hvsparse (holes left out) for moving it
# to the phone. Needs: curl, xz, zstd, mkfs.ext4 (e2fsprogs), depmod (kmod),
# dpkg-deb, and a C compiler for --pack. Run as root (file ownership in the
# image).
set -euo pipefail

OUT=""; SIZE=60G; DESKTOP=""; PACK=0; RELEASE=noble; KDIR=""; DISTRO=ubuntu
# The release's own kernel series (noble: 6.8, what the Linux machine is tried with), not the
# newer hardware-enablement kernels the same archive also has. KSERIES=7.0.0 picks those.
KSERIES=${KSERIES:-6.8.0}
ARCHIVE=${ARCHIVE:-http://ports.ubuntu.com/ubuntu-ports}
CLOUD=${CLOUD:-https://cloud-images.ubuntu.com}
while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE=$2; shift ;;
        --desktop) DESKTOP=xfce ;;
        --gnome) DESKTOP=gnome ;;
        --kali) DISTRO=kali ;;
        --pack) PACK=1 ;;
        --release) RELEASE=$2; shift ;;
        --kernel-dir) KDIR=$(cd "$2" && pwd); shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) OUT=$1 ;;
    esac
    shift
done
[ -n "$OUT" ] || { echo "usage: $0 OUTDIR [--size 60G] [--desktop | --gnome] [--pack] [--release noble] [--kernel-dir DIR]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "$0: run as root (the image's files keep their owners)" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/henge-ubuntu.XXXXXX")
ROOT="$WORK/root"
cleanup() {
    for m in dev/pts dev proc sys run; do umount -l "$ROOT/$m" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

say() { echo "== $*"; }

if [ "$DISTRO" = kali ]; then
    # Kali rolling (Debian testing underneath), bootstrapped with Kali's own signing key.
    KALI=${KALI_ARCHIVE:-http://http.kali.org/kali}
    say "root file system: Kali rolling (arm64, debootstrap from $KALI)"
    kr=$(curl -fsSL "$KALI/dists/kali-rolling/main/binary-arm64/Packages.gz" | zcat |
        awk '$1 == "Package:" { hit = ($2 == "kali-archive-keyring") } hit && $1 == "Filename:" && !f { f = $2 } END { print f }')
    [ -n "$kr" ] || { echo "kali-archive-keyring not found in $KALI" >&2; exit 1; }
    curl -fsSL "$KALI/$kr" -o "$WORK/keyring.deb"
    mkdir -p "$WORK/keyring" "$ROOT"
    dpkg-deb -x "$WORK/keyring.deb" "$WORK/keyring"
    debootstrap --arch=arm64 --keyring="$WORK/keyring/usr/share/keyrings/kali-archive-keyring.gpg" \
        --include=kali-archive-keyring,systemd-sysv,sudo,ca-certificates,curl,iproute2,iputils-ping,network-manager,dbus,locales,less,nano,kmod,udev \
        kali-rolling "$ROOT" "$KALI" /usr/share/debootstrap/scripts/sid
    echo "deb $KALI kali-rolling main contrib non-free non-free-firmware" > "$ROOT/etc/apt/sources.list"
    mkdir -p "$ROOT/boot"
else
say "root file system: Ubuntu $RELEASE cloud image (arm64)"
curl -fsSL "$CLOUD/$RELEASE/current/$RELEASE-server-cloudimg-arm64-root.tar.xz" -o "$WORK/root.tar.xz"
mkdir -p "$ROOT"
tar -C "$ROOT" --numeric-owner -xJf "$WORK/root.tar.xz"
rm "$WORK/root.tar.xz"
fi

if [ -n "$KDIR" ]; then
    KVER=$(cat "$KDIR/release")
    say "kernel: $KVER from $KDIR"
    cp "$KDIR/Image" "$OUT/Image"
    mkdir -p "$ROOT/usr/lib/modules"
    rm -rf "$ROOT/usr/lib/modules/$KVER"
    cp -a "$KDIR/lib/modules/$KVER" "$ROOT/usr/lib/modules/$KVER"
    cp "$KDIR/config" "$ROOT/boot/config-$KVER" 2>/dev/null || true
    depmod -b "$ROOT/usr" "$KVER"
else
    say "kernel: the newest $KSERIES generic kernel in $RELEASE-updates"
    curl -fsSL "$ARCHIVE/dists/$RELEASE-updates/main/binary-arm64/Packages.xz" | xz -d > "$WORK/Packages"
    KVER=$(sed -n 's/^Package: linux-image-unsigned-\([0-9.]*-[0-9]*-generic\)$/\1/p' "$WORK/Packages" | grep "^$KSERIES-" | sort -V | tail -1)
    [ -n "$KVER" ] || { echo "no generic kernel found in $RELEASE-updates" >&2; exit 1; }
    echo "   $KVER"
    mkdir -p "$WORK/k"
    for pkg in linux-image-unsigned-$KVER linux-modules-$KVER linux-modules-extra-$KVER; do
        file=$(awk -v p="$pkg" '$1 == "Package:" { hit = ($2 == p) } hit && $1 == "Filename:" { print $2; exit }' "$WORK/Packages")
        [ -n "$file" ] || { echo "$pkg not found" >&2; exit 1; }
        curl -fsSL "$ARCHIVE/$file" -o "$WORK/pkg.deb"
        dpkg-deb -x "$WORK/pkg.deb" "$WORK/k"
        rm "$WORK/pkg.deb"
    done
    # Henge loads an uncompressed arm64 Image; Ubuntu's vmlinuz is gzip.
    zcat "$WORK/k/boot/vmlinuz-$KVER" > "$OUT/Image"
    mkdir -p "$ROOT/usr/lib/modules"
    rm -rf "$ROOT/usr/lib/modules/$KVER"
    cp -a "$WORK/k/lib/modules/$KVER" "$ROOT/usr/lib/modules/$KVER"
    cp "$WORK/k/boot/config-$KVER" "$ROOT/boot/" 2>/dev/null || true
    depmod -b "$ROOT/usr" "$KVER"
    rm -rf "$WORK/k"
fi

say "settings"
# No cloud to ask for user data; the machine is configured here instead.
[ -d "$ROOT/etc/cloud" ] && touch "$ROOT/etc/cloud/cloud-init.disabled"
echo "/dev/vda / ext4 discard,commit=30,errors=remount-ro 0 1" > "$ROOT/etc/fstab"
HOST=henge-$DISTRO
echo $HOST > "$ROOT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' $HOST > "$ROOT/etc/hosts"
# The network: virtio-net on Henge's user-mode network, by DHCP (Kali: NetworkManager does it on its own).
if [ "$DISTRO" = ubuntu ]; then
cat > "$ROOT/etc/netplan/01-henge.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    henge:
      match:
        driver: virtio_net
      renderer: networkd
      dhcp4: true
YAML
chmod 600 "$ROOT/etc/netplan/01-henge.yaml"
ln -sf /dev/null "$ROOT/etc/systemd/system/systemd-networkd-wait-online.service"
fi
# The user: henge, no password, an administrator (sudo).
groups=$(for g in adm sudo audio video plugdev input netdev; do grep -q "^$g:" "$ROOT/etc/group" && printf '%s,' $g; done)
useradd -R "$ROOT" -m -s /bin/bash -G "${groups%,}" henge
passwd -R "$ROOT" -d henge >/dev/null
echo 'henge ALL=(ALL) NOPASSWD:ALL' > "$ROOT/etc/sudoers.d/henge"
chmod 440 "$ROOT/etc/sudoers.d/henge"
# The serial console (and the screen's text console) sign in by themselves.
for unit in serial-getty@ttyAMA0 getty@tty1; do
    mkdir -p "$ROOT/etc/systemd/system/$unit.service.d"
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin henge --noclear %%I $TERM\n' \
        > "$ROOT/etc/systemd/system/$unit.service.d/autologin.conf"
done

# A self-test that only runs when the kernel's command line has henge.autotest (the
# Linux machine workflow, .github/workflows/linux-machine.yml): reports to the serial
# console what came up, then powers off.
cat > "$ROOT/usr/local/bin/henge-autotest" <<'TEST'
#!/bin/sh
# The Linux machine's self-test (tools/linux/make-ubuntu-disk.sh): what came up, on the serial console.
echo
echo "=== henge-autotest: Ubuntu is up ==="
. /etc/os-release
echo "$PRETTY_NAME, kernel $(uname -r), PID 1 is $(cat /proc/1/comm)"
dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service)
case "$dm" in
    lightdm) desktop=xfce shell=xfce4-panel wait=120 ;;
    gdm|gdm3) desktop=gnome shell=gnome-shell wait=300 ;;
    *) desktop="" ;;
esac
if [ -n "$desktop" ]; then
    i=0
    while [ $i -lt $wait ] && ! pgrep -u henge -x "$shell" >/dev/null; do sleep 1; i=$((i + 1)); done
    sleep 20
    if pgrep -u henge -x "$shell" >/dev/null; then echo "desktop: $desktop ($shell) up after about $i s"
    else echo "desktop: no $shell after $i s"; fi
    if [ "$desktop" = gnome ]; then
        echo "gnome: $(gnome-shell --version 2>&1 | head -1); gdm: $(systemctl is-active gdm 2>&1)"
        # Why GNOME did not come up: GDM's, the session's and the shell's own words.
        pgrep -u henge -x "$shell" >/dev/null ||
            journalctl -b --no-pager -o cat | grep -iE "gdm|gnome-shell|gnome-session|mutter|wayland|logind|seat" | tail -80 | sed "s/^/journal: /"
        echo "extensions: $(runuser -u henge -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u henge)/bus timeout 20 gnome-extensions list --enabled 2>&1 | tr "\n" " ")"
    fi
    echo "=== henge-autotest: screenshot ==="
    sleep 2
    ps -eo comm= | grep -xE "Xorg|Xwayland|lightdm|gdm-.*|gnome-shell|gnome-session-b.*|xfce4-session|xfce4-panel|xfwm4|xfdesktop|Thunar|nautilus|pulseaudio|pipewire|wireplumber|plank" | sort -u | tr "\n" " "
    echo
    echo "display: $(for d in /sys/class/drm/card[0-9]; do basename "$(readlink -f $d/device/driver)"; done | tr "\n" " ")"
    u=$(id -u henge)
    if [ "$desktop" = xfce ]; then
        grep -hE "LoadModule: .(modesetting|fbdev).|glamor|Output .* connected|using drmmode|Not using" /var/log/Xorg.0.log 2>/dev/null | cut -d"]" -f2- | sed "s/^/xorg:/" | head -8
        g=$(DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 timeout 90 glxinfo -B 2>&1)
    else
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            echo "session $s: $(loginctl show-session "$s" -p Name -p Type -p Desktop -p Class -p State 2>/dev/null | tr "\n" " ")"
        done
        journalctl -b -o cat --no-pager _COMM=gnome-shell 2>/dev/null | grep -iE "device|render|gpu|egl|kms|software|llvmpipe|virgl|error|fail" | head -15 | sed "s/^/shell: /"
        xa=$(ls /run/user/$u/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
        [ -n "$xa" ] || xa=/run/user/$u/gdm/Xauthority
        g=$(runuser -u henge -- env DISPLAY=:0 XAUTHORITY="$xa" XDG_RUNTIME_DIR=/run/user/$u timeout 90 glxinfo -B 2>&1)
    fi
    echo "gl: $(echo "$g" | grep -E "OpenGL renderer|OpenGL version|direct rendering" | tr -s " " | tr "\n" ";")"
    echo "$g" | grep -q "OpenGL renderer" || echo "glxinfo said: $(echo "$g" | tail -6 | tr "\n" ";")"
fi
echo "state: $(systemctl is-system-running)"
echo "failed units:"
systemctl --failed --no-legend --no-pager
echo "firefox: $(command -v firefox || command -v firefox-esr || echo none)"
ff=$(command -v firefox || command -v firefox-esr || true)
if [ -n "$ff" ]; then
    # Firefox for real: its version, a page drawn offscreen, then a window on the desktop.
    echo "firefox version: $(runuser -u henge -- env HOME=/home/henge timeout 60 "$ff" --version 2>&1 | tail -3 | tr "\n" ";")"
    echo "<html><body style='background:#e95420'><h1>henge</h1></body></html>" > /tmp/henge-ff.html
    chmod 644 /tmp/henge-ff.html
    o=$(runuser -u henge -- env HOME=/home/henge MOZ_HEADLESS=1 timeout 240 "$ff" --screenshot /tmp/henge-ff.png file:///tmp/henge-ff.html 2>&1)
    echo "firefox headless: exit $? $(ls -l /tmp/henge-ff.png 2>/dev/null | awk '{print $5" bytes"}')"
    echo "$o" | tail -25 | sed "s/^/ff: /"
    if [ -n "$desktop" ]; then
        if [ "$desktop" = xfce ]; then fenv="DISPLAY=:0"
        else fenv="WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XAUTHORITY=$xa"; fi
        runuser -u henge -- env HOME=/home/henge XDG_RUNTIME_DIR=/run/user/$u $fenv \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$u/bus \
            "$ff" file:///tmp/henge-ff.html > /tmp/henge-ff.log 2>&1 &
        sleep 90
        echo "firefox window: $(pgrep -u henge -c -f firefox) firefox processes after 90 s"
        tail -25 /tmp/henge-ff.log | sed "s/^/ffw: /"
    fi
    dmesg | grep -iE "firefox|Web Content|Isolated|GPU Process|segfault|unhandled|traps" | tail -15 | sed "s/^/kernel: /"
fi
# Video: how fast this CPU decodes YouTube-like H.264 (300 frames, as fast as it can; 30 fps is real time).
for f in /usr/local/share/henge/sample*.mp4; do
    [ -f "$f" ] || continue
    t0=$(date +%s.%N)
    timeout 200 mpv --no-config --vo=null --ao=null --untimed --hwdec=no --really-quiet "$f" 2>/dev/null
    t1=$(date +%s.%N)
    echo "video $(basename "$f" .mp4): $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "300 frames in %.1f s, %.1f fps", b - a, 300 / (b - a) }')"
done
if [ -n "$desktop" ]; then
    echo "sound: $(runuser -u henge -- env XDG_RUNTIME_DIR=/run/user/$u pactl info 2>&1 | grep -E "Server Name|Default Sink" | tr "\n" ";")"
    runuser -u henge -- env XDG_RUNTIME_DIR=/run/user/$u pactl list short sinks 2>&1 | head -3 | sed "s/^/sink: /"
fi
echo "input:"
grep -h "^N:" /proc/bus/input/devices
ip -brief address
snap version 2>&1 | head -2
echo "=== henge-autotest: end ==="
TEST
chmod 755 "$ROOT/usr/local/bin/henge-autotest"
cat > "$ROOT/etc/systemd/system/henge-autotest.service" <<'UNIT'
[Unit]
Description=Henge Linux machine self-test
ConditionKernelCommandLine=henge.autotest
After=multi-user.target serial-getty@ttyAMA0.service
# The console's sign-in would hang the serial port up under the test (Kali starts it after the test): it stays off.
Conflicts=serial-getty@ttyAMA0.service

[Service]
Type=oneshot
StandardOutput=tty
TTYPath=/dev/ttyAMA0
TTYVHangup=no
ExecStart=/bin/sh -c 'trap "" HUP; exec /usr/local/bin/henge-autotest'
ExecStopPost=/bin/systemctl poweroff

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/henge-autotest.service "$ROOT/etc/systemd/system/multi-user.target.wants/henge-autotest.service"

if [ -n "$DESKTOP" ]; then
    if ! chroot "$ROOT" /bin/true 2>/dev/null; then
        echo "--$DESKTOP: this host cannot run the image's arm64 programs (use an arm64 machine, or register qemu-user with binfmt_misc)" >&2
        exit 1
    fi
    for m in dev dev/pts proc sys run; do mkdir -p "$ROOT/$m"; mount --bind "/$m" "$ROOT/$m"; done
    mv "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.image" 2>/dev/null || true
    cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
fi

if [ "$DESKTOP" = xfce ] && [ "$DISTRO" = ubuntu ]; then
    say "desktop: Xfce with LightDM signing in as henge"
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xubuntu-core lightdm lightdm-gtk-greeter xserver-xorg-video-fbdev xserver-xorg-input-libinput \
        pulseaudio pavucontrol fonts-dejavu-core \
        yaru-theme-gtk yaru-theme-icon yaru-theme-sound fonts-ubuntu ubuntu-wallpapers plank \
        xfce4-terminal mousepad ristretto xfce4-screenshooter \
        libgl1-mesa-dri libegl-mesa0 mesa-utils
    # Ubuntu's look on Xfce: Yaru theme and icons, Ubuntu font and wallpaper, a dock (plank) at the
    # bottom. Set per user on first sign-in (xfconf), so Xubuntu's defaults stay underneath.
    cat > "$ROOT/usr/local/bin/henge-look" <<'LOOK'
#!/bin/sh
# Ubuntu's look for Xfce, once per user (tools/linux/make-ubuntu-disk.sh).
mark="$HOME/.config/henge-look-1"
if [ ! -e "$mark" ]; then
    sleep 2
    x() { xfconf-query -c "$1" -p "$2" --create -t "$3" -s "$4"; }
    x xsettings /Net/ThemeName string Yaru-dark
    x xsettings /Net/IconThemeName string Yaru
    x xsettings /Gtk/FontName string "Ubuntu 11"
    x xsettings /Gtk/MonospaceFontName string "Ubuntu Mono 13"
    x xfwm4 /general/theme string Default-xhdpi
    x xfwm4 /general/title_font string "Ubuntu Bold 11"
    x xfwm4 /general/button_layout string "O|HMC"
    x xfce4-panel /panels/panel-1/background-style uint 1
    x xfce4-panel /panels/panel-1/background-rgba string "rgba(0,0,0,0.85)" 2>/dev/null || true
    wall=$(ls /usr/share/backgrounds/*Numbat*.png /usr/share/backgrounds/warty-final-ubuntu.png 2>/dev/null | head -1)
    if [ -n "$wall" ]; then
        for p in $(xfconf-query -c xfce4-desktop -l | grep '/last-image$'); do xfconf-query -c xfce4-desktop -p "$p" -s "$wall"; done
        x xfce4-desktop /backdrop/screen0/monitorVirtual-1/workspace0/last-image string "$wall"
    fi
    x xfce4-desktop /desktop-icons/style int 0
    mkdir -p "$HOME/.config" && touch "$mark"
fi
pgrep -u "$(id -u)" -x plank >/dev/null || exec plank
LOOK
    chmod 755 "$ROOT/usr/local/bin/henge-look"
    printf '[Desktop Entry]\nType=Application\nName=Henge look\nExec=/usr/local/bin/henge-look\nOnlyShowIn=XFCE;\n' \
        > "$ROOT/etc/xdg/autostart/henge-look.desktop"
    # Plank's launchers: files, browser, terminal.
    mkdir -p "$ROOT/etc/skel/.config/plank/dock1/launchers"
    for app in thunar firefox yt xfce4-terminal mousepad; do
        printf '[PlankDockItemPreferences]\nLauncher=file:///usr/share/applications/%s.desktop\n' "$app" \
            > "$ROOT/etc/skel/.config/plank/dock1/launchers/$app.dockitem"
    done
    cp -a "$ROOT/etc/skel/.config/plank" "$ROOT/home/henge/.config/" 2>/dev/null || { mkdir -p "$ROOT/home/henge/.config"; cp -a "$ROOT/etc/skel/.config/plank" "$ROOT/home/henge/.config/"; }
    chroot "$ROOT" chown -R henge:henge /home/henge/.config
    mkdir -p "$ROOT/etc/lightdm/lightdm.conf.d"
    printf '[Seat:*]\nautologin-user=henge\nautologin-session=xfce\n' > "$ROOT/etc/lightdm/lightdm.conf.d/50-henge.conf"
fi

BROWSER=firefox
if [ "$DESKTOP" = xfce ] && [ "$DISTRO" = kali ]; then
    # Kali's own default desktop (Xfce, Kali's theme and menu), LightDM signing in as henge.
    say "desktop: Kali's Xfce with LightDM signing in as henge, and Kali's top 10 tools"
    BROWSER=firefox-esr
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kali-desktop-xfce kali-linux-core kali-tools-top10 firefox-esr \
        xfce4 xfce4-terminal thunar mousepad lightdm lightdm-gtk-greeter \
        xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput x11-xserver-utils \
        pipewire-pulse wireplumber pavucontrol libgl1-mesa-dri libegl-mesa0 mesa-utils fonts-dejavu-core
    mkdir -p "$ROOT/etc/lightdm/lightdm.conf.d"
    printf '[Seat:*]\nautologin-user=henge\nautologin-session=xfce\n' > "$ROOT/etc/lightdm/lightdm.conf.d/50-henge.conf"
    chroot "$ROOT" groupadd -rf autologin && chroot "$ROOT" gpasswd -a henge autologin >/dev/null
    chroot "$ROOT" systemctl enable lightdm 2>/dev/null || true
    ln -sf /lib/systemd/system/lightdm.service "$ROOT/etc/systemd/system/display-manager.service"
fi
if [ "$DESKTOP" = gnome ] && [ "$DISTRO" = kali ]; then
    say "desktop: Kali's GNOME with GDM signing in as henge, and Kali's top 10 tools"
    BROWSER=firefox-esr
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kali-desktop-gnome kali-linux-core kali-tools-top10 firefox-esr \
        gdm3 gnome-shell gnome-session nautilus gnome-terminal gnome-text-editor gnome-control-center eog \
        xwayland pipewire-pulse wireplumber dconf-cli libgl1-mesa-dri libegl-mesa0 mesa-utils fonts-dejavu-core
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get purge -y gnome-initial-setup 2>/dev/null || true
    # A dock like Ubuntu's (Dash to Dock), when Kali's archive has one for its GNOME.
    if chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gnome-shell-extension-dashtodock; then
        mkdir -p "$ROOT/etc/dconf/db/local.d" "$ROOT/etc/dconf/profile"
        [ -f "$ROOT/etc/dconf/profile/user" ] || printf 'user-db:user\nsystem-db:local\n' > "$ROOT/etc/dconf/profile/user"
        printf "[org/gnome/shell]\nenabled-extensions=['dash-to-dock@micxgx.gmail.com']\n\n[org/gnome/shell/extensions/dash-to-dock]\ndock-position='BOTTOM'\ndock-fixed=true\nextend-height=false\nanimate-show-apps=false\n" \
            > "$ROOT/etc/dconf/db/local.d/10-henge-dock"
        chroot "$ROOT" dconf update
    else
        echo "   no Dash to Dock in Kali's archive: GNOME's own dash (Activities) has the apps"
    fi
    mkdir -p "$ROOT/etc/gdm3" "$ROOT/var/lib/AccountsService/users"
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=henge\n\n[security]\n\n[xdmcp]\n\n[chooser]\n\n[debug]\n' \
        > "$ROOT/etc/gdm3/daemon.conf"
    printf '[User]\nSession=gnome\nSystemAccount=false\n' > "$ROOT/var/lib/AccountsService/users/henge"
    chmod 600 "$ROOT/var/lib/AccountsService/users/henge"
fi
if [ "$DESKTOP" = gnome ] && [ "$DISTRO" = ubuntu ]; then
    say "desktop: GNOME (Ubuntu's desktop) with GDM signing in as henge"
    # Ubuntu's own desktop, without what it only recommends (printing, the snap store, ...): GNOME Shell with
    # Ubuntu's session, dock and Yaru theme, and the usual apps.
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ubuntu-desktop-minimal gdm3 ubuntu-session gnome-shell gnome-session \
        gnome-shell-extension-ubuntu-dock gnome-shell-extension-appindicator \
        yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound fonts-ubuntu ubuntu-wallpapers ubuntu-wallpapers-noble \
        nautilus gnome-terminal gnome-text-editor eog gnome-calculator gnome-system-monitor file-roller gnome-control-center gnome-tweaks \
        xwayland pipewire-pulse wireplumber dconf-cli \
        libgl1-mesa-dri libegl-mesa0 mesa-utils
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get purge -y gnome-initial-setup 2>/dev/null || true
    # GDM signs henge in on its own, into Ubuntu's session (GNOME on Wayland; GDM falls back to Xorg itself).
    mkdir -p "$ROOT/etc/gdm3" "$ROOT/var/lib/AccountsService/users"
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=henge\n\n[security]\n\n[xdmcp]\n\n[chooser]\n\n[debug]\n' \
        > "$ROOT/etc/gdm3/custom.conf"
    printf '[User]\nSession=ubuntu\nSystemAccount=false\n' > "$ROOT/var/lib/AccountsService/users/henge"
    chmod 600 "$ROOT/var/lib/AccountsService/users/henge"
fi
if [ "$DESKTOP" = gnome ]; then
    # No first-run setup or welcome tour; no screen lock or blanking (the phone has its own); Firefox (Mozilla's
    # deb) in the dock; no animations while the guest draws with the CPU (Settings > Accessibility turns them on).
    mkdir -p "$ROOT/home/henge/.config" "$ROOT/etc/skel/.config"
    echo yes > "$ROOT/home/henge/.config/gnome-initial-setup-done"
    echo yes > "$ROOT/etc/skel/.config/gnome-initial-setup-done"
    cat > "$ROOT/usr/share/glib-2.0/schemas/99_henge.gschema.override" <<'GS'
[org.gnome.desktop.session]
idle-delay=0

[org.gnome.desktop.screensaver]
lock-enabled=false
idle-activation-enabled=false

[org.gnome.desktop.lockdown]
disable-lock-screen=true

[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
idle-dim=false

[org.gnome.desktop.interface]
enable-animations=false

[org.gnome.desktop.interface:ubuntu]
enable-animations=false

[org.gnome.shell]
welcome-dialog-last-shown-version='999'
favorite-apps=['BROWSER.desktop', 'yt.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Settings.desktop']

[org.gnome.shell:ubuntu]
favorite-apps=['BROWSER.desktop', 'yt.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Settings.desktop']
GS
    sed -i "s/'BROWSER.desktop'/'$BROWSER.desktop'/" "$ROOT/usr/share/glib-2.0/schemas/99_henge.gschema.override"
    chroot "$ROOT" glib-compile-schemas /usr/share/glib-2.0/schemas
fi

if [ -n "$DESKTOP" ] && [ "$DISTRO" = ubuntu ]; then
    # Firefox as a deb from Mozilla's own repository: Ubuntu's firefox package only installs the snap,
    # which cannot be installed into an image being built.
    mkdir -p "$ROOT/etc/apt/keyrings"
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o "$ROOT/etc/apt/keyrings/packages.mozilla.org.asc"
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > "$ROOT/etc/apt/sources.list.d/mozilla.list"
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > "$ROOT/etc/apt/preferences.d/mozilla"
    # Mozilla's repository is sometimes caught mid-sync (its lists do not match their Release file): try again.
    for try in 1 2 3 4 5; do
        chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update && break
        [ $try = 5 ] && exit 1
        echo "   apt-get update failed (try $try): again in $((try * 20)) s"; sleep $((try * 20))
    done
    if ! chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y firefox; then
        echo "   Mozilla's firefox deb not available: the snap is installed at first boot instead"
        rm -f "$ROOT/etc/apt/sources.list.d/mozilla.list" "$ROOT/etc/apt/preferences.d/mozilla"
        cat > "$ROOT/etc/systemd/system/henge-firefox.service" <<'UNIT'
[Unit]
Description=Install Firefox (snap) once the network is up
After=snapd.seeded.service network-online.target
ConditionPathExists=!/var/lib/henge-firefox-done

[Service]
Type=oneshot
ExecStart=/usr/bin/snap install firefox
ExecStartPost=/usr/bin/touch /var/lib/henge-firefox-done

[Install]
WantedBy=multi-user.target
UNIT
        ln -sf /etc/systemd/system/henge-firefox.service "$ROOT/etc/systemd/system/multi-user.target.wants/henge-firefox.service"
    fi
    chroot "$ROOT" update-alternatives --set x-www-browser /usr/bin/firefox 2>/dev/null || true
fi
if [ -n "$DESKTOP" ]; then
    # YouTube without a browser (a browser's JavaScript JIT is slow on the engine): search, pick, play in mpv,
    # at 720p H.264 (the self-test decodes 720p at about 6 times real time on the engine).
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mpv zenity python3 ffmpeg pulseaudio-utils
    # Sample videos for the self-test's playback speed check (H.264 as YouTube sends it, 30 fps, 10 s each).
    mkdir -p "$ROOT/usr/local/share/henge"
    for h in 360 480 720; do
        w=$(( (h * 16 / 9 + 1) / 2 * 2 ))
        chroot "$ROOT" ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=${w}x${h}:rate=30" -t 10 \
            -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p "/usr/local/share/henge/sample$h.mp4" || true
    done
    curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$ROOT/usr/local/bin/yt-dlp"
    chmod 755 "$ROOT/usr/local/bin/yt-dlp"
    cat > "$ROOT/usr/local/bin/yt" <<'YT'
#!/bin/sh
# YouTube without a browser (tools/linux/make-ubuntu-disk.sh): search or a link, pick, play in mpv.
q=$(zenity --entry --title=YouTube --text="Search YouTube or paste a link:") || exit
case "$q" in http*) url=$q ;; *)
  list=$(yt-dlp --flat-playlist --print "%(id)s|%(title)s" "ytsearch15:$q") || { zenity --error --text="YouTube search failed (try: sudo yt-dlp -U)"; exit 1; }
  pick=$(echo "$list" | cut -d'|' -f2- | zenity --list --title=YouTube --column=Video --width=700 --height=500) || exit
  url="https://youtu.be/$(echo "$list" | grep -F "|$pick" | head -1 | cut -d'|' -f1)" ;;
esac
exec mpv --ytdl-format='bv*[height<=720][vcodec^=avc1]+ba/b[height<=720]' --hwdec=no --cache=yes --force-window=immediate "$url"
YT
    chmod 755 "$ROOT/usr/local/bin/yt"
    printf '[Desktop Entry]\nName=YouTube\nComment=Search and watch YouTube without a browser\nExec=yt\nIcon=mpv\nType=Application\nCategories=AudioVideo;Video;\n' \
        > "$ROOT/usr/share/applications/yt.desktop"
    # Quiet in the background (the guest's CPUs are slow): no automatic updates or update checks, no modem or
    # multipath daemons, no activity accounting, no file indexer. Updates: sudo apt update && sudo apt upgrade.
    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer fwupd-refresh.timer motd-news.timer \
             man-db.timer ModemManager.service packagekit.service multipathd.service multipathd.socket \
             sysstat-collect.timer sysstat-summary.timer update-notifier-download.timer update-notifier-motd.timer; do
        ln -sf /dev/null "$ROOT/etc/systemd/system/$u"
    done
    mkdir -p "$ROOT/etc/systemd/user"
    for u in tracker-miner-fs-3.service tracker-extract-3.service tracker-miner-fs-control-3.service tracker-writeback-3.service; do
        ln -sf /dev/null "$ROOT/etc/systemd/user/$u"
    done
    for a in update-notifier gnome-software-service org.gnome.Software tracker-miner-fs-3; do
        [ -f "$ROOT/etc/xdg/autostart/$a.desktop" ] && echo "Hidden=true" >> "$ROOT/etc/xdg/autostart/$a.desktop"
    done
    chroot "$ROOT" chown -R henge:henge /home/henge
    chroot "$ROOT" apt-get clean
    chroot "$ROOT" systemctl set-default graphical.target
    rm -f "$ROOT/etc/resolv.conf"
    mv "$ROOT/etc/resolv.conf.image" "$ROOT/etc/resolv.conf" 2>/dev/null || true
    for m in dev/pts dev proc sys run; do umount -l "$ROOT/$m"; done
fi

say "disk: $SIZE ext4"
rm -f "$OUT/disk.img"
truncate -s "$SIZE" "$OUT/disk.img"
mkfs.ext4 -q -F -L henge-root -d "$ROOT" "$OUT/disk.img"

NAME="Ubuntu ${RELEASE^}"
[ "$DISTRO" = kali ] && NAME="Kali Linux"
[ "$DESKTOP" = xfce ] && NAME="$NAME (Xfce)"
[ "$DESKTOP" = gnome ] && NAME="$NAME (GNOME)"
cat > "$OUT/machine.json" <<JSON
{"kind": "linux", "name": "$NAME", "ramMB": 4096, "kernel": "Image", "kernelVersion": "$KVER",
 "cmdline": "console=tty0 console=ttyAMA0 root=/dev/vda rw rootwait"}
JSON

if [ "$PACK" = 1 ]; then
    say "packing the disk (holes left out)"
    cc -O2 -std=gnu11 -I"$HERE/host" "$HERE/tools/hvsparse_main.c" "$HERE/host/hvsparse.c" -o "$WORK/hvsparse"
    "$WORK/hvsparse" pack "$OUT/disk.img" "$OUT/disk.img.hvsparse"
    rm "$OUT/disk.img"
fi
say "done: $OUT ($(du -sh "$OUT" | cut -f1))"
