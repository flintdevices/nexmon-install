# D10: minimal nexmon_csi build that boots on Pi 4 + kernel 6.12

Date: 2026-05-17

## Background

A full `seemoo-lab/nexmon_csi` build firmware-traps during init on Pi 4 + kernel 6.12 (the usual `type 0x4 @ epc 0x0022bcd8`). Tried 18+ bisection rounds — the failure is structural: the C function definitions in `src/csi_extractor.c` are what crashes init, not any single attribute patch.

## Recipe

Apply this to upstream `seemoo-lab/nexmon_csi` `src/csi_extractor.c` (the version at commit `a975a10`, the latest as of 2026-05):

```python
# strip-csi-extractor.py — run from nexmon_csi/ dir
PATH = "src/csi_extractor.c"
with open(PATH) as f: src = f.read()

# Keep a backup of the unmodified version
import shutil
shutil.copy(PATH, PATH + ".full")

# Cut everything from the "// header of csi frame coming from ucode" comment
# through the end of process_frame_prehook_off0x8. Keep the size + amsdu
# patches that come after.
prefix_end = src.find("extern void prepend_ethernet_ipv4_udp_header(struct sk_buff *p);")
marker = "// Increase d11rxhdr size in initvals"
idx = src.find(marker)
new_src = (
    src[:prefix_end]
    + "extern void prepend_ethernet_ipv4_udp_header(struct sk_buff *p);\n\n"
    + "// All C function definitions removed — they crash firmware init on\n"
    + "// Pi 4 + kernel 6.12. Only __attribute__((at())) patches remain.\n\n"
    + src[idx:]
)
with open(PATH, "w") as f: f.write(new_src)
print("D10 source ready")
```

What's left after the strip:
- Size patches at `0x1F5768`, `0x1F5778` (d11rxhdr length doubling)
- Size patches at `0x210F56`, `0x210F60` (hwrxoff / hwrxoff_pktget)
- AMSDU workaround at `0x1B6B02` (per nexmon_csi issue #41)

What's gone:
- `process_frame_hook` (the C function that would package CSI as UDP/5500)
- `process_frame_prehook_off0x8` (the asm hook at `0x1C1C3E`)
- `create_new_csi_frame`, `prepend_ethernet_ipv4_udp_header` helpers
- BCM4339 variant of the prehook

The ucode patches and IOCTL handlers in other source files (`patch.c`, `ioctl.c`, `console.c`, `regulations.c`) remain. The chip is still configured for CSI — it generates marker frames into SHM — there's just no C code to package the data for export.

## Build

```sh
cd ~/nexmon
source ./setup_env.sh
cd patches/bcm43455c0/7_45_189/nexmon_csi
make clean && make
# Result: brcmfmac43455-sdio.bin, ~617123 bytes
# Identifies as "7.45.189 (nexmon.org/csi: a975-dirty-N)" at runtime
```

## Verify it boots

```sh
sudo make -f Makefile.rpi install-firmware   # registers via update-alternatives
sudo modprobe -r brcmfmac_wcc brcmfmac
sudo modprobe brcmfmac
sudo dmesg | grep brcmf_c_preinit_dcmds | tail -1
# Should show: "version 7.45.189 (nexmon.org/csi: ...)"
```

If you see that line WITHOUT a `brcmf_sdio_checkdied: firmware trap` after it, the D10 build is alive.

## Why this works when the full build doesn't

Hypothesis: the `process_frame_prehook` asm at `0x1C1C3E` destroys instructions that the firmware's init loop iteration needs. The function `0x1C1B2C` containing the prehook is reached during chip init (probably as part of self-test or rxqueue scanning), runs one loop iteration with sentinel data, and the original `str r5, [sp, #8]; bl wlc_phy_rssi_compute; bl wlc_recv` are essential for that iteration to complete cleanly. Replacing them with `bl process_frame_hook + NOPs` breaks the iteration, and any C body for `process_frame_hook` that later calls `wlc_phy_rssi_compute` with the init-time wlc_hw fails inside chip-init code paths.

Removing the prehook entirely (D3) wasn't enough because the C functions still ended up in the patch RAM region (`PATCHSTART = 0x22A95C`), and the firmware's reclaim mechanism touched that region during init. Removing the C functions ENTIRELY (D10) clears patch RAM down to just helper code, which happens to leave the firmware init path alone.
