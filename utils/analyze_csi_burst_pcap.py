#!/usr/bin/env python3
"""
analyze_csi_burst_pcap.py — parse a pcap captured by csipi-csi-burst and
extract per-frame metadata (BSSID, SSID, RSSI, frame type) from the nexmon
CSI Ethernet wrapper format.

Background: nexmon D10 firmware (the minimal monitor build) delivers wifi
frames to the host through brcmfmac's normal data path, NOT as canonical
radiotap-format monitor frames. Each pcap entry is presented as a fake
Ethernet frame with a 64-byte nexmon CSI wrapper at the front and the real
802.11 frame starting at offset 64. The wrapper contains per-frame metadata
including RSSI as a signed byte at offset 30.

This script extracts that metadata + the embedded 802.11 frame info so the
captures are usable for motion analysis EVEN WHEN the pcap was captured in
the Ethernet-wrapped form (i.e. when NetworkManager re-asserted managed
mode before tcpdump opened the socket).

Usage:
  python3 analyze_csi_burst_pcap.py <pcap-file>
  python3 analyze_csi_burst_pcap.py --csv <pcap-file>  # per-frame CSV output
  python3 analyze_csi_burst_pcap.py --summary <pcap-file>  # per-BSSID summary
"""
from __future__ import annotations

import argparse
import collections
import csv
import statistics
import sys

try:
    from scapy.all import rdpcap, Dot11
except ImportError:
    print("error: scapy not installed. pip install scapy", file=sys.stderr)
    sys.exit(1)

# Nexmon CSI Ethernet wrapper offsets (validated 2026-05-18 against per-BSSID σ)
WRAPPER_LEN     = 64        # 802.11 frame starts here
RSSI_OFFSET     = 30        # signed byte
# Other offsets (per byte-variation analysis in CSIPI_SESSION_STATE.md):
#   off 22-23  → microsecond timestamp (most-varying bytes)
#   off 24     → counter (~88 unique values per 1000 frames)
#   off 18-19  → frame length probably
# These are not yet decoded; only RSSI is confirmed.


def parse_frame(raw: bytes) -> dict | None:
    """Return per-frame dict or None if too short / unparseable."""
    if len(raw) < WRAPPER_LEN + 24:    # need at least the 802.11 header
        return None
    # RSSI from the wrapper (signed byte)
    rssi_raw = raw[RSSI_OFFSET]
    rssi = rssi_raw if rssi_raw < 128 else rssi_raw - 256
    # Parse the 802.11 frame
    try:
        d = Dot11(raw[WRAPPER_LEN:])
    except Exception:
        return None
    return {
        "rssi": rssi,
        "type": d.type,
        "subtype": d.subtype,
        "addr1": (d.addr1 or "").lower(),
        "addr2": (d.addr2 or "").lower(),
        "addr3": (d.addr3 or "").lower(),  # BSSID for mgmt/data from-ds
        "len":  len(raw),
        "frame": d,
    }


def extract_ssid(dot11_frame) -> str | None:
    """Walk Dot11Elt chain for ID=0 (SSID)."""
    elt = dot11_frame.payload
    while elt and hasattr(elt, "ID"):
        if elt.ID == 0:
            try:
                return bytes(elt.info).decode("utf-8", errors="ignore")
            except Exception:
                return None
        elt = elt.payload
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pcap", help="path to csi-burst-*.pcap")
    ap.add_argument("--csv", action="store_true",
                    help="emit per-frame CSV to stdout")
    ap.add_argument("--summary", action="store_true",
                    help="emit per-BSSID summary table (default)")
    args = ap.parse_args()

    frames = rdpcap(args.pcap)
    print(f"# parsed {len(frames)} frames from {args.pcap}", file=sys.stderr)

    parsed = []
    for f in frames:
        p = parse_frame(bytes(f))
        if p:
            parsed.append({
                **p,
                "ts": float(f.time),
            })

    print(f"# {len(parsed)} valid 802.11 frames extracted", file=sys.stderr)

    if args.csv:
        w = csv.writer(sys.stdout)
        w.writerow(["ts", "rssi", "type", "subtype", "bssid", "ssid", "len"])
        for p in parsed:
            ssid = extract_ssid(p["frame"]) if (p["type"], p["subtype"]) in [(0, 8), (0, 5)] else ""
            bssid = p["addr3"] or p["addr2"]
            w.writerow([p["ts"], p["rssi"], p["type"], p["subtype"],
                        bssid, ssid or "", p["len"]])
        return

    # default: per-BSSID summary
    by_bssid: dict[str, list[dict]] = collections.defaultdict(list)
    ssids: dict[str, str] = {}
    for p in parsed:
        bssid = p["addr3"] or p["addr2"]
        if not bssid or bssid == "ff:ff:ff:ff:ff:ff" or bssid == "00:00:00:00:00:00":
            continue
        by_bssid[bssid].append(p)
        if (p["type"], p["subtype"]) in [(0, 8), (0, 5)]:
            ssid = extract_ssid(p["frame"])
            if ssid and bssid not in ssids:
                ssids[bssid] = ssid

    print(f"\n=== per-BSSID summary ===")
    print(f"{'BSSID':18}  {'SSID':28}  {'frames':>6}  {'rssi min/max/μ/σ':>22}  {'top frame type':<15}")
    rows = sorted(by_bssid.items(), key=lambda kv: -len(kv[1]))
    for bssid, ps in rows[:30]:
        rssis = [p["rssi"] for p in ps]
        types = collections.Counter((p["type"], p["subtype"]) for p in ps)
        top = types.most_common(1)[0]
        top_str = f"t{top[0][0]}s{top[0][1]}×{top[1]}"
        ssid = ssids.get(bssid, "")
        sig = (f"{min(rssis):4d}/{max(rssis):4d}/{statistics.mean(rssis):5.1f}/"
               f"{statistics.stdev(rssis) if len(rssis)>1 else 0:.1f}")
        print(f"{bssid:18}  {ssid[:28]:28}  {len(ps):6d}  {sig:>22}  {top_str:<15}")

    # global stats
    all_rssis = [p["rssi"] for p in parsed]
    if all_rssis:
        print(f"\n=== global RSSI ===")
        print(f"  n={len(all_rssis)}  min={min(all_rssis)}  max={max(all_rssis)}  "
              f"mean={statistics.mean(all_rssis):.1f}  σ={statistics.stdev(all_rssis):.1f}")
    types = collections.Counter((p["type"], p["subtype"]) for p in parsed)
    print(f"\n=== global frame type distribution (top 8) ===")
    type_names = {(0,8):"beacon", (0,5):"probe-resp", (0,4):"probe-req",
                  (1,9):"BAR", (1,11):"RTS", (1,12):"CTS", (1,13):"ACK", (1,8):"block-ack",
                  (2,0):"data", (2,4):"qos-null", (2,8):"qos-data"}
    for k, v in types.most_common(8):
        name = type_names.get(k, f"t{k[0]}s{k[1]}")
        print(f"  {name:14}: {v}")
    duration = parsed[-1]["ts"] - parsed[0]["ts"] if len(parsed) > 1 else 0
    if duration > 0:
        print(f"\n=== rate ===")
        print(f"  duration: {duration:.1f}s   rate: {len(parsed)/duration:.1f} frames/s")


if __name__ == "__main__":
    main()
