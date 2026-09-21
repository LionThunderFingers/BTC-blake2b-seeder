# BTC-blake2b-seeder

A DNS seed for the Bitcoin Knots BLAKE2b hardfork, plus a deploy script that sets
one up on a fresh Debian 13 server in a single command.

> ### This is derived work
>
> **The crawler in this repository was written by Pieter Wuille and the
> [bitcoin-seeder](https://github.com/sipa/bitcoin-seeder) contributors, not by me.**
>
> This repository carries their full commit history, which is why GitHub lists
> sipa, luke-jr, jonasschnelli, petertodd and others as contributors here — those
> are the people who actually wrote it. GitHub does not display a "forked from"
> banner because the history was pushed into a fresh repository rather than
> created with the fork button, so this notice takes its place.
>
> My own contribution to the crawler is **146 added and 6 removed lines across 4
> files** — the BLAKE2b service bit and filtering, and a fork-node crawl priority
> queue — plus the `deploy/` directory and this README. Check it with
> `git diff upstream/master -- '*.cpp' '*.h'`, and see
> [What this repository is](#what-this-repository-is) for how to verify that
> yourself against upstream.

---

## There is a live instance

`seed.thelionpool.org` runs this code, on a dedicated VPS in Germany, serving the
BLAKE2b fork. It is **not in any Bitcoin Knots chainparams** and is operated
independently, so nothing reaches it unless you point something at it yourself:

```
dig +short x10000009.seed.thelionpool.org
```

Operating practices, current figures, and a write-up of an outage it had on
2026-09-20 are documented at
<https://lionthunderfingers.github.io/B2B-Node-census/seed/>. Contact:
knots.seed@gmail.com

---

## What a DNS seed is, and why this matters

When a brand-new node starts for the very first time, it has no idea where any
other nodes are. It has never spoken to the network, so it has nothing in its
address book. To get started it asks a small number of hard-coded hostnames for a
list of addresses to try. Those hostnames are **DNS seeds**: tiny special-purpose
DNS servers that continuously crawl the network, keep track of which nodes are
actually reachable and up to date, and hand out a handful of them in response to
an ordinary DNS query.

Once a node has connected to a few peers it learns about the rest of the network
by itself and never needs the seed again. So a DNS seed matters for a few seconds
in a node's life — but those are the seconds without which the node never starts
at all.

The BLAKE2b fork currently relies on what is effectively **one working seed**.
That is a single point of failure and a point of control: if it goes down, is
censored, or starts behaving badly, new nodes joining the fork are affected
immediately and have no alternative to fall back on. Every additional independent
operator — different person, different country, different hosting provider —
makes that problem measurably smaller. That is the entire purpose of this
repository: to make running a seed something an ordinary member of the community
can do in an afternoon.

---

### Checking that for yourself

You do not have to take "effectively one seed" on trust, and the obvious way of
checking it is misleading. A single DNS reply can only carry around 25 addresses
before it runs into the 512-byte limit on a UDP DNS packet, so counting what one
query returns tells you almost nothing about how much a seed knows — every
healthy seed looks roughly the same size.

Asking repeatedly is what separates them. A live crawler holds a large database
and hands out a different random subset each time, so distinct addresses keep
accumulating. A fixed, hand-maintained list returns exactly the same addresses
every time, and the count stops dead.

```
for i in $(seq 1 15); do dig +short x10000009.<seed hostname>; sleep 0.4; done \
  | sort -u | wc -l
```

Measured on 2026-09-18, 15 queries each:

| Seed | Per reply | Distinct over 15 replies |
| --- | --- | --- |
| `seed.thelionpool.org` | 24 | **46** |
| `dnsseed.bitcoin.dashjr-list-of-p2p-nodes.us` | 22 | 22 |
| `seed.bitcoin.haf.ovh` | 25 | 25 |

The two long-standing seeds returned an identical set every single time. They
are curated lists, which is a perfectly reasonable thing to run — Luke's
hostname says as much — but a list only stays accurate while somebody maintains
it by hand, and it cannot notice a node going away. That is the gap another
crawler fills.

---

## What this repository is

This is a fork of [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder),
the crawler used by several of Bitcoin's long-standing DNS seeds, with **one
commit** on top that teaches it about the BLAKE2b fork.

You do not have to take that on trust. Audit it yourself against upstream:

```
git remote add upstream https://github.com/sipa/bitcoin-seeder.git
git fetch upstream
git log --oneline upstream/master..HEAD                 # every commit this fork adds
git diff upstream/master..HEAD -- main.cpp protocol.h   # the C++ changes only
```

The change to the seeder itself is **7 added and 1 removed line across 2 files**
(`protocol.h` and `main.cpp`) — small enough to read in full before you decide
whether to trust a seed running it. Everything else this fork adds is the
`deploy/` directory and this README, which do not affect what the daemon serves.

There are three changes:

1. **A service bit for the fork.** `NODE_BLAKE2B` is defined as bit 28
   (`1 << 28`), and the two sensible fork service-flag combinations are added to
   the seeder's filter whitelist, so clients can ask for them by name
   (`x10000009` and `x10000408`).

2. **Accepting an uppercase `X` prefix.** Service-flag queries look like
   `x10000009.seed.example.org`. Many resolvers use "DNS 0x20" case
   randomisation, which flips the case of letters in the query name at random as
   an anti-spoofing measure. Upstream only matched a lowercase `x`, so a query
   that arrived as `X10000009.…` silently fell through and returned zero records.
   Matching both cases fixes that.

3. **Forcing the BLAKE2b bit on every answer.** A plain query for the bare
   hostname, with no `x…` prefix at all, now has `NODE_BLAKE2B` applied to it
   regardless. This means the seed can only ever return fork nodes. A client that
   queries it without knowing about service flags cannot accidentally be handed a
   list of non-fork peers it will never manage to sync from.

Nothing else is changed. The crawler, the DNS server, the peer database and the
selection logic are upstream's.

---

## Before you start

You will need:

- **A VPS with a public, static IPv4 address.** Not behind NAT, not on a dynamic
  address. The seeder advertises its own address and must be directly reachable
  on UDP port 53.
- **A domain name you control**, and the ability to create **A** and **NS**
  records for it at your registrar or DNS provider. If your provider's control
  panel does not let you create NS records on a subdomain, you cannot run a seed
  there — most do.
- **Debian 13 (trixie)**, which is what the deploy script has been built and
  verified on. It is expected to work on Debian 12 (bookworm) as well, but that
  is untested. It will probably work on Ubuntu, but nobody has checked.

The resource requirements are small. A cheap 1 vCPU / 2 GB instance is plenty.

### Do not run this on your home connection

This is worth stating plainly, because the rest of the setup is easy enough that
it is tempting.

**Do not run a DNS seed on your home internet connection.**

- It publishes your home IP address, permanently and by design. Your seed's
  address ends up in a list that anyone can look up, and eventually in node
  software itself. It is not something you can take back.
- It puts a permanently internet-facing service, on a privileged port, on the
  same connection as whatever else you run at home — your own node, a wallet, a
  miner, your family's devices.
- Home connections have dynamic addresses, and a seed whose address changes is a
  seed that is silently broken.

Use a VPS. They cost a few pounds a month, and that separation is the point.

---

## Installing

On a fresh Debian 13 server, as root or with sudo:

```
apt-get update && apt-get install -y git
git clone https://github.com/LionThunderFingers/BTC-blake2b-seeder.git
cd blake2b-seeder
sudo CONTACT_EMAIL=you@example.com ./deploy/deploy.sh
```

(The first line is only needed because minimal Debian images often ship without
`git`. The deploy script installs everything else it needs itself.)

The script installs build dependencies, compiles the seeder, creates an
unprivileged `dnsseed` system user, installs a hardened systemd unit, sets up a
default-drop nftables firewall with rate limiting, and enables unattended
security upgrades. It is safe to re-run: every step checks the current state
before changing anything.

It deliberately does **not** start the daemon. DNS delegation has to exist first
— see the next section.

### Configuration

Every setting is an environment variable you put in front of the command.

| Variable | Default | What it does |
| --- | --- | --- |
| `CONTACT_EMAIL` | *(none — required)* | Your email address. Published in the zone's SOA record so other operators can reach you about abuse or problems. There is deliberately no default; the script aborts without it. |
| `SEED_HOST` | `seed.thelionpool.org` | The hostname people put in their configuration to use your seed. **You must override this.** |
| `NS_HOST` | `ns-seed.thelionpool.org` | The nameserver name that `SEED_HOST` is delegated to. Must be different from `SEED_HOST`. **You must override this.** |
| `PUBLIC_IP` | auto-detected | The public IPv4 address the seeder binds to and advertises. Detected from the kernel routing table when unset. The script refuses to proceed if the detected address is private or otherwise not globally routable. |
| `SEED_USER` | `dnsseed` | The unprivileged system account the daemon runs as. |
| `CRAWLER_THREADS` | `48` | Number of peer-crawling threads (`dnsseed -t`). They spend nearly all their time waiting on network timeouts rather than using CPU, so this can be higher than the core count. Upstream defaults to 96, which is tuned for the large machines the long-standing Bitcoin seeds run on; 48 is a conservative choice for a small VPS. |
| `DNS_THREADS` | `4` | Number of threads answering DNS queries (`dnsseed -d`). Four is ample — they only parse and reply to small UDP packets. |
| `BOOTSTRAP_SEEDS` | `x10000009.dnsseed.bitcoin.dashjr-list-of-p2p-nodes.us x10000009.seed.bitcoin.haf.ovh` | Space-separated list of existing seeds the crawler starts from. Not optional: the upstream compiled-in list is all non-fork seeds, so without this the crawler warms up on the wrong chain. |
| `HEALTHCHECK_PING_URL` | *(unset)* | A healthchecks.io (or compatible) ping URL. When set, the script installs a systemd timer that checks the seeder every five minutes and pings this URL, so the *absence* of pings is what raises the alarm remotely. Must start with `https://`. Left unset, the monitoring scripts are still installed but no alerting timer is configured. |

**Read this bit twice:** `SEED_HOST` and `NS_HOST` default to *someone else's
domain*. They are there as a worked example of the shape the two names should
take, not as something you should leave alone. If you run the script without
overriding them you will end up with a daemon that is authoritative for a zone
you do not own and that nobody will ever query. A realistic invocation looks
like:

```
sudo CONTACT_EMAIL=you@example.com \
     SEED_HOST=seed.yourdomain.org \
     NS_HOST=ns-seed.yourdomain.org \
     ./deploy/deploy.sh
```

---

## DNS delegation

This is the part that trips people up, so here is what is actually happening.

The seeder **is itself a small authoritative DNS server**. It is not a program
that writes records into a zone file somewhere for BIND to serve; it answers DNS
queries directly, off the top of its head, from its live database of crawled
peers. That is why it binds UDP port 53.

So the job is not "point a hostname at my server". The job is to hand your
seeder **authority over a subdomain**, so that any resolver asking about that
subdomain is told to go and ask your machine directly. That takes two records at
your registrar or DNS provider:

**1. An A record** giving the nameserver a name and an address:

```
Name : ns-seed.yourdomain.org
Type : A
Value: 203.0.113.10          (your VPS's public IP)
TTL  : 3600
```

**2. An NS record** delegating the seed name to that nameserver:

```
Name : seed.yourdomain.org
Type : NS
Value: ns-seed.yourdomain.org
TTL  : 3600
```

Read together, these say: "`seed.yourdomain.org` is not handled here — go and ask
`ns-seed.yourdomain.org`, which lives at 203.0.113.10." Your seeder is the thing
at that address, and it answers.

The two names must be different. `seed.yourdomain.org` is the name being
delegated; `ns-seed.yourdomain.org` is the nameserver it is delegated *to*. They
cannot be the same record.

Some registrars require you to register the A record as a "host record" or "glue
record" for the domain before it will let you use that name as a nameserver
target. If your NS record is rejected, look for that option.

**Put the delegation in place before you start the service.** Propagation takes
anywhere from a few minutes to a few hours depending on the parent zone's TTL,
and until it has happened nobody can reach your seed no matter how well it is
running. The deploy script installs and enables the service but leaves it stopped
for exactly this reason.

---

## Starting and verifying

Once the records are in place and have propagated:

```
sudo systemctl start dnsseed
sudo systemctl status dnsseed
```

Check it directly. These query your host by address, so they work even before
delegation has propagated:

```
dig @203.0.113.10 seed.yourdomain.org +short
dig @203.0.113.10 x10000009.seed.yourdomain.org +short
```

The first returns addresses of crawled fork peers. The second exercises the
service-flag filter: `0x10000009` is
`NODE_NETWORK | NODE_WITNESS | NODE_BLAKE2B`. If the first command returns
addresses but the second returns nothing, the whitelist entry is not in effect —
check you built from this fork and not from upstream.

Once delegation has propagated you can drop the `@` and query normally:

```
dig seed.yourdomain.org +short
```

### Be patient — this is the bit people get wrong

**A brand-new seed starts with an empty database and takes hours to become
useful.** The crawler has to reach out to the bootstrap seeds, connect to the
peers it learns about, verify each one is genuinely reachable and on the right
chain, and only then does it have anything worth handing out. It then has to keep
doing that across the whole network before its answers are representative rather
than a handful of lucky finds.

An empty or very small response in the first minutes after starting is **normal
and expected**. It is not a sign that anything is broken. Leave it running
overnight and check again the next day. Only start investigating if it is still
returning nothing after many hours.

---

## Monitoring your seed

A seed that has quietly stopped working is worse than no seed at all: it stays in
people's configuration, it stays in lists, and it hands out nothing. Two small
scripts ship in `deploy/` to make that situation visible. Both are installed by
the deploy script.

### A snapshot, on demand

`seed-status` gives you the state of the whole thing in one screen. SSH in and
run:

```
sudo seed-status
```

It reports the service state, peer counts, whether any BLAKE2b nodes are
reachable, the client versions it has seen, the uptime trend, how many records
the seed is actually answering with right now, and the host's own CPU, memory
and disk. It is read-only — it reads state and changes nothing.

### The dead-man's switch, and why it is inside out

A monitor running on the seed host cannot tell you that the host died, because it
died too. That is not a detail to be engineered around; it is the whole problem.
So the check is inverted: the host pings out to a remote service on a schedule,
and the **silence** is the alarm. Nothing on your machine has to survive the
failure in order to report it — which is precisely what makes it able to catch
the failure it exists to watch for.

To enable it, sign up for a free account at <https://healthchecks.io>, create a
check, copy its ping URL, and re-run the deploy script with that URL set:

```
HEALTHCHECK_PING_URL=https://hc-ping.com/your-uuid ./deploy/deploy.sh
```

Pass the same `CONTACT_EMAIL`, `SEED_HOST` and `NS_HOST` you used the first time
alongside it — the script re-validates them on every run, and it has no memory of
what you gave it before:

```
sudo CONTACT_EMAIL=you@example.com \
     SEED_HOST=seed.yourdomain.org \
     NS_HOST=ns-seed.yourdomain.org \
     HEALTHCHECK_PING_URL=https://hc-ping.com/your-uuid \
     ./deploy/deploy.sh
```

Re-running is safe. Every step checks the current state first, so an existing,
working seed is left alone and only the monitoring pieces are added.

**Then change two settings on the check itself: set Period to 5 minutes and Grace
to 15 minutes.** The default period is one day, so if you leave it alone a dead
server will not raise an alert for over a day — which defeats the point of
checking every five minutes.

What the switch catches:

- The host is dead, or its network has been cut — the pings simply stop.
- The service has stopped or failed to restart.
- The service is running, but has not updated its peer database for hours.
- The service is running, but is answering with no DNS records at all.
- The service is running and answering, but knows of no reachable BLAKE2b nodes
  — every process green, and the seed still useless.

### It never repairs anything

The monitor deliberately does not restart the seeder, clear its state, or fix
anything else. A monitor that quietly repairs faults hides the problem it exists
to report: the alert never fires, the underlying cause is never found, and you
learn about it only when the self-repair eventually stops working. Its job is to
tell you, and then stop.

### Do not lower the staleness threshold

The health check treats the peer database as stale after **2 hours**. That looks
generous, and it is deliberate. The seeder's dump interval backs off by doubling
— see `ThreadDumper()` in `main.cpp` — and settles at 3200 seconds, which is 53
minutes, permanently. A threshold below that produces false alarms forever, and
an alert you learn to ignore is not an alert.

---

## Running it responsibly

Running a seed means new nodes trust you, briefly, with their first view of the
network. Bitcoin Knots publishes a policy for seed operators, and you are
expected to follow it:

<https://github.com/bitcoinknots/bitcoin/blob/master/doc/dnsseed-policy.md>

In summary:

- **Return a fair selection of functioning nodes.** Your seed should hand out
  nodes chosen fairly from those it has found to be working. Do not filter for or
  against particular groups of nodes, implementations, or operators, and do not
  weight the results to favour anything you have an interest in. The software
  does this correctly out of the box — the obligation is not to undermine it.
- **Never set a DNS TTL below 60 seconds.** Shorter TTLs push load onto the whole
  resolver system for no benefit.
- **Do not log queries beyond operational need.** Query logs are a record of
  which IP addresses are joining the network and when. Do not retain them, and do
  not share them with third parties. If you need logging temporarily to debug
  something, turn it off again afterwards.
- **Keep the host secure.** A compromised seed can feed attacker-controlled peers
  to every new node that asks. Keep the system patched (the deploy script enables
  unattended security upgrades), keep SSH access tight, and do not use the box
  for anything else.
- **Keep control of the seed.** Do not sell, rent, or transfer it, and do not
  hand operational control to someone else. The name may end up compiled into
  node software; whoever controls it inherits that trust.
- **Publish a contact address that actually reaches you** and read what arrives
  there. That is what `CONTACT_EMAIL` is for — it goes into the zone's SOA record
  so people can get hold of you when something is wrong.

If you cannot commit to those things indefinitely, it is better not to run a
seed than to run one badly and then abandon it.

---

## Please use a different provider from everyone else

If five people each run a seed and all five are on the same popular VPS host, in
the same datacentre, that is not five seeds. That is **one seed with five IP
addresses**. One provider outage, one policy change, one account suspension, one
legal order, and all of them disappear at the same moment — which is precisely
the failure the fork is trying to get away from.

Diversity is not a nice-to-have on top of the redundancy. It *is* the redundancy.
Before you pick a host, ask around and find out what other operators are already
using, then deliberately choose something else:

- A different hosting company, ideally a smaller one.
- A different country, and ideally a different legal jurisdiction.
- A different network — check the AS number, not just the brand name. Several
  well-known "different" providers resell capacity on the same underlying
  networks.

A seed on an unglamorous host in an unusual country is worth considerably more to
the network than another one in the same handful of datacentres as everybody
else.

---

## Getting your seed into chainparams

Being listed in the node software's built-in seed list is a **separate step**,
and it is not part of this repository or this script.

It is a trust decision, not a code review. Getting the software running correctly
is necessary but nowhere near sufficient. Maintainers are being asked to point
every new node at a machine they do not control, run by someone they need to have
confidence in. Realistically, that means:

- Running the seed reliably for a good while — months, not days — before asking.
- Being able to show evidence of that: uptime, sensible answers, an address that
  has not changed.
- Being contactable and responsive, and being a known quantity in the community.
- Being willing to keep running it, and to say so plainly if you ever stop.

Nothing about this is automatic, and there is no queue you join by deploying.
Run a good seed, tell people about it so it can actually be used and observed,
and let a track record accumulate.

Your seed is useful from day one regardless. Anyone can point their node at it
manually, and that alone adds real resilience.

---

## Troubleshooting

**Never run `dnsseed --help`.** It does not print help — it starts the crawler.

This is a bug inherited from upstream, not something this fork introduced. In the
option table, `--help` is mapped to the same short option as `-h <host>`, so
`--help` is parsed as "set the hostname", with no value attached. The usage text
is never shown, the check that would have caught the missing hostname does not
fire, and the daemon starts up instead. If you have already installed the systemd
service, you now have a second, unmanaged crawler running as whichever user you
typed the command as.

If you did this, stop it with:

```
sudo pkill -f /usr/local/bin/dnsseed
sudo systemctl restart dnsseed
```

**There is no invocation of this binary that prints help and then stops.** Running
it bare does not either — with no hostname and no nameserver set, the check that
would trigger the usage text never fires, and it starts crawling. Even when the
usage text *is* printed, the code only prints it and carries on into startup; it
never exits. So `dnsseed`, `dnsseed --help` and `dnsseed -Z` all end up running a
crawler.

Every option is documented in this README, so you should not need to ask the
binary. If you want to see its built-in text anyway, put a time limit on it and
run it somewhere disposable so its state files do not land in your home
directory:

```
cd "$(mktemp -d)" && timeout 2 dnsseed -Z 2>&1 | head -30
```

The invalid `-Z` triggers the usage text and `timeout` kills the crawler two
seconds later. This does not disturb an already-running `dnsseed` service.

**The service will not start.** Look at the journal first — it almost always says
exactly what happened:

```
sudo journalctl -u dnsseed -n 100 --no-pager
```

**It exits immediately with no output from the seeder itself.** The systemd unit
is aggressively hardened, and one of the sandboxing directives is the likely
cause. The one most likely to conflict, depending on how your OpenSSL was built,
is:

```
MemoryDenyWriteExecute=true
```

Some OpenSSL builds use write-and-execute JIT pages, which this directive
forbids. Try relaxing that one **first**.

Edit `/etc/systemd/system/dnsseed.service`, change one directive at a time, then:

```
sudo systemctl daemon-reload
sudo systemctl restart dnsseed
```

Change one thing per attempt so you learn which directive is responsible, rather
than dropping all the hardening at once and never finding out. If
`MemoryDenyWriteExecute` is not the culprit, `RestrictAddressFamilies` is the
next thing to try.

Note that the deploy script rewrites this unit file on every run, so any manual
change you make will be overwritten the next time you run it.

**Nothing answers from outside, but `dig @<your-ip>` works locally.** The
delegation is not in place or has not propagated. Check both records at your
registrar and give it time.

**Answers are empty hours after starting.** Check the journal for errors
connecting to the bootstrap seeds, and confirm outbound traffic is not being
blocked by your provider.

---

## Credits

The crawler and DNS server are [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder)
by Pieter Wuille and contributors. This repository adds the BLAKE2b fork support
and the deployment tooling; everything that does the hard work is upstream's.
