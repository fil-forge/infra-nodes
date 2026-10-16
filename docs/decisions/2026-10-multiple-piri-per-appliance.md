# An appliance runs one Piri per storage volume

Production appliances attach several storage volumes to one machine. Each volume gets its own Piri,
and one Ingot serves them all. Dev and staging run three Piris each, so this setup is tested against
the current Forge version before production runs it (FIL-1503).

## Names

A Piri is named `piri-<n>`, where `<n>` counts from 0 within the appliance. Hilt keeps one regional
provider, Ingot, per region, so an appliance and a region are one-to-one and the index is unique in
the region too. In production `piri-<n>` serves storage volume `<n>`.

The public hostname is `piri-<n>.<region>.<stage suffix>`:

- `piri-0.us-east-9.latest.dev.fil-forge.com`
- `piri-0.eu-central-3.staging.fil-forge.com`

The region label is in the hostname for two reasons. RFC 16 used to number Piris within the stage
suffix (`piri-0.staging.fil-forge.com`), so two regions in one stage would both have a `piri-0`.
And the region in the address says which appliance a Piri belongs to, as it already does for Ingot
(`s3.<region>.<content suffix>`). [fil-one/RFC#35](https://github.com/fil-one/RFC/pull/35) amends
RFC 16 to match.

`node.env` carries one `PIRI_HOSTNAME_SUFFIX`, `<region>.<stage suffix>`. Compose, Caddy, the host
scripts and the smoke test build `piri-<n>.$PIRI_HOSTNAME_SUFFIX` from it.

Every name on the box is the same `piri-<n>`: the compose service, the container (`filone-piri-<n>`),
the OpenBao path, the data directory, the secret files and, on dev, the EBS volume and its mount
point. The region is not repeated there, because the box serves one region and every stream it
ships already carries a `region` label. The one exception is the Postgres database, `piri_<n>`, so a
one-off query needs no quoting.

A name derived from the DID (`piri-<last characters of the DID>`) would rename a Piri whenever its
key changes, which suits "a new key is a new Piri". It was rejected because the name has to exist
before the key does: Terraform creates the DNS records and volumes, and compose names the services,
before `keygen.sh` runs on the node. It also loses the tie between a Piri and its volume.

## Identities, wallets and databases

Each Piri has its own key, DID, sprue proof and owner wallet, at OpenBao path `piri-<n>`. The
`ServiceProviderRegistry` contract allows one provider per address, so Piris sharing a wallet would
share one on-chain provider. Three processes sending from one address would also race for nonces,
because each Piri's Curio coordinates nonces only within its own database.

Each Piri has its own Postgres database. Piri uses fixed schema names (`curio`, `replicator`,
`egress_tracker`), so two Piris cannot share one. One role, `piri`, owns all three databases, as in
Smelt.

## Writes

Ingot sends every upload to sprue, and sprue picks the Piri. It chooses at random, weighted, among
the candidates in the region's hilt routing policy. infra-central records each Piri onboarded for a
region and sends hilt the whole set, so onboarding three Piris at weight 100 gives each about a
third of uploads by count. Choosing Piris by bytes or free space would need new code in sprue.
Replicas ignore the routing policy and can land on any Piri in the stage.

## Storage

On dev each Piri has its own EBS volume, mounted at `/mnt/fil-one/piri-<n>`, and the data volume
keeps Ingot. Dev is therefore where per-volume disk alerts can be tested. Staging keeps one data
disk with a `piri-<n>` directory per Piri until the bare-metal host is reconfigured.

## Compose and deploys

Each node's compose file writes out `piri-0`, `piri-1` and `piri-2`, sharing an `x-piri-base`
anchor, and all three share one `PIRI_IMAGE` pin. `piri-<n>` waits for `piri-<n-1>` to be
healthy before it starts. Without that ordering, concurrent gas estimation underestimates gas and
`createDataSet` reverts out of gas ([storacha/piri#466](https://github.com/storacha/piri/issues/466)).

The host scripts read the list of Piris from compose instead of naming them. An apps deploy
recreates changed Piris one at a time, each behind its own PDP gate. A platform deploy restarts
Postgres under all Piris, so it waits until all Piris report a safe proving window.

Every Piri hostname serves the status document at `/.well-known/filone-node-status.json`, and the
smoke test checks `/readyz` and the status document on each.

## Telemetry

All Piris are one service with multiple instances, following the OpenTelemetry conventions:
`service.name` stays `piri`, and `service_name` stays `appliance-<stage>-<region>-piri` on logs and
metrics alike. `service.instance.id` tells them apart. Each Piri sets it to
`<FILONE_NODE>/piri-<n>`, for example `staging/eu-central-3/piri-0`, through
`OTEL_RESOURCE_ATTRIBUTES` ([fil-forge/piri#173](https://github.com/fil-forge/piri/pull/173)).
Alloy maps it to `instance` and no longer overwrites `instance` with the node name. Logs from a Piri
container carry the same `instance`. Until a Piri image with that change reaches a node, `instance`
is the Piri's DID.

## Moving from one Piri

Both nodes reset their apps when they move to three Piris, and Forge central resets its apps for
the stage at the same time. On the node, `scripts/host/reset-apps.sh` drops the Ingot and Piri
databases and empties their data directories, staging's import runs included. At central,
`make reset-apps` empties sprue, hilt, swarf and plc, the delegator's allow list and the recorded
Piri DIDs. The stage's tenants, buckets and stored objects are gone afterwards, and FilOne's
tenants for the region are reset to match.

The node's identity survives the reset:

- OpenBao, which holds the region key, Ingot's identity and the link to Forge central
- hilt's delegation to Ingot, which still verifies, because neither hilt's key nor the Ingot DID
  changes
- piri-0's key and funded wallet, copied from OpenBao path `piri` to `piri-0`, so piri-0 keeps its
  DID and on-chain provider ID

sprue is empty after the reset, so all three Piris are onboarded from scratch, piri-0 at its new
URL. Each Piri creates a new proof set when it first starts. piri-0's old data set faults and is
left to fault, with about 0.9 USDFC of the payer's lockup stranded in it. Piri's on-chain
registration carries only its DID and is found again by wallet address, so nothing else changes on
chain.
