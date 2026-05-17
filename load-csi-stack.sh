#!/bin/bash
# load-csi-stack.sh — switch wlan0 to nexmon CSI monitor mode.
# Usage: sudo ./load-csi-stack.sh [channel] [bandwidth]
#   channel:   integer (default 36)
#   bandwidth: NOHT|HT20|HT40+|HT40-|80MHz|160MHz (default NOHT = 20 MHz)
set -eu

CHANNEL=${1:-36}
BANDWIDTH=${2:-NOHT}

if [[ $EUID -ne 0 ]]; then
    echo "must be run as root: sudo $0 [channel] [bandwidth]" >&2
    exit 1
fi

KERNEL=$(uname -r)
DRIVER_TARGET="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"

# 1. Make sure update-alternatives points to nexmon firmware
echo "[1/6] Activating nexmon firmware..."
update-alternatives --quiet --set cyfmac43455-sdio.bin \
    /lib/firmware/nexmon/brcmfmac43455-sdio.bin

# 2. Make sure our modified brcmfmac is installed
WANT_MD5="7957d8d72c74b1bf828dd012e1c1cc6a"
HAVE_MD5=$(md5sum "$DRIVER_TARGET" | cut -d" " -f1)
if [[ "$HAVE_MD5" != "$WANT_MD5" ]]; then
    echo "[2/6] Installing modified brcmfmac driver..."
    BUNDLED="$(dirname "$0")/driver/brcmfmac.ko.xz"
    if [[ ! -f "$BUNDLED" ]]; then
        BUNDLED="/home/$(logname)/brcmfmac-6.6.y-nexmon-PORTED-FOR-6.12.75.ko.xz"
    fi
    cp "$BUNDLED" "$DRIVER_TARGET"
    depmod -a
else
    echo "[2/6] Modified brcmfmac driver already installed."
fi

# 3. Stop anything that holds wlan0
echo "[3/6] Releasing wlan0..."
nmcli dev disconnect wlan0 2>/dev/null || true
nmcli dev set wlan0 managed no 2>/dev/null || true

# 4. Reload driver stack
echo "[4/6] Reloading driver..."
modprobe -r brcmfmac_wcc 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true
sleep 1
modprobe brcmfmac
sleep 5

# 5. Set monitor mode
echo "[5/6] Setting cfg80211 monitor mode + channel $CHANNEL $BANDWIDTH..."
ip link set wlan0 down
iw dev wlan0 set type monitor
ip link set wlan0 up
iw dev wlan0 set channel "$CHANNEL" "$BANDWIDTH"

# 6. Also flip nexmon internal monitor mode (required for frames to flow)
echo "[6/6] Setting nexmon monitor mode..."
/usr/bin/nexutil -Iwlan0 -m1

echo
echo "✓ Ready. wlan0 is in monitor mode."
iw dev wlan0 info | head -7
echo
echo "Capture:    sudo tcpdump -i wlan0 -w cap.pcap"
echo "Parse:      python3 examples/parse_monitor_capture.py cap.pcap"
echo "Restore:    sudo $(dirname "$0")/restore-stock.sh"
