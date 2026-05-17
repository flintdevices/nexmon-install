# D20: bypassing wlc->hw->up gate in IOCTL handler crashes firmware

Date: 2026-05-17

## What I tried

Modified `nexmon_csi/src/ioctl.c` case 500 to bypass the `wlc->hw->up`
check, hoping the SHM write inside would then succeed in monitor mode:

```c
// Before:
if (wlc->hw->up && len > 1) {
    wlc_bmac_write_shm(wlc->hw, SHM_CSI_COLLECT * 2, ...);
    ...
}

// After (D20):
if (1 || (wlc->hw->up && len > 1)) {  // skip the hw->up gate
    wlc_bmac_write_shm(wlc->hw, SHM_CSI_COLLECT * 2, ...);
    ...
}
```

Rebuilt the firmware on top of the D10 csi_extractor.c strip (kept the C-functions-removed change). Deployed via update-alternatives + modprobe reload.

## What happened

Firmware traps almost immediately after the driver brings up wlan0:

```
brcmfmac: brcmf_sdio_checkdied: firmware trap in dongle
brcmfmac: dongle trap info: type 0x2 @ epc 0x00251fe8
```

Type 0x2 in the Broadcom HND trap-type enumeration is a software interrupt
(`TR_SWI` / `SVC`). EPC `0x251FE8` is in RAM (`>= 0x198000`) but past the
loaded firmware blob's end (`0x22EAA3`), meaning execution landed in
uninitialized runtime RAM. That's the same pattern we've seen before with
the original full-CSI build — a corrupted code pointer sent the CPU into junk.

## Why

The `wlc->hw->up` check exists because the SHM writes are unsafe when the
chip isn't fully initialized. Specifically:
- `wlc_bmac_write_shm` walks `wlc->hw` for the SDIO mailbox.
- During monitor-only operation, `wlc` is set up but `wlc->hw->up` is 0,
  meaning various state machines in the firmware haven't reached
  ready-for-SHM-writes state.
- The IOCTL also does `set_chanspec()` and `set_scansuppress()`. These
  do their own state-machine transitions which assume the chip is operational.

So the gate isn't cosmetic. Removing it lets the IOCTL run through code
paths that aren't safe yet, corrupting state and trapping the chip.

## Implication

Userspace cannot enable CSI capture in monitor mode by simply bypassing the
gate. The firmware genuinely needs to be in operational state (associated
or actively scanning, not pure monitor) for the SHM write chain in IOCTL
500 to be safe.

## What might still work

- A **minimal IOCTL** (say case 504) that does ONE small thing — `wlc_bmac_write_shm(wlc->hw, SHM_CSI_COLLECT * 2, 1)` — and nothing else. No `set_chanspec`, no `set_scansuppress`, no other SHM writes. If `wlc_bmac_write_shm` itself is safe even with `hw->up=0`, this would work.
- Send IOCTL 500 ONLY from managed-associated state, before switching to monitor. We tried this; IOCTL returned rc=0 but SHM didn't change, meaning the gate STILL no-op'd. So the firmware's view of `hw->up` differs from what we thought "associated" means.
- Hack the firmware to set a custom flag we control, then gate on THAT instead of `hw->up`.

## State after

Reverted to D10 firmware (csi_extractor.c stripped, ioctl.c restored to upstream). Stock Cypress is the active alternative for safety. Pi healthy.
