# Why D10 alone doesn't produce CSI markers — and what would

Date: 2026-05-17

## Tested theory: chip might be producing CSI marker frames in monitor mode without IOCTL 500

It doesn't. Captured 10,049 frames over 30 seconds on channel 40 with the D10
stack in monitor mode (no IOCTL 500 sent). Analyzed all 10K frames in Python.
Found: regular WiFi traffic only (beacons, probes, data, control). No frames
with the nexmon CSI marker pattern (RxFrameSize == 2 in the d11rxhdr).

The 528-byte frames in the capture (1108 of them, biggest cluster) are just
long beacons with many information elements (extended capabilities, multi-AP
disclosure IEs, etc.) — not CSI marker frames.

## Why no CSI markers

The ucode patch generates CSI markers ONLY when SHM_CSI_COLLECT is non-zero.
SHM_CSI_COLLECT is set by IOCTL 500. IOCTL 500 silently no-ops in pure monitor
mode because of `wlc->hw->up` gating (see `2026-05-17-shm-access-via-nexutil.md`).

Even tried "associate to home WiFi in managed mode first, send IOCTL 500, then
switch to monitor". The IOCTL returned rc=0 but reading SHM at the CSI_COLLECT
address didn't change — suggesting the IOCTL handler's case body still no-op'd
silently. The actively-associated state wasn't enough to make `hw->up` true
inside the firmware's view at IOCTL-receive time.

## The chain that needs to work

1. **Chip must boot** (D10 firmware does this ✓)
2. **Driver must communicate** (modified brcmfmac for 6.12 does this ✓)
3. **SHM_CSI_COLLECT must be set to 1** (BLOCKED — IOCTL 500 no-ops)
4. **Ucode marker frames must reach userspace** (would work if step 3 was set)
5. **Userspace must parse the marker frames into CSI** (Python is fine for this)

We have 1, 2, 5. Stuck at 3.

## Workarounds I'd try next

- **Patch ioctl.c case 500 to skip the `if (wlc->hw->up...)` gate** and just always write the SHM. Rebuild D10 with this change. Risk: if `hw->up=0` means the firmware really isn't ready for SHM writes, this could crash. Worth testing because the result is well-defined either way.
- **Add a brand-new IOCTL handler** (say cmd 504) that does ONLY `wlc_bmac_write_shm(wlc->hw, SHM_CSI_COLLECT * 2, 1)` and nothing else, with no gating. Smallest possible attack surface.
- **Direct SHM write via a different chip-debug mechanism** — broadcom chips have a JTAG-like debug interface accessible from the host bus. nexmon doesn't use it but the documentation exists. Probably out of scope.

## Honest assessment

Without modifying the firmware (which crashes init when modified beyond the
D10-minimal recipe), we cannot enable CSI from userspace via the existing
IOCTLs. The D10 stack gives us monitor mode + raw WiFi capture, which is
useful for many things (presence detection via per-frame RSSI, beacon SSID
discovery, IDS-style monitoring) but is NOT CSI subcarrier data.

For CSI specifically, the realistic paths are:
- Pi 4 + Pi OS Bullseye (kernel 5.15) + legacy nexmon driver
- Pi 5 + Pi OS Bookworm/Trixie + Discussion #395 procedure
- ESP32-C6 distributed sensors (cheap, distributed, stock firmware ships CSI)
