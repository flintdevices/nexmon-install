#!/bin/bash
# Revert from nexmon back to stock Cypress
set -eu
if [[ $EUID -ne 0 ]]; then echo "must be root"; exit 1; fi

update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/cypress/cyfmac43455-sdio-standard.bin

# Restore original brcmfmac (need the original somehow)
# For now just request reboot - the original brcmfmac is in linux-image package
modprobe -r brcmfmac 2>/dev/null
modprobe brcmfmac_wcc

nmcli dev set wlan0 managed yes
sleep 2
nmcli dev connect wlan0 2>/dev/null || true

# Start csipi services
for s in csipi-live-server csipi-fb-gui csipi-sys-mqtt motion-detector csipi-lcd-touch; do
  systemctl start $s 2>/dev/null || true
done

iw dev wlan0 info
