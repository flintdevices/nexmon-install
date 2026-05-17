#!/bin/bash
# install.sh — install the nexmon CSI stack (firmware + modified brcmfmac + nexutil) on
# Raspberry Pi 4 + Pi OS Bookworm + kernel 6.12.x.
#
# After install, use load-csi-stack.sh to switch wlan0 to monitor mode, and
# restore-stock.sh to revert.

set -eu

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root: sudo $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Sanity checks ---

KERNEL=$(uname -r)
if [[ "$KERNEL" != 6.12.* ]]; then
    echo "WARNING: this stack is tested on kernel 6.12.x. You're on $KERNEL."
    echo "         Continuing anyway, but expect breakage."
    sleep 2
fi

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

# --- 1. Stage the nexmon firmware via update-alternatives ---

echo "[1/4] Installing nexmon firmware to /lib/firmware/nexmon/"
mkdir -p /lib/firmware/nexmon
cp "$REPO_DIR/firmware/brcmfmac43455-sdio.bin" /lib/firmware/nexmon/brcmfmac43455-sdio.bin

update-alternatives --quiet --install \
    /lib/firmware/cypress/cyfmac43455-sdio.bin \
    cyfmac43455-sdio.bin \
    /lib/firmware/nexmon/brcmfmac43455-sdio.bin 30

# Leave the system on stock for now; the user switches via load-csi-stack.sh
update-alternatives --quiet --set cyfmac43455-sdio.bin \
    /lib/firmware/cypress/cyfmac43455-sdio-standard.bin

# --- 2. Install the modified brcmfmac driver ---

DRIVER_TARGET="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"

if [[ -f "$DRIVER_TARGET" && ! -f "$DRIVER_TARGET.stock-backup" ]]; then
    echo "[2/4] Backing up stock brcmfmac.ko.xz"
    cp "$DRIVER_TARGET" "$DRIVER_TARGET.stock-backup"
fi

echo "[2/4] Installing modified brcmfmac.ko.xz"
cp "$REPO_DIR/driver/brcmfmac.ko.xz" "$DRIVER_TARGET"
depmod -a

# --- 3. Install nexutil ---

if [[ -f /usr/bin/nexutil && ! -f /usr/bin/nexutil.stock-backup ]]; then
    cp /usr/bin/nexutil /usr/bin/nexutil.stock-backup
fi

echo "[3/4] Installing nexutil (USE_VENDOR_CMD=1 build)"
cp "$REPO_DIR/utils/nexutil" /usr/bin/nexutil
chmod 755 /usr/bin/nexutil
setcap cap_net_admin+ep /usr/bin/nexutil

# --- 4. Install scripts ---

echo "[4/4] Installing helper scripts"
install -m 755 "$REPO_DIR/load-csi-stack.sh" /usr/local/bin/load-csi-stack
install -m 755 "$REPO_DIR/restore-stock.sh"  /usr/local/bin/restore-stock

# --- 5. Arm the BCM2835 hardware watchdog (HIGHLY recommended for CSI work) ---
# Sustained monitor-mode capture can lock the SDIO bus and hang the kernel.
# With the hw watchdog armed, that hang becomes a 30-second auto-reboot
# instead of "walk over to the power supply." Idempotent — re-runs are safe.

WD_CONF=/etc/systemd/system.conf.d/csipi-hardware-watchdog.conf
if [[ ! -f "$WD_CONF" ]]; then
    echo "[5/5] Arming BCM2835 hardware watchdog (auto-reboot on kernel hang)"
    mkdir -p "$(dirname "$WD_CONF")"
    cat > "$WD_CONF" <<'WDEOF'
[Manager]
# Hardware watchdog — auto-reboot if the kernel hangs (e.g. nexmon firmware
# crash starving the SDIO bus). Pi BCM2711 hw watchdog max timeout is ~15s.
# systemd kicks /dev/watchdog0 every RuntimeWatchdogSec/2.
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
WDEOF
    systemctl daemon-reexec
    if systemctl show -p RuntimeWatchdogUSec --value | grep -q '15s'; then
        echo "        ✓ watchdog armed (15s timeout)"
    else
        echo "        ⚠ watchdog conf written but systemd didn't pick it up — reboot to apply"
    fi
else
    echo "[5/5] Hardware watchdog already configured at $WD_CONF — skipping"
fi

# --- Done ---

cat <<EOF

✓ Installed.

Quick usage:

    sudo load-csi-stack 36           # Switch to nexmon firmware, channel 36 (HT20)
    sudo load-csi-stack 36 HT40+     # Or with explicit bandwidth/HT40+

    sudo tcpdump -i wlan0 -c 20      # Capture some frames in monitor mode
    sudo tcpdump -i wlan0 -w cap.pcap

    sudo restore-stock               # Back to stock Cypress + NetworkManager

Notes:
    - You currently still have stock Cypress firmware loaded. The above
      switches to nexmon. wlan0 will lose its connection to your WiFi network.
    - This is a live driver reload. If it fails, reboot for safety: stock
      Cypress is the configured default (priority 50) and nexmon is priority 30.
    - Keep eth0 plugged in during experimentation.
    - The BCM2835 hardware watchdog is now armed; sustained monitor-mode
      capture can hang the kernel after ~60-90s, and the hw watchdog will
      hard-reset the Pi within 15s of the hang. See README "Known limitations".
EOF
