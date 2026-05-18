# Kali's brcmfmac-nexmon-dkms fixes sustained CSI capture on Pi 4 / kernel 6.12

Date: 2026-05-18
Author: Peter Koczan
Status: SHIPPED. Supersedes `2026-05-18-shipped-solution-burst-only-csi.md`.

## The headline

Sustained monitor-mode CSI capture on the Pi 4 BCM43455 + kernel 6.12.75
**works**. The bug we'd been hunting for weeks was in **our self-ported
brcmfmac driver**, not in the firmware, the chip, the SDIO bus, or the
kernel. Replacing the driver with Kali Linux's
`brcmfmac-nexmon-dkms 6.12.2` package flips the failure mode from
"60-90 s silent kernel hang" to "indefinite sustained capture, no errors."

## The validated production stack

```
  Driver:    Kali brcmfmac-nexmon-dkms 6.12.2     (replaces self-port)
  Firmware:  our D10 minimal nexmon-CSI build      (provides per-frame RSSI)
             md5 dcf871872d, version 7.45.189 (nexmon.org/csi: a975-dirty-1)
  Kernel:    6.12.75+rpt-rpi-v8                    (stock RPi OS Bookworm)
  BT:        DISABLED (dtoverlay=disable-bt)       (D10 doesn't init BT cleanly)
```

Result: **5-min sustained tcpdump capture, 32,869 frames, 0 kernel errors,
30+ BSSIDs detected, per-BSSID RSSI σ matches reality.**

## Why this combination

There are two distinct "nexmon" firmware projects, and you need to
know which is which:

- **nexmon** (what Kali ships in `firmware-nexmon`) — monitor mode +
  injection support. Delivers raw 802.11 frames via `EN10MB`-typed pcap
  with NO per-frame metadata wrapper.
- **nexmon_csi** (our self-built D10 minimal) — adds CSI extraction code
  that wraps each frame in a 64-byte header containing per-frame RSSI
  (signed byte at offset 30), timestamp, and CSI data on supported frames.

For motion detection via per-BSSID RSSI σ analysis we **need** the wrapper.
So we have to keep our D10 firmware build. Kali's firmware-nexmon is not
sufficient on its own.

The driver problem is independent of which firmware you load — Kali's
DKMS driver works with both. Our D10 firmware loaded under Kali's driver
delivers the wrapper format we already wrote `analyze_csi_burst_pcap.py`
to consume.

## Why BT must be disabled

The D10 minimal build was compiled without BT-coexistence init code (it's
a CSI-only minimum-features firmware). With BT enabled at boot, the
firmware load itself succeeds and wlan0 enters monitor mode briefly, but
the system rapidly enters a watchdog-driven reboot loop. With
`dtoverlay=disable-bt` in `/boot/firmware/config.txt`, boot is clean and
sustained capture is stable indefinitely.

This is consistent with the original BCM43455 nexmon-CSI project guidance
(`seemoo-lab/nexmon_csi` README recommends disabling BT to avoid
interference). Our Pi doesn't use BT for anything, so this is free.

## Comparison: before vs after

| Configuration | Result |
|---|---|
| Self-ported brcmfmac + D10 firmware + BT enabled  | crash @ 60-90 s |
| Self-ported brcmfmac + D10 firmware + BT disabled | crash @ 114 s |
| **Kali DKMS brcmfmac + D10 firmware + BT disabled** | **5 min clean, 32,869 frames, 0 errors** |
| Kali DKMS brcmfmac + Kali firmware + BT enabled | 5 min clean, but **no CSI wrapper / no RSSI** |
| Kali DKMS brcmfmac + D10 firmware + BT enabled | watchdog reboot loop (D10 ↔ BT) |

The 5-min ceiling is just our test budget. The chip is steady at ~100 fps,
no error logs anywhere — there is no indication it would stop on its own.

## Why the self-ported driver was broken

We backported brcmfmac from nexmon's 6.6.y branch to kernel 6.12 ourselves
in earlier sessions. The Kali maintainers have done that work properly,
tested it on Pi 4, and ship it as a DKMS package that auto-rebuilds against
the running kernel. Their module is 131,716 bytes vs our 130,492 bytes —
that ~1.2 KB delta is enough room for the fixes that prevent whatever
pathology was causing sustained-sniff to silently jam the SDIO IRQ path
under load.

Concrete evidence the driver was the culprit:

- Same firmware, same kernel, same chip, same userspace tooling — only
  the driver `.ko.xz` changed between the two test runs.
- Under the old driver, motion-detector NEVER received a packet in monitor
  mode (`csipi-nexmon-watchdog` reverted firmware every boot because its
  heartbeat check failed). Under the new driver, packets flow to userspace
  immediately (~100 fps via tcpdump, 0 drops).
- Old driver runs ended in `wlan0` becoming unrecoverable, kernel logs
  going silent. New driver finishes a 5-min run with `wlan0` still in
  `Mode:Monitor`, still healthy.

## Captured data validation

5-min pcap, analysed with `utils/analyze_csi_burst_pcap.py`:

- 30,463 valid 802.11 frames extracted (~100 fps average)
- 30+ BSSIDs detected including both home SSIDs, REOLINK cameras,
  guest BSSIDs, mobile devices
- Per-BSSID RSSI σ matches reality:
  - cameras (stable mounts): σ = 1.3-3.0
  - mobile devices (laptops, phones): σ = 10-15
- Frame type distribution healthy: 22,543 beacons, 4,344 data,
  2,170 probe-resp, 839 qos-null, 259 probe-req

## What this changes for the deployed system

- The auto-resolver lock-to-alfa in `motion-detector-v2.py` can be relaxed:
  CSI is no longer a "burst-only" capability — it's a viable continuous
  source again.
- `csipi-csi-burst` remains useful for harvesting pcaps on demand, but the
  bounded-burst + auto-revert design (a workaround for the crash) is no
  longer strictly needed.
- `csipi-nexmon-watchdog` can be downgraded from "revert on no-packets" to
  "alert on no-packets" — the new driver doesn't need it.
- `dtoverlay=disable-bt` should be made permanent in `install.sh`.

## Recommended migration path for the repo

1. `install.sh`:
   - `apt install brcmfmac-nexmon-dkms` from Kali repo (carrying the .deb
     directly is fine too — it's `brcmfmac-nexmon-dkms_6.12.2_all.deb`).
   - Skip `firmware-nexmon` (it doesn't help us — we use our D10 build).
   - Ensure `dtoverlay=disable-bt` is in `/boot/firmware/config.txt`.
   - Stop building / shipping the self-ported `brcmfmac.ko.xz`.
2. Re-enable CSI as a normal `--source` in motion-detector's auto-resolver.
3. Keep our D10 firmware build and `csipi-mode csi`/`csipi-mode alfa`
   tooling as-is — they're still the right way to swap firmware.

## Reference

- Kali Linux 2025.1 package: <https://pkg.kali.org/pkg/brcmfmac-nexmon-dkms>
- nexmon_csi upstream: <https://github.com/seemoo-lab/nexmon_csi>
- DKMS source on the Pi: `/usr/src/brcmfmac-nexmon-6.12.2/`
