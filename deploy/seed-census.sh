#!/bin/bash
#
# seed-census -- append a point-in-time census of the reachable BLAKE2b network
# to a JSON-lines file, so an adoption curve exists later.
#
# This exists because a software-upgrade curve cannot be reconstructed after the
# fact: if you start measuring on release day you have nothing to compare to.
#
# Strictly read-only with respect to the seeder. It parses dnsseed.dump, which
# the daemon rewrites on its own schedule (every 3200s once warmed up), and
# writes only to its own output file.
#
# Deliberate limitation, stated here because every number this produces inherits
# it: a crawler only sees nodes that ACCEPT incoming connections. Nodes behind
# NAT that never listen are invisible. This measures the REACHABLE network, not
# the whole network, and is a lower bound.

set -uo pipefail

DUMP="${DUMP:-/var/lib/dnsseed/dnsseed.dump}"
OUT="${OUT:-/var/lib/dnsseed/census.jsonl}"

[ -f "$DUMP" ] || { echo "no dump at $DUMP" >&2; exit 1; }

# mawk has no strtonum()/and(), so service bit 28 is tested by position: svcs is
# always 8 hex digits, so bit 28 is the low bit of the first character.
awk -v ts="$(date +%s)" -v dumpts="$(stat -c %Y "$DUMP")" '
function isb2b(s,   n) {
    n = substr(s, 1, 1)
    return (n=="1"||n=="3"||n=="5"||n=="7"||n=="9"||n=="b"||n=="d"||n=="f"||n=="B"||n=="D"||n=="F")
}
NR > 1 {
    total++
    if ($2 == 1) reachable++
    if (isb2b($10)) {
        b2b++
        # Poll recency for ALL known fork nodes, not just currently-good ones:
        # a node that decayed out of "good" is exactly what we want to measure.
        # 4980s = 83min is the point at which stat2H.count (tau=2h) falls below
        # the IsGood() threshold of 2, i.e. where a reachable node silently
        # stops being served. $3 == 0 means never succeeded, not age zero, so
        # it is excluded. Age is measured against ts (script run time), not the
        # dump mtime.
        if ($3 + 0 > 0) {
            age = ts - ($3 + 0)
            pa[n_pa++] = age
            if (age < 4980) recent++
        }
        if ($2 == 1) {
            b2b_up++
            ua = ""
            for (i = 12; i <= NF; i++) ua = ua (i > 12 ? " " : "") $i
            gsub(/"/, "", ua)
            ver[ua]++
            if ($9 + 0 > maxh) maxh = $9 + 0
            # hua[] is indexed by the SAME counter as h[], so height and
            # user-agent stay aligned by construction rather than by a second
            # counter that could drift. It is written AFTER the increment,
            # using n_h - 1: on the first record n_h is still uninitialised,
            # and an uninitialised awk variable used as a subscript is the
            # empty string, not 0. h[n_h++] escapes that because ++ forces
            # numeric context; hua[n_h] would not have.
            h[n_h++] = $9 + 0
            hua[n_h - 1] = ua
        }
    }
}
END {
    # Height spread among reachable fork nodes. Note this is each node height as
    # of its LAST HANDSHAKE, not right now, so lag here is partly crawl recency.
    #
    # The per-UA counters below use the identical bucket boundaries and the same
    # maxh reference over the identical population (reachable fork nodes only),
    # so INVARIANT: for each bucket, the sum of heights_by_version[*][bucket]
    # over all user agents equals the aggregate h_<bucket> for that sample.
    for (i = 0; i < n_h; i++) {
        d = maxh - h[i]
        u = hua[i]
        if (d == 0) { tip++; hv_tip[u]++ }
        else if (d <= 6) { near++; hv_near[u]++ }
        else if (d <= 144) { day++; hv_day[u]++ }
        else { behind++; hv_behind[u]++ }
    }
    # Ascending insertion sort over pa[0 .. n_pa-1]; mawk has no asort().
    for (i = 1; i < n_pa; i++) {
        key = pa[i]
        j = i - 1
        while (j >= 0 && pa[j] > key) {
            pa[j + 1] = pa[j]
            j--
        }
        pa[j + 1] = key
    }
    pa_med = 0
    pa_p90 = 0
    pa_max = 0
    if (n_pa > 0) {
        pa_max = pa[n_pa - 1]
        if (n_pa % 2 == 1) pa_med = pa[int((n_pa - 1) / 2)]
        else pa_med = int((pa[int(n_pa / 2) - 1] + pa[int(n_pa / 2)]) / 2)
        pi = int(0.9 * n_pa)
        if (pi >= n_pa) pi = n_pa - 1
        pa_p90 = pa[pi]
    }
    printf "{\"ts\":%d,\"dump_ts\":%d,\"total\":%d,\"reachable\":%d,", ts, dumpts, total+0, reachable+0
    printf "\"b2b\":%d,\"b2b_reachable\":%d,\"max_height\":%d,", b2b+0, b2b_up+0, maxh+0
    printf "\"b2b_poll_age_median\":%d,\"b2b_poll_age_p90\":%d,\"b2b_poll_age_max\":%d,\"b2b_polled_recently\":%d,", pa_med+0, pa_p90+0, pa_max+0, recent+0
    printf "\"h_tip\":%d,\"h_near\":%d,\"h_day\":%d,\"h_behind\":%d,\"versions\":{", tip+0, near+0, day+0, behind+0
    first = 1
    for (v in ver) {
        if (!first) printf ","
        printf "\"%s\":%d", v, ver[v]
        first = 0
    }
    # Iterate ver[] again (not the bucket arrays) so every reachable fork-node
    # user agent appears exactly once, with explicit zeros for empty buckets.
    # Fresh flag and loop variable: reusing first/v here would emit a stray
    # leading comma under mawk.
    printf "},\"heights_by_version\":{"
    hbv_first = 1
    for (vk in ver) {
        if (!hbv_first) printf ","
        printf "\"%s\":{\"tip\":%d,\"near\":%d,\"day\":%d,\"behind\":%d}", vk, hv_tip[vk]+0, hv_near[vk]+0, hv_day[vk]+0, hv_behind[vk]+0
        hbv_first = 0
    }
    printf "}}\n"
}' "$DUMP" >> "$OUT"

tail -1 "$OUT"
