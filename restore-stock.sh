#!/bin/bash
# restore-stock.sh — revert from nexmon stack back to stock Cypress firmware
# + stock brcmfmac driver + NetworkManager-managed wlan0.
set -eu

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root: sudo $0" >&2
    exit 1
fi

KERNEL=$(uname -r)

# 1. Switch firmware alternative back to stock Cypress
echo "[1/4] Switching firmware to stock Cypress..."
update-alternatives --quiet --set cyfmac43455-sdio.bin \
    /lib/firmware/cypress/cyfmac43455-sdio-standard.bin

# 2. Restore stock brcmfmac driver (the modified one breaks brcmfmac_wcc)
DRIVER_TARGET="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"
if [[ -f "$DRIVER_TARGET.stock-backup" ]]; then
    echo "[2/4] Restoring stock brcmfmac.ko.xz from backup..."
    cp "$DRIVER_TARGET.stock-backup" "$DRIVER_TARGET"
    depmod -a
else
    echo "[2/4] No backup found. Reinstalling kernel package to restore stock driver..."
    apt-get install --reinstall -y linux-image-$KERNEL
fi

# 3. Reload the kernel module stack
echo "[3/4] Reloading driver stack..."
modprobe -r brcmfmac 2>/dev/null || true
modprobe -r brcmfmac_wcc 2>/dev/null || true
sleep 1
modprobe brcmfmac_wcc   # this pulls in stock brcmfmac as a dependency
sleep 5

# 4. Hand wlan0 back to NetworkManager
echo "[4/4] Handing wlan0 back to NetworkManager..."
nmcli dev set wlan0 managed yes 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
sleep 2
nmcli dev connect wlan0 2>/dev/null || true

echo
echo "✓ Stock Cypress restored."
iw dev wlan0 info 2>&1 | head -6 || true
echo
echo "If wlan0 doesn't reconnect to your AP, reboot once:"
echo "  sudo reboot"
