# Examples

## `parse_monitor_capture.py`

Reads a pcap captured from this stack and lists the 802.11 frames inside.

```bash
sudo apt install python3-scapy
sudo /usr/local/bin/load-csi-stack 6 NOHT       # channel 6, 20 MHz
sudo tcpdump -i wlan0 -c 200 -w cap.pcap
python3 parse_monitor_capture.py cap.pcap
```

Expected output: counts of frames, list of beacons seen with BSSID + SSID + TSF.

This is a small example for sanity-checking the capture pipeline. It does not
extract CSI subcarriers (those are not in the canonical UDP/5500 format with
this firmware build — see the README's "Known limitations" section).
