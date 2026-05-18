# Shipped solution — burst-only CSI on BCM43455 + Pi 4 + kernel 6.12

Date: 2026-05-18
Author: Peter Koczan
Status: SHIPPED. This is the practical answer after a full session of attempted fixes.

## Why this is the answer

Sustained monitor-mode capture on the BCM43455 with nexmon-patched firmware
crashes the Pi 4 kernel within 60-90 s. This has been verified on D10
(minimal CSI build) under kernel 6.12.75+rpt-rpi-v8, and the crash is
**not fixable from userspace**. We tried, separately:

| attempt | result |
|---|---|
| scapy → libpcap+BPF (use TPACKET ring buffer) | crash @ ~60 s |
| Channel hopping disabled (--hop-interval 0) | crash @ ~60 s |
| brcmfmac roamoff=1 + (fcmode=0 + txglomsz=4 not honored by our .ko.xz) | crash @ ~60 s |
| kernel rmem_max raised to 16 MB (80× default) | crash @ ~60 s |
| NetworkManager configured to ignore wlan0+wlan1 (eliminates 14 s pre-disturbance) | crash @ ~60 s |
| wifi power save off (`iw set power_save off`) | crash @ ~60 s |
| All of the above combined in one boot | crash @ ~60 s |

Across multiple tests on two days (2026-05-17 + 2026-05-18), the crash
window is consistently 60-90 s from the moment `wlan0` enters promiscuous
mode. With persistent journald properly engaged on the second day, we
confirmed the crash is **silent** — no `brcmf_sdio` timeout, no `trap` from
the chip, no `dmesg` warning. The kernel just stops scheduling. Symptom
matches openwrt/openwrt#23069 (BCM43455 brcmfmac stuck state).

The remaining un-tested paths to actually fix this are:

- **Recompile nexmon without the CSI patches** (monitor-mode-only build) —
  hours of work on a separate build environment. Would prove whether the
  CSI patches OR monitor mode itself is the trigger.
- **ESP32-C6 hardware pivot** — days of work, new hardware, but sidesteps
  the BCM43455 entirely. Recommended long-term path per the established
  literature.

Both are deferred.

## What ships now

CSI is treated as a **burst-only capability** for short data harvesting,
not as a continuous motion-detection source. The architecture:

```
  Production motion detection: Alfa AWUS036ACH on wlan1 (ath9k_htc).
                               Proven stable for months.

  CSI experimentation: sudo csipi-csi-burst <seconds>
                       Captures up to 75 s into a pcap, then auto-reverts
                       firmware to stock + reboots. Pi outage ~2 min total
                       for a 60 s capture.

  Offline pcap analysis: utils/analyze_csi_burst_pcap.py
                         Extracts per-frame RSSI from the nexmon CSI
                         Ethernet wrapper at byte offset 30 + the
                         embedded 802.11 frame info (BSSID, SSID, type).
```

## Why the burst pcaps are still useful for motion analysis

Even though sustained capture crashes the kernel, **the captures we DO get
are full-quality**. Validated 2026-05-18:

- Per-frame RSSI is in the nexmon CSI wrapper at byte offset 30 (signed byte)
- Per-BSSID σ matches reality: stable cameras (REOLINK, ARLO) report σ=0.9-1.8,
  mobile devices (laptops, phones moving) σ=10-15
- All 802.11 frame metadata (BSSID, SSID, type, length) is preserved
- Frame rate observed: ~80 pps on busy 2.4 GHz channels, ~50 pps quieter

So a 60-second CSI burst gives ~5000 timestamped + RSSI-annotated frames —
plenty for short-window motion classification, RSSI σ analysis, and BSSID
inventory updates. It's just not a continuous-feed source.

## How to use the shipped pipeline

```sh
# 1. Capture a 60 s CSI burst (Pi outage ~2 min total — two reboots)
sudo /usr/local/bin/csipi-csi-burst 60

# 2. After Pi is back on alfa, copy the pcap to wherever you want
scp pkoczan@csipi:/var/log/csipi-csi-bursts/csi-burst-*.pcap ~/

# 3. Analyze offline
python3 utils/analyze_csi_burst_pcap.py csi-burst-*.pcap          # summary
python3 utils/analyze_csi_burst_pcap.py --csv csi-burst-*.pcap    # per-frame CSV
```

## Auto-resolver behaviour

The `motion-detector --source auto` resolver now always picks alfa when
alfa is available (which is the production setup). It never auto-picks CSI
even if nexmon firmware is staged. To use CSI you MUST explicitly opt in
via `csipi-mode csi` (which reboots into nexmon and stays there until you
revert) or via `csipi-csi-burst` (bounded burst with auto-revert).

This guarantees nothing on the Pi ever silently tries to run continuous
CSI and crashes the kernel.

## Reference: what's deployed on the Pi

```
/usr/local/bin/motion-detector-v2.py         (auto-resolver locked to alfa)
/usr/local/bin/csipi-csi-burst               (bounded CSI capture + auto-revert)
/usr/local/bin/csipi-mode                    (manual mode switch)
/usr/local/bin/csipi-nexmon-watchdog         (boot-time, heartbeat-based)
/usr/local/bin/csipi-irq-logger              (SDIO IRQ logger every minute)
/usr/local/bin/csipi-calibration-overnight.py (GT label scheduler, optional)
/etc/systemd/system/motion-detector.service  (includes --hop-interval 0,
                                              power_save off, nmcli unmanage)
/etc/systemd/system.conf.d/csipi-hardware-watchdog.conf
                                              (BCM2835 hw watchdog 15 s)
/etc/systemd/journald.conf.d/persistent.conf (Storage=persistent)
/etc/sysctl.d/90-csipi-bigger-buffers.conf   (kernel socket buffer 16 MB)
/etc/NetworkManager/conf.d/csipi-unmanaged-wlan0.conf
                                              (NM ignores wlan0+wlan1)
/etc/modprobe.d/brcmfmac.conf                (fcmode=0 txglomsz=4 roamoff=1)
/etc/cron.d/csipi-irq-logger                 (per-minute SDIO IRQ snapshot)
/var/log/csipi-csi-bursts/                   (pcap output directory)
/var/log/csipi-irq-log.csv                   (long-running SDIO IRQ log)
```

The obsolete `nexmon-watchdog.service` (90-second `wlan0 has no IP` check)
has been DISABLED — without it, the Pi enters a reboot loop because we now
tell NetworkManager to ignore wlan0 (so wlan0 never gets an IP).

The `csipi-nexmon-watchdog.service` (heartbeat-based, marker-aware) remains
enabled and is the correct boot-time safety net.
