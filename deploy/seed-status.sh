#!/usr/bin/env bash
#
# seed-status.sh — read-only status report for the BLAKE2b Bitcoin DNS seeder.
#
# SAFETY: this script is strictly READ-ONLY. It reads files, queries systemd,
# and sends DNS queries to the local seeder. It never writes, moves or deletes
# anything, never restarts a service and never changes configuration.
#
# Portability: written for Debian's default awk (mawk). No strtonum(), and(),
# gensub(), asort() or length(array) — do not "improve" it with gawk-isms.
#
# Note on DNS: the seeder binds one specific public address, so a query to
# 127.0.0.1 may return nothing even when the daemon is perfectly healthy.
# Section E therefore falls back to the bind address parsed out of the unit's
# ExecStart line (`systemctl cat`) rather than a hardcoded IP.
#
# Exit code: 0 if the unit is active AND the dump file is fresher than 30
#            minutes; 1 otherwise. Missing optional data does not fail the run.
#
# Overridable via environment:
UNIT="${UNIT:-dnsseed.service}"
DUMP="${DUMP:-/var/lib/dnsseed/dnsseed.dump}"
STATS="${STATS:-/var/lib/dnsseed/dnsstats.log}"
SEED_HOST="${SEED_HOST:-seed.thelionpool.org}"

set -uo pipefail   # deliberately NOT -e: a status tool must finish the report

STALE_SECS=1800
status_fail=0

# ---------------------------------------------------------------- colour ----
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
fi

# --------------------------------------------------------------- helpers ----
_hdr_gap=""   # blank line between sections, but not before the first one
hdr() {
    printf '%s%s%s== %s ==%s\n' "$_hdr_gap" "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
    _hdr_gap=$'\n'
}
kv()  { printf '  %-26s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

# file exists, is a regular file, is readable and is non-empty
file_ready() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }

# human_age <seconds> -> "45s" / "12m" / "3h 05m" / "2d 4h"
human_age() {
    local s="${1:-}"
    case "$s" in ''|*[!0-9]*) printf 'unknown'; return;; esac
    if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ];  then printf '%dm' "$((s / 60))"
    elif [ "$s" -lt 86400 ]; then printf '%dh %02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
    else                          printf '%dd %dh' "$((s / 86400))" "$(((s % 86400) / 3600))"
    fi
}

now="$(date +%s 2>/dev/null)"
case "$now" in ''|*[!0-9]*) now=0;; esac

printf '%s%sBLAKE2b DNS seeder status%s  %s%s%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)" "$C_RESET"

# ======================================================= A. SERVICE =========
hdr "A. SERVICE"
if ! have systemctl; then
    printf '  %ssystemctl not available — cannot inspect the unit%s\n' "$C_YELLOW" "$C_RESET"
    status_fail=1
else
    sd_out="$(systemctl show "$UNIT" \
                -p ActiveState -p SubState -p UnitFileState -p MainPID \
                -p MemoryCurrent -p NRestarts -p ActiveEnterTimestamp 2>/dev/null)"
    if [ -z "$sd_out" ]; then
        printf '  %scould not query %s via systemctl%s\n' "$C_YELLOW" "$UNIT" "$C_RESET"
        status_fail=1
    else
        act=""; sub=""; ufs=""; pid=""; mem=""; nrest=""; aets=""
        while IFS='=' read -r k v; do
            case "$k" in
                ActiveState)          act="$v" ;;
                SubState)             sub="$v" ;;
                UnitFileState)        ufs="$v" ;;
                MainPID)              pid="$v" ;;
                MemoryCurrent)        mem="$v" ;;
                NRestarts)            nrest="$v" ;;
                ActiveEnterTimestamp) aets="$v" ;;
            esac
        done <<< "$sd_out"

        if [ "$act" != "active" ]; then
            printf '  %s%s!! UNIT %s IS NOT ACTIVE (state: %s/%s) !!%s\n' \
                "$C_BOLD" "$C_RED" "$UNIT" "${act:-unknown}" "${sub:-unknown}" "$C_RESET"
            status_fail=1
            kv "state" "${act:-unknown} (${sub:-unknown}) — PID ${pid:-n/a}"
        else
            kv "state" "${C_GREEN}${act} (${sub:-running})${C_RESET} — PID ${pid:-n/a}"
        fi

        # uptime / since
        up_str="unknown"
        if [ -n "$aets" ]; then
            aet_epoch="$(date -d "$aets" +%s 2>/dev/null)"
            case "$aet_epoch" in
                ''|*[!0-9]*) up_str="since $aets" ;;
                *)  age=$(( now - aet_epoch ))
                    [ "$age" -lt 0 ] && age=0
                    up_str="$(human_age "$age") (since $aets)" ;;
            esac
        fi
        kv "active for" "$up_str"

        # memory: sentinel / [not set] / non-numeric all mean "not accounted"
        mem_str="n/a"
        case "$mem" in
            18446744073709551615|'[not set]'|''|*[!0-9]*) mem_str="n/a" ;;
            *) mem_str="$(awk -v b="$mem" 'BEGIN { printf "%.1f MiB", b / 1048576 }')" ;;
        esac
        rest_str="n/a"
        case "$nrest" in
            ''|*[!0-9]*) rest_str="n/a" ;;
            *)           rest_str="$nrest" ;;
        esac
        kv "memory / restarts" "$mem_str / $rest_str"
        kv "enabled at boot" "${ufs:-n/a}"
    fi
fi

# ========================================================= B. PEERS =========
hdr "B. PEERS"
if ! file_ready "$DUMP"; then
    # A missing/empty dump is by definition not "fresher than 30 minutes",
    # so it must fail the documented exit-code contract just like a stale one.
    status_fail=1
    printf '  %sdump not available yet (%s missing or empty)%s\n' "$C_YELLOW" "$DUMP" "$C_RESET"
else
    peers="$(awk '
        /^[ 	]*#/ { next }
        NF < 11         { next }
        {
            total++
            if ($2 == 1) reach++
            # $10 is the peer service-flags nibble for bits 28-31. BLAKE2b
            # support is advertised as bit 28, the low bit of that nibble, so
            # it is set in exactly the odd hex digits (1,3,5,7,9,b,d,f).
            c = substr($10, 1, 1)
            if (c ~ /^[13579bdfBDF]$/) {
                b_total++
                if ($2 == 1) b_reach++
            }
        }
        END {
            pct = (total > 0) ? (b_total * 100.0 / total) : 0
            printf "%d %d %d %d %.1f\n", total, reach, b_total, b_reach, pct
        }' "$DUMP" 2>/dev/null)"

    read -r p_total p_reach p_btotal p_breach p_pct <<< "${peers:-}"
    if [ -z "$peers" ]; then
        printf '  %scould not parse %s%s\n' "$C_YELLOW" "$DUMP" "$C_RESET"
    elif [ "${p_total:-0}" -eq 0 ]; then
        printf '  %sdump contains no node rows yet (header only)%s\n' "$C_YELLOW" "$C_RESET"
    else
        kv "nodes known" "$p_total"
        kv "nodes reachable now" "$p_reach"
        kv "BLAKE2b known" "$p_btotal"
        printf '  %-26s %s%s%s%s\n' "BLAKE2b REACHABLE NOW" "$C_BOLD" "$C_GREEN" "$p_breach" "$C_RESET"
        kv "BLAKE2b share of known" "${p_pct}%"
    fi

    dump_mtime="$(stat -c %Y "$DUMP" 2>/dev/null)"
    case "$dump_mtime" in
        ''|*[!0-9]*) kv "dump age" "unknown (stat failed)" ;;
        *)  d_age=$(( now - dump_mtime ))
            [ "$d_age" -lt 0 ] && d_age=0
            if [ "$d_age" -gt "$STALE_SECS" ]; then
                status_fail=1
                printf '  %-26s %s%swritten %s ago — STALE, daemon may have stopped updating it%s\n' \
                    "dump age" "$C_BOLD" "$C_RED" "$(human_age "$d_age")" "$C_RESET"
            else
                kv "dump age" "written $(human_age "$d_age") ago"
            fi ;;
    esac
fi

# ======================================== C. BLAKE2b CLIENT VERSIONS ========
hdr "C. BLAKE2b CLIENT VERSIONS (top 10)"
if ! file_ready "$DUMP"; then
    printf '  %sdump not available yet%s\n' "$C_YELLOW" "$C_RESET"
else
    ua_rows="$(awk '
        /^[ 	]*#/ { next }
        NF < 11         { next }
        {
            # Same BLAKE2b bit-28 test as section B above; skip non-BLAKE2b peers.
            c = substr($10, 1, 1)
            if (c !~ /^[13579bdfBDF]$/) next
            if (NF < 12) { ua = "(no user agent)" }
            else {
                # The user-agent string may itself contain spaces, so it is not
                # a single awk field; rejoin $12..NF, then strip only the one
                # leading/trailing quote pair the dump wraps it in (a substr()
                # trim rather than gsub(), so quotes inside the UA are kept).
                ua = $12
                for (i = 13; i <= NF; i++) ua = ua " " $i
                n = length(ua)
                if (n >= 2 && substr(ua, 1, 1) == "\"" && substr(ua, n, 1) == "\"")
                    ua = substr(ua, 2, n - 2)
                if (ua == "") ua = "(no user agent)"
            }
            cnt[ua]++
        }
        END { for (u in cnt) printf "%d\t%s\n", cnt[u], u }' "$DUMP" 2>/dev/null \
        | sort -rn | head -n 10)"

    if [ -z "$ua_rows" ]; then
        printf '  %sno BLAKE2b nodes in dump%s\n' "$C_YELLOW" "$C_RESET"
    else
        while IFS=$'\t' read -r cnt ua; do
            [ -z "${cnt:-}" ] && continue
            if [ "${#ua}" -gt 46 ]; then
                ua="${ua:0:43}..."
            fi
            printf '  %-46s %s\n' "$ua" "$cnt"
        done <<< "$ua_rows"
    fi
fi

# ================================================== D. UPTIME TREND =========
hdr "D. UPTIME TREND (node-equivalents, not a node count)"
if ! file_ready "$STATS"; then
    printf '  %sstats not available yet (%s missing or empty)%s\n' "$C_YELLOW" "$STATS" "$C_RESET"
else
    samples="$(wc -l < "$STATS" 2>/dev/null | tr -d ' ')"
    case "$samples" in ''|*[!0-9]*) samples=0 ;; esac
    newest="$(tail -n 1 "$STATS" 2>/dev/null)"
    prev="$(tail -n 2 "$STATS" 2>/dev/null | head -n 1)"

    n_ok=0
    read -r n_ts n_2h n_8h n_1d n_7d n_30d _rest <<< "${newest:-}"
    if [ -n "${n_ts:-}" ] && [ -n "${n_30d:-}" ]; then
        case "$n_ts" in ''|*[!0-9]*) ;; *) n_ok=1 ;; esac
    fi

    if [ "$n_ok" -ne 1 ]; then
        printf '  %slatest sample is unreadable or truncated — try again shortly%s\n' "$C_YELLOW" "$C_RESET"
        kv "samples in log" "$samples"
    else
        kv "sum of uptime fractions" \
           "$(awk -v a="$n_2h" -v b="$n_8h" -v c="$n_1d" -v d="$n_7d" -v e="$n_30d" \
                'BEGIN { printf "2h %.2f | 8h %.2f | 1d %.2f | 7d %.2f | 30d %.2f", a, b, c, d, e }')"
        s_age=$(( now - n_ts ))
        [ "$s_age" -lt 0 ] && s_age=0
        kv "sample written" "$(human_age "$s_age") ago"
        kv "samples in log" "$samples"

        if [ "$samples" -ge 2 ] && [ -n "${prev:-}" ]; then
            read -r p_ts p_2h _p8 _p1 _p7 _p30 _prest <<< "$prev"
            ok=0
            case "${p_ts:-}" in ''|*[!0-9]*) ;; *) [ -n "${p_2h:-}" ] && ok=1 ;; esac
            if [ "$ok" -eq 1 ]; then
                delta="$(awk -v a="$n_2h" -v b="$p_2h" 'BEGIN { printf "%+.2f", a - b }')"
                dcol="$C_DIM"
                case "$delta" in
                    +0.00|-0.00) dcol="$C_DIM" ;;
                    +*)          dcol="$C_GREEN" ;;
                    -*)          dcol="$C_RED" ;;
                esac
                printf '  %-26s %s%s%s vs previous sample\n' "2h change" "$dcol" "$delta" "$C_RESET"
            fi
        fi
    fi
fi

# =================================================== E. DNS ANSWERS =========
hdr "E. DNS ANSWERS"
if ! have dig; then
    printf '  %sdig not installed — skipping DNS checks%s\n' "$C_YELLOW" "$C_RESET"
else
    bind_addr=""; bind_port="53"
    exec_line="$(systemctl cat "$UNIT" 2>/dev/null | awk '
        /^ExecStart=/ && !seen {
            seen = 1
            a = ""; p = ""
            for (i = 1; i < NF; i++) {
                if ($i == "-a") a = $(i + 1)
                if ($i == "-p") p = $(i + 1)
            }
            # systemd may report ExecStart with each argument quoted; strip a
            # leading/trailing quote pair the same way section C strips the UA.
            n = length(a)
            if (n >= 2 && substr(a, 1, 1) == "\"" && substr(a, n, 1) == "\"")
                a = substr(a, 2, n - 2)
            n = length(p)
            if (n >= 2 && substr(p, 1, 1) == "\"" && substr(p, n, 1) == "\"")
                p = substr(p, 2, n - 2)
            print a " " p
        }')"
    if [ -n "$exec_line" ]; then
        read -r cand_addr cand_port <<< "$exec_line"
        if [[ "${cand_addr:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            bind_addr="$cand_addr"
        fi
        case "${cand_port:-}" in ''|*[!0-9]*) ;; *) bind_port="$cand_port" ;; esac
    fi

    dns_count() { # dns_count <server> <name>
        local out n
        out="$(dig @"$1" -p "$bind_port" "$2" +short +time=2 +tries=1 2>/dev/null)"
        n="$(printf '%s\n' "$out" | grep -c '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' || true)"
        printf '%s' "${n:-0}"
    }

    srv="127.0.0.1"
    c_plain="$(dns_count "$srv" "$SEED_HOST")"
    c_filt="$(dns_count "$srv" "x10000009.$SEED_HOST")"
    if [ "$c_plain" -eq 0 ] && [ "$c_filt" -eq 0 ] && \
       [ -n "$bind_addr" ] && [ "$bind_addr" != "127.0.0.1" ]; then
        srv="$bind_addr"
        c_plain="$(dns_count "$srv" "$SEED_HOST")"
        c_filt="$(dns_count "$srv" "x10000009.$SEED_HOST")"
    fi

    kv "server queried" "${srv}:${bind_port}"
    if [ "$c_plain" -eq 0 ] && [ "$c_filt" -eq 0 ]; then
        printf '  %-26s %s%s / %s A records (plain / x10000009) — no answers%s\n' \
            "$SEED_HOST" "$C_YELLOW" "$c_plain" "$c_filt" "$C_RESET"
    else
        kv "$SEED_HOST" "$c_plain A records"
        kv "x10000009.$SEED_HOST" "$c_filt A records"
    fi
fi

# ========================================================== F. HOST =========
hdr "F. HOST"
disk="$(df -P -h / 2>/dev/null | awk 'NR == 2 { printf "%s free of %s (%s used)", $4, $2, $5 }')"
kv "disk /" "${disk:-n/a}"

memline="$(free -m 2>/dev/null | awk '$1 == "Mem:" { printf "%s MiB available of %s MiB", $7, $2 }')"
kv "memory" "${memline:-n/a}"

loadline="$(awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg 2>/dev/null)"
kv "load average" "${loadline:-n/a}"

up_secs="$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)"
case "${up_secs:-}" in
    ''|*[!0-9]*) kv "system uptime" "n/a" ;;
    *)           kv "system uptime" "$(human_age "$up_secs")" ;;
esac

exit "$status_fail"
