#!/bin/bash
# install.sh — install the nexmon CSI stack (firmware + Kali's brcmfmac-nexmon-dkms
# driver + nexutil) on Raspberry Pi 4 + Pi OS Bookworm + kernel 6.12.x.
#
# As of 2026-05-18, the production stack uses Kali Linux's `brcmfmac-nexmon-dkms`
# package as a drop-in replacement for our previous self-ported brcmfmac. The
# Kali driver fixes the sustained-monitor-mode kernel hang we'd been chasing
# for weeks. See findings/2026-05-18-kali-dkms-driver-fixes-sustained-csi.md.
#
# The .deb is shipped in the repo at driver/brcmfmac-nexmon-dkms_6.12.2_all.deb
# (mirrored from https://pkg.kali.org/pkg/brcmfmac-nexmon-dkms).
#
# Our D10 nexmon-CSI firmware is still required (Kali's firmware-nexmon
# package is monitor-only, not CSI-patched), so we install it via
# update-alternatives the same way we always did.
#
# After install, use load-csi-stack.sh (or csipi-mode csi) to switch wlan0
# to monitor mode, and restore-stock.sh to revert.

set -eu

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root: sudo $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Sanity checks ---

KERNEL=$(uname -r)
KERNEL_MAJOR_MINOR=$(echo "$KERNEL" | grep -oE '^[0-9]+\.[0-9]+')

case "$KERNEL_MAJOR_MINOR" in
    6.12|6.18)
        ;;
    *)
        echo "WARNING: this stack is tested on kernel 6.12.x and 6.18.x. You're on $KERNEL."
        echo "         Continuing anyway, but expect breakage."
        sleep 2
        ;;
esac

if [[ ! -f /lib/firmware/cypress/cyfmac43455-sdio-standard.bin ]]; then
    echo "ERROR: stock Cypress firmware not found at"
    echo "       /lib/firmware/cypress/cyfmac43455-sdio-standard.bin"
    echo "       Install firmware-brcm80211 from apt first."
    exit 2
fi

if [[ ! -e /sys/class/net/eth0 ]]; then
    echo "WARNING: no eth0 detected. If wlan0 breaks after switching to nexmon,"
    echo "         you may need physical access to recover."
    echo "         Continue anyway? [y/N]"
    read -r yn
    [[ "$yn" =~ ^[Yy] ]] || exit 3
fi

# --- 1. Stage the D10 nexmon-CSI firmware via update-alternatives ---

echo "[1/6] Installing D10 nexmon-CSI firmware to /lib/firmware/nexmon/"
mkdir -p /lib/firmware/nexmon
cp "$REPO_DIR/firmware/brcmfmac43455-sdio.bin" /lib/firmware/nexmon/brcmfmac43455-sdio.bin

update-alternatives --quiet --install \
    /lib/firmware/cypress/cyfmac43455-sdio.bin \
    cyfmac43455-sdio.bin \
    /lib/firmware/nexmon/brcmfmac43455-sdio.bin 30

# Leave the system on stock for now; the user switches via load-csi-stack.sh
# or csipi-mode csi.
update-alternatives --quiet --set cyfmac43455-sdio.bin \
    /lib/firmware/cypress/cyfmac43455-sdio-standard.bin

# --- 2. Install the Kali brcmfmac-nexmon-dkms driver ---
# This replaces our former self-ported brcmfmac.ko.xz. The DKMS build
# auto-recompiles on kernel upgrades, which the self-port did not.

KALI_DEB="$REPO_DIR/driver/brcmfmac-nexmon-dkms_6.12.2_all.deb"
if [[ ! -f "$KALI_DEB" ]]; then
    echo "ERROR: Kali DKMS driver not found at $KALI_DEB"
    echo "       Download from https://pkg.kali.org/pkg/brcmfmac-nexmon-dkms"
    echo "       and drop the .deb into driver/."
    exit 4
fi

echo "[2/6] Installing dkms + kernel headers (required to build the DKMS module)"
# --no-install-recommends avoids pulling in linux-headers-arm64 (Debian package
# that conflicts with Raspberry Pi OS's raspberrypi-kernel-headers).
apt-get install -y --no-install-recommends dkms raspberrypi-kernel-headers

echo "[3/6] Installing Kali brcmfmac-nexmon-dkms (DKMS will build against running kernel)"
# Back up the in-tree driver before DKMS lands the updates/ version on top.
INTREE="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"
if [[ -f "$INTREE" && ! -f "$INTREE.stock-backup" ]]; then
    cp "$INTREE" "$INTREE.stock-backup"
fi
dpkg -i "$KALI_DEB" || true   # may fail on first run if DKMS build fails; we patch below

# On kernel 6.16+ the timer API changed (del_timer_sync→timer_delete_sync,
# from_timer→timer_container_of) and several cfg80211_ops signatures gained a
# radio_idx parameter. The Kali 6.12.2 DKMS source needs a small patch to
# compile on kernel 6.18. Apply it now and trigger a rebuild.
DKMS_SRC="/usr/src/brcmfmac-nexmon-6.12.2"
PATCH_6_18="$REPO_DIR/driver/kernel-6.18-porting.patch"
KERNEL_MAJOR_MINOR_NUM=$(echo "$KERNEL_MAJOR_MINOR" | tr -d '.')

if [[ -d "$DKMS_SRC" && -f "$PATCH_6_18" && "$KERNEL_MAJOR_MINOR_NUM" -ge 616 ]]; then
    if ! grep -q "timer_delete_sync" "$DKMS_SRC/cfg80211.c" 2>/dev/null; then
        echo "    Applying kernel-6.18-porting.patch to DKMS source..."
        patch -p1 -d /usr/src < "$PATCH_6_18"
        dkms build  brcmfmac-nexmon/6.12.2 -k "$KERNEL"
        dkms install brcmfmac-nexmon/6.12.2 -k "$KERNEL"
    else
        echo "    kernel-6.18-porting.patch already applied — skipping"
    fi
fi

# --- 3. Install nexutil ---

if [[ -f /usr/bin/nexutil && ! -f /usr/bin/nexutil.stock-backup ]]; then
    cp /usr/bin/nexutil /usr/bin/nexutil.stock-backup
fi

echo "[4/6] Installing nexutil (USE_VENDOR_CMD=1 build)"
cp "$REPO_DIR/utils/nexutil" /usr/bin/nexutil
chmod 755 /usr/bin/nexutil
setcap cap_net_admin+ep /usr/bin/nexutil

# --- 4. Install scripts ---

echo "[5/6] Installing helper scripts"
install -m 755 "$REPO_DIR/load-csi-stack.sh" /usr/local/bin/load-csi-stack
install -m 755 "$REPO_DIR/restore-stock.sh"  /usr/local/bin/restore-stock

# --- 5. Disable BT — D10 minimal firmware does not init BT coexistence cleanly ---
# Without this, boot enters a watchdog-driven reboot loop when D10 is staged.
# Our Pi doesn't use BT for anything; this is free.

CONFIG_TXT=/boot/firmware/config.txt
if [[ -f "$CONFIG_TXT" ]] && ! grep -q "^dtoverlay=disable-bt" "$CONFIG_TXT"; then
    echo "[6/6] Adding 'dtoverlay=disable-bt' to $CONFIG_TXT (required for D10 CSI firmware)"
    echo "dtoverlay=disable-bt" >> "$CONFIG_TXT"
    NEEDS_REBOOT_FOR_BT=1
else
    echo "[6/6] dtoverlay=disable-bt already in $CONFIG_TXT — skipping"
    NEEDS_REBOOT_FOR_BT=0
fi

# --- 6. Arm the BCM2835 hardware watchdog (defensive — should no longer be
#        needed now that the Kali driver doesn't hang, but kept for safety) ---

WD_CONF=/etc/systemd/system.conf.d/csipi-hardware-watchdog.conf
if [[ ! -f "$WD_CONF" ]]; then
    echo "    Arming BCM2835 hardware watchdog (defensive — auto-reboot on kernel hang)"
    mkdir -p "$(dirname "$WD_CONF")"
    cat > "$WD_CONF" <<'WDEOF'
[Manager]
# Hardware watchdog — defensive. With the Kali brcmfmac-nexmon-dkms driver the
# kernel no longer hangs on sustained CSI capture, but the watchdog is cheap
# insurance against future firmware/driver bugs. systemd kicks /dev/watchdog0
# every RuntimeWatchdogSec/2 (so this is a no-op when the system is healthy).
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
WDEOF
    systemctl daemon-reexec
fi

# --- Done ---

cat <<EOF

✓ Installed.

Quick usage:

    sudo csipi-mode csi              # Switch to D10 nexmon-CSI firmware (reboots)
    sudo csipi-mode alfa             # Switch back to stock Cypress (reboots)

    sudo tcpdump -i wlan0 -c 20      # Capture some frames once in CSI mode
    sudo tcpdump -i wlan0 -w cap.pcap

    python3 utils/analyze_csi_burst_pcap.py cap.pcap   # decode wrapped frames

Notes:
    - You currently still have stock Cypress firmware loaded. csipi-mode csi
      switches to the nexmon CSI firmware (priority 30 in update-alternatives;
      stock standard is priority 50 = the default).
    - The Kali brcmfmac-nexmon-dkms driver auto-rebuilds on kernel upgrades —
      no manual driver step is needed after \`apt upgrade\`.
    - With the new driver, sustained monitor-mode capture is stable indefinitely
      (validated 5 min in repo tests). The hw watchdog is kept armed defensively.
EOF

if [[ "${NEEDS_REBOOT_FOR_BT:-0}" = "1" ]]; then
    echo
    echo "  ⚠  REBOOT required to apply dtoverlay=disable-bt: sudo reboot"
fi
