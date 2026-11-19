# The first production appliance, `prod/us-east-2`, runs on the IST-1 host

`prod/us-east-2` is the first production FilOne appliance. It runs on IST-1, a provider's
bare-metal machine with Ubuntu 26.04, and keeps its state on an encrypted ZFS mirror of the host's
two NVMe drives. It runs one Piri, whose blobs go to the site's disk array over an S3 interface,
and one Ingot. The platform project and the apps are provisioned together.

The node's directory is `nodes/prod/us-east-2`, modelled on `nodes/staging/eu-central-3`, the other
bare-metal node. `scripts/host/bootstrap-prod-us-east-2.sh` prepares the host.

## The region label is a real AWS region name

The node's label is `us-east-2`. The
[initial design](2026-08-initial-design.md#the-region-label-is-us-east-9) gave each appliance a
region name that does not exist in AWS. That rule now applies to non-production stages only, and a
production node carries the real name of its region.

The label is the string Ingot is configured with, the one central registers the node under and the
one a client signs requests with. Piri answers at `piri-0.us-east-2.fil-forge.com` and Ingot at
`s3.us-east-2.filonecontent.com`. Production names carry no stage label.

## The host

Caddy and Alloy run in the node's platform project, as on dev. On staging the host owns both,
because that machine also serves other workloads. Nothing else on IST-1 serves the node's traffic
or ships its telemetry.

SSH reaches the host only through the jump host that infra-central runs, and the provider offers no
out-of-band console. A lost firewall rule for port 22, a broken sshd or a failed jump host
therefore leaves a ticket with the provider as the only way back in. Bootstrap checks that a UFW
rule admits port 22 from the jump host and stops when none does. It never adds, removes or
reorders a firewall rule.

UFW does not filter the ports Docker publishes, so the node's Compose files decide which of them
are reachable. Caddy publishes 80 and 443 on every host address. The host has one public address
today. If it gains a second, both ports must be bound to the public address alone.

## The pool

The two 7.68 TB NVMe drives form one ZFS mirror, a pool named `data` mounted at `/mnt/data`, with
about 6.9 TiB usable. Either drive can fail without losing data or stopping the node. The operating
system stays on its own disk. The node's control and data directories go on the pool, under
`/mnt/data/fil-one`.

| Setting | Value | Why |
|---|---|---|
| Layout | a mirror of both NVMe drives, named by `/dev/disk/by-id` | `nvme0n1`-style names can change between boots |
| `ashift` | 12 | 4 KiB blocks, which suits NVMe; fixed at creation |
| `autotrim` | on | returns freed space to the SSDs |
| `compression` | lz4 | costs almost no CPU and usually saves space |
| `atime` | off | no metadata write on every read |
| `xattr`, `acltype` | `sa`, `posixacl` | the usual settings for Linux |

Ubuntu's ZFS package scrubs the pool on the second Sunday of each month and trims it on the first.

After one drive fails, the pool and the containers keep running. The node therefore reports the
pool's state, its scrub results and its error counters, and central alerts on them, so that
on-call replaces the drive before a second failure loses the pool. `docs/observability.md` lists
the series.

## Encryption

The whole pool is encrypted with ZFS native encryption (`aes-256-gcm`), set on the pool's root
dataset so that everything created on the pool inherits it. The key is 64 hex characters in
`/etc/zfs/keys/data.key` on the OS disk, readable by root only. A copy is kept in the team password
manager, because without the key the pool's data cannot be read and a failed OS disk would take the
only copy with it. The key loads unattended at boot, so the node comes back after a reboot with nobody at
the console.

This protects the data on the NVMe drives when they leave the machine without the OS disk, for
example on a drive return. It does not protect against someone who has the OS disk, the whole
machine or root on it, because the OS disk holds the key and the node's tokens unencrypted.

## Unlocking at boot

Ubuntu 26.04, with ZFS 2.4, ships `zfs-load-key.service` masked, so nothing loads a key file at boot on its own. A
local unit, `zfs-load-key-data.service`, loads the key before `zfs-mount.service` mounts
the pool.

Docker must not start the containers before the pool is mounted, or Postgres would initialise a
new, empty cluster on the OS disk. Two checks prevent that. The node's Compose files set
`create_host_path: false` on every bind, so a container fails to start when its directory is
missing ([#252](https://github.com/fil-forge/infra-nodes/pull/252)). That check passes when a
dataset is unmounted but its mount point still exists as an empty directory in the dataset above
it. So a drop-in for `docker.service` also makes Docker wait for `zfs-mount.service` and refuse to
start while the pool is missing or any dataset on it is unmounted. Once the pool is fixed,
`systemctl reset-failed docker.service docker.socket` clears the failed starts so Docker can start
again.

The bootstrap script's test also fails when a bind under `/mnt` in the node's Compose files lies
outside the datasets bootstrap creates.

## The checkout

The node's checkout of this repository is at `/opt/fil-one/infra-nodes` on the OS disk, the path
the cloud nodes use. The node's bootstrap refuses to run from anywhere else.

The checkout holds no state. Secrets are rendered to a tmpfs, the node's state is on the pool, and
the repository is public, so the pool's encryption and redundancy protect nothing in it. On the OS
disk the scripts are still there when the pool is locked or missing, which on a host with no
console is when the person repairing it needs them. A lost OS disk takes the pool's key file, the
node's configuration under `/etc` and the systemd units with it, so bootstrap runs again either
way, and cloning again is one command.

A checkout on the pool would also need a dataset of its own, created by hand before the bootstrap
that creates the datasets: bootstrap gives `data/fil-one` the mount point `/mnt/data/fil-one`,
the directory a checkout cloned below that path would already occupy.

## Datasets

The pool is created with its root dataset only. Bootstrap creates one dataset under `data/fil-one`
for each kind of state, mounted at the same path under `/mnt/data/fil-one`, following the fast pool
layout in the
[appliance layout RFC](https://github.com/fil-one/RFC/blob/f0a3e7ad24a4a946cc05838bcce9a05a3bc84ba6/rfcs/2026-10-appliance-layout-and-disaster-recovery.md#fast-pool).

| Dataset | Holds | Size |
|---|---|---|
| `control/postgres` | the Postgres cluster | reservation, 20% of the pool |
| `control/openbao` | OpenBao's raft store | reservation, 10 GiB |
| `control/state` | reconcile's state, the node's status document and the deploy metrics | quota, 50 GiB |
| `control/caddy` | Caddy's certificates and ACME account keys | quota, 1 GiB |
| `control/alloy` | the write-ahead log Alloy buffers telemetry in | quota, 10 GiB |
| `piri` | what `piri init` writes and Piri's rendered config | quota, 50 GiB |
| `ingot/segments` | Ingot's segments | quota, 5% of the pool |
| `ingot/blobs` | Ingot's spool and cache | quota, 50% of the pool |

A reservation keeps space for Postgres and OpenBao however full the rest of the pool gets. A quota
stops one kind of state from growing into the space the others share. The quotas of
`control/caddy` and `control/alloy` are a first guess, to be corrected once the node has run.

Ingot's byte budget for its spool and cache, `INGOT_LOCAL_BLOB_MAX_BYTES`, is 80% of the
`ingot/blobs` quota. Request bodies in flight are written above the budget and need room there, and
central pages when an Ingot volume has less than 10% free. Bootstrap prints the value, and
`node.env` commits it.

## Bootstrap changes nothing it did not create

`scripts/host/bootstrap-prod-us-east-2.sh` first checks the host against this record: the pool, its
encryption and key file, the key unit, the Docker drop-in and the SSH rule. A failed check names
itself and stops the run before anything changes.

An existing dataset whose reservation, quota or mount point differs from the table above is
reported and left alone, and so is an existing `/etc/docker/daemon.json` that differs from the log
rotation bootstrap would write. A smaller quota on a dataset that holds data, or a Docker restart
under running containers, is not a change to apply unattended. A second run changes nothing.

## Platform services

**Postgres is `postgres:18-bookworm`.** Dev and staging run `postgres:16-alpine`. A node with no
data yet starts on 18 so that it needs no major-version upgrade for a while, and so that it matches
Pandora's move to 18. The image is Debian's because a cluster's sort order depends on the image's
libc, and Alpine's musl is what dev and staging are moving away from. PostgreSQL 18 turns data
checksums on by default and keeps its cluster one directory per major version below the directory
the node binds, so a later version can be initialised beside this one. Nothing else in the fleet
has run 18, so Piri's and Ingot's migrations first meet it on this node.

**The four platform images are pinned by digest.** OpenBao, Postgres, Caddy and Alloy each carry
`tag@sha256:…` in `platform/versions.env`. A tag can move to another image and a digest cannot, so
production runs only an image someone reviewed. Nothing bumps the pins automatically: a new one is
a hand edit, reviewed like any other change to the node.

**The node takes backups.** `FILONE_TAKES_BACKUPS=true`, as on staging: provisioning stores the
access key for central's production backup bucket and uploads the first OpenBao snapshot, and a
timer takes one daily from then on. The dev node takes none.

## Piri keeps its blobs on the site's disk array

IST-1's storage is a disk array of many petabytes that the site exposes over an S3 interface. Piri
therefore uses its S3 blob backend, and the node runs one Piri. Because the blobs are not on the
pool, the `piri` dataset holds only Piri's configuration and can be small.

The endpoint and the bucket prefix are in `node.env`, and the credentials come from OpenBao.
`deploy-apps.sh` refuses to start a Piri while any of them is missing. `piri init` copies the
credentials into the config file it writes on the `piri` dataset, which the pool's encryption
covers.

## Chain, telemetry and tests

The node runs on the Calibration testnet, as central's production stage does for now. It pushes
logs, metrics and traces to the one Grafana Cloud stack every appliance reports to.

GitHub CI runs the smoke test against the node as it does for dev and staging. The end-to-end test
does not run for the production stage until it has a credential that cannot reach customer tenants
(FIL-1491).

## The database VPN

A service on the node reaches a database in central's VPC over two IPsec tunnels to central's AWS
Site-to-Site VPN. `scripts/host/setup-vpn.sh` builds the node's half: strongSwan, one route for the
database's network alone, and a health check that moves the route to the other tunnel when one
goes down. UFW gains rules only for the two tunnel endpoints, and traffic arriving through a tunnel
is dropped unless it answers a connection the node opened. Every site-specific value is an input at
provisioning time, because this repository is public.

## The import service

The import service runs as a Compose service of its own in the node's apps project and reaches its
ledger database through the VPN. It publishes one port, which an nftables table of the node's own
admits only from a list of client addresses kept on the host. With an empty list the port is closed
to everyone. `scripts/host/deploy-import.sh` deploys it apart from Piri and Ingot and leaves it
stopped while any of its settings is still a placeholder.

## Not decided yet

- **The Postgres locale.** The node sets no `POSTGRES_INITDB_ARGS`, so the cluster would get the
  image's default locale. The alternative is PostgreSQL's builtin provider
  (`--locale-provider=builtin --builtin-locale=C.UTF-8`), with which sort order never depends on
  the image's libc. The locale is fixed at `initdb`, so this has to be settled before
  `provision-platform.sh` first runs on the host.
- **The import service's key store.** The service takes an HTTP(S) URL for the key store its pack
  keys derive from. The node's OpenBao listens only on loopback inside its container and on a unix
  socket. Either OpenBao gains a listener the Docker network can reach, or the service learns to
  use a socket.
- **The jump host's address.** Bootstrap reads it from `JUMP_HOST_ADDRESS` at run time because this
  repository is public. Committing it would remove an input the operator can get wrong.
- **OpenBao's store directory.** The store is the `control/openbao` dataset's own mount point, so
  a damaged store cannot be renamed aside and is copied aside and emptied. A store one directory
  below the mount point could be renamed, as on dev and staging.

## Setting up the pool

As root, after checking with `wipefs -n` that both drives are blank:

```sh
apt install -y zfsutils-linux

install -d -m 700 /etc/zfs/keys
(umask 077; openssl rand -hex 32 | tr -d '\n' > /etc/zfs/keys/data.key)
cat /etc/zfs/keys/data.key; echo   # copy into the password manager now

zpool create -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
  -O encryption=aes-256-gcm -O keyformat=hex -O keylocation=file:///etc/zfs/keys/data.key \
  -O mountpoint=/mnt/data \
  data mirror /dev/disk/by-id/nvme-<first drive> /dev/disk/by-id/nvme-<second drive>
```

The key unit, `/etc/systemd/system/zfs-load-key-data.service`:

```ini
[Unit]
Description=Load the ZFS encryption key for the data pool
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'zfs get -H -o value keystatus data | grep -qx available || zfs load-key data'

[Install]
WantedBy=zfs-mount.service
```

The Docker drop-in, `/etc/systemd/system/docker.service.d/10-zfs-mounted.conf`:

```ini
[Unit]
Wants=zfs-mount.service
After=zfs-mount.service

[Service]
ExecStartPre=/bin/sh -c 'zfs list -H -o name data >/dev/null && ! zfs get -H -r -t filesystem -o value mounted data | grep -vqx yes'
```

```sh
systemctl daemon-reload
systemctl enable zfs-load-key-data.service
```

Before anything writes to the pool, check that the key loads from the file. Exporting and
re-importing the pool leaves it as it is at boot, locked and unmounted:

```sh
zpool export data
zpool import data
systemctl restart zfs-load-key-data.service zfs-mount.service
zfs get -r -t filesystem keystatus,mounted data   # available, yes
```

A reboot at a quiet moment confirms the boot order.
