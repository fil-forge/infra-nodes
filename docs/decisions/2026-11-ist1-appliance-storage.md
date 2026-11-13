# The IST-1 appliance stores its state on an encrypted ZFS mirror

The IST-1 appliance's two 7.68 TB NVMe drives form one ZFS mirror, a pool named `data` mounted at
`/mnt/data`, with about 6.9 TiB usable. Either drive can fail without losing data or stopping the
node. The operating system stays on its own disk. The node's control and data directories go on the
pool; `/mnt/data/fil-one/control` and `/mnt/data/fil-one/data` match staging.

## The pool

| Setting | Value | Why |
|---|---|---|
| Layout | a mirror of both NVMe drives, named by `/dev/disk/by-id` | `nvme0n1`-style names can change between boots |
| `ashift` | 12 | 4 KiB blocks, which suits NVMe; fixed at creation |
| `autotrim` | on | returns freed space to the SSDs |
| `compression` | lz4 | costs almost no CPU and usually saves space |
| `atime` | off | no metadata write on every read |
| `xattr`, `acltype` | `sa`, `posixacl` | the usual settings for Linux |

Ubuntu's ZFS package scrubs the pool on the second Sunday of each month and trims it on the first.

## Encryption

The whole pool is encrypted with ZFS native encryption (`aes-256-gcm`), set on the pool's root
dataset so that everything created on the pool inherits it. The key is 64 hex characters in
`/etc/zfs/keys/data.key` on the OS disk, readable by root only, and a copy is kept in the team
password manager. The pool unlocks unattended at boot, which the node's timers and restart policies
need.

This protects the data on drives that leave the machine, for example on a return or at disposal,
which is the protection EBS encryption gives the EC2 nodes. It does not protect against someone who
has the whole machine or root on it, since the key sits beside the drives. Without the key the pool
cannot be read, so the password manager's copy is what makes a failed OS disk recoverable.

## Unlocking at boot

Ubuntu 24.04 ships `zfs-load-key.service` masked, so nothing loads a key file at boot on its own. A
unit of the host's own, `zfs-load-key-data.service`, loads the key before `zfs-mount.service` mounts
the pool.

Docker must not start the containers before the pool is mounted. If it did, each bind mount would
land in the empty directory under `/mnt/data` on the OS disk, and Postgres, for one, would create a
new, empty cluster there. A drop-in for `docker.service` makes Docker wait for `zfs-mount.service`
and refuse to start while any dataset on the pool is unmounted.

## Setting it up

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
Requires=zfs-mount.service
After=zfs-mount.service

[Service]
ExecStartPre=/bin/sh -c '! zfs get -H -r -t filesystem -o value mounted data | grep -vqx yes'
```

```sh
systemctl daemon-reload
systemctl enable zfs-load-key-data.service
```

Then reboot and check, before anything writes to the pool:

```sh
zpool status data
zfs get -r -t filesystem keystatus,mounted data
systemctl status zfs-load-key-data.service --no-pager
```
