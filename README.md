# BTC-blake2b-seeder

A DNS seed for the Bitcoin Knots BLAKE2b fork, plus a script that sets one up on a fresh Debian 13 VPS.

**I didn't write the crawler.** It's [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder) by Pieter Wuille and contributors, and this repo carries their full history, which is why GitHub lists sipa, luke-jr, jonasschnelli and others as contributors. There's no "forked from" banner because I pushed the history into a new repo instead of using the fork button.

What I added is BLAKE2b support, some fixes I found running it for real, the `deploy/` scripts and this README. I had Claude help me with the code and the scripts, and all of it runs on my own seed.

## The live one

`seed.thelionpool.org` runs this code on a VPS in Germany. It's **not in Knots chainparams**, so nothing uses it unless you point something at it:

```
dig +short x10000009.seed.thelionpool.org
```

How I run it, current numbers, and a write-up of the outage it had on 2026-09-20 are here: <https://lionthunderfingers.github.io/B2B-Node-census/seed/>

There's also a census dashboard built from what the crawler sees: <https://lionthunderfingers.github.io/B2B-Node-census/>

Contact: knots.seed@gmail.com

## Why bother

A new node doesn't know any peers yet, so the first thing it does is ask a few hard-coded DNS seeds for addresses. After it has a few peers it never needs them again... but without them it can't start at all.

Of the 9 mainnet seeds in Knots chainparams, only 2 return BLAKE2b nodes (Luke's and Léo's, checked 2026-09-24). Every extra seed run by a different person, on a different host, makes that less fragile.

## What's different from upstream

Against upstream it's 231 lines added and 15 removed across 4 files (`db.cpp`, `db.h`, `main.cpp`, `protocol.h`). Check it yourself:

```
git remote add upstream https://github.com/sipa/bitcoin-seeder.git
git fetch upstream
git log --oneline upstream/master..HEAD
git diff upstream/master..HEAD -- '*.cpp' '*.h'
```

The changes:

1. **BLAKE2b service bit.** `NODE_BLAKE2B` is bit 28, and `x10000009` and `x10000408` are added to the filter whitelist.
2. **Uppercase `X` works.** Lots of resolvers randomise the case of query names (DNS 0x20). Upstream only matched a lowercase `x`, so `X10000009...` quietly returned nothing.
3. **Only BLAKE2b nodes are ever served**, even for a bare hostname query with no `x` prefix, so a client that doesn't know about service bits can't get handed peers it can't sync from.
4. **Fork nodes get their own crawl queue.** The crawler walks the whole Bitcoin network (around 250k addresses) and fork nodes are a few hundred of them. In one shared queue they weren't re-checked often enough to stay "good", so the seed ended up serving 1 or 2 addresses. Nodes that have proven they advertise BLAKE2b now rotate in a separate queue that gets 5% of the crawl.
5. **`dnsseed.dump` is written to a temp file and renamed**, so scripts reading it never see half a file.
6. **The dump and the saved database include nodes that are mid-test.** The crawler pulls nodes out of the queue in batches while it tests them, and before this fix every dump was missing a different 10 to 15% of nodes.
7. **`dnssets.log`** logs the fork queue size as a fifth column.

## Before you start

You need:

- **A VPS with a static public IPv4 address.** Not behind NAT. The seed has to answer on UDP port 53.
- **A domain you control** where you can create A and NS records.
- **Debian 13.** That's what the deploy script has been run on. Debian 12 and Ubuntu will probably work but I haven't tried them.

A 1 or 2 vCPU / 2 GB VPS is plenty. Mine uses about 80 MB of RAM.

**Don't run it at home.** It publishes your IP address permanently, it's a public service on port 53 sitting on the same connection as everything else in your house, and home IPs change. A VPS is a few quid a month.

## Installing

On a fresh Debian 13 box:

```
apt-get update && apt-get install -y git
git clone https://github.com/LionThunderFingers/BTC-blake2b-seeder.git
cd BTC-blake2b-seeder
sudo CONTACT_EMAIL=you@example.com \
     SEED_HOST=seed.yourdomain.org \
     NS_HOST=ns-seed.yourdomain.org \
     ./deploy/deploy.sh
```

It installs the build dependencies, compiles the seeder, creates a `dnsseed` user, installs a hardened systemd unit, sets up an nftables firewall and turns on unattended security upgrades. It's safe to run again, every step checks first.

It **doesn't start the seed**, because the DNS delegation needs to exist first (next section).

### Settings

All settings are environment variables in front of the command.

| Variable | Default | What it does |
| --- | --- | --- |
| `CONTACT_EMAIL` | required | Goes in the SOA record so other operators can reach you. |
| `SEED_HOST` | required | The name people query, e.g. `seed.yourdomain.org`. |
| `NS_HOST` | required | The nameserver name `SEED_HOST` is delegated to. Must be different from `SEED_HOST`. |
| `PUBLIC_IP` | detected | The IPv4 address to bind to. The script refuses private addresses. |
| `SEED_USER` | `dnsseed` | The account the seed runs as. |
| `CRAWLER_THREADS` | `160` | Crawler threads (`dnsseed -t`). They mostly sit waiting on timeouts to dead addresses, so this can be way above the core count. 48 was too few on my seed and the crawl fell behind. |
| `DNS_THREADS` | `4` | Threads answering DNS queries (`dnsseed -d`). |
| `BOOTSTRAP_SEEDS` | Luke's and Léo's seeds with `x10000009` | Where the crawler starts. The seeds compiled into upstream don't serve the fork, so you need these. |
| `HEALTHCHECK_PING_URL` | unset | A healthchecks.io ping URL. If set, a timer checks the seed every 5 minutes and pings it (see Monitoring). Must start with `https://`. |

There are no defaults for `SEED_HOST` and `NS_HOST` on purpose. They used to default to my seed, so if you missed them you'd end up with a seed for a domain you don't own.

## DNS delegation

The seeder is its own little authoritative DNS server, so you're not pointing a name at your box, you're handing your box authority over a subdomain. That's two records at your registrar:

```
ns-seed.yourdomain.org   A    203.0.113.10          (your VPS IP)
seed.yourdomain.org      NS   ns-seed.yourdomain.org
```

The two names have to be different. Some registrars want the A record registered as a "host" or "glue" record before they'll accept it as an NS target, so look for that if the NS record gets rejected.

Set these up before starting the seed. Propagation can take a few minutes or a few hours.

## Starting and checking it

```
sudo systemctl start dnsseed
dig @203.0.113.10 seed.yourdomain.org +short
dig @203.0.113.10 x10000009.seed.yourdomain.org +short
```

Querying your IP directly works before the delegation has propagated. After it has, `dig seed.yourdomain.org +short` should work from anywhere.

**Give it time.** A new seed starts with an empty database. Getting little or nothing back for the first while is normal... leave it overnight before you start worrying.

### Is it really a live crawler?

One reply only fits about 24 addresses, so a single query doesn't tell you much. Ask it lots of times and a live crawler keeps giving you new addresses, while a fixed list gives you the same ones every time.

Ask your own nameserver directly though. If you go through a normal resolver you're mostly measuring its cache, because the answers have a 3600 second TTL.

```
for i in $(seq 1 15); do
  dig @ns-seed.yourdomain.org +short x10000009.seed.yourdomain.org
  sleep 0.4
done | sort -u | wc -l
```

Mine gave 87 to 102 distinct addresses over 15 queries on 2026-09-22.

## Monitoring

Two scripts get installed with the seed.

**`sudo seed-status`** shows everything on one screen: service state, peer counts, reachable BLAKE2b nodes, client versions, how many records it's answering with, and the box's CPU, memory and disk. It doesn't change anything.

**`seed-healthcheck`** is a dead man's switch. A monitor on the seed box can't tell you the box died, so instead the box pings healthchecks.io every 5 minutes and it's the pings stopping that alerts you. To turn it on, make a free check at <https://healthchecks.io> and re-run the deploy script with the same settings plus the ping URL:

```
sudo CONTACT_EMAIL=you@example.com \
     SEED_HOST=seed.yourdomain.org \
     NS_HOST=ns-seed.yourdomain.org \
     HEALTHCHECK_PING_URL=https://hc-ping.com/your-uuid \
     ./deploy/deploy.sh
```

Then **set the check's Period to 5 minutes and Grace to 15 minutes** on healthchecks.io. The default period is a day, which means a dead seed wouldn't alert you for over a day.

It alerts if the box is down, the service stopped, the dump hasn't been written in 2 hours, it's answering with no records, or it knows no reachable BLAKE2b nodes. It never restarts or fixes anything, on purpose, because a monitor that quietly fixes things hides the problem.

Don't lower the 2 hour limit. The seeder only writes its dump every 53 minutes once it's been running a while, so anything shorter will give false alarms.

## Census and dashboard (optional)

This is the pipeline behind my dashboard. `deploy.sh` doesn't install it, you set it up by hand if you want it.

- `deploy/seed-census.sh` reads `dnsseed.dump` hourly and appends a line to `census.jsonl`: BLAKE2b node counts, client versions, how far behind the tip nodes are, and so on. It only reads the dump.
- `deploy/seed-stable.py` lists the fork nodes that have been reliably reachable.
- `deploy/seed-publish.sh` pushes the newest sample and a trimmed history to a GitHub Pages repo, using a deploy key that can only write to that one repo.
- `deploy/systemd/` has the timers. Install steps are at the top of each unit file.

`seed-publish` needs your repo URL in `/etc/default/seed-publish`. Copy `deploy/seed-publish.default.example` and fill it in. It won't run without it, so it can't end up publishing to mine.

The census only counts what one crawler in Germany can see, so treat the numbers as a sample, not a full count of the network.

## Running it properly

Knots has a policy for seed operators and you should follow it: <https://github.com/bitcoinknots/bitcoin/blob/29.x-knots/doc/dnsseed-policy.md>

The short version:

- Hand out a fair selection of working nodes. The software already does this, just don't mess with it.
- Don't set a TTL below 60 seconds.
- Don't log queries beyond what you need to fix something, and don't share them.
- Keep the box patched and locked down, and don't use it for anything else. A hacked seed can feed bad peers to every new node.
- Don't sell or hand over control of it.
- Use a contact address you actually read.

If you can't keep that up long term it's better not to run one than to run one and abandon it.

### Pick a different host from everyone else

Five seeds on the same provider is really one seed with five IPs. One outage or one account suspension and they all go at once. Ask what other operators are using and pick something else: a different company, a different country, and check the AS number too, because some "different" providers are on the same network underneath.

### Getting into chainparams

That's a separate step and it's up to the maintainers. It's about trust more than code: running reliably for a good while, being contactable, and sticking around. I'm still working out that part myself. Your seed is useful before that anyway, since anyone can point a node at it by hand.

## Troubleshooting

**Don't run `dnsseed --help`.** It doesn't print help, it starts a crawler. That's an upstream bug: `--help` is mapped to the same option as `-h <host>`. Running it bare does the same thing. If you did it by accident:

```
sudo pkill -f /usr/local/bin/dnsseed
sudo systemctl restart dnsseed
```

If you want to see the built-in usage text anyway, run it somewhere throwaway with a time limit:

```
cd "$(mktemp -d)" && timeout 2 dnsseed -Z 2>&1 | head -30
```

**It won't start.** Check the journal first, it usually says why:

```
sudo journalctl -u dnsseed -n 100 --no-pager
```

**It exits straight away with no output from the seeder.** That's probably the systemd sandboxing. Edit `/etc/systemd/system/dnsseed.service` and relax one directive at a time, `RestrictAddressFamilies` first and then `MemoryDenyWriteExecute` (some OpenSSL builds need writable and executable memory). Then `sudo systemctl daemon-reload && sudo systemctl restart dnsseed`. Bear in mind the deploy script rewrites that file every time you run it.

**`dig @your-ip` works but nothing works from outside.** The delegation isn't set up or hasn't propagated yet.

**Still no answers hours later.** Check the journal for errors reaching the bootstrap seeds, and make sure your provider isn't blocking outbound connections.

## Credits

The crawler and DNS server are [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder) by Pieter Wuille and contributors, under the licence in `COPYING`. All the hard work is theirs.
