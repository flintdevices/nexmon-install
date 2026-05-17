#!/bin/bash
# restore-stock.sh — revert from nexmon back to stock Cypress firmware.
# Uses reboot-based revert (safer than live modprobe).
set -eu

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root" >&2
    exit 1
fi

KERNEL=$(uname -r)

echo "[1/3] Switching firmware alternative back to stock Cypress..."
update-alternatives --quiet --set cyfmac43455-sdio.bin \
    /lib/firmware/cypress/cyfmac43455-sdio-standard.bin

# Optional: restore stock brcmfmac driver if backup exists
DRIVER_TARGET="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"
if [[ -f "$DRIVER_TARGET.stock-backup" ]]; then
    echo "[2/3] Restoring stock brcmfmac.ko.xz from backup..."
    cp "$DRIVER_TARGET.stock-backup" "$DRIVER_TARGET"
    depmod -a
else
    echo "[2/3] No stock-backup found. Reinstalling kernel package to get stock driver..."
    apt-get install --reinstall -y "linux-image-$KERNEL" || true
fi

rm -f /etc/profile.d/csi-mode-tip.sh

echo "[3/3] Reverted. System will reboot in 5 seconds. Cancel with Ctrl-C."
sleep 5
reboot
