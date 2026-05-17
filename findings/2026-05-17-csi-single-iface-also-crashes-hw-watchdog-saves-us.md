# CSI-only (single-iface scapy) also crashes — ~90s — but hardware watchdog saves the day

Date: 2026-05-17
Author: Peter Koczan

## What we tested

After the dual-iface (`source=both`) crash earlier today, we hypothesised
that the problem was just dual-iface scapy on a busy Pi. So we switched
to `csi` alone — single-iface scapy on wlan0 with nexmon D10 firmware
(md5 `dcf871872d0a215e8e0dfe8de931637a`) loaded, Alfa NOT in monitor mode.

## Result

CSI ran fine for ~90 seconds (publishing motion-state.json with `heard`
counts increasing normally), then the kernel hung. SSH died on both eth0
and wlan0. Same symptom as the dual-iface case — the BCM43455 SDIO bus
locks up and brcmfmac's error handler starves the system.

So **CSI is not a scapy-load problem** — D10 firmware itself is unstable
under continuous monitor-mode capture on this Pi 4 / kernel 6.12 stack,
regardless of how many ifaces scapy is reading from.

This corroborates the earlier session's conclusion (memory note dated
2026-05-17): "nexmon_csi ❌ (dongle trap at ROM addr 0x0022bcd8, even
with fresh build + linker fix). CSI patches need real debug work OR pivot
to ESP32-C6 hardware."

## What saved us this time: the hardware watchdog

For the dual-iface crash earlier, we needed a manual power cycle. For
this CSI-only crash, the BCM2711 hardware watchdog auto-rebooted the Pi
within 15 seconds.

Setup deployed in `/etc/systemd/system.conf.d/csipi-hardware-watchdog.conf`:

    [Manager]
    RuntimeWatchdogSec=15s
    RebootWatchdogSec=2min

systemd kicks `/dev/watchdog0` every ~7.5s. If the kernel hangs longer
than 15s, the BCM2835 hardware watchdog block fires a hard reset. From
the user's perspective: a 30-second downtime and the Pi is back, instead
of "Peter, please walk over to the power supply."

## Behaviour now

1. Default `motion-detector --source auto` picks `alfa` (proven stable
   for months). `csi` is only chosen if firmware is staged AND the
   `/etc/csipi-csi-unstable` marker is older than 30 minutes.

2. `sudo csipi-mode csi` and `sudo csipi-mode both` still work — they're
   labelled experimental in this repo. The hw watchdog will auto-recover
   any crash so users can safely poke at CSI without bricking the Pi.

3. The new `csi unstable: …` line in `csipi-mode status` shows the
   operator exactly why the auto-resolver isn't picking CSI:

       csi unstable: YES (touched 16s ago — auto-resolver falls back to alfa for 30 min)
                     reason: D10 nexmon csi crashes after ~90s of sustained sniff

## Next steps (not done today)

- Try to capture an SDIO trace before/during the hang to see whether the
  chip is firing IRQs that brcmfmac drops, or whether SDIO command timeout
  is what kills it.
- Compile a `nexmon_csi` build that does NOT install the `process_frame`
  hook — see if just monitor mode + nexutil -m1 without the CSI extraction
  shim survives sustained sniff.
- Pivot to ESP32-C6 hardware: a dedicated CSI capture board frees the Pi
  from the BCM43455 entirely.

## Bottom line

Production: stays on `alfa` (proven). CSI is for science.
The hardware watchdog turns CSI experiments from "needs power cycle" into
"30-second blip" — safer to keep poking.

