"""
Regenerates tools/smoke/api_members.json, the compact member index the smoke
harness uses to tell properties, events and methods apart and to reject
writes Roblox would reject (unknown member, read-only property, wrong
security level).

Input is the public Roblox API dump (Full-API-Dump.json or API-Dump.json from
MaximumADHD/Roblox-Client-Tracker). Usage:

    python3 tools/smoke/gen_api.py path/to/API-Dump.json

Output format (kept small on purpose):
    { "version": <dump version>,
      "classes": { Name: { "s": Superclass, "f": class flags,
                           "p": { Prop: [ValueType, Category, flags] },
                           "e": [events], "m": [methods], "c": [callbacks] } } }
Property flags: 1 read-only, 2 not scriptable, 4 deprecated, 8 write needs
elevated security, 16 read needs elevated security.
Class flags: 1 not creatable, 2 service, 4 deprecated.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

CATEGORY = {"Primitive": "P", "DataType": "D", "Enum": "E", "Class": "C", "Group": "G"}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    api = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    out: dict[str, dict] = {}
    for c in api["Classes"]:
        tags = set(c.get("Tags") or [])
        cflags = (1 if "NotCreatable" in tags else 0) | (2 if "Service" in tags else 0) | (4 if "Deprecated" in tags else 0)
        props: dict[str, list] = {}
        events: list[str] = []
        methods: list[str] = []
        callbacks: list[str] = []
        for m in c["Members"]:
            mt = m["MemberType"]
            mtags = set(m.get("Tags") or [])
            sec = m.get("Security") or {}
            if mt == "Property":
                if isinstance(sec, str):
                    read_sec = write_sec = sec
                else:
                    read_sec = sec.get("Read", "None")
                    write_sec = sec.get("Write", "None")
                flags = 0
                if "ReadOnly" in mtags:
                    flags |= 1
                if "NotScriptable" in mtags:
                    flags |= 2
                if "Deprecated" in mtags:
                    flags |= 4
                if write_sec not in ("None",):
                    flags |= 8
                if read_sec not in ("None",):
                    flags |= 16
                vt = m["ValueType"]
                props[m["Name"]] = [vt["Name"], CATEGORY.get(vt["Category"], "?"), flags]
            elif mt == "Event":
                events.append(m["Name"])
            elif mt == "Function":
                methods.append(m["Name"])
            elif mt == "Callback":
                callbacks.append(m["Name"])
        entry: dict = {"s": c["Superclass"]}
        if cflags:
            entry["f"] = cflags
        if props:
            entry["p"] = props
        if events:
            entry["e"] = events
        if methods:
            entry["m"] = methods
        if callbacks:
            entry["c"] = callbacks
        out[c["Name"]] = entry
    dest = Path(__file__).with_name("api_members.json")
    dest.write_text(json.dumps({"version": api.get("Version"), "classes": out}, separators=(",", ":"), sort_keys=True), encoding="utf-8")
    print(f"wrote {dest} ({dest.stat().st_size // 1024} KiB, {len(out)} classes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
