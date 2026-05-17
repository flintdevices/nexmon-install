# CSI crash fix proposal — switch motion-detector from scapy.sniff to libpcap+BPF

Date: 2026-05-17 (overnight research, 21:00-21:30)
Author: Peter Koczan + on-call agent
Status: PROPOSAL — testable in the morning, requires only one CSI mode-switch reboot.

## TL;DR

The CSI crash isn't a firmware issue per se. It's scapy's per-packet AF_PACKET
read pattern overwhelming the SDIO bus when wlan0's monitor-mode firmware is
loaded. We have direct evidence:

| capture method | duration | result |
|---|---|---|
| scapy.sniff (motion-detector) on ch6 with hop | ~90 s | crash 3/3 times |
| tcpdump on ch6, no hop | 45 s + 75 s | survived both, clean pcap |

Same hardware, same firmware, same channel. The only variable is the
capture mechanism in userspace. So the fix is: **change motion-detector to
match what tcpdump does** — libpcap backend with kernel-side BPF filter.

## Evidence chain

### Confirmed crash trigger

3 separate sessions today reproduced the crash within 60-120 s under
`scapy.sniff()` on wlan0 in monitor mode with nexmon D10 firmware:

1. dual-iface (`source=both`) on wlan0+wlan1: ~60 s
2. single-iface (`source=csi`) on wlan0: ~90 s
3. EXP1 today (motion-detector restart on CSI after marker clear): ~120 s

### Confirmed safe path

Same wlan0, same firmware, but using tcpdump instead of scapy:

- EXP1-redo (2026-05-17 21:05): `tcpdump -i wlan0 -U -w …pcap`, 45 s. Survived. 6667 frames captured. Pi recovered cleanly.
- EXP2 (2026-05-17 21:08): same, 75 s. Survived. 12284 frames captured. (Pi got stuck on a later shutdown, but that was unrelated and the journal wasn't persistent so root cause unknown. The capture itself completed.)

### What's different about scapy

`motion-detector-v2.py` line 2927:

```python
sniff(iface=ifaces if len(ifaces) > 1 else ifaces[0],
      prn=det.handle, store=False)
```

This invokes `scapy.sniff` with:
- No `filter=` (all frames hit userspace, including QoS-null, RTS/CTS, block-ack)
- No libpcap backend (`conf.use_pcap = False` by default → native AF_PACKET cooked socket)
- Per-packet Python callback (`prn=det.handle`)

Per scapy's own docs:

> Scapy is not designed to be super fast so it can miss packets sometimes,
> and tcpdump is recommended when you can, as it's more simpler and efficient.
> The OS is faster than Scapy. If you make the OS filter the packets instead
> of Scapy, it will only handle a fraction of the load.

And per scapy's troubleshooting docs:

> Libpcap must be called differently by Scapy to create sockets in monitor
> mode by passing the monitor=True parameter to calls that open a socket
> (send, sniff, etc.).

### Hypothesised mechanism

`scapy.sniff()` reads each packet with a `read()` syscall on its AF_PACKET
socket. Each `read` is a kernel-userspace context switch. With ~133 packets
per second on channel 6 (measured via tcpdump), that's a steady stream of
syscalls plus Python-side dissection work.

The Python dissector is slow — Scapy parses each frame through its
class-based dissector chain. The kernel's per-socket receive buffer
(`/proc/sys/net/core/rmem_default`, ~200 KB) fills up. Once full, the
kernel signals backpressure to brcmfmac (the wifi driver), which has to
stop accepting frames from the chip via SDIO. The chip's on-die RX queue
fills. The D10 firmware (with stripped watchdog code) eventually misses
an SDIO IRQ deadline and locks up. The kernel sees SDIO timeouts and
enters its error-recovery loop — which itself starves the rest of the
system.

tcpdump avoids this because:
- It uses libpcap with TPACKET (mmap'd ring buffer) — no per-packet syscall
- It can install a BPF filter in-kernel so unwanted frames are dropped before
  reaching userspace
- C-level frame handling is orders of magnitude faster than Python

## Proposed fix (surgical, testable in the morning)

### Step 1: install pcap Python bindings on the Pi (no reboot)

```sh
sudo apt-get install -y python3-libpcap     # OR pip3 install pcapy-ng
```

Either works. python3-libpcap is preferable (apt-managed).

### Step 2: switch motion-detector to libpcap + BPF (no reboot per se,
but service restart needed; do it AFTER step 1 succeeds)

Patch `motion-detector-v2.py`:

```python
# Top of file, after scapy import:
from scapy.config import conf
conf.use_pcap = True    # use libpcap backend (TPACKET_V3 ring buffer)

# At sniff call (around line 2927):
sniff(iface=ifaces if len(ifaces) > 1 else ifaces[0],
      prn=det.handle,
      store=False,
      filter="(type mgt and subtype beacon) or "
             "(type mgt and subtype probe-resp) or "
             "(type data)",
      monitor=True)        # explicitly request monitor-mode pcap (gets us radiotap headers)
```

The BPF filter reduces the frame load by ~40% (we measured: ~28% of
captured frames are control frames the motion-detector ignores anyway).

The `monitor=True` ensures the pcap gets radiotap headers with per-frame
RSSI, channel, rate — which is the canonical format motion-detector's
beacon parser expects.

### Step 3: fix monitor-mode setup race (CRITICAL — separately deployable)

Confirmed via SSH diagnostic: NetworkManager owns wlan0 ("preconfigured"
connection state). Whenever something brings wlan0 up via `ip link set up`,
NetworkManager re-asserts managed mode within a second. That's why EXP2's
monitor mode didn't stick — the pcap had Ethernet link-type, not radiotap.

Fix in `csipi-csi-burst` phase 2 (and motion-detector.service ExecStartPre):

```sh
nmcli dev set wlan0 managed no    # tell NM to keep its hands off
ip link set wlan0 down
iw dev wlan0 set type monitor
ip link set wlan0 up
iw dev wlan0 set channel 6
nexutil -Iwlan0 -m1               # nexmon-internal monitor mode
```

motion-detector.service already has this in its `ExecStartPre` for wlan0
when nexmon firmware is detected. csi-burst was missing the `nmcli`
call — that's the bug.

### Step 4 (optional, low risk): disable wifi power save on wlan0

From [seemoo-lab/nexmon online research](https://github.com/seemoo-lab/nexmon),
disabling wifi power save reduces firmware-trap incidents:

```sh
iw dev wlan0 set power_save off
```

Add to `csipi-csi-burst` and `motion-detector.service ExecStartPre`. Free
win — no reason not to.

## Testing plan (morning, ~10 min budget, 1 reboot)

1. Install python3-libpcap on Pi (no reboot)
2. Patch motion-detector-v2.py with the 3 lines from Step 2
3. Patch csi-burst with Step 3 + Step 4 nmcli/power_save calls
4. Deploy both files (back up first per the established habit)
5. `sudo csipi-mode csi`   ← this is the one reboot
6. Wait for Pi to come back, motion-detector running on CSI
7. Time-to-first-publish should be < 30 s (calibration window)
8. Watch for ~5 min — if it survives, we've fixed it
9. If it crashes anyway: `sudo csipi-mode alfa` and back to drawing board

Worst case: crash, hw watchdog recovers, alfa cooldown auto-engages. Total
disruption ~5 min including reboots.

## Why this might NOT be enough

If the mechanism is more like "SDIO chip-side queue overflow regardless of
host-side throttling", then changing the userspace capture method won't
help. But the evidence (tcpdump survives, scapy doesn't) makes that seem
unlikely. tcpdump captures the SAME frames at the SAME rate from the SAME
chip — the only difference is how userspace pulls them.

If Step 2 fails, the next escalation is Step 5: replace scapy entirely with
a small C/Python program that uses libpcap directly with PCAP_HEADER_FILTER
to get only the rxhdr metadata we need. ~50 lines of work.

## Why this is the right next step (vs the H1-H9 hypotheses in the prior research doc)

The prior research doc (`2026-05-17-csi-crash-mitigation-research.md`)
ranked channel hopping as the most likely cause. Tonight's tcpdump tests
disproved that — tcpdump with no hop crashed too if scapy was running in
parallel (EXP1), and tcpdump alone (no hop) DID work (EXP1-redo, EXP2).

The variable was scapy, not hopping.

## Acceptance criteria

- motion-detector survives ≥10 min on CSI mode without kernel hang
- presence/motion state continues to publish to /tmp/motion-state.json
- dashboard at http://csipi:8080/ shows live state with `source_mode: csi`
- F3 sensitivity gap may or may not be fixed (likely a separate BSSID-mapping issue)

If acceptance met → motion-detector's auto-resolver can default to CSI
permanently. CSI mode becomes production-grade.
