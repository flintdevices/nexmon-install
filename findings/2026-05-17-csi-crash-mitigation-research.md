# CSI sustained-capture crash — mitigation research (read-only)

Date: 2026-05-17 (evening)
Author: Peter Koczan + on-call agent
Status: research only, no experiments run tonight (user request: no risk of overnight power-cycle)

## Recap of the known failure

D10 minimal firmware (`brcmfmac43455-sdio.bin` md5 `dcf871872d0a215e8e0dfe8de931637a`)
boots cleanly on Pi 4 + kernel 6.12.75. Monitor mode works, packets capture. But
**under sustained scapy or tcpdump on `wlan0`**, the BCM43455 SDIO bus locks up
within 60-90 seconds:

- SSH stops responding on both eth0 and wlan0
- ICMP no longer answers
- BCM2835 hardware watchdog auto-reboots within 30 s (mitigation already deployed)

journald cannot preserve the actual crash signature because the kernel hangs
before the log flushes. So the root cause has to be inferred from what we know
about the chip + the patches.

## Current configuration (verified 2026-05-17 20:55)

- SDIO bus: 50 MHz nominal / 41.7 MHz actual, high-speed mode, 4-bit width
- Channel hop: every 1.5 s across [1, 6, 11] when running default motion-detector config
- Channel-set syscall per hop: `iw dev wlan0 set channel <N>` → triggers firmware reconfiguration over SDIO
- brcmfmac loaded with no special module parameters (defaults across the board)
- nexutil monitor mode enabled via `nexutil -Iwlan0 -m1` in motion-detector.service
- scapy v2.5.0, libpcap 1.10.3 with TPACKET_V3

## Hypotheses, ranked by plausibility and ease of test

### H1: Channel hop is the trigger (HIGH plausibility, EASY test)

Every 1.5 s, `iw set channel N` fires. Each invocation triggers a sequence of
SDIO command + register-write transactions inside the brcmfmac driver to
reconfigure the radio. D10 firmware strips the original watchdog code that
catches SDIO timeouts cleanly — so a hop coinciding with a heavy beacon-rx burst
could starve the chip's main loop just long enough to drop an SDIO IRQ.

**Experiment**: hold wlan0 on a single channel for the whole capture, no
hopping. Use `tcpdump -i wlan0 -w /tmp/csi-no-hop.pcap` (no scapy) for ~3 min.
If the Pi stays alive past 90 s, channel hop is the trigger.

**Recipe** (DO IN THE MORNING, ~5 min outage):
```sh
sudo systemctl stop motion-detector   # stop scapy contention
sudo csipi-mode csi                   # reboots into nexmon
# wait ~30s for boot
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
sudo iw dev wlan0 set channel 6      # stay on 6, no hopping
sudo nexutil -Iwlan0 -m1
sudo timeout 180 tcpdump -i wlan0 -U -w /tmp/csi-no-hop.pcap
# if Pi still alive at end:
sudo csipi-mode alfa                  # reboot back to safe
```

### H2: scapy's Python loop is overhead-heavy (LOW plausibility — disproven)

Already disproven: prior testing showed single-iface scapy and dual-iface scapy
both crash. tcpdump uses libpcap directly. If H1 is right, tcpdump alone (no
scapy) also crashes if channel hop is left on.

If H1 is wrong AND tcpdump survives where scapy fails, then it's Python
overhead. Unlikely but cheap to disprove during the H1 test (it uses tcpdump).

### H3: Beacon rx volume overflows SDIO upload queue (MEDIUM, EASY test)

Channel 6 in Bussum is busy — `n_bssids=22` last snapshot. Each beacon
(~100 µs frame) is rx'd by the chip, packaged into an SDIO frame, and pushed
up to the host. At ~10 beacons/s × 22 networks × 3 channels = ~660 beacons/min,
plus probe-req/resp + data frames. If brcmfmac's SDIO read path can't keep up,
the on-chip rx queue fills and the firmware locks.

**Experiment**: stay on channel 36 or 149 (5 GHz, far less crowded). If only
a handful of beacons arrive per second, the queue stays shallow.

**Recipe** (similar to H1 but with `iw dev wlan0 set channel 36 HT20`).

### H4: Need to disable channel scan probe-requests (MEDIUM, EASY test)

`iw set channel` may also trigger a scan-like probe-request burst. Try adding
`nexutil -t0` (no scan) before sniffing.

### H5: Reduce brcmfmac txglomsz to bound TX queue (LOW, needs reboot to apply)

`txglomsz` is the SDIO TX packet chain size. Default unknown — `modprobe -r`
hangs the Pi, so we can't reload safely. If next firmware swap happens, drop
to `txglomsz=4` via `/etc/modprobe.d/brcmfmac.conf`.

### H6: Use BPF filter to drop most frames at kernel level (MEDIUM, EASY)

`tcpdump -i wlan0 'subtype data'` filters out beacons + probe traffic via BPF,
so only data frames hit userspace. The frames the chip generated are still
delivered over SDIO, BUT they get discarded earlier. Net effect on SDIO
pressure: zero. So this probably doesn't help — BPF runs after SDIO.

Listing for completeness but expecting no improvement.

### H7: Run with brcmfmac debug=0x80000 to log SDIO events (READ-ONLY)

`echo 0x80000 | sudo tee /sys/module/brcmfmac/parameters/debug` enables SDIO
debug logging without re-loading the module. Combined with a CSI session,
journalctl should capture detailed SDIO command logs RIGHT UP TO the crash —
giving us the actual mechanism instead of inference. ⚠ This might itself
overflow journald and slow the kernel enough to mask the bug.

### H8: Replace D10 with a "monitor-mode-only" nexmon build (HARD, days of work)

The actual firmware-debug path. Strip the CSI patches (size, ucode,
flashpatches) entirely from `nexmon_csi` and leave only the monitor-mode
enabler. If THAT runs stable, we've isolated the CSI patches as the crash
cause. If THAT also crashes, the issue is fundamental to running BCM43455
in monitor mode under kernel 6.12.

Requires a build cycle on a separate machine (cross-compile env not set up
on the Pi).

### H9: Pivot to ESP32-C6 (HIGH effort, but ENDS the project's CSI problem)

ESP32-C6 has working CSI extraction with sub-second sustained capture, no
SDIO issues (uses different bus to the host). Drop-in replacement for the
"WiFi CSI" sensor role. Already noted in earlier session docs as the
recommended pivot.

## Recommendation for tomorrow

Run H1 first — it's the cheapest test that yields the most information.
Total wall-clock: ~5 min including two reboots. If channel hopping IS the
trigger, motion-detector can be patched to disable hopping in CSI mode
(`--hop-interval 0` or per-source override), and CSI mode becomes usable.

If H1 fails (crash within 90s even without hopping), H3 (5 GHz channel) is
the next-cheapest test.

If H3 also fails, the channel-rx-volume hypothesis is wrong and the issue
is deeper — proceed to H8 or H9 over multiple sessions.

## Pieces that are already in place to enable this safely

- BCM2835 hardware watchdog: auto-reboots on kernel hang (~30 s)
- `csipi-mode csi|both|alfa` CLI: clean firmware swap + reboot
- `csipi-csi-burst <seconds>` tool (untested as of 2026-05-17): 2-stage capture
  with auto-revert + boot-time resume service
- `/etc/csipi-csi-unstable` cooldown marker: auto-resolver respects it for
  30 min after a crash

So tests can be run during the day with confidence that the worst case is
a 2-min outage + an auto-recovered reboot. No physical power cycle needed.
