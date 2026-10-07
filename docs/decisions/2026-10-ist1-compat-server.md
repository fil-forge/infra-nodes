# A node can run the IST-1 compatibility server as a third Compose project

A node can run the IST-1 compatibility server as an optional third Compose project, `compat`,
beside `platform` and `apps` ([FIL-1402](https://linear.app/filecoin-foundation/issue/FIL-1402)).
It is off unless the node turns it on. The project runs a TLS router that sends each login to one of
32 server shards, with PgBouncer between the server and its database. The database is a second
Aurora cluster in prod central, reached over a site-to-site VPN that ends on the node's host
([infra-central: the compatibility server's database](https://github.com/fil-forge/infra-central/blob/main/docs/decisions/2026-10-compat-server-database.md)).
Nothing in the project stores account tables locally, and nothing in it uses the platform project's
Postgres.

## Turning it on

A node runs the project when its `node.env` sets `COMPAT_ENABLED=true` and its directory has a
`compat/` project:

```
nodes/<node>/compat/
  compose.yml
  versions.env        server, router and PgBouncer images, pinned by digest
  templates/          compat.env.tpl, pgbouncer.ini.tpl, the strongSwan configuration
  config/             PgBouncer's static settings, the RDS CA bundle
```

Reconcile gains a third project. It deploys `compat` when that directory or the shared paths change,
as it does for the other two (`scripts/host/reconcile.sh`, section 3). It does so only on a node
with the flag set, or with a `compat` project still running, so that clearing the flag tears the
project down. A node without the flag never pulls the images, publishes no extra ports and starts
no tunnel. The project joins the per-node convention: it is written for one node, watched there,
and copied to the next.

The server reads its settings under its own variable names. The image maps neutral `COMPAT_*`
variables to those names at start-up, so the files under `nodes/` carry only the neutral names.

## Containers

| Service | Runs | Networks |
|---|---|---|
| `compat-router-storage` | the TLS router for storage logins | `compat` |
| `compat-router-fetch` | the TLS router for fetch logins | `compat` |
| `compat-server` | s6-overlay as PID 1, supervising each shard's storage daemon, fetch daemon, commit process and accounting process, plus one RabbitMQ, one memcached and one redis that every shard shares | `compat` (fixed address), `filone` |
| `compat-pgbouncer` | PgBouncer, the only process that holds connections to the database | `compat` (fixed address) |

At 32 shards the server container supervises 128 long-lived processes, and each commit process
starts up to four short-lived commit workers. The shard list comes from the environment, so the
same image can later run as several containers that each take a slice of the shards.

**The shards share one container.** A shard is a process tree: commit workers are children of the
commit process, the daemons hand commits to it through files under the shard's directory, and every
process reaches the message broker at `localhost`. Containers per process would split nothing that
matters and would need server changes first. The broker, memcached and redis can be shared because
every queue name carries the shard's name and every cache key carries an account's, and each
account lives on one shard. s6 starts the support services before the daemons, reaps orphaned
children, stops services in reverse order and restarts a crashed daemon in about a second. A crash
drops that shard's sessions, and the other shards keep serving.

**The router runs in its own containers.** It comes from a different repository on its own release
cadence, and it alone holds the client-facing TLS key. Packed into the server image, a router fix
would restart every shard and a server bump would restart the only front door. There are two
containers because one router process serves one listener: its listen address, service name and
control port are process-wide settings.

**PgBouncer runs in its own container.** It gives the host one fixed source address to route into
the tunnel, and a server image bump does not drop the pool of connections to the database. Its
transaction pool serves the daemons and commit workers. A small session pool serves the few
connections that hold session state. The routers' lookups go through the transaction pool too. Their
database driver requires TLS by default, so the router containers set `PGSSLMODE=disable` for the
hop on the `compat` network, and `binary_parameters=yes` so each lookup reaches PgBouncer as one
batch and runs on one server connection. That second setting is inferred from the driver's source,
and the lab run checks it.

**One container per shard was the strongest alternative.** It makes server deploys rolling, one
thirty-second of the sessions at a time, and gives per-shard CPU and memory from cAdvisor with no
extra work. It costs a supervisor in every container anyway, a configurable broker address or a
broker per shard, and 32 near-identical services in `compose.yml`, which Compose cannot loop over
and which changing the shard count would rewrite. Because the shard list is environment, splitting
`compat-server` into four containers of eight shards later is a Compose edit with no new image.

## Network and public addresses

Clients dial port 443 for both the storage name and the fetch name, and send no SNI. One listener
cannot tell the two apart, and Caddy already owns port 443 on the node's primary address. The node
therefore needs two more public IPv4 addresses:

| Address | Published to |
|---|---|
| Primary | Caddy on 80 and 443, as today; the node's egress and the VPN's customer gateway |
| Storage | `compat-router-storage`, `<storage address>:443` to its listener |
| Fetch | `compat-router-fetch`, `<fetch address>:443` to its listener |

Caddy binds the primary address only (`default_bind` in the global options), since a wildcard bind
on 443 takes the port on every address. On a node whose host owns Caddy, that setting is the host's.
Where the provider cannot route extra addresses to the host, it can translate two public addresses
on 443 to the primary address on two ports inside the 15000-15999 range Forge services keep to on
shared hosts, and the publish lines change to match. Docker-published ports bypass UFW, so the
publish binding alone decides which address answers. The client names under the two domains point
at the two addresses through records outside this repository.

`compat-server` publishes no ports. The router looks up each login's shard in the database and
dials the address and port it finds there, so the server takes a fixed address on the `compat`
network and each shard takes fixed ports on it, numbered by shard. The routing rows the
server's loader writes name that address and those ports. Each daemon also binds an unused TLS
listener on the same address, because the server binds its plain and TLS listeners to one
interface, so each daemon's TLS listener gets a per-shard port too.

Each shard's admin listeners bind a loopback address of its own, `127.0.1.k`, inside the container.
They do not collide across shards, and no other container, Piri, Ingot and Caddy included, can reach
them. Their callers, the account-management web tier and the billing notices, can reach them only
from inside `compat-server`, so when those callers move onto the node they run as further s6
services in that container. The server also joins `filone` to reach Ingot by name.

## Database, VPN and secrets

The database endpoint, its reader endpoint and the database names are not secret and go in
`node.env`. The databases take neutral names when the cluster is provisioned. PgBouncer connects
with `sslmode=verify-full` against the RDS CA bundle committed under `config/`, as the
infra-central ADR requires. TCP keepalives and a TCP user timeout make a dead WAN connection fail
within a minute, and a short `dns_max_ttl` makes PgBouncer follow the writer endpoint after a
failover. PgBouncer is estimated to hold about 300 connections to the cluster. The infra-central
ADR's 1,000-1,100 is the unpooled count, and either fits under the `db.r8g.large` limit of just
under 1,800. The server's own pools open against PgBouncer on the `compat` network.

The tunnel is host configuration, and the node's side follows the infra-central ADR: strongSwan
with both tunnels up, one xfrm interface per tunnel, a health check that moves the database route
between them, loose reverse-path filtering and a clamped TCP MSS. A private /32 on a dummy interface
is the site's address. Docker's forwarding rules accept all container egress, so a rule in
`DOCKER-USER`, which Docker leaves in place, forwards into the tunnel only from PgBouncer's fixed
address. That traffic is source-NATed to the /32 by a rule placed ahead of Docker's masquerade
rule. No other container can reach the database, Piri and Ingot included.

A provision script, `provision-compat-vpn.sh`, installs this and can be re-run. It also installs a
systemd unit that waits for the node's OpenBao to unseal, renders the pre-shared keys under `/run`
and starts strongSwan, so the tunnel comes back after a reboot with no operator. Reconcile never
changes the tunnel, because a bad tunnel change stops every login and every commit; a tunnel change
is applied by re-running the script by hand.

Secrets live in the node's OpenBao and are rendered into `/run/fil-one/secrets` on each deploy,
like the apps project's (`scripts/host/deploy-apps.sh:40-104`):

| Secret | Source | Read by |
|---|---|---|
| Database role passwords | operator, by hand | `compat-pgbouncer`; the server and the routers authenticate to PgBouncer with the same roles |
| Client-facing certificate and key | operator, by hand | both router containers |
| VPN pre-shared keys | operator, by hand, from the central account's Secrets Manager | strongSwan, through the boot unit |
| Registry pull credential, read-only | operator, by hand | Docker on the host |
| Self-signed pair for the server's unused TLS listeners | generated on the node at provisioning | `compat-server` |
| Ingot S3 credential and the server's tenant identity, which Ingot needs before it accepts the tenant's writes | pending the server's design | `compat-server` |
| Credential for the account key service | pending the server's design | `compat-server` |

Database passwords minted in central have no path into a node's OpenBao yet, so they are copied by
hand until that path exists. The certificate chains to a private CA, which ACME cannot issue, so it
also arrives by hand. The server and router images are private, so the node holds a read-only pull
credential. A node with the project on therefore takes at least four more manual secrets than the
three in the README.

## Volumes and disks

One bind mount from the data volume, `/mnt/fil-one/data/compat`, the literal path style
`apps/compose.yml` uses, holds:

- `shards/<name>/`, one per shard, serving as that shard's scratch root, repository and local path:
  head files, packs under construction, account directories and the commit hand-off queue. Shards
  must not share it, because a commit process runs every pending commit it finds in its directory.
  Moving an account to another shard moves its directory.
- `logs/`, the rotated server logs described under Observability.

Every process sets the server's lease name to one fixed name for the node. The default is the host
name, which under Docker is the container ID. It changes on every recreate and would refuse logins
for a minute or two after each deploy.

The project runs only on a data volume mirrored across two drives. A node turns it on after its
drive layout is confirmed. Ingot acknowledges a PUT once its catalog change is fsynced on the box
and ships the catalog to Forge afterwards, and the server's uploaded transactions exist only on
this volume until they commit. On a striped volume one drive failure would lose acknowledged writes
from both.

As coded, the server writes each uploaded byte to the volume four to five times (estimate), through
its spool, pack construction and Ingot's spool. On read-intensive drives under sustained uploads
that can use the rated endurance in about six months (estimate). The node exports NVMe wear
(`percentage_used` and data units written) and alerts well before the rating. Moving pack
construction onto tmpfs is estimated to halve the writes. Its pages count against
`compat-server`'s `mem_limit`, so it is sized once transaction sizes are measured.

When Ingot or central is unreachable, commits stop and uploads keep landing in `scratch/`. The node
alerts on the data volume's free space and on the size of `scratch/`, so a backlog is seen while
there is still room for it.

## Resource budget

infra-nodes sets no container limits today. The project sets them, because even on a large node an
unbounded server could take memory from Postgres or Ingot. All figures are estimates until a load
run of one shard measures them.

| Consumer | CPU | Memory |
|---|---|---|
| `compat-server`, steady | about one core per busy daemon; Python work in each process runs on one core at a time | 30 GB for commit workers (128 slots at about 230 MB) plus session caches, which scale with open sessions |
| `compat-server`, reconnect storm | every free core for a few minutes, mostly password hashing | as steady |
| `compat-router-*` | about one core each for TLS | about 100 KiB per open connection |
| `compat-pgbouncer` | under one core | under 1 GB |
| Ingot, Piri, Postgres, OpenBao | as today, plus the server's reads and commit PUTs | the remainder |

`compat-server` gets `mem_limit: 240g` to start, set from the load run's per-session RSS with the
per-session cache caps the server reads from its environment. When the limit is reached the kernel
kills a process in the container. RabbitMQ, memcached and redis share that container, and if the
broker dies every shard stops after its retries run out. The run scripts therefore raise
`oom_score_adj` on the daemons and commit workers, which needs no privilege, so the kernel picks a
shard process: s6 restarts it, one shard reconnects and the rest of the node keeps serving. Without
the limit the kernel could pick Postgres or Ingot instead. `compat-server` also gets
`cpu_shares: 512`, half the default weight, so Piri's proving and Postgres stay ahead of it when the
CPU is full. The server and router containers set `ulimits: nofile` high, since each open client
connection holds a descriptor.

A sustained bulk ingest into Ingot competes for the same drives, NIC and CPU, and runs rate-limited
on a node while the server serves.

## Deploys, upgrades and drain

`versions.env` pins the server, router and PgBouncer images by digest. The server and router images
live in a private registry under neutral names. Bumps arrive as pull requests dispatched from the
service repositories, as Piri's and Ingot's do, and reconcile deploys them. The bump workflow
writes the digest only, with no link back to the source pull request.

`deploy-compat.sh` follows `deploy-apps.sh`: render secrets, pull, hash each service's definition
with its mounted files, and recreate only the services that changed. Every recreate in this project
drops client sessions, and a server recreate reconnects every client at once. Each login then
crosses the WAN, so the storm is estimated to last minutes. The script therefore recreates only
inside `COMPAT_DEPLOY_HOURS`, a UTC window in `node.env` set to the quietest hours of measured
traffic. Outside the window it reports the change as deferred, records no revision, and the next
pass in the window applies it. An operator can run it with `--now`.

Before recreating `compat-server`, the script runs the drain command the image carries. The drain
stops the daemons accepting work, waits until no commit worker is running, and then lets the
container stop. A plain stop is unsafe: the commit process and its workers exit on SIGTERM, and a
worker killed mid-PUT leaves a commit to recover. `stop_grace_period` starts at an estimated 15
minutes so a large commit can finish, and the lab run sets the final value. s6-overlay kills every
process about six seconds after the stop signal by default, so the image raises
`S6_SERVICES_GRACETIME` and `S6_KILL_GRACETIME` to match. Whether a commit killed mid-PUT is
resubmitted is unverified, and a lab test kills one before the project is turned on anywhere.

PgBouncer's rendered files go in `/run/fil-one/secrets/compat/pgbouncer/`, mounted as a directory.
The render step replaces files by rename, and a single-file mount would keep the old file, so the
directory mount lets a reload see the new one. A configuration change is then applied with a
reload, which keeps client connections. A router recreate drops only its own listener's sessions.

A platform deploy stops Ingot, and an apps deploy that changes Ingot recreates it. Neither runs in
the compat window. The server's reads and commit PUTs fail until Ingot is back. Whether a commit
worker retries a failed PUT is part of the same lab test.

No scheduled restarts are carried into the project. The router fixes listed below remove the
connection leak that made nightly router restarts necessary. If the daemons need periodic
restarts, s6 restarts one shard at a time inside the running container.

The `compat` revision and the digests of the four containers go to the node's metrics, where the
smoke check compares them with the pins. `publish_node_status` (`scripts/host/lib.sh:902`) is
public and carries only public digests, so it leaves the `compat` project out of its project list.

## Observability

The server image sends every process's log to stdout, which is a server change listed below. s6-log
prefixes each line with the shard and the process, keeps the full lines in `logs/` rotated by size,
and forwards them to the container's output. Alloy labels the containers from their Compose service
names, so `service_name` is `appliance-<stage>-<region>-compat-server` and so on with no change to
the label rules. One added pipeline stage extracts `shard` and `process` from the prefix and drops
account names and client addresses before lines leave the node. On a node whose host owns Alloy,
that stage goes into the host's configuration ([observability](../observability.md)).

cAdvisor reports one series per container. Per-shard CPU and RSS come from a process exporter that
groups processes by the shard name each run script puts on its command line, and per-shard RSS is
the number the memory limit is set from. A PgBouncer exporter ships waiting clients and server
connection errors, which show a slow or broken tunnel before logins time out. The central
`TunnelState` alarm covers the tunnel from the AWS side. An external probe completes a TLS handshake
on both client addresses every minute, offering the protocol versions and cipher suites the
deployed clients use. Each probe holds a router socket for about a minute, which is harmless.

Alerts on the node:

- a shard process restarting more than once in ten minutes, from the process exporter's start times;
- PgBouncer's longest client wait above 5 seconds, with `query_wait_timeout` set well under the
  server's lease margin, so a stuck wait fails one call before it costs the shard its sessions;
- NVMe wear, data volume free space and `scratch/` growth.

## Turning it off

Setting `COMPAT_ENABLED=false` makes the next reconcile, inside or outside the deploy window, drain
the server and run `docker compose down --remove-orphans` for the project. It removes the rendered
compat secrets from `/run/fil-one/secrets` and leaves the OpenBao entries, the data directory and
the tunnel in place. Platform and apps are untouched.

Clients are moved off the two addresses before the switch, or the node accepts that they fail to
connect until they are. After the drain, `scratch/` and the shard directories hold no pending
commits; the operator confirms that before deleting the data directory. Removing the tunnel is an
operator step paired with removing the site in infra-central. The two extra addresses can then be
released, and Caddy's bind setting can stay as it is.

## Work this leaves

- The `compat` project for the first node, `deploy-compat.sh`, and reconcile's third project.
- `provision-compat-vpn.sh`, with the /32, the routes, the `DOCKER-USER` and source-NAT rules, the
  health check and the boot unit.
- Two public addresses and Caddy bound to the primary one, or the provider's translation.
- The server image with s6-overlay, the `COMPAT_*` mapping, the shard-list start-up step, per-shard
  admin and TLS listener addresses, every process logging to stdout, raised s6 grace times,
  `oom_score_adj` in the run scripts and the drain command.
- The router image, with the fixes the server's design lists: the per-connection leak, the deployed
  clients' TLS settings and an in-memory login-to-shard map.
- A private registry for both images, a read-only pull credential, and a bump workflow that writes
  digests only.
- The Alloy stage, the process exporter, the PgBouncer exporter, the NVMe wear export and the
  external probe.
- A lab test that kills a commit worker mid-PUT and fails an Ingot PUT, and checks both commits
  land; the same run checks the routers' lookups on the transaction pool.
