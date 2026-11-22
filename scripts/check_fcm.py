#!/usr/bin/env python3
"""Check a kernel .config against the device's framework compatibility matrix (FCM).

Android 12+ verifies the kernel against <system>/etc/vintf/compatibility_matrix.<N>.xml
inside VintfObject.verifyWithoutAvb().  Any mismatch makes Build.isBuildConsistent()
return false and the framework shows the "There's an internal problem with your device"
dialog at boot.  Stock MIUI passes, so our kernel must match the matrix exactly.

Usage:
    python check_fcm.py <config-final.txt> [matrix.xml] [--simulate KEY=n ...]

Without matrix.xml the bundled requirement list (config/fcm-4.19.110-level5.txt)
is used, so the check also works inside CI where the phone is not reachable.
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLED = os.path.join(HERE, "..", "config", "fcm-4.19.110-level5.txt")
KERNEL_VERSION = "4.19.110"


def parse_config(path):
    cfg = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            m = re.match(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$", line)
            if m:
                cfg[m.group(1)] = m.group(2).strip('"')
                continue
            m = re.match(r"^# CONFIG_([A-Za-z0-9_]+) is not set", line)
            if m:
                cfg[m.group(1)] = "n"
    return cfg


def reqs_from_matrix(path, version=KERNEL_VERSION):
    root = ET.parse(path).getroot()
    blocks = [k for k in root.findall("kernel") if k.get("version") == version]
    if not blocks:
        sys.exit(f"matrix {path} has no <kernel version=\"{version}\"> block")
    # The block with the most requirements is the base set; the smaller ones only
    # add entries under <conditions>, which are evaluated by libvintf, not by us.
    blk = max(blocks, key=lambda k: len(k.findall("config")))
    return [(c.find("key").text, c.find("value").text) for c in blk.findall("config")]


def reqs_from_bundle(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            key, val = line.split("=", 1)
            out.append((key.strip(), val.strip()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("matrix", nargs="?")
    ap.add_argument("--simulate", action="append", default=[],
                    metavar="KEY=VALUE", help="override a config value before checking")
    args = ap.parse_args()

    cfg = parse_config(args.config)
    reqs = reqs_from_matrix(args.matrix) if args.matrix else reqs_from_bundle(BUNDLED)
    for item in args.simulate:
        key, val = item.split("=", 1)
        cfg[key.replace("CONFIG_", "", 1)] = val

    print(f"  FCM 要求项: {len(reqs)} 项 (kernel {KERNEL_VERSION}, level 5)")
    bad = []
    for key, want in reqs:
        have = cfg.get(key.replace("CONFIG_", "", 1), "n")
        if have != want:
            bad.append((key, want, have))

    if bad:
        print(f"  不满足: {len(bad)} 项")
        for key, want, have in bad:
            print(f"    {key:<40} 要求={want:<28} 实际={have}")
        print("  FAIL: 内核配置与设备框架兼容矩阵不一致，开机将弹出 "
              "\"internal problem with your device\" 对话框")
        return 1

    print("  OK: 全部满足，VintfObject.verifyWithoutAvb() 应返回 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
