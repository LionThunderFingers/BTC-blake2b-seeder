#!/bin/bash
#
# seed-publish -- push the newest census sample to the GitHub Pages site.
#
# Takes the last line of census.jsonl, adds the fields the page needs that are
# policy rather than measurement (activation height, which releases actually
# contain the rule), and commits it as data.json.
#
# Also emits history.json: the whole census series, trimmed, so the page can
# draw an adoption curve without shipping the raw JSON-lines file.
#
# Pushes with a repo-scoped deploy key, not an account token: if this host is
# ever compromised the key can write to this one repository and nothing else.
#
# Commits only when the content changed, so the history stays meaningful rather
# than one empty commit per hour.

set -uo pipefail

CENSUS="${CENSUS:-/var/lib/dnsseed/census.jsonl}"
WORK="${WORK:-/var/lib/census-site}"
# REPO has no default: it is the git URL of YOUR census site repository, and a
# default pointing at someone else's would make a fresh install try to publish
# there. Set it in /etc/default/seed-publish (see seed-publish.default.example).
REPO="${REPO:-}"
KEY="${KEY:-/root/.ssh/census_deploy}"
# Identity on the hourly commits. Public in the site repo's history.
GIT_NAME="${GIT_NAME:-seed-publish}"
GIT_EMAIL="${GIT_EMAIL:-seed-publish@localhost}"

# Policy values, not measurements. Keep them here so the page never has to guess.
#   ACTIVATION      - flag-day height for long coinbase maturity, from consensus
#                     (getdeploymentinfo long_coinbase_maturity.height on Knots 29.4.2).
#   ACTIVATION_END  - height at which normal coinbase maturity RESUMES (default
#                     979920). ACTIVATION_END - 1 is therefore the LAST block
#                     mined under the long-maturity rule; the rule is in force
#                     for heights ACTIVATION .. ACTIVATION_END - 1 inclusive,
#                     and ACTIVATION_END itself is already back to normal.
#   ENFORCING       - user-agent strings of releases that actually contain that rule.
#                     With an empty list the page shows 0%, which is correct rather
#                     than broken.
ACTIVATION="${ACTIVATION:-973440}"
ACTIVATION_END="${ACTIVATION_END:-979920}"
ENFORCING_JSON=${ENFORCING_JSON:-'["/Satoshi:29.4.2/Knots:20260508/","/Satoshi:29.4.2(BIP110 meow miao)/Knots:20260508/","/Satoshi:29.4.2(Undersector XBT)/Knots:20260508/","/Satoshi:29.4.2/Knots:20260508rc2/","/Satoshi:29.4.2(mempool.guide)/Knots:20260508rc2/"]'}

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

[ -n "$REPO" ] || { echo "REPO is not set (the git URL of your census site repo); see /etc/default/seed-publish" >&2; exit 1; }
[ -s "$CENSUS" ] || { echo "no census data at $CENSUS" >&2; exit 1; }

if [ ! -d "$WORK/.git" ]; then
    echo "cloning site repo into $WORK"
    rm -rf "$WORK"
    git clone --quiet "$REPO" "$WORK" || { echo "clone failed" >&2; exit 1; }
fi

cd "$WORK" || exit 1
git config user.email "$GIT_EMAIL"
git config user.name "$GIT_NAME"

# Discard any local drift and follow the remote, so a hand edit on GitHub is
# never silently clobbered into a conflict this script cannot resolve.
git fetch --quiet origin main 2>/dev/null
git reset --quiet --hard origin/main 2>/dev/null

python3 - "$CENSUS" "$ACTIVATION" "$ENFORCING_JSON" "$ACTIVATION_END" > data.json.new <<'PY'
import json, sys
census, activation, enforcing = sys.argv[1], int(sys.argv[2]), json.loads(sys.argv[3])
activation_end = int(sys.argv[4])
with open(census) as f:
    last = [l for l in f if l.strip()][-1]
d = json.loads(last)
d["activation_height"] = activation
d["activation_end_height"] = activation_end
d["enforcing_versions"] = enforcing
d["heights"] = {
    "tip": d.pop("h_tip", 0), "near": d.pop("h_near", 0),
    "day": d.pop("h_day", 0), "behind": d.pop("h_behind", 0),
}

# Chain agreement split by whether a node enforces the rule. Policy (the
# enforcing list) lives here; the per-version measurement comes from the census
# script. heights_by_version is deliberately left in the output as well -- this
# is an additional view of it, not a replacement.
#
# Membership is EXACT string equality, no prefix or substring matching: a rule
# written for "/Satoshi:29.4.2/Knots:20260508/" must not silently swallow
# "/Satoshi:29.4.2/Knots:20260508rc2/". Anything not in the list is
# not_enforcing.
#
# Census lines written before heights_by_version existed have no such field. In
# that case the key is omitted entirely rather than emitted as zeros, so the
# page can tell "no data" apart from "data, and it is zero".
hbv = d.get("heights_by_version")
if isinstance(hbv, dict):
    enforcing_set = set(enforcing)
    split = {
        "enforcing": {"tip": 0, "near": 0, "day": 0, "behind": 0},
        "not_enforcing": {"tip": 0, "near": 0, "day": 0, "behind": 0},
    }
    for ua, buckets in hbv.items():
        side = split["enforcing"] if ua in enforcing_set else split["not_enforcing"]
        if not isinstance(buckets, dict):
            buckets = {}
        for bucket in ("tip", "near", "day", "behind"):
            try:
                side[bucket] += int(buckets.get(bucket, 0) or 0)
            except (TypeError, ValueError):
                pass
    d["heights_by_enforcement"] = split

print(json.dumps(d, indent=1, sort_keys=True))
PY

if [ ! -s data.json.new ]; then
    echo "generator produced nothing, refusing to publish" >&2
    rm -f data.json.new
    exit 1
fi
python3 -m json.tool data.json.new >/dev/null 2>&1 || {
    echo "generated data.json is not valid JSON, refusing to publish" >&2
    rm -f data.json.new; exit 1
}
mv data.json.new data.json

# history.json -- the adoption curve. One point per census sample, oldest first.
#
# Deliberately NOT merged into the data.json generator. That one reads a single
# line and must fail hard if it is bad, because it is the live number. This one
# reads the whole file and SKIPS lines it cannot parse, because a series with a
# hole in it is still useful and a torn write halfway down the file should not
# take the site down. The asymmetry is intentional. If nothing parses at all we
# print nothing, which trips the same fail-closed check below.
#
# No percentage is computed here: b2b_reachable ships alongside enforcing so the
# page does the division itself and cannot disagree about the denominator.
python3 - "$CENSUS" "$ENFORCING_JSON" > history.json.new <<'PY'
import json, sys
census, enforcing = sys.argv[1], json.loads(sys.argv[2])
enforcing_set = set(enforcing)

with open(census) as f:
    lines = [l for l in f if l.strip()]
# Trim BEFORE parsing so parse cost stays bounded however long the file grows.
# File order is chronological, so this keeps the 2000 most recent samples and
# preserves oldest -> newest ordering.
lines = lines[-2000:]


def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


points = []
for line in lines:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue
    versions = rec.get("versions")
    if not isinstance(versions, dict):
        versions = {}
    # Applied RETROACTIVELY using the CURRENT enforcing list: every point is
    # scored by today's policy, so the curve is not kinked by the list having
    # been edited partway through the series.
    enforcing_count = sum(as_int(versions.get(ua, 0)) for ua in enforcing_set)
    points.append({
        "ts": as_int(rec.get("ts")),
        "b2b": as_int(rec.get("b2b")),
        "b2b_reachable": as_int(rec.get("b2b_reachable")),
        "max_height": as_int(rec.get("max_height")),
        "enforcing": enforcing_count,
    })

if points:
    sys.stdout.write(json.dumps(points, separators=(",", ":")) + "\n")
PY

if [ ! -s history.json.new ]; then
    echo "history generator produced nothing, refusing to publish" >&2
    rm -f history.json.new
    exit 1
fi
python3 -m json.tool history.json.new >/dev/null 2>&1 || {
    echo "generated history.json is not valid JSON, refusing to publish" >&2
    rm -f history.json.new; exit 1
}
mv history.json.new history.json

# Stable-node list, for people running a curated fixed-list seed. Evidence for a
# human to curate from, not a list to serve unexamined.
DUMP="${DUMP:-/var/lib/dnsseed/dnsseed.dump}"
START="$(date -d "$(systemctl show dnsseed -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)"
if [ -f "$DUMP" ] && command -v seed-stable >/dev/null; then
    if seed-stable "$DUMP" "$START" > stable-nodes.json.new 2>/dev/null \
       && python3 -m json.tool stable-nodes.json.new >/dev/null 2>&1; then
        mv stable-nodes.json.new stable-nodes.json
    else
        echo "stable-nodes generation failed, keeping the previous file" >&2
        rm -f stable-nodes.json.new
    fi
fi

# Stage first, then compare against the index. `git diff` on its own reports no
# change for an UNTRACKED file, so on the very first run a brand new data.json
# would look unchanged and never get committed. history.json goes through the
# same explicit add, so the check below covers it with no extra logic.
#
# One `git add` PER FILE, and only for files that exist. `git add a b c` is
# atomic: if any one pathspec matches nothing it exits 128 and stages NOTHING,
# so a missing stable-nodes.json (first ever run, or a failed seed-stable) used
# to silently drop the validated data.json and history.json too -- and with
# stderr discarded the run then printed "no change since last publish" and
# exited 0 while publishing nothing. `git add --` does not help; the pathspec
# check is per argument. stable-nodes.json is optional; the other two are not,
# and a real staging failure on them exits non-zero rather than being mistaken
# for "nothing changed".
stage_failed=0
for f in data.json history.json; do
    if [ -f "$f" ]; then
        git add -- "$f" || stage_failed=1
    else
        echo "$f missing at stage time, refusing to publish" >&2
        stage_failed=1
    fi
done
if [ -f stable-nodes.json ]; then
    git add -- stable-nodes.json \
        || echo "could not stage stable-nodes.json, continuing without it" >&2
fi
if [ "$stage_failed" -ne 0 ]; then
    exit 1
fi
if git diff --cached --quiet 2>/dev/null; then
    echo "no change since last publish"
    exit 0
fi

git commit --quiet -m "census $(date -u '+%Y-%m-%d %H:%M UTC')"
if git push --quiet origin main; then
    echo "published $(date -u '+%Y-%m-%d %H:%M UTC')"
else
    echo "push failed" >&2
    exit 1
fi
