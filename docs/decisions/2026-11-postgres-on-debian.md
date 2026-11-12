# Postgres runs on the Debian image

The nodes ran `postgres:16-alpine`. They move to `postgres:16-bookworm`, and each node's cluster
moves into a new data directory by a dump and restore, for FIL-1599's WAL archive.

## Why Debian

WAL-G v3.0.9 publishes its Postgres builds for Ubuntu releases only, with no static or musl build.
`wal-g-pg-22.04-amd64` is dynamically linked and needs glibc 2.34; in the Alpine image, whose C
library is musl, it does not start. `archive_command` runs inside the Postgres container, and so
does `restore_command` during a point-in-time restore, so the image has to be one WAL-G runs in.
WAL-G will be a binary on the host, pinned the way the node pins its other tools and mounted into
the container.

The other way was to keep Alpine and build WAL-G for musl ourselves, in this repository's CI or in
an image of our own. That makes this repository the builder and publisher of the tool every restore
depends on, where today it builds nothing.

## Why a dump and not the same data directory

Both images initialise a cluster with `en_US.utf8` under the libc locale provider. musl sorts that
locale in byte order, and glibc sorts it by language:

| | `ORDER BY` on `a B _x Z b a-b ab` |
|---|---|
| Alpine (musl) | `B Z _x a a-b ab b` |
| Debian (glibc) | `a a-b ab b B _x Z` |

A text index built under one order is wrong under the other. Tried on a test cluster: the Debian
image started on an Alpine data directory without a complaint, an index lookup then missed a row a
sequential scan found, and `amcheck` reported a violated invariant. Postgres cannot warn, because it
detects a collation change by comparing versions and musl reports none.

The new cluster is initialised with `C.UTF-8`, which glibc sorts by code point: the same order musl
gave, so nothing that sorts text in SQL sees a change. A `REINDEX` in place would have kept
`en_US.utf8`, and with it changed the order every such query returns.

## How a node moves

`versions.env` states the image and the data directory together, since the one decides what the
other may hold. The directory is `postgres-glibc`, beside the old `postgres` in the control
directory. Once a node's checkout names the new pair, `deploy-platform.sh` refuses to run until
`migrate-postgres-to-debian.sh` has moved the data, so a merge cannot start an empty cluster under
the apps. The script dumps every database, restores it into the new cluster, compares every table's
row count, and leaves the old directory as the way back. If a step fails after the old cluster
stopped, it starts the old cluster again. The runbook has the procedure.

Dev moves first, then staging. Both have to move before FIL-1600's standby is cloned from the
primary: a physical standby, and a cluster restored from WAL-G's base backups, have to run the
same C library as the primary they came from, for the same reason.
