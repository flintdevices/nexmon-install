# Dual-iface (`source=both`) scapy sniff hangs the kernel — D10 firmware

Date: 2026-05-17
Author: Peter Koczan

## Symptom

With nexmon CSI firmware (D10 minimal, md5 `dcf871872d0a215e8e0dfe8de931637a`)
loaded on wlan0 AND Alfa AWUS036ACH on wlan1, both in monitor mode, running
`scapy.sniff(iface=["wlan0", "wlan1"])` for 1-2 minutes hangs the kernel hard:

- SSH stops responding on both eth0 and wlan0
- ICMP no longer answers
- Pi requires physical power cycle to recover
- Hangs are NOT caught by the boot-time watchdog (it never gets a chance to
  run on the next boot if the boot-time firmware load itself crashes)

## What we tried (all reproducible)

1. Single sniff thread on wlan0 only (`--source csi`): not yet stable-tested
2. Single sniff thread on wlan1 only (`--source alfa`): proven stable over months
3. Two sniff threads (`--source both`): **crashes within ~60s** of sustained
   traffic, regardless of channel-hopping setting

## Hypothesis

The Pi 4's BCM43455 chip + SDIO bus + USB controller share interrupt lines.
Running scapy on both ifaces simultaneously appears to starve one or the other,
and once the BCM43455 firmware misses an SDIO IRQ deadline (D10 trims a lot of
the original watchdog code), the SDIO bus locks up. The brcmfmac driver's error
handling sits in a tight retry loop and starves the rest of the kernel.

## Mitigation deployed today

1. `motion-detector-v2.py` auto-resolver no longer defaults to `both`. The order is
   `csi > alfa > both`. `both` requires explicit `--source both`.
2. A new marker `/etc/csipi-csi-unstable` is touched by `csipi-nexmon-watchdog`
   on every revert. The auto-resolver checks its mtime and falls back to alfa
   for 30 min after any CSI crash.
3. `csipi-mode csi|both` clears the unstable marker — explicit user opt-in
   overrides the cooldown.
4. `csipi-mode status` surfaces the unstable marker so the operator sees the
   state without having to guess.

## Open questions

- Is `csi` alone (wlan0-only scapy) stable under sustained sniff? Not yet
  tested (the dual-iface crash kept stealing our test window).
- Would lowering the channel-hop interval on wlan0 help? Maybe — fewer
  channel changes = less SDIO chatter.
- Would dropping scapy in favour of nl80211 + a tight C reader on wlan0 (skip
  the kernel netlink path entirely) avoid the SDIO IRQ storm?

## Bottom line

`--source both` is documented as **experimental** in the CLI help.
Default stays on `csi` when firmware is staged AND not in cooldown, else `alfa`.

