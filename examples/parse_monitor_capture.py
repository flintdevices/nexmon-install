#!/usr/bin/env python3
"""
Parse a pcap captured from this nexmon CSI stack and list 802.11 frames inside.

Each EN10MB-framed packet from the modified brcmfmac driver contains:
  - 14-byte Ethernet header (src/dst are nexmon-synthetic, ethertype is junk)
  - 50-byte nexmon d11rxhdr (with size patches active, this is the doubled size)
  - the raw 802.11 frame starting at offset 64 (eth 14 + rxhdr 50)

Usage:
    python3 parse_monitor_capture.py capture.pcap
"""

import struct
import sys
import collections

try:
    from scapy.all import rdpcap, Dot11, Dot11Elt
except ImportError:
    print("Need scapy: pip install scapy", file=sys.stderr)
    sys.exit(1)


NEXMON_RXHDR_LEN = 50
ETH_HDR_LEN = 14
DOT11_OFFSET = ETH_HDR_LEN + NEXMON_RXHDR_LEN  # 50


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    pkts = rdpcap(sys.argv[1])
    total = len(pkts)
    print(f"Loaded {total} frames from {sys.argv[1]}")

    nexmon_frames = 0
    csi_markers = 0
    beacons = collections.Counter()
    other_dot11 = collections.Counter()

    for p in pkts:
        raw = bytes(p)
        if len(raw) < DOT11_OFFSET + 2:
            continue

        eth_dst = raw[:6]
        eth_src = raw[6:12]
        rxhdr = raw[ETH_HDR_LEN:DOT11_OFFSET]
        dot11_bytes = raw[DOT11_OFFSET:]

        # Filter to frames that look like they came from our nexmon stack
        # (synthetic MACs start with 00:00)
        if eth_src[:2] != b"\x00\x00":
            continue
        nexmon_frames += 1

        # Optional: detect CSI markers via the last 2 bytes of rxhdr
        # (RxFrameSize field, =2 means CSI marker in nexmon_csi)
        if rxhdr[-2:] == b"\x02\x00":
            csi_markers += 1

        # Parse 802.11 frame
        if len(dot11_bytes) < 2:
            continue
        try:
            d = Dot11(dot11_bytes)
        except Exception:
            continue

        if d.type == 0 and d.subtype == 8:  # Beacon
            ssid = "?"
            # Walk IEs to find SSID (element ID 0)
            try:
                ie = d.payload
                while ie:
                    if hasattr(ie, "ID") and ie.ID == 0:
                        ssid = bytes(ie.info).decode("ascii", errors="replace") or "<hidden>"
                        break
                    ie = ie.payload
            except Exception:
                pass
            bssid = d.addr3 or "??"
            beacons[(bssid, ssid)] += 1
        elif d.type == 0:
            other_dot11[("mgmt", d.subtype)] += 1
        elif d.type == 1:
            other_dot11[("ctrl", d.subtype)] += 1
        elif d.type == 2:
            other_dot11[("data", d.subtype)] += 1

    print(f"Frames with nexmon source MAC:   {nexmon_frames} / {total}")
    print(f"CSI marker frames (RxFrameSize=2): {csi_markers}")
    print()

    if beacons:
        print("BEACONS observed (by BSSID, ssid, count):")
        for (bssid, ssid), n in sorted(beacons.items(), key=lambda x: -x[1])[:20]:
            print(f"  {bssid}  ssid={ssid!r:30}  count={n}")
        print()

    if other_dot11:
        print("Other 802.11 frame types:")
        for (kind, st), n in sorted(other_dot11.items(), key=lambda x: -x[1])[:10]:
            print(f"  type={kind:5} subtype={st:2}  count={n}")


if __name__ == "__main__":
    main()
