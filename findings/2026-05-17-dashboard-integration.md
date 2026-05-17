# Integrating nexmon CSI capture into a motion detection backend

Date: 2026-05-17

Notes on how I wired the D10 stack into an existing scapy-based RSSI motion
detector so it could use the Pi's built-in WiFi (with nexmon firmware) instead
of an external USB adapter — and how to make the switch user-selectable.

This isn't required to use this repo — the repo's firmware/driver/scripts
stand on their own. But people asking "how do I actually USE this for motion
detection" might find the pattern useful.

## The backend selector

Three modes:

1. **alfa** — sniff a USB adapter (e.g. Alfa AWUS036ACH) in monitor mode.
   Works with stock Pi WiFi (Cypress firmware) intact. Pi keeps its own WiFi
   connection for SSH/whatever.
2. **csi** — sniff the Pi's built-in `wlan0` in monitor mode with this repo's
   nexmon firmware loaded. Pi loses its built-in WiFi (it's in monitor mode,
   can't associate). Need Ethernet for management.
3. **both** — sniff both `wlan0` (nexmon) AND `wlan1` (USB) at once.
   scapy supports `sniff(iface=["wlan0", "wlan1"], ...)`. Each iface gets its
   own channel hopper. Doubles the data into the same detector; the detector
   pools by BSSID so duplicate sightings just give more samples.

## Auto-detect logic

```python
def _detect_csi_available():
    # Check the firmware md5 — stock Cypress vs this repo's nexmon build.
    import hashlib
    with open("/lib/firmware/cypress/cyfmac43455-sdio.bin", "rb") as f:
        md5 = hashlib.md5(f.read()).hexdigest()
    return md5 != "64410bcb1364a794ce4946bc40c7998f"  # stock Cypress md5

def _detect_alfa_available():
    return os.path.exists("/sys/class/net/wlan1")

def resolve_source(requested):
    if requested == "auto":
        if _detect_csi_available() and _detect_alfa_available():
            return "both", ["wlan0", "wlan1"]
        if _detect_csi_available():
            return "csi", ["wlan0"]
        return "alfa", ["wlan1"]
    return requested, {"alfa": ["wlan1"], "csi": ["wlan0"], "both": ["wlan0", "wlan1"]}[requested]
```

## The toggle script

A small CLI to switch modes that survives reboot via a marker file:

```sh
sudo csipi-mode status        # show current
sudo csipi-mode alfa          # USB only (no firmware change)
sudo csipi-mode csi           # nexmon firmware, reboot needed
sudo csipi-mode both          # nexmon + USB, reboot
```

When set to `csi` or `both`, it writes `/etc/csipi-csi-mode-active` and reboots.
A boot-time watchdog checks that marker; if present, it knows wlan0 will be
in monitor mode (no IP) and DOESN'T revert nexmon firmware.

## Watchdog gotcha

If you have an existing "revert nexmon if wlan0 doesn't get an IP" watchdog
(useful for full-WiFi nexmon use), it WILL revert in CSI mode because monitor
mode doesn't get an IP. Either:

- Disable the watchdog when in CSI mode, or
- Have the watchdog check for the marker file before reverting.

The latter is what I did.

## Systemd service prep

Bring up both ifaces in monitor mode IF available:

```systemd
ExecStartPre=-/bin/bash -c '\
    if [ -d /sys/class/net/wlan1 ]; then \
        nmcli dev set wlan1 managed no 2>/dev/null; \
        ip link set wlan1 down 2>/dev/null; \
        iw dev wlan1 set type monitor 2>/dev/null; \
        ip link set wlan1 up; \
        iw dev wlan1 set channel 6 2>/dev/null; \
    fi'

ExecStartPre=-/bin/bash -c '\
    if [ -e /lib/firmware/cypress/cyfmac43455-sdio.bin ]; then \
        md5=$(md5sum /lib/firmware/cypress/cyfmac43455-sdio.bin | cut -d" " -f1); \
        if [ "$md5" != "64410bcb1364a794ce4946bc40c7998f" ]; then \
            nmcli dev set wlan0 managed no 2>/dev/null; \
            ip link set wlan0 down 2>/dev/null; \
            iw dev wlan0 set type monitor 2>/dev/null; \
            ip link set wlan0 up; \
            iw dev wlan0 set channel 6 2>/dev/null; \
            nexutil -Iwlan0 -m1 2>/dev/null; \
        fi; \
    fi'

ExecStart=/usr/local/bin/your-motion-detector.py --source auto
```

The `--source auto` lets the script pick the right mode based on what's actually
present. If you boot with nexmon firmware AND Alfa plugged in → "both". If you
boot with stock Cypress → "alfa". No reconfiguration needed when you swap firmware.

## Showing the mode in your UI

The motion detector writes `/tmp/motion-state.json` (or whatever) with a
`source_mode` field. The dashboard reads it and renders a small badge:

```html
<div class="badge" style="color: {{ palette[source_mode] }}">
  {{ source_mode.upper() }}
</div>
```

Color palette I used: CSI = blue (`#79c0ff`), ALFA = purple (`#d2a8ff`),
BOTH = green (`#56d364`).
