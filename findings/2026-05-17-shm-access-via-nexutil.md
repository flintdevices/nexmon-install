# SHM access via nexutil + the wlc->hw->up gating

Date: 2026-05-17

## What works

`nexutil -Iwlan0 -o <byte-addr> -l <bytes>` reads chip object memory from
userspace. This is the `NEX_READ_OBJMEM` IOCTL (cmd 406) handled in
`nexmon_csi/src/ioctl.c`:

```c
case NEX_READ_OBJMEM:
{
    set_mpc(wlc, 0);
    if (wlc->hw->up && len >= 4) {
        int addr = ((int *) arg)[0];
        for (i = 0; i < len / 4; i++) {
            wlc_bmac_read_objmem32_objaddr(wlc->hw, addr + i,
                                            &((unsigned int *) arg)[i]);
        }
        ret = IOCTL_SUCCESS;
    }
    break;
}
```

Verified working with the D10 minimal build + USE_VENDOR_CMD nexutil. Example:

```sh
sudo nexutil -Iwlan0 -o 0x1160 -l 8
# 0x000000: ab 77 f5 06 e0 80 01 00
```

## Address mapping gotcha

nexmon source uses 16-bit word indices for SHM constants:

```c
#define SHM_CSI_COLLECT  0x8b0
```

But the IOCTL handler passes addresses through `wlc_bmac_read_objmem32_objaddr`
which expects byte addresses. So `nexutil -o` takes byte addresses. To read
`SHM_CSI_COLLECT`, use `nexutil -o 0x1160` (= `0x8b0 * 2`).

## What doesn't work yet: SHM writes from monitor mode

`IOCTL 500` (configure CSI), `IOCTL 502` (force deaf), `IOCTL 503` (clean
deaf) all return `rc=0` from nexutil but the SHM values they're supposed to
write don't actually change. Reason: each case body is gated on `wlc->hw->up`:

```c
case 502:    // force deaf mode
{
    if (wlc->hw->up && len > 1) {       // <-- this check fails in monitor mode
        wlc_bmac_write_shm(wlc->hw, FORCEDEAF * 2, 1);
        ret = IOCTL_SUCCESS;
    }
    break;
}
```

When we switch wlan0 to cfg80211 monitor mode (`iw dev wlan0 set type
monitor`) and put the chip in nexmon monitor (`nexutil -m1`), the firmware's
internal `wlc->hw->up` is FALSE — so any SHM write the IOCTL would do is
silently skipped.

The IOCTL succeeds (returns 0) because the handler doesn't error on
`!hw->up` — it just no-ops.

## Implications

To actually configure CSI from userspace via the existing IOCTL handlers,
you need to:

1. Bring `wlan0` UP in managed mode (so `wlc->hw->up == 1`).
2. Associate with an AP (or at least start scanning so chip thinks it's
   operational).
3. Send `nexutil -s500 -v<config>` while still in managed.
4. THEN switch to monitor mode + capture.

This is risky — the IOCTL 500 handler also runs `set_chanspec(wlc, params->chanspec)`
which can deauth/disassociate, and then sends a long chain of `wlc_bmac_write_shm`
that has historically traps the firmware on Pi 4 + kernel 6.12 (`type 0x4 trap`
at various addresses, depending on patch layout).

If you want to skip the IOCTL and write SHM yourself, the firmware doesn't
currently expose an objmem WRITE path — you'd need to add a new IOCTL case
to `ioctl.c` (e.g., `case NEX_WRITE_OBJMEM`) that does
`wlc_bmac_write_objmem32_objaddr(wlc->hw, addr, value)` and rebuild
firmware. Note that this still requires `wlc->hw->up`, so it doesn't
escape the gating.

## Where CSI subcarriers actually land in SHM

The nexmon_csi ucode patches write CSI data into specific SHM regions per
`csi.ucode.bcm43455c0.7_45_189.patch`:

- `SHM_CSI_COLLECT 0x8B0` — control register (1 = capture enabled)
- `RX_HDR_BASE 0x8d0` and following — extended d11rxhdr with per-subcarrier values
- `SPARE1..SPARE6` — scratch registers used by the ucode patch

Once CSI is properly enabled (the gating above is solved), polling
`nexutil -o 0x11a0 -l 1024` (= byte address for `0x8d0` word, plus 1024 bytes
of CSI data) should return live CSI samples that change per RX packet.

## Tried + ruled out

- Pure read access: works ✓
- SHM write via IOCTL 500/502/503 in monitor mode: silently no-ops (hw->up=0)
- Sending IOCTL 500 in managed mode then switching to monitor: not yet tested
  (skipped because the SHM writes inside IOCTL 500 have a history of firmware
  traps on Pi 4 + kernel 6.12)

## Next ideas to try

1. **Managed-first sequence**: `iw set type managed → ip up → nmcli connect →
   nexutil -s500 → iw set type monitor → tcpdump`. Risk: the IOCTL 500 SHM
   write chain might trap firmware. Mitigation: use the `csipi-csi-mode`
   safety net with auto-revert if it traps.
2. **Add `NEX_WRITE_OBJMEM` IOCTL to ioctl.c** and rebuild firmware. Then
   userspace can write CSI_COLLECT=1 directly without going through cmd 500's
   long chain. Still gated on `hw->up`.
3. **Patch the IOCTL handler to bypass the `hw->up` gate** for the SHM-write
   paths. Risky — `hw->up=0` exists for a reason (chip not in operational
   state) — writes might fail or hang the firmware.
4. **Hook the bare firmware's `wl_up` path** to set a custom flag we control,
   then check that flag instead of `hw->up` in the IOCTL handler. Most
   robust but requires nexmon firmware modification.
