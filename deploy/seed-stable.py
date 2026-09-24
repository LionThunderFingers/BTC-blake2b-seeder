#!/usr/bin/env python3
"""
Emit stable-nodes.json: fork nodes this crawler has found consistently reachable.

Intended for people running a FIXED-LIST seed. A curated list is Sybil-resistant
because a human chooses it, but nobody currently gives that human evidence about
which nodes are actually reliable. This supplies the evidence; it is deliberately
NOT a list to serve unexamined.

On the uptime windows: the seeder keeps exponentially-weighted reliability figures
over 2h/8h/1d/7d/30d. They start at zero and fill as the crawler runs, so a 30-day
figure is meaningless until the crawler has been up for roughly that long. The
qualifying rule below therefore keys off the longest window the crawler has
actually been running for, and tightens on its own over time.
"""
import json, os, sys, time

DUMP = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/dnsseed/dnsseed.dump"
START = int(sys.argv[2]) if len(sys.argv) > 2 else 0   # crawler start, unix seconds

B2B_NIBBLES = set("13579bdfBDF")          # bit 28 set -> low bit of the first hex digit
# A window needs runtime well beyond its own length before its figure is worth
# trusting: these are exponentially-weighted averages that start at zero, so at
# exactly one window length they are still filling and read far too low. Requiring
# 3x the window length before using it avoids rejecting perfectly good nodes purely
# because the crawler is young.
CONVERGENCE_FACTOR = 3
WINDOWS = [                                # (label, column index, window length in seconds)
    ("30d", 7, 30 * 86400),
    ("7d",  6, 7 * 86400),
    ("1d",  5, 86400),
    ("8h",  4, 8 * 3600),
    ("2h",  3, 0),
]
WINDOWS = [(lbl, col, length * CONVERGENCE_FACTOR) for lbl, col, length in WINDOWS]
THRESHOLD = 90.0                           # percent reliability required in that window

age = max(0, int(time.time()) - START) if START else 0
window_label, window_col, _ = next(w for w in WINDOWS if age >= w[2])

nodes = []
try:
    with open(DUMP) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.split()
            if len(f) < 11:
                continue
            svcs = f[9]
            if not svcs or svcs[0] not in B2B_NIBBLES:
                continue
            if f[1] != "1":                 # not currently reachable
                continue
            try:
                pct = [float(f[i].rstrip("%")) for i in range(3, 8)]
                height = int(f[8])
            except ValueError:
                continue
            # Deliberately NOT recording the per-node software version here.
            # The addresses are already public (the seed hands them out), and the
            # version mix is published in aggregate on the census page. But pairing
            # a specific address to a specific version on a ~70 node network is an
            # inventory of who is running what, and becomes a target list the moment
            # some version has a known bug. The aggregate answers the useful
            # question; the mapping only adds risk.
            nodes.append({
                "address": f[0],
                "uptime": {"2h": pct[0], "8h": pct[1], "1d": pct[2], "7d": pct[3], "30d": pct[4]},
                "height": height,
                "services": svcs,
                "qualifies": pct[window_col - 3] >= THRESHOLD,
            })
except FileNotFoundError:
    print(json.dumps({"error": "dump not found"}), file=sys.stderr)
    sys.exit(1)

nodes.sort(key=lambda n: (-n["uptime"][window_label], n["address"]))
qualifying = [n for n in nodes if n["qualifies"]]

print(json.dumps({
    "generated": int(time.time()),
    "crawler_started": START,
    "crawler_age_days": round(age / 86400, 2),
    "criterion": {
        "window": window_label,
        "threshold_pct": THRESHOLD,
        "explanation": (
            f"Reachable fork nodes with at least {THRESHOLD:.0f}% reliability over the "
            f"{window_label} window. That window is the longest this crawler has been "
            f"running for, so the list gets stronger the longer it runs."
        ),
    },
    "qualifying_count": len(qualifying),
    "observed_count": len(nodes),
    "nodes": qualifying,
    "all_reachable": nodes,
}, indent=1))
