#!/bin/bash
# csipi-csi-deploy — load nexmon CSI stack: D10 firmware + modified brcmfmac + monitor mode
# Pi 4 + kernel 6.12 ONLY. Tested 2026-05-17.
set -eu

CSIPI_CHANNEL=${1:-36}
CSIPI_BANDWIDTH=${2:-HT20}

if [[ $EUID -ne 0 ]]; then echo "must be root"; exit 1; fi

# 1. Make sure update-alternatives points to nexmon firmware
update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/nexmon/brcmfmac43455-sdio.bin 2>/dev/null

# 2. Make sure our modified brcmfmac is installed
INSTALLED_MD5=$(md5sum /lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz | cut -d" " -f1)
WANT_MD5=$(md5sum /home/pkoczan/brcmfmac-6.6.y-nexmon-PORTED-FOR-6.12.75.ko.xz | cut -d" " -f1)
if [[ "$INSTALLED_MD5" != "$WANT_MD5" ]]; then
  echo "Installing modified brcmfmac driver..."
  cp /home/pkoczan/brcmfmac-6.6.y-nexmon-PORTED-FOR-6.12.75.ko.xz \
     /lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz
  depmod -a
fi

# 3. Stop wlan0 users
for s in csipi-live-server csipi-fb-gui csipi-sys-mqtt motion-detector; do
  systemctl stop $s 2>/dev/null || true
done
nmcli dev disconnect wlan0 2>/dev/null || true
nmcli dev set wlan0 managed no 2>/dev/null || true

# 4. Reload driver
modprobe -r brcmfmac_wcc 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true
sleep 1
modprobe brcmfmac
sleep 5

# 5. Set monitor mode
ip link set wlan0 down
iw dev wlan0 set type monitor
ip link set wlan0 up
iw dev wlan0 set channel $CSIPI_CHANNEL $CSIPI_BANDWIDTH

# 6. Set nexmon monitor mode
/usr/bin/nexutil -Iwlan0 -m1

# 7. Show state
iw dev wlan0 info
echo "Ready. Capture with: sudo tcpdump -i wlan0 -w capture.pcap"
