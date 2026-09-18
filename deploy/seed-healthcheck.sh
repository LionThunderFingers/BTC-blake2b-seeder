#!/usr/bin/env bash
#
# seed-healthcheck -- dead-man's switch for the BLAKE2b DNS seeder.
#
# Run on a timer. Checks that the seeder is genuinely working, then pings
# healthchecks.io. If this host dies, the network is cut, or the service
# breaks, the pings stop and healthchecks.io raises the alarm on its own.
# The ALARM IS THE SILENCE -- that is the whole point, and it is why this
# survives the failure it is watching for, unlike a monitor that has to be
# alive to send you mail.
#
# On a detected fault it pings the /fail endpoint so you are told immediately
# instead of waiting for the grace period to expire.
#
# Deliberately read-only: it never restarts or repairs anything. A monitor
# that fixes things hides the fault it is supposed to report.

set -uo pipefail

PING_URL="${PING_URL:-}"
SERVICE="dnsseed"
DUMP="/var/lib/dnsseed/dnsseed.dump"
SEED_HOST="${SEED_HOST:-seed.thelionpool.org}"

# Max age of dnsseed.dump before we call it stale. The daemon rewrites it
# every few minutes; 30 minutes without a write means it has stopped working
# even if the process is technically still alive.
MAX_DUMP_AGE=1800

[ -n "$PING_URL" ] || { echo "PING_URL not set" >&2; exit 1; }

problems=()
details=()

# --- 1. is the unit running at all? ---
if ! systemctl is-active --quiet "$SERVICE"; then
    problems+=("service '$SERVICE' is not active (state: $(systemctl is-active "$SERVICE" 2>&1))")
else
    details+=("service: active since $(systemctl show "$SERVICE" -p ActiveEnterTimestamp --value)")
fi

# --- 2. is it still writing its database? ---
if [ ! -f "$DUMP" ]; then
    problems+=("$DUMP does not exist")
else
    now="$(date +%s)"
    mtime="$(stat -c %Y "$DUMP" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if [ "$age" -gt "$MAX_DUMP_AGE" ]; then
        problems+=("$DUMP is stale: last written ${age}s ago (limit ${MAX_DUMP_AGE}s)")
    fi
    details+=("dump age: ${age}s")
fi

# --- 3. peer counts, straight from the dump ---
# mawk on Debian has no strtonum()/and(), so test service bit 28 by its
# position: svcs is exactly 8 hex digits, so bit 28 is the low bit of the
# first character.
if [ -f "$DUMP" ]; then
    counts="$(awk 'NR>1{
        tot++
        n=substr($10,1,1)
        if (n=="1"||n=="3"||n=="5"||n=="7"||n=="9"||n=="b"||n=="d"||n=="f"||n=="B"||n=="D"||n=="F") {
            B++
            if ($2==1) Bg++
        }
    } END{ printf "%d %d %d", tot+0, B+0, Bg+0 }' "$DUMP" 2>/dev/null)"
    read -r total_known blake2b blake2b_good <<< "${counts:-0 0 0}"
    details+=("nodes: ${total_known} known, ${blake2b} BLAKE2b, ${blake2b_good} BLAKE2b reachable")

    # A seed that knows of no reachable fork nodes is useless even if every
    # process is healthy, so treat it as a fault in its own right.
    if [ "${blake2b_good:-0}" -eq 0 ]; then
        problems+=("no reachable BLAKE2b nodes in the database")
    fi
fi

# --- 4. does it actually answer a query? ---
# Ask the address the daemon really binds rather than assuming localhost:
# it binds one specific public address, so 127.0.0.1 would not respond.
bind_addr="$(systemctl cat "$SERVICE" 2>/dev/null \
    | sed -n 's/.*ExecStart=.* -a "\([^"]*\)".*/\1/p' | head -1)"
bind_addr="${bind_addr:-127.0.0.1}"

answers="$(dig "@${bind_addr}" "$SEED_HOST" +short +time=5 +tries=2 2>/dev/null \
    | grep -c '^[0-9a-fA-F:.]*$')"
answers="${answers:-0}"
details+=("dns: ${answers} records for ${SEED_HOST} via ${bind_addr}")

if [ "$answers" -eq 0 ]; then
    problems+=("DNS query to ${bind_addr} returned no records")
fi

# --- report ---
body="$(printf '%s\n' "${details[@]}")"

if [ "${#problems[@]}" -gt 0 ]; then
    body="FAULTS:
$(printf '  - %s\n' "${problems[@]}")

STATUS:
${body}"
    curl -fsS -m 15 --data-raw "$body" "${PING_URL}/fail" >/dev/null 2>&1
    echo "$body" >&2
    exit 1
fi

curl -fsS -m 15 --data-raw "$body" "$PING_URL" >/dev/null 2>&1
exit 0
