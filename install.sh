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
KVER=${KERNEL%%[!0-9.]*}             # strip suffix, e.g. 6.18.34
KMAJ=${KVER%%.*}                     # 6
KMIN=${KVER#*.}; KMIN=${KMIN%%.*}    # 18
# 6.12 is the reference kernel. 6.13-6.18 build via driver/kernel-6.18-porting.patch
# (applied automatically below). Anything outside that range is untested.
if [[ "$KMAJ" != 6 || "$KMIN" -lt 12 || "$KMIN" -gt 18 ]]; then
    echo "WARNING: this stack is validated on kernel 6.12-6.18. You're on $KERNEL."
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
# apt's package index may be empty/stale (fresh image, or install.sh run before
# any other apt command) — that alone produces "Unable to locate package" for
# every name below, so refresh it first.
apt-get update -q

# --no-install-recommends avoids pulling in linux-headers-arm64 (Debian package
# that conflicts with Raspberry Pi OS's raspberrypi-kernel-headers).
apt-get install -y --no-install-recommends dkms patch

# raspberrypi-kernel-headers only exists on Raspberry Pi OS's own vendor-kernel
# repo. Devices running a mainline/Debian-provided kernel (or a Pi OS suite
# where that repo hasn't published headers yet) need the generic
# linux-headers-$(uname -r) package instead. Try both rather than hard-failing
# on the first one that apt doesn't know about.
if apt-cache show raspberrypi-kernel-headers >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends raspberrypi-kernel-headers
elif apt-cache show "linux-headers-$KERNEL" >/dev/null 2>&1; then
    echo "    raspberrypi-kernel-headers not found in apt — using linux-headers-$KERNEL"
    apt-get install -y --no-install-recommends "linux-headers-$KERNEL"
else
    echo "ERROR: no matching kernel headers package found for kernel $KERNEL" >&2
    echo "       Tried: raspberrypi-kernel-headers, linux-headers-$KERNEL" >&2
    echo "       Run 'apt-cache search linux-headers' and install the matching" >&2
    echo "       package manually, then re-run this script." >&2
    exit 6
fi

# The package name existing in apt doesn't guarantee it matches the *running*
# kernel (e.g. a headers package for an older/newer point release). DKMS needs
# a real build tree, so fail clearly here instead of deep inside `dkms build`.
if [[ ! -e "/lib/modules/$KERNEL/build" ]]; then
    echo "ERROR: /lib/modules/$KERNEL/build is missing after installing headers." >&2
    echo "       Installed kernel headers don't match the running kernel ($KERNEL)." >&2
    echo "       This usually means the headers package is out of sync with the" >&2
    echo "       running kernel — try 'apt-get update && apt-get upgrade' and reboot," >&2
    echo "       or install headers matching $KERNEL manually." >&2
    exit 7
fi

echo "[3/6] Installing Kali brcmfmac-nexmon-dkms (DKMS will build against running kernel)"
# Back up the in-tree driver before DKMS lands the updates/ version on top.
INTREE="/lib/modules/$KERNEL/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz"
if [[ -f "$INTREE" && ! -f "$INTREE.stock-backup" ]]; then
    cp "$INTREE" "$INTREE.stock-backup"
fi
# DKMS AUTOINSTALL builds the module immediately. On kernels newer than 6.12
# that first build fails until the porting patch is applied, so tolerate a
# non-zero exit here and rebuild from patched source below.
dpkg -i "$KALI_DEB" || true

# Locate the DKMS source tree the .deb just unpacked and apply the kernel
# 6.13-6.18 compatibility port (version-gated; a no-op on 6.12). Idempotent.
NEXMON_SRC=$(ls -d /usr/src/brcmfmac-nexmon-*/ 2>/dev/null | head -n1)
if [[ -z "$NEXMON_SRC" ]]; then
    echo "ERROR: brcmfmac-nexmon DKMS source not found under /usr/src" >&2
    exit 5
fi
NEXVER=$(basename "${NEXMON_SRC%/}" | sed 's/^brcmfmac-nexmon-//')
if ! grep -q "nexmon 6.18 port" "$NEXMON_SRC/cfg80211.c"; then
    echo "    Applying kernel 6.13-6.18 porting patch"
    patch -p1 -d "$NEXMON_SRC" < "$REPO_DIR/driver/kernel-6.18-porting.patch"
fi

# (Re)build and install the module against the running kernel from patched source.
dkms build   --force -m brcmfmac-nexmon -v "$NEXVER"
dkms install --force -m brcmfmac-nexmon -v "$NEXVER"

# Reconcile dpkg state (postinst DKMS steps now succeed against the patched tree).
dpkg --configure -a || true

# --- 3. Install nexutil ---
# flint detects nexmon by probing /usr/local/bin/nexutil and applies its
# capability bits there (flint-caps.service), so install to that path.

if [[ -f /usr/local/bin/nexutil && ! -f /usr/local/bin/nexutil.stock-backup ]]; then
    cp /usr/local/bin/nexutil /usr/local/bin/nexutil.stock-backup
fi

echo "[4/6] Installing nexutil (USE_VENDOR_CMD=1 build)"
install -m 755 "$REPO_DIR/utils/nexutil" /usr/local/bin/nexutil
setcap cap_net_admin+ep /usr/local/bin/nexutil

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
    # Marked so flint's restore-to-stock path removes only the line we added.
    echo "dtoverlay=disable-bt   # flint-nexmon" >> "$CONFIG_TXT"
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
