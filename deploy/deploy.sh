#!/usr/bin/env bash
#
# deploy.sh -- Idempotent provisioning for a Bitcoin Knots BLAKE2b-fork DNS seeder.
#
# Target:  fresh Debian 13 (trixie) VPS, Netcup "nano" class (1 vCPU / 2 GB RAM).
#          Built and verified on trixie; bookworm is expected to work, untested.
# Source:  the repository this script ships in -- a fork of sipa/bitcoin-seeder with
#          the BLAKE2b patch already applied as a commit. The script builds the
#          sources sitting next to it; it does not clone or patch anything.
#
# Safe to re-run: every step checks current state before mutating. Re-running after
# a config edit will rewrite only what actually changed.
#
# Usage (from the root of the checkout):
#   sudo CONTACT_EMAIL=you@example.com \
#        SEED_HOST=seed.yourdomain.org NS_HOST=ns-seed.yourdomain.org ./deploy/deploy.sh
#
#   ...and the same with optional overrides:
#   sudo CONTACT_EMAIL=you@example.com \
#        SEED_HOST=seed.yourdomain.org NS_HOST=ns-seed.yourdomain.org \
#        PUBLIC_IP=203.0.113.10 CRAWLER_THREADS=24 ./deploy/deploy.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION -- every value below is overridable from the environment.
# ---------------------------------------------------------------------------

# Hostname that answers with A/AAAA records for crawled peers. This is the name
# users put in their bitcoin.conf as a -dnsseed / addnode source.
# REQUIRED. There is deliberately no default -- see STEP 1. The '+' form (not
# ':-') records whether the caller supplied the variable at all, so a supplied
# empty string is distinguishable from an unset one. Both are safe under set -u.
SEED_HOST_SUPPLIED="${SEED_HOST+yes}"
SEED_HOST="${SEED_HOST-}"

# The authoritative nameserver name for SEED_HOST. The registrar needs an A
# record for this name (glue/host record) plus an NS record delegating
# SEED_HOST to it. Must differ from SEED_HOST.
# REQUIRED, on the same terms as SEED_HOST.
NS_HOST_SUPPLIED="${NS_HOST+yes}"
NS_HOST="${NS_HOST-}"

# REQUIRED. Embedded in the zone's SOA RNAME so abuse reports can reach you.
# There is deliberately no default -- an unset value aborts the run.
CONTACT_EMAIL="${CONTACT_EMAIL:-}"

# Public IPv4 address this box answers on and advertises. Auto-detected from the
# kernel routing table when unset. Must be a globally routable address: a NAT'd
# RFC1918 address here produces a seeder that advertises an unreachable bind
# address, so the script refuses to guess in that case.
PUBLIC_IP="${PUBLIC_IP:-}"

# Unprivileged system account the daemon runs as.
SEED_USER="${SEED_USER:-dnsseed}"

# Crawler thread count (dnsseed -t). NOTE the flag: -t is crawlers, -d is DNS
# server threads. Upstream defaults are -t 96 and -d 4.
#
# The crawler walks the whole Bitcoin network (a quarter of a million
# addresses), not just the fork's few hundred nodes, and the threads spend
# nearly all their time blocked on connect() timeouts to dead addresses rather
# than using CPU. On the live seed 48 threads starved: 44 of 48 sat in SYN_SENT,
# nodes were not re-polled often enough to stay "good", and the served set
# collapsed. 160 fixed it on a 2 vCPU / 2 GB VPS at about 80 MB RSS.
CRAWLER_THREADS="${CRAWLER_THREADS:-160}"

# DNS server threads (dnsseed -d). Upstream default is 4, which is ample: these
# only parse and answer small UDP queries.
DNS_THREADS="${DNS_THREADS:-4}"

# Bootstrap seeds the crawler starts from (dnsseed -s), space separated.
#
# THIS IS NOT OPTIONAL. The upstream seeder's compiled-in mainnet_seeds[] are
# all SHA256d Bitcoin seeds (and bitseed.xf2.org is dead -- 0 records as of
# 2026-09-18). Without -s the crawler warms up almost entirely on the wrong
# chain and takes far longer to find any BLAKE2b peers. Passing -s at least
# once REPLACES the built-in list wholesale (main.cpp:565, `swap`), and the
# flag accumulates, so every seed we want must be listed here.
#
# The x10000009. prefix asks each upstream seed to pre-filter to
# NODE_NETWORK|NODE_WITNESS|NODE_BLAKE2B. Both seeds below currently return
# fork-only results for the bare name too, so this is defensive rather than
# strictly necessary -- it keeps our bootstrap clean if either operator later
# starts serving mixed SHA256d/BLAKE2b results.
BOOTSTRAP_SEEDS="${BOOTSTRAP_SEEDS:-x10000009.dnsseed.bitcoin.dashjr-list-of-p2p-nodes.us x10000009.seed.bitcoin.haf.ovh}"

# Optional. A healthchecks.io (or compatible) ping URL. When set, this script
# installs a systemd timer that checks the seeder every 5 minutes and pings
# this URL. If the host dies the pings stop and the alarm is raised remotely --
# which is why it catches failures a monitor running ON this host cannot.
# Leave unset to install the scripts without the timer.
HEALTHCHECK_PING_URL="${HEALTHCHECK_PING_URL:-}"

# ---------------------------------------------------------------------------
# Fixed constants (not intended to be overridden).
# ---------------------------------------------------------------------------

# Where the sources are staged and compiled. This is a BUILD COPY, never the
# operator's own checkout -- see STEP 5 for the rationale.
BUILD_DIR="/opt/blake2b-seeder"
BUILD_ARTIFACT="dnsseed"          # binary name produced by the upstream Makefile
BIN_PATH="/usr/local/bin/dnsseed"
STATE_DIR="/var/lib/dnsseed"
UNIT_PATH="/etc/systemd/system/dnsseed.service"
NFT_CONF="/etc/nftables.conf"
AUTO_UPGRADES_CONF="/etc/apt/apt.conf.d/20auto-upgrades"

# Locate the repository we ship in, from this script's own path. The cd+pwd form
# is deliberate rather than string manipulation on $0: it resolves a relative
# invocation ("./deploy/deploy.sh", "bash deploy/deploy.sh"), a PATH-less call
# from another directory, and any symlinked parent directory, all to one
# canonical absolute path. ${BASH_SOURCE[0]} rather than $0 so it stays correct
# if the script is ever sourced instead of executed.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# Cleanup of any temp files we leave behind on an abort.
TMP_FILES=()
cleanup() {
    local rc=$?
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
        rm -f "$f" 2>/dev/null || true
    done
    return "$rc"
}
trap cleanup EXIT

# Creates a temp file and puts its path in the global TMPF. Deliberately not a
# command substitution: that would run in a subshell and the TMP_FILES entry
# registered for cleanup would be lost when the subshell exited.
TMPF=""
mk_tmp() {
    TMPF="$(mktemp)"
    TMP_FILES+=("$TMPF")
}

# write_if_changed <source-tmp-file> <destination> <mode>
# Installs the candidate only when it differs from what is already on disk.
# Echoes "changed" on stdout when it replaced the file, "unchanged" otherwise,
# so callers can react (e.g. warn that a restart is needed).
write_if_changed() {
    local src="$1" dest="$2" mode="$3"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        printf 'unchanged'
        return 0
    fi
    install -o root -g root -m "$mode" "$src" "$dest"
    printf 'changed'
}

# Strict dotted-quad check with real 0-255 per-octet range validation.
# A naive [0-9]{1,3} regex happily accepts 999.1.1.1, which would then be
# handed to dnsseed -a and fail at bind time with a confusing error.
is_valid_ipv4() {
    local ip="$1" o1 o2 o3 o4 extra octet
    case "$ip" in
        *[!0-9.]*|"") return 1 ;;
    esac
    extra=""
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    if [ -n "${extra:-}" ]; then
        return 1
    fi
    for octet in "${o1:-}" "${o2:-}" "${o3:-}" "${o4:-}"; do
        if [ -z "$octet" ] || [ "${#octet}" -gt 3 ]; then
            return 1
        fi
        # Reject leading zeros (e.g. 010.1.1.1 is ambiguous/octal-looking).
        if [ "${#octet}" -gt 1 ] && [ "${octet#0}" != "$octet" ]; then
            return 1
        fi
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# Returns 0 when the address is NOT globally routable (loopback, link-local,
# RFC1918, CGNAT, multicast, 0.0.0.0/8).
is_non_public_ipv4() {
    local ip="$1" o1 o2 rest
    rest=""
    IFS='.' read -r o1 o2 rest <<< "$ip"
    case "$o1" in
        0|127) return 0 ;;                                                    # this-network, loopback
        10)    return 0 ;;                                                    # RFC1918
        169)   if [ "$o2" -eq 254 ]; then return 0; fi ;;                     # link-local
        172)   if [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi ;;  # RFC1918
        192)   if [ "$o2" -eq 168 ]; then return 0; fi ;;                     # RFC1918
        100)   if [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then return 0; fi ;; # CGNAT 100.64/10
    esac
    if [ "$o1" -ge 224 ]; then
        return 0    # multicast and reserved space
    fi
    return 1
}

is_valid_hostname() {
    local h="$1"
    [ "${#h}" -le 253 ] || return 1
    printf '%s' "$h" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
}

# ---------------------------------------------------------------------------
# STEP 1 -- Preflight validation. Nothing below this block mutates the system,
# so every failure here is cheap and leaves the box untouched.
# ---------------------------------------------------------------------------

[ "${EUID:-$(id -u)}" -eq 0 ] || die "must be run as root (try: sudo -E $0)"

if [ -z "$CONTACT_EMAIL" ]; then
    die "CONTACT_EMAIL is required and has no default.
       It is published in the zone SOA so operators can reach you about abuse.
       Re-run as:  CONTACT_EMAIL=you@example.com $0"
fi

if ! printf '%s' "$CONTACT_EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
    die "CONTACT_EMAIL='$CONTACT_EMAIL' does not look like an email address (expected user@domain.tld)"
fi

# dnsseed itself silently ignores an out-of-range -t/-d (it only assigns when
# 0 < n < 1000), so validate here where we can actually tell the operator.
case "$CRAWLER_THREADS" in
    ''|*[!0-9]*) die "CRAWLER_THREADS='$CRAWLER_THREADS' must be a positive integer" ;;
esac
[ "$CRAWLER_THREADS" -ge 1 ]   || die "CRAWLER_THREADS='$CRAWLER_THREADS' must be at least 1"
[ "$CRAWLER_THREADS" -le 256 ] || die "CRAWLER_THREADS='$CRAWLER_THREADS' is implausibly high for a 1 vCPU / 2 GB host"

case "$DNS_THREADS" in
    ''|*[!0-9]*) die "DNS_THREADS='$DNS_THREADS' must be a positive integer" ;;
esac
[ "$DNS_THREADS" -ge 1 ]  || die "DNS_THREADS='$DNS_THREADS' must be at least 1"
[ "$DNS_THREADS" -le 32 ] || die "DNS_THREADS='$DNS_THREADS' is implausibly high; these only answer small UDP queries"

if [ -z "$SEED_HOST_SUPPLIED" ] || [ -z "$SEED_HOST" ]; then
    die "SEED_HOST is required and has no default.
       It must be a hostname in a domain you control -- the seeder becomes
       authoritative for it, and it is what users put in their bitcoin.conf.
       Re-run as:  SEED_HOST=seed.yourdomain.org NS_HOST=ns-seed.yourdomain.org $0"
fi

if [ -z "$NS_HOST_SUPPLIED" ] || [ -z "$NS_HOST" ]; then
    die "NS_HOST is required and has no default.
       It is the nameserver name your registrar delegates SEED_HOST to, so it
       must also be in a domain you control, and must differ from SEED_HOST.
       Re-run as:  SEED_HOST=seed.yourdomain.org NS_HOST=ns-seed.yourdomain.org $0"
fi

is_valid_hostname "$SEED_HOST" || die "SEED_HOST='$SEED_HOST' is not a valid fully-qualified hostname"
is_valid_hostname "$NS_HOST"   || die "NS_HOST='$NS_HOST' is not a valid fully-qualified hostname"
[ "$SEED_HOST" != "$NS_HOST" ] || die "SEED_HOST and NS_HOST must differ ('$SEED_HOST'). NS_HOST is the nameserver name that SEED_HOST is delegated to."

case "$SEED_USER" in
    ''|*[!a-z0-9_-]*) die "SEED_USER='$SEED_USER' must be a lowercase alphanumeric/underscore/dash name" ;;
esac

# Fail fast on a wrong or missing source tree before spending minutes in apt and
# the compiler. This script only makes sense one directory below the seeder
# sources, so check that the sources are actually there.
if [ ! -f "$REPO_ROOT/Makefile" ]; then
    die "no Makefile found at '$REPO_ROOT/Makefile'.
       This script expects to live in 'deploy/' inside the seeder repository, so
       that its parent directory is the seeder source tree. Run it as:
         sudo CONTACT_EMAIL=you@example.com ./deploy/deploy.sh"
fi
if [ ! -f "$REPO_ROOT/main.cpp" ]; then
    die "no main.cpp found at '$REPO_ROOT/main.cpp'.
       This script expects to live in 'deploy/' inside the seeder repository, so
       that its parent directory is the seeder source tree. Run it as:
         sudo CONTACT_EMAIL=you@example.com ./deploy/deploy.sh"
fi
# Check protocol.h exists before grepping it, so a missing file reports as a
# missing file rather than as a failed content check.
if [ ! -f "$REPO_ROOT/protocol.h" ]; then
    die "no protocol.h found at '$REPO_ROOT/protocol.h'.
       This script expects to live in 'deploy/' inside the seeder repository, so
       that its parent directory is the seeder source tree. Run it as:
         sudo CONTACT_EMAIL=you@example.com ./deploy/deploy.sh"
fi

# The BLAKE2b service bit is the one unambiguous marker that these sources are
# the patched fork and not upstream. Without it the built binary crawls and
# serves the SHA256d chain, which is worse than useless for fork users: it would
# hand brand-new fork nodes a list of peers they can never sync from.
if ! grep -Fq 'NODE_BLAKE2B' "$REPO_ROOT/protocol.h"; then
    die "'$REPO_ROOT/protocol.h' does not define NODE_BLAKE2B.
       This looks like unpatched upstream sipa/bitcoin-seeder. A seeder built
       from these sources will NOT serve BLAKE2b fork nodes.
       Clone the patched fork instead and run this script from there:
         git clone https://github.com/LionThunderFingers/blake2b-seeder.git
         cd blake2b-seeder
         sudo CONTACT_EMAIL=you@example.com ./deploy/deploy.sh"
fi

# PUBLIC_IP: auto-detect using only coreutils/iproute2 (curl is intentionally not
# a dependency of this script). `ip route get` reports the source address the
# kernel would use for outbound traffic, which on a directly-addressed VPS is
# the public IP.
if [ -z "$PUBLIC_IP" ]; then
    detected=""
    if command -v ip >/dev/null 2>&1; then
        detected="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]]\([0-9.]*\).*/\1/p' | head -n 1)"
    fi
    if [ -z "$detected" ] && command -v hostname >/dev/null 2>&1; then
        detected="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -n 1)"
    fi
    [ -n "$detected" ] || die "could not auto-detect a public IPv4 address. Re-run with PUBLIC_IP=<your.public.ip>"
    PUBLIC_IP="$detected"
    log "auto-detected PUBLIC_IP=$PUBLIC_IP"
fi

is_valid_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP='$PUBLIC_IP' is not a valid IPv4 address"

if is_non_public_ipv4 "$PUBLIC_IP"; then
    die "PUBLIC_IP='$PUBLIC_IP' is loopback/link-local/private/reserved, not globally routable.
       The seeder advertises this address as its own; behind NAT the auto-detected
       address is wrong. Re-run with the real external address:
         PUBLIC_IP=203.0.113.10 CONTACT_EMAIL='$CONTACT_EMAIL' $0"
fi

cat <<EOF

================ resolved configuration ================
  SEED_HOST      : $SEED_HOST
  NS_HOST        : $NS_HOST
  CONTACT_EMAIL  : $CONTACT_EMAIL
  PUBLIC_IP      : $PUBLIC_IP
  SEED_USER      : $SEED_USER
  CRAWLER_THREADS: $CRAWLER_THREADS
  DNS_THREADS    : $DNS_THREADS
  REPO_ROOT      : $REPO_ROOT
  BUILD_DIR      : $BUILD_DIR
========================================================

EOF

# ---------------------------------------------------------------------------
# STEP 2 -- Packages
# ---------------------------------------------------------------------------
log "updating package lists"
apt-get update -qq

log "installing build and runtime dependencies"
apt-get install -y -qq --no-install-recommends \
    build-essential \
    libboost-dev \
    libssl-dev \
    rsync \
    nftables \
    unattended-upgrades \
    apt-listchanges \
    ca-certificates \
    curl \
    bind9-dnsutils

# ---------------------------------------------------------------------------
# STEP 3 -- Unattended security upgrades, enabled non-interactively.
# dpkg-reconfigure would prompt; writing the config file directly does not.
# ---------------------------------------------------------------------------
mk_tmp; tmp="$TMPF"
cat > "$tmp" <<'EOF'
// Managed by deploy.sh -- enables unattended-upgrades without a debconf prompt.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
if [ "$(write_if_changed "$tmp" "$AUTO_UPGRADES_CONF" 0644)" = "changed" ]; then
    log "wrote $AUTO_UPGRADES_CONF (unattended-upgrades enabled)"
else
    log "$AUTO_UPGRADES_CONF already correct"
fi
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || \
    warn "could not enable the unattended-upgrades service; check 'systemctl status unattended-upgrades'"

# ---------------------------------------------------------------------------
# STEP 4 -- Unprivileged service account
# ---------------------------------------------------------------------------
if getent passwd "$SEED_USER" >/dev/null 2>&1; then
    log "user '$SEED_USER' already exists"
else
    log "creating system user '$SEED_USER'"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SEED_USER"
fi

# ---------------------------------------------------------------------------
# STEP 5 -- Stage the sources into a build copy and compile.
#
# We deliberately do NOT build in the operator's checkout. Two reasons:
#   1) It keeps the checkout pristine. Compiling in place scatters .o files and a
#      binary through the worktree, so `git status` and `git diff` stop being
#      usable for auditing what the fork actually changes -- which is the whole
#      point of shipping this as a readable fork rather than a blob.
#   2) It makes re-runs reproducible. The build always starts from a known state
#      mirrored from the checkout, never from whatever a previous run left behind.
# ---------------------------------------------------------------------------

# Refuse to rsync --delete into something that is itself a real checkout; that
# would silently destroy someone's work if they placed a repo at this path.
if [ -e "$BUILD_DIR/.git" ]; then
    die "$BUILD_DIR contains a .git directory, so it looks like a real checkout
       rather than a build copy created by this script. Refusing to overwrite it.
       Move it aside and re-run."
fi

log "staging sources from $REPO_ROOT into $BUILD_DIR"
install -d -o root -g root -m 0755 "$BUILD_DIR"

# The trailing slash on the SOURCE path is load-bearing: "$REPO_ROOT/" copies the
# CONTENTS of the directory into $BUILD_DIR, while "$REPO_ROOT" (no slash) would
# nest a directory and produce $BUILD_DIR/<reponame>/Makefile instead.
# --delete removes files left over from an older revision of the fork.
rsync -a --delete --exclude '.git/' --exclude '.github/' "$REPO_ROOT"/ "$BUILD_DIR"/

# `make clean` is not optional here. On a re-run, reset+re-patch rewrites the
# sources but object files from the previous build can retain newer mtimes, so
# make would consider them up to date and quietly relink a stale binary.
log "cleaning previous build objects"
make -C "$BUILD_DIR" clean >/dev/null 2>&1 || true

# NOTE on -march=native: the upstream Makefile compiles with -march=native and we
# deliberately leave it alone. We compile on the exact machine that will run the
# binary, so native tuning is safe and free. It would be unsafe only if this
# artifact were copied to a host with a different CPU, which this script never does.
log "building with make -j$(nproc) (this takes a few minutes on 1 vCPU)"
make -C "$BUILD_DIR" -j"$(nproc)"

# The upstream Makefile links the binary as ./dnsseed in the repo root. Verify
# rather than assume -- silently installing nothing would leave a broken unit.
BUILT_BIN="$BUILD_DIR/$BUILD_ARTIFACT"
[ -f "$BUILT_BIN" ] || die "build finished but expected artifact '$BUILT_BIN' was not found.
       The upstream Makefile's output name may have changed. Inspect $BUILD_DIR
       and update BUILD_ARTIFACT in this script."
[ -s "$BUILT_BIN" ] || die "built artifact '$BUILT_BIN' is empty"

# ---------------------------------------------------------------------------
# STEP 6 -- Install the binary (install(1) is idempotent by construction).
# ---------------------------------------------------------------------------
log "installing binary to $BIN_PATH"
install -o root -g root -m 0755 "$BUILT_BIN" "$BIN_PATH"

# ---------------------------------------------------------------------------
# STEP 7 -- Runtime state directory (holds dnsseed.dat, the crawler's peer db).
# 0750 so the peer database is not world-readable.
# ---------------------------------------------------------------------------
log "ensuring state directory $STATE_DIR"
install -d -o "$SEED_USER" -g "$SEED_USER" -m 0750 "$STATE_DIR"

# ---------------------------------------------------------------------------
# STEP 8 -- Hardened systemd unit.
# ---------------------------------------------------------------------------
mk_tmp; tmp="$TMPF"
# Expand BOOTSTRAP_SEEDS into repeated `-s <host>` flags. Unquoted on purpose:
# word splitting is how the space-separated list becomes separate arguments.
# Hostnames cannot contain spaces, so this is safe.
[ -n "${BOOTSTRAP_SEEDS// /}" ] || die "BOOTSTRAP_SEEDS is empty. Without it the crawler
       falls back to the upstream SHA256d seed list and will not find BLAKE2b peers."
SEED_FLAGS=""
for _bs in $BOOTSTRAP_SEEDS; do
    SEED_FLAGS="$SEED_FLAGS -s \"$_bs\""
done

cat > "$tmp" <<EOF
# Managed by deploy.sh -- local edits will be overwritten on the next run.
[Unit]
Description=Bitcoin Knots BLAKE2b DNS seeder
Documentation=https://github.com/sipa/bitcoin-seeder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SEED_USER
Group=$SEED_USER
WorkingDirectory=$STATE_DIR
ExecStart="$BIN_PATH" -h "$SEED_HOST" -n "$NS_HOST" -m "$CONTACT_EMAIL" -p 53 -a "$PUBLIC_IP" -t "$CRAWLER_THREADS" -d "$DNS_THREADS"$SEED_FLAGS
Restart=always
RestartSec=10

# The daemon binds UDP/53, a privileged port, but runs as an unprivileged user.
# CAP_NET_BIND_SERVICE is the single capability that permits that bind; the
# bounding set pins it so no other capability can ever be acquired.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Hardening. ProtectSystem=strict mounts the entire filesystem read-only for
# this unit, so ReadWritePaths must re-open the one directory the crawler needs
# to write (dnsseed.dat lives there).
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$STATE_DIR
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
LockPersonality=true
# AF_NETLINK is required in addition to the two IP families. netbase.cpp:81
# resolves the bootstrap seeds with getaddrinfo(AI_ADDRCONFIG), and glibc
# implements AI_ADDRCONFIG by opening an AF_NETLINK socket (__check_pf) to
# enumerate local addresses. Denying it does not hard-fail -- glibc falls back
# to assuming both families are present -- but it defeats the flag's purpose
# for no security gain, since netlink here is read-only interface enumeration.
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

unit_state="$(write_if_changed "$tmp" "$UNIT_PATH" 0644)"
if [ "$unit_state" = "changed" ]; then
    log "wrote $UNIT_PATH"
else
    log "$UNIT_PATH already correct"
fi

systemctl daemon-reload
systemctl enable dnsseed.service >/dev/null

UNIT_RESTART_NEEDED=0
if [ "$unit_state" = "changed" ] && systemctl is-active --quiet dnsseed.service; then
    UNIT_RESTART_NEEDED=1
fi

# ---------------------------------------------------------------------------
# STEP 9 -- Monitoring and alerting.
#
# Two read-only monitors ship in this directory. seed-status is an on-demand
# snapshot the operator runs over SSH; seed-healthcheck is the dead-man's switch
# body, run on a timer. Neither is required for the seeder to serve DNS, so a
# missing script here warns and is skipped -- an absent optional monitor must
# never abort a seeder deployment.
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/seed-healthcheck.sh" ]; then
    log "installing health check script to /usr/local/bin/seed-healthcheck"
    install -o root -g root -m 0755 "$SCRIPT_DIR/seed-healthcheck.sh" "/usr/local/bin/seed-healthcheck"
else
    warn "'$SCRIPT_DIR/seed-healthcheck.sh' not found; skipping the health check script"
fi

if [ -f "$SCRIPT_DIR/seed-status.sh" ]; then
    log "installing status script to /usr/local/sbin/seed-status"
    install -o root -g root -m 0750 "$SCRIPT_DIR/seed-status.sh" "/usr/local/sbin/seed-status"
else
    warn "'$SCRIPT_DIR/seed-status.sh' not found; skipping the status script"
fi

HEALTHCHECK_CONFIGURED=0
if [ -n "$HEALTHCHECK_PING_URL" ]; then
    # The ping URL is a credential in transit: anyone who observes it can forge
    # liveness pings. Plain HTTP is refused rather than downgraded silently.
    case "$HEALTHCHECK_PING_URL" in
        https://*) : ;;
        *) die "HEALTHCHECK_PING_URL='$HEALTHCHECK_PING_URL' must start with https://.
       The ping URL is a credential in transit -- anyone who can read it can send
       fake liveness pings and suppress a real alert -- so plain HTTP is refused." ;;
    esac

    # 0600 root-only: anyone holding the ping URL can send fake liveness pings and
    # suppress a real alert, so it stays out of the world-readable unit file and
    # lives here instead.
    mk_tmp; tmp="$TMPF"
    # SEED_HOST must be passed through too. The health check queries it to prove
    # the daemon is really answering, and its built-in default is this project's
    # own hostname -- so without this line every operator using their own domain
    # would get a permanent, entirely false "returned no records" alert.
    cat > "$tmp" <<EOF
PING_URL=$HEALTHCHECK_PING_URL
SEED_HOST=$SEED_HOST
EOF
    if [ "$(write_if_changed "$tmp" "/etc/default/seed-healthcheck" 0600)" = "changed" ]; then
        log "wrote /etc/default/seed-healthcheck (mode 0600, root only)"
    else
        log "/etc/default/seed-healthcheck already correct"
    fi

    mk_tmp; tmp="$TMPF"
    cat > "$tmp" <<'EOF'
[Unit]
Description=BLAKE2b DNS seeder health check (dead-man's switch)
After=network-online.target dnsseed.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/seed-healthcheck
ExecStart=/usr/local/bin/seed-healthcheck
# Read-only monitor: it must never be able to change the thing it watches.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictSUIDSGID=true
LockPersonality=true
EOF
    if [ "$(write_if_changed "$tmp" "/etc/systemd/system/seed-healthcheck.service" 0644)" = "changed" ]; then
        log "wrote /etc/systemd/system/seed-healthcheck.service"
    else
        log "/etc/systemd/system/seed-healthcheck.service already correct"
    fi

    mk_tmp; tmp="$TMPF"
    cat > "$tmp" <<'EOF'
[Unit]
Description=Run BLAKE2b seeder health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=false

[Install]
WantedBy=timers.target
EOF
    if [ "$(write_if_changed "$tmp" "/etc/systemd/system/seed-healthcheck.timer" 0644)" = "changed" ]; then
        log "wrote /etc/systemd/system/seed-healthcheck.timer"
    else
        log "/etc/systemd/system/seed-healthcheck.timer already correct"
    fi

    systemctl daemon-reload
    # A failure here must not abort the run: the firewall step below has not
    # happened yet, and leaving a box unfirewalled because a monitor timer would
    # not enable is a far worse outcome than an un-enabled timer.
    if systemctl enable --now seed-healthcheck.timer >/dev/null 2>&1; then
        HEALTHCHECK_CONFIGURED=1
        log "health check timer enabled (runs 2 minutes after boot, then every 5 minutes)"
    else
        warn "could not enable the seed-healthcheck timer; check 'systemctl status seed-healthcheck.timer'"
    fi

    log "IMPORTANT: in your healthchecks.io check settings, set Period = 5 minutes and"
    log "Grace = 15 minutes. The service default is a period of 1 day, so left alone a"
    log "dead host would not raise an alert for over a day."
else
    if [ -f "/etc/systemd/system/seed-healthcheck.timer" ]; then
        warn "HEALTHCHECK_PING_URL is unset but /etc/systemd/system/seed-healthcheck.timer
         already exists; the previously configured timer is left running untouched."
    fi
    log "monitoring scripts installed, but no alerting timer was configured."
    log "To add it later, re-run with a ping URL:"
    log "  HEALTHCHECK_PING_URL=https://hc-ping.com/your-uuid ./deploy/deploy.sh"
fi

# ---------------------------------------------------------------------------
# STEP 10 -- Firewall.
#
# HIGHEST-RISK STEP. The ruleset is default-drop on input, so a syntax error
# loaded live over SSH would lock the operator out permanently. The candidate is
# therefore validated with `nft -c -f` (parse/check only, no commit) BEFORE the
# live /etc/nftables.conf is touched and before anything is loaded.
# ---------------------------------------------------------------------------
mk_tmp; tmp="$TMPF"
cat > "$tmp" <<'EOF'
#!/usr/sbin/nft -f
# Managed by deploy.sh -- local edits will be overwritten on the next run.

# Flush first so repeated loads of this file replace rather than duplicate rules.
flush ruleset

table inet filter {

    # ------------------------------------------------------------------
    # Per-source-address rate limiting for DNS.
    #
    # WHY: DNS is the classic UDP amplification/reflection vector. An attacker
    # spoofs a victim's source address, sends small queries here, and this host
    # blasts much larger responses at the victim. Even though this seeder is
    # AUTHORITATIVE-ONLY for its own delegated zone and NEVER recurses -- so it
    # is not an open resolver and cannot be used for the high-gain ANY/DNSSEC
    # tricks -- its responses are still several times larger than the queries
    # that trigger them, which is enough to be worth abusing.
    #
    # These dynamic sets meter each source address independently. Legitimate
    # Bitcoin clients issue one query at startup; 20 packets/second per source
    # is orders of magnitude above any honest use.
    #
    # `timeout` expires idle entries and `size` caps the table so a spoofed-
    # source flood cannot exhaust memory on a 2 GB box. Separate v4 and v6 sets
    # are required because a single set in an inet table cannot key both address
    # families.
    # ------------------------------------------------------------------
    set dns_meter_v4 {
        type ipv4_addr
        size 65535
        flags dynamic, timeout
        timeout 1m
    }

    set dns_meter_v6 {
        type ipv6_addr
        size 65535
        flags dynamic, timeout
        timeout 1m
    }

    # SSH brute-force meters, also per source address.
    set ssh_meter_v4 {
        type ipv4_addr
        size 16384
        flags dynamic, timeout
        timeout 10m
    }

    set ssh_meter_v6 {
        type ipv6_addr
        size 16384
        flags dynamic, timeout
        timeout 10m
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Return traffic for connections we started, and anything already
        # accepted. Must come first so nothing below can throttle live sessions.
        ct state established,related accept
        ct state invalid drop

        # Loopback is trusted; reject spoofed loopback arriving on a real NIC.
        iif lo accept
        iif != lo ip  saddr 127.0.0.0/8 drop
        iif != lo ip6 saddr ::1/128 drop

        # ICMP: needed for path-MTU discovery and basic reachability, but
        # rate-limited so it cannot be used as a flood channel.
        ip  protocol icmp   icmp  type { echo-request, destination-unreachable, time-exceeded, parameter-problem } limit rate 10/second burst 20 packets accept
        ip6 nexthdr icmpv6  icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } limit rate 20/second burst 40 packets accept

        # SSH: rate limit NEW connections only, to 10/minute per source with a
        # burst for legitimate reconnects. Matching `ct state new` specifically
        # is important -- limiting established SSH traffic would throttle the
        # operator's own interactive session.
        tcp dport 22 ct state new add @ssh_meter_v4 { ip  saddr limit rate over 10/minute burst 5 packets } drop
        tcp dport 22 ct state new add @ssh_meter_v6 { ip6 saddr limit rate over 10/minute burst 5 packets } drop
        tcp dport 22 ct state new accept

        # DNS -- see the rationale on the meters above. The `add ... limit rate
        # over` form returns true only for packets EXCEEDING the rate, so these
        # two rules drop the excess and the rule after them accepts the rest.
        udp dport 53 add @dns_meter_v4 { ip  saddr limit rate over 20/second burst 40 packets } drop
        udp dport 53 add @dns_meter_v6 { ip6 saddr limit rate over 20/second burst 40 packets } drop
        udp dport 53 accept

        # TCP/53 is deliberately NOT opened. This seeder serves only small UDP
        # responses; no zone transfers, no TCP fallback path is required.
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        # Wide open outbound: the crawler opens a very large number of short
        # connections to port 8333 across the whole network, plus DNS and apt.
        type filter hook output priority filter; policy accept;
    }
}
EOF

# Validate in check mode. `nft -c -f` parses and semantically validates the
# ruleset without committing it. Abort here without touching the live file.
log "validating candidate nftables ruleset (check mode, nothing loaded yet)"
if ! nft -c -f "$tmp"; then
    die "candidate nftables ruleset failed validation. NOTHING was written or loaded,
       the existing firewall is untouched. Fix the ruleset before re-running."
fi

nft_state="$(write_if_changed "$tmp" "$NFT_CONF" 0644)"
if [ "$nft_state" = "changed" ]; then
    log "wrote $NFT_CONF"
else
    log "$NFT_CONF already correct"
fi

log "loading firewall and enabling nftables at boot"
nft -f "$NFT_CONF"
systemctl enable --now nftables >/dev/null

# ---------------------------------------------------------------------------
# STEP 11 -- Operator instructions.
# ---------------------------------------------------------------------------

# Built before the heredoc below rather than branched inside it, so the NEXT
# STEPS block stays one contiguous piece of text in the operator's terminal.
if [ "$HEALTHCHECK_CONFIGURED" -eq 1 ]; then
    ALERTING_NOTE="The dead-man's switch is ACTIVE: this host checks itself every 5 minutes and
   pings your healthchecks.io URL. If the host dies the pings stop and the alarm
   is raised remotely.

   Set Period = 5 minutes and Grace = 15 minutes in that check's settings. The
   service default is a period of 1 day, so a dead server would otherwise go
   unreported for over a day."
else
    ALERTING_NOTE="No alerting is active. The monitoring scripts are installed, but nothing
   will tell you if this host dies. To add the dead-man's switch, create a free
   check at healthchecks.io, copy its ping URL, and re-run (re-running is safe):

        HEALTHCHECK_PING_URL=https://hc-ping.com/your-uuid ./deploy/deploy.sh"
fi

cat <<EOF

========================= NEXT STEPS =========================

The seeder is built, installed and ENABLED but deliberately NOT STARTED.
It cannot answer anything until DNS delegation exists, so do these first.

1) At your DNS registrar/provider, create TWO records:

   a) A (host/glue) record -- gives the nameserver name an address:

        Name : $NS_HOST
        Type : A
        Value: $PUBLIC_IP
        TTL  : 3600

   b) NS record -- delegates the seed name to that nameserver:

        Name : $SEED_HOST
        Type : NS
        Value: $NS_HOST
        TTL  : 3600

   Some registrars require the A record to be registered as a "host record" /
   "glue record" under the domain before it can be used as a nameserver target.

2) Wait for propagation (minutes to a few hours depending on the parent TTL).

3) Start the daemon:

        systemctl start dnsseed
        systemctl status dnsseed

4) Verify -- these query THIS host directly, so they work even before the
   delegation has propagated:

        dig @$PUBLIC_IP $SEED_HOST +short
          -> returns addresses of crawled BLAKE2b fork peers. The patch forces
             NODE_BLAKE2B on even a bare query, so a non-fork node can never
             appear in this answer.

        dig @$PUBLIC_IP x10000009.$SEED_HOST +short
          -> exercises the service-flag filter added by the patch.
             0x10000009 = NODE_NETWORK | NODE_WITNESS | NODE_BLAKE2B.
             An empty answer here with a populated answer above means the
             whitelist entry did not take -- check the patch applied.

   Expect empty answers for the first several minutes: the crawler has to find
   and verify peers before it has anything to hand out.

5) If it fails to start:

        journalctl -u dnsseed -n 100 --no-pager

   The unit is aggressively hardened. If the journal shows an immediate exit
   with no seeder output, relax ONE directive at a time in $UNIT_PATH --
   RestrictAddressFamilies first, then MemoryDenyWriteExecute (some OpenSSL
   builds use W+X JIT pages) -- running 'systemctl daemon-reload' between
   attempts, so you learn which one is responsible instead of dropping all
   hardening at once.

6) For a snapshot of how the seed is doing, run over SSH:

        seed-status

   (installed at /usr/local/sbin/seed-status) -- service state, peer counts,
   BLAKE2b reachability, client versions, uptime trend, live DNS answer counts
   and host resources. It is read-only and changes nothing.

7) $ALERTING_NOTE

==============================================================
EOF

if [ "$UNIT_RESTART_NEEDED" -eq 1 ]; then
    cat <<EOF
NOTE: $UNIT_PATH changed while dnsseed was running. The new configuration is
      NOT live yet. Restart it when you are ready:

        systemctl restart dnsseed

EOF
fi

log "done."
