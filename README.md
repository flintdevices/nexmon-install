# Raspberry Pi 4 — built-in WiFi monitor mode + nexmon CSI on Pi OS Bookworm (kernel 6.12)

A working stack for **monitor mode** (and partial CSI groundwork) on the Raspberry Pi 4's built-in BCM43455 chip, running the current Pi OS Bookworm with kernel **6.12.x** — the kernel version that's been blocking [nexmon_csi](https://github.com/seemoo-lab/nexmon_csi) for everyone.

This is the result of about a week of debugging because every existing guide assumed kernel 5.x or Pi 5. Pi 4 + kernel 6.12 was a black hole. The artifacts here unblock it.

## What works

| Capability | Status |
|---|---|
| Boot the nexmon firmware on Pi OS Bookworm + kernel 6.12 | ✅ |
| Load the modified `brcmfmac` driver (ported to kernel 6.12) | ✅ |
| Use `nexutil` with `USE_VENDOR_CMD=1` | ✅ |
| `cfg80211` monitor mode on `wlan0` (`iw dev wlan0 set type monitor`) | ✅ |
| Capture raw 802.11 frames in 2.4 GHz / 5 GHz with `tcpdump` | ✅ |
| One-shot deploy/restore scripts | ✅ |
| Auto-detect firmware on boot, pick interface mode (csi/alfa/both/auto) | ✅ |
| Watchdog auto-reverts nexmon firmware if motion-detector can't see packets | ✅ |
| Full `nexmon_csi` UDP/5500 CSI packets (`process_frame_hook` style) | ❌ — see "Known limitations" |

So: this is the **monitor-mode-on-built-in-WiFi** problem solved for Pi 4 + Bookworm. The CSI subcarrier extraction in the canonical nexmon UDP/5500 format is still not solved because of a deep firmware-init crash that the modified driver does not fix. The chip is configured for CSI capture (ucode + size patches active) but no `process_frame_hook` packages CSI into UDP packets. The monitor capture path is usable if you want to write your own parser.

## Tested combination

- **Pi**: Raspberry Pi 4 Model B Rev 1.1 (BCM4345/6 / BCM43455c0)
- **OS**: Raspberry Pi OS Bookworm 64-bit
- **Kernel**: `6.12.75+rpt-rpi-v8`
- **Firmware**: nexmon-built `7.45.189 (nexmon.org/csi: a975-dirty-1)`, derived from `seemoo-lab/nexmon_csi` master
- **Driver**: nexmon-modified `brcmfmac` ported from `nexmon/patches/driver/brcmfmac_6.6.y-nexmon` to kernel 6.12 API
- **nexutil**: built with `USE_VENDOR_CMD=1`

## Quick install

**Before you do anything, plug in an Ethernet cable.** This stack swaps the WiFi firmware live. If anything goes wrong, `wlan0` is gone — you need eth0 to recover.

```sh
git clone https://github.com/peterkoczan/raspberry-pi-4-wifi-csi-pi-os-bookworm.git
cd raspberry-pi-4-wifi-csi-pi-os-bookworm
sudo ./install.sh
```

After install, switch to the nexmon stack:

```sh
sudo ./load-csi-stack.sh 36           # channel 36, default HT20
# or
sudo ./load-csi-stack.sh 36 HT80      # channel 36, 80 MHz wide
```

Verify:

```sh
sudo iw dev wlan0 info                 # should show "type monitor"
sudo tcpdump -i wlan0 -c 20            # should show real 802.11 frames
```

Switch back to stock Cypress (regular WiFi) when done:

```sh
sudo ./restore-stock.sh
```

If you bricked `wlan0` and the script is unreachable, see [Recovery](#recovery).


### Verify it captures real traffic

Once `wlan0` is in monitor mode, run a quick capture and parse it:

```sh
sudo apt install -y python3-scapy
sudo tcpdump -i wlan0 -c 200 -w cap.pcap
python3 examples/parse_monitor_capture.py cap.pcap
```

You should see beacons from every nearby AP, with SSID + BSSID + frame count.
That confirms `wlan0` is genuinely in monitor mode and capturing 5GHz/2.4GHz
traffic.

## What's in here

```
firmware/brcmfmac43455-sdio.bin       — nexmon CSI firmware that BOOTS on kernel 6.12
                                          md5: dcf871872d0a215e8e0dfe8de931637a
                                          built from seemoo-lab/nexmon_csi (commit a975a10)
                                          identifies as "7.45.189 (nexmon.org/csi: a975-dirty-1)"

driver/brcmfmac.ko.xz                  — out-of-tree brcmfmac for kernel 6.12.75+rpt-rpi-v8
                                          md5: 7957d8d72c74b1bf828dd012e1c1cc6a
                                          based on nexmon/patches/driver/brcmfmac_6.6.y-nexmon
                                          adds the kernel-6.7→6.12 API porting patches

driver/kernel-6.12-porting.patch       — what changed vs upstream nexmon 6.6.y, in case you
                                          want to rebuild yourself

utils/nexutil                          — statically linked nexutil aarch64 binary built with
                                          USE_VENDOR_CMD=1 (per nexmon_csi discussion #395)
                                          md5: 08c0936f0af0dd3d261b79fd9a72d47b

install.sh                             — install firmware + driver + nexutil to system paths,
                                          register firmware via update-alternatives
load-csi-stack.sh [channel] [bandwidth] — switch to nexmon firmware + load modified driver
                                          + put wlan0 in monitor mode
restore-stock.sh                       — switch back to stock Cypress firmware + stock driver
                                          + reconnect WiFi via NetworkManager
```

## Why this exists

Recent nexmon_csi works on:
- Older kernels (4.19, 5.4, 5.10, 5.15) — well-documented, modified `brcmfmac` driver shipped.
- Pi 5 + kernel 6.12 — works via the `Makefile.rpi` flow ([discussion #395](https://github.com/seemoo-lab/nexmon_csi/discussions/395)).

It does **not** work on:
- Pi 4 + kernel 6.6 / 6.12 — there's no modified driver shipped for these kernels, AND the `Makefile.rpi` flow assumes the unmodified upstream driver works, which it doesn't on Pi 4 (the firmware fails to expose `wlan0` to cfg80211 monitor mode without nexmon driver hooks).

So you're stuck unless you either downgrade your kernel (painful on current Pi OS) or build the driver yourself. This repo is the latter, pre-built.

## How to build the driver yourself

If you don't trust the prebuilt `brcmfmac.ko.xz`, here's the build:

```sh
sudo apt install -y git build-essential bc bison flex libssl-dev raspberrypi-kernel-headers \
                    libnl-3-dev libnl-genl-3-dev libgmp3-dev gawk qpdf autoconf libtool texinfo

# 1. Get nexmon
git clone --depth=1 https://github.com/seemoo-lab/nexmon.git ~/nexmon
cd ~/nexmon && source ./setup_env.sh && make

# 2. Apply the kernel 6.12 porting patches
cd patches/driver/brcmfmac_6.6.y-nexmon
patch -p1 < <path-to-this-repo>/driver/kernel-6.12-porting.patch

# 3. Build
make -C /lib/modules/$(uname -r)/build M=$PWD modules
# Result: brcmfmac.ko (~570 KB)

# 4. Install
xz brcmfmac.ko
sudo cp brcmfmac.ko.xz \
  /lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.xz
sudo depmod -a
```

The porting patch is small — six kernel-API fixes between 6.6 and 6.12:

| Change | Why |
|---|---|
| `<asm/unaligned.h>` → `<linux/unaligned.h>` | Header moved in kernel 6.12 |
| Remove `bss_data.scan_width` assignment | Field removed from `struct cfg80211_inform_bss` in 6.7 |
| `change_beacon` callback: `cfg80211_beacon_data *` → `cfg80211_ap_update *` | Signature changed in 6.7 |
| `strlcpy` → `strscpy` | `strlcpy` removed in 6.8 |
| `platform_device.remove` returns `void` instead of `int` | Signature changed in 6.11 |
| `no_llseek` → `noop_llseek` | `no_llseek` removed in 6.12 |
| `usb_driver.drvwrap.driver` → `usb_driver.driver` | Layout changed in 6.12 |

## How to build the firmware yourself

The firmware here is built from upstream `seemoo-lab/nexmon_csi` with one source modification: `src/csi_extractor.c` has the C function definitions removed (only the `__attribute__((at()))` patches remain). This is the minimal change required for the firmware to boot on Pi 4 + kernel 6.12 without trapping.

```sh
cd ~/nexmon/patches/bcm43455c0/7_45_189
git clone --depth=1 https://github.com/seemoo-lab/nexmon_csi.git
cd nexmon_csi

# Strip the function definitions out of csi_extractor.c (keep only the patch attributes)
# See `csi_extractor.c.minimal-diff` in this repo for the exact change.

source ~/nexmon/setup_env.sh
make
# Result: brcmfmac43455-sdio.bin (617 KB)

# Install via update-alternatives (not by hand-copying — see "Recovery" below)
sudo make -f Makefile.rpi install-firmware
```

## How `load-csi-stack.sh` works

It does the dance manually:
1. `update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/nexmon/brcmfmac43455-sdio.bin`
2. Install the modified `brcmfmac.ko.xz` if not already installed.
3. Stop any service that holds `wlan0` open.
4. `nmcli dev set wlan0 managed no` so NetworkManager stops touching it.
5. `modprobe -r brcmfmac_wcc brcmfmac` then `modprobe brcmfmac` (loads our driver, **not** the Cypress `_wcc` plugin).
6. `iw dev wlan0 set type monitor`, set channel.
7. `nexutil -Iwlan0 -m1` — also flip nexmon-internal monitor mode. Both flags are required: cfg80211 type and nexmon mode.

After that, `tcpdump -i wlan0` captures real 802.11 frames.

## Known limitations

### CSI in the canonical UDP/5500 format does not work

In a normal nexmon_csi setup, the firmware emits CSI data as UDP packets to port 5500 (decoded by tools like [`CSIKit`](https://github.com/Gi-z/CSIKit)). That requires nexmon's `process_frame_hook` C function in firmware, which crashes the Pi 4 + kernel 6.12 driver during init (firmware trap `type 0x4 @ epc 0x0022bcd8`, deep inside chip-init code paths). The crash is firmware-internal — the modified driver does **not** fix it.

This repo ships a firmware build with the `process_frame_hook` C functions removed but the rest of the CSI patches (size patches, AMSDU workaround, ucode patches, IOCTL hook) intact. The chip is in CSI mode; raw 802.11 frames with the doubled `d11rxhdr` (containing some CSI metadata) flow through the monitor interface; nothing writes the canonical UDP/5500 format. If you want CSI in this setup, write a userspace parser that pulls the rxhdr metadata out of monitor captures.

### `nexutil -s500` (the CSI config IOCTL) often crashes the firmware

Sending the standard CSI configuration IOCTL (cmd 500) sometimes works, sometimes traps the firmware (trap `0x4 @ 0x0022acf2` or similar). The IOCTL handler does a long chain of SHM writes that don't survive the modern driver init. If this happens you need to power-cycle (the auto-revert in `update-alternatives` brings stock Cypress back on next boot).

### Sustained monitor-mode capture hangs the kernel after ~60-90 s

Even with the minimal D10 firmware (CSI patches present, `process_frame_hook` C-side stripped), running `scapy.sniff()` continuously against `wlan0` in monitor mode locks up the BCM43455 SDIO bus within roughly 60-90 seconds. The brcmfmac error handler then loops on SDIO command timeouts and starves the rest of the kernel — SSH stops responding, ICMP stops answering, and the Pi appears dead.

What helps:

- **Hardware watchdog (auto-armed by `install.sh`).** The BCM2835 hardware watchdog is on the SoC but isn't armed by default. `install.sh` drops a systemd unit at `/etc/systemd/system.conf.d/csipi-hardware-watchdog.conf` that kicks `/dev/watchdog0` every ~7.5 s; if the kernel misses by more than 15 s the hardware fires a hard reset. From the outside, a kernel hang turns into a ~30-second blip instead of a "please walk to the power supply." Verify with `systemctl show -p RuntimeWatchdogUSec`.
- **Run short capture bursts only.** A few seconds of `tcpdump -i wlan0 -c 5000` is usually fine; sustained `sniff` for minutes is the trigger.
- **Use a USB adapter (Alfa AWUS036ACH / ath9k_htc) for production capture.** Treat the BCM43455 nexmon stack as the lab toy — handy for exploring CSI internals, not what you want feeding your motion detector at 4 AM.

This is a firmware-side problem, not a driver bug; the same modified `brcmfmac.ko.xz` is rock-solid under normal `wpa_supplicant` workloads.

### What this does NOT cover

- Pi 5 (use the [official discussion #395 procedure](https://github.com/seemoo-lab/nexmon_csi/discussions/395) — it works).
- Pi Zero / Pi 3 / CM4 (untested, may need different chip-specific patches).
- Other kernel versions (built for `6.12.75+rpt-rpi-v8`; YMMV with other 6.12.x patch levels).
- Other Pi OS variants (tested only on Bookworm 64-bit).

## Recovery

If `wlan0` is gone after running these scripts, you have two options:

**Easy** — via Ethernet:
```sh
sudo update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/cypress/cyfmac43455-sdio-standard.bin
sudo apt install --reinstall linux-image-$(uname -r)   # restores stock brcmfmac.ko
sudo reboot
```

**Harder** — physical access to the SD card:
1. Pull the SD card, mount on another machine.
2. Edit the firmware symlink: `cypress/cyfmac43455-sdio.bin` should point to `cyfmac43455-sdio-standard.bin`.
3. Replace `brcmfmac.ko.xz` from a known-good kernel modules backup (or `apt-get install --reinstall linux-image-...` on first boot).

If you bricked things badly: the `brcmfmac` change is reversible by `apt --reinstall linux-image-...`. The firmware change is reversible via `update-alternatives`. The Pi itself is fine — only `wlan0` is affected. Ethernet, USB, HDMI all keep working regardless.

**Strong recommendation: keep eth0 plugged in during all firmware/driver experiments.** It is the only path back if `wlan0` dies and you don't want to physically touch the Pi.

## Background and references

- [seemoo-lab/nexmon](https://github.com/seemoo-lab/nexmon) — the C-based firmware patching framework
- [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi) — the CSI extraction patches
- [Discussion #395](https://github.com/seemoo-lab/nexmon_csi/discussions/395) — the "use Makefile.rpi on recent kernels" tutorial (works on Pi 5, not Pi 4)
- [Project Zero on Broadcom Wi-Fi](https://googleprojectzero.blogspot.com/2017/04/over-air-exploiting-broadcoms-wi-fi_4.html) — for context on how the firmware's "reclaim" memory regions work
- [CSIKit](https://github.com/Gi-z/CSIKit) — the standard CSI parser, if you can get CSI out (this repo doesn't, currently)

## Why a minimal CSI firmware build?

The full `nexmon_csi` firmware crashes Pi 4 + kernel 6.12 with `firmware trap in dongle, type 0x4 @ epc 0x0022bcd8`. The crash is inside `process_frame_hook`'s CSI extraction path — specifically the indirect call `wl->dev->chained->funcs->xmit(...)` lands in stale memory during firmware self-init (the function is reached on an init code path before `wl->dev` is fully populated).

After 18 rounds of bisection across firmware patches and a custom-built brcmfmac driver for kernel 6.12, the conclusion is: **the C function definitions in `csi_extractor.c` must be removed for the firmware to boot on Pi 4 + kernel 6.12**. The `__attribute__((at()))` patches (size patches, AMSDU patch) are safe; the C functions are not.

Removing the C functions gives up the CSI UDP/5500 path but keeps the firmware bootable. The chip's ucode is still patched, so CSI data IS generated, it just doesn't get packaged. Writing a userspace parser for the raw monitor captures is the way to get CSI from here.

## License

The nexmon firmware and driver are under nexmon's original license (see [seemoo-lab/nexmon](https://github.com/seemoo-lab/nexmon)). The scripts and porting patches in this repo are MIT.

## Issues, PRs, questions

If you can get the `process_frame_hook` C path working on Pi 4 + 6.12, please open a PR — that would close the last gap. Likely paths: (a) finding a different firmware address to hook at (one only called at real RX time, not during init), or (b) deeper trap-state debugging to understand exactly which pointer is bad and why.
