# Set up the database VPN on the prod/us-east-2 appliance

The node reaches its database in central's VPC over two IPsec tunnels to an AWS Site-to-Site VPN.
Central's half, and what the site must provide (a static public IPv4 address, UDP 500, UDP 4500
and ESP open to the two tunnel addresses, a 1,500-byte path MTU), are in infra-central's
[VPN document](https://github.com/fil-forge/infra-central/blob/main/docs/pandora-vpn.md).
`scripts/host/setup-vpn.sh` sets up this node's half: strongSwan with both tunnels up, one xfrm
interface per tunnel (`filone-tun1`, `filone-tun2`), the site's private /32 on the dummy interface
`filone-site`, a route for the VPC's CIDR alone, and the nftables table `filone_vpn`. A health
check every 20 seconds moves the route to the other tunnel when the one carrying it goes down.

This follows the host's bootstrap in
[the prod/us-east-2 appliance's setup](../RUNBOOK.md#the-produs-east-2-appliance-on-ist-1).

## Inputs

Every site-specific value is an input at provisioning time, because this repository is public.
Central's `scripts/fetch-pandora-vpn-secrets.sh --stage prod --site <site> --out <dir>`, run on a
laptop with the stage's AWS credentials, writes most of them to `<dir>/tunnels.env` and the two
keys to `<dir>/psk1` and `<dir>/psk2`. Copy `psk1` and `psk2` to the host's `/run` tmpfs, through
the jump host, readable by root only.

| Input | Where it comes from |
|---|---|
| `VPN_SITE_PUBLIC_ADDRESS` | `CUSTOMER_GATEWAY_IP` in `tunnels.env`; the site's `public_ip` in central's `pandora_sites` |
| `VPN_BEHIND_NAT` | `false` when that address is on the host, `true` when the provider translates it in front of the host. The script checks it against the host's addresses |
| `VPN_SITE_PRIVATE_ADDRESS` | `SITE_PRIVATE_IP` in `tunnels.env`; the site's `private_ip` in `pandora_sites` |
| `VPN_TUNNEL1_OUTSIDE_ADDRESS`, `VPN_TUNNEL2_OUTSIDE_ADDRESS` | `TUNNEL1_ADDRESS` and `TUNNEL2_ADDRESS` in `tunnels.env` |
| `VPN_TUNNEL{1,2}_INSIDE_LOCAL`, `VPN_TUNNEL{1,2}_INSIDE_REMOTE` | the customer gateway's and the virtual private gateway's inside address of each tunnel, in the VPN connection's `CustomerGatewayConfiguration` from `aws ec2 describe-vpn-connections`. The local one takes its prefix, `/30`. See below for pairing them with the right tunnel |
| `VPN_PSK_SOURCE`, `VPN_TUNNEL1_PSK_FILE`, `VPN_TUNNEL2_PSK_FILE` | `files` and the paths of `psk1` and `psk2`; tunnel 1's key belongs to `TUNNEL1_ADDRESS`. Or `openbao`, once the node's OpenBao runs, with the keys stored at `filone/vpn`, fields `tunnel1_psk` and `tunnel2_psk`. Unset, the run keeps the keys already installed |

Each tunnel's inside addresses must be given with that same tunnel's outside address. Tunnel 1 is
the one whose outside address is `TUNNEL1_ADDRESS`, which central reads from the first entry of the
connection's `Options.TunnelOptions`. List each tunnel's outside address beside its inside /30
with:

```sh
aws ec2 describe-vpn-connections \
  --filters Name=tag:Name,Values=<VPN_CONNECTION_NAME from tunnels.env> \
  --query 'VpnConnections[0].Options.TunnelOptions[].[OutsideIpAddress,TunnelInsideCidr]' \
  --output text
```

The line with `TUNNEL1_ADDRESS` gives tunnel 1's /30; both inside addresses come from the
`ipsec_tunnel` element of `CustomerGatewayConfiguration` whose virtual private gateway outside
address is that same address, and the same for tunnel 2. With the pairs swapped the tunnels still
come up, but neither inside address answers, so the health check fails on every run and never fails
over. The status command below prints each tunnel's outside and inside addresses on one line, to be
compared with this listing.

Four more are optional: `VPN_TUNNEL_MTU` (1,446 bytes, or 1,438 behind NAT, unless the site's
path MTU is below 1,500), `VPN_DOCKER_NETWORKS` (the Docker networks whose containers may use the
tunnel, `filone` by default), `VPN_HEALTH_PING` (see below) and `VPN_VPC_CIDR`. The last defaults
to `10.20.192.0/18`, the VPC's side as central's VPN document states it; the script refuses any
other value unless `VPN_VPC_CIDR_OVERRIDE=true` is set as well.

## Provision

With the values in an environment file of your own, kept off the repository, run as root:

```sh
set -a; . /run/vpn-inputs.env; set +a
scripts/host/setup-vpn.sh
```

The script takes the deploy lock first, so a reconcile pass cannot reset the checkout under it,
then the VPN lock, which the health check also takes. It checks every input, then installs
whichever of `charon-systemd`, `strongswan-swanctl` and `libstrongswan-standard-plugins` is
missing, without prompting. On Debian 12 and Ubuntu 24.04 the AES-GCM and DH group 20 and 21
support is in `libstrongswan-standard-plugins`, a recommended package that an install without
recommends leaves out, so the script names it. It then checks strongSwan's unit, UFW, IP
forwarding, the public address against the host's addresses, any existing route for the VPC's
CIDR or a part of it other than the script's own `unreachable` fallback, and that no subnet of
the Docker networks overlaps the VPC's CIDR either way round. A failed check names itself and
changes nothing; a failed input check also installs nothing. It never prints a key.

It then admits UDP 500 and 4500 and ESP from the two tunnel addresses in UFW, and no other address,
and creates the interfaces, the route and the nftables table. Only then does it write the
strongSwan connections and secrets under `/etc/swanctl/conf.d/` (both 0600, root's) and
`/etc/fil-one/vpn.conf`, which the boot unit and the health check read, and restart strongSwan if
its configuration changed. The strongSwan files and `vpn.conf` go in as a set: each is written
beside itself as `<file>.new` first, and each file being replaced is copied beside itself as
`<file>.old`; they are renamed into place only once all are written. A failed write removes the
copies. A failed rename puts back the files renamed before it from their `.old` copies and removes
those the run created, so a reboot before the next run still finds the previous set. Each run and
`down` remove any copies that a run killed on the way left behind. A file whose mode or owner alone has drifted is written again
without a restart. It checks that charon offers the pinned algorithms and has loaded both tunnels,
then enables `filone-vpn.service`, which recreates the interfaces after a boot, and
`filone-vpn-health.timer`. A second run with the same inputs changes nothing.

A run that stops on the way, on a UFW rule it cannot delete or a ruleset `nft` refuses, leaves the
previous strongSwan files and `vpn.conf` in place. Re-run it until it succeeds: the re-run retries
what failed and restarts strongSwan even when the files already match, because the first run left a
marker, `/run/fil-one/vpn-restart-pending`, that only a restart followed by passing algorithm and
connection checks clears. A reboot before a successful re-run starts strongSwan and the interfaces
from the files on disk: the previous configuration when the run stopped before writing them, the
new one after. UFW is the exception. A stopped run may already have removed the old tunnel
addresses' rules, so after such a reboot a tunnel whose address changed stays down until the
re-run. A run that succeeds removes the rules of every address that is not a current tunnel
address, both those `vpn.conf` names and any whose rules carry the script's comment, so an address
a stopped run admitted goes even when the next run names a different one. A configuration
strongSwan itself refuses also stays on disk: each re-run stops at the check that both tunnels
loaded, and the next boot starts strongSwan without them, until a run with corrected inputs
succeeds.

Delete `psk1` and `psk2` after a run that succeeds: strongSwan reads its copy of the keys from
`/etc/swanctl/conf.d/filone-vpn-secrets.conf`, on the OS disk like the node's other tokens. A later
run that changes no key needs neither file: leave `VPN_PSK_SOURCE` and the two key-file inputs
unset, and the script reads the keys back from that file. It does so only while the file's keys
belong to the tunnel addresses given; with new addresses it stops and asks for the new keys. Keep
the inputs file without those three lines, readable by root only, for such re-runs.

## Check the tunnels

```sh
scripts/host/setup-vpn.sh status
```

It prints one line per tunnel with its outside address, its two inside addresses, its interface,
one state that reads `established` only when the IKE SA is established and the child SA installed,
whether AWS's inside address answers through it and whether it carries the route. It then says
whether the nftables table is loaded. It exits non-zero when no
working tunnel carries the route. Then check the path to the database as central's VPN document
describes under "Checking the path". Central's two tunnel alerts stay paused until this site runs
strongSwan; the same document says how to unpause them. Do not run central's host check while this
strongSwan runs: two IKE initiators from one address compete for the same tunnels.

## How container traffic reaches the database

Docker masquerades traffic leaving its bridges, which would give a container's connection whatever
address the kernel picks, and the VPN admits only the site's /32. The `filone_vpn` table therefore
source-NATs everything routed into a tunnel towards the VPC to the /32, in a NAT chain that runs
just before Docker's (priority `srcnat - 10`). The first NAT chain that maps a connection decides
its source, so Docker's masquerade leaves it alone. The table's forward chain lets only the subnets
of `VPN_DOCKER_NETWORKS` into the tunnels, only towards the VPC, and lets nothing in the VPC open a
connection to the node. It also clamps the TCP MSS to the tunnel MTU less 40 in both directions.
The table belongs to the node: Docker and UFW never flush it, and nothing is added to their chains.
The host's own processes use the /32 as the route's source address.

## The health check

The health check calls a tunnel healthy when its child SA is installed and AWS's inside address
answers a ping through it: it sends three, and one reply is enough. When the tunnel carrying the
route is not healthy and the other is, it moves the route, and says so in the journal of
`filone-vpn-health.service`. With both down it leaves the route and fails. Each run also puts back
the VPC route and its `unreachable` fallback if either has gone. A run that finds a provisioning
run or `down` holding the VPN lock skips its turn and says so. If AWS's inside address turns out
not to answer pings, set `VPN_HEALTH_PING=false` and re-run the script; the check then goes on SA
state alone, which notices a dead tunnel only when strongSwan's dead peer detection gives up on it.

## Changes

A change of tunnel addresses or keys, after central's platform root is destroyed and applied
again, is a re-run with the new values, including new `psk1` and `psk2` from a fresh run of
central's fetch script. It removes the UFW rules for the old addresses and restarts
strongSwan, which takes both tunnels down for a few seconds. A re-run with another
`VPN_VPC_CIDR` removes the tunnel and `unreachable` routes it made for the previous one. Reconcile
never changes the tunnel.

## Take the VPN off the node

```sh
scripts/host/setup-vpn.sh down
```

It takes the same two locks, stops and disables the health timer, the boot unit and strongSwan,
deletes the nftables table, removes the tunnel and `unreachable` routes and the three interfaces,
deletes the UFW rules for the tunnel addresses in `vpn.conf` and for any address whose rules carry
the `filone-vpn` comment, and removes any `.new` and `.old` copies a stopped run left, strongSwan's three
files, the ruleset, the restart marker and `vpn.conf`, in that order. It never prints a key. A
second run changes nothing. The packages stay installed, and so do the unit files, which every
node's checkout installs and which do nothing without `vpn.conf`.

## Not yet run against a real gateway

The script and its units are tested only against stubs (`scripts/host/tests/setup-vpn.test.sh`).
Not yet exercised: the package install, IKE and ESP negotiation with AWS using these proposals,
NAT traversal, the rendered swanctl files as strongSwan parses them, the nftables table as `nft`
parses it, the source NAT and MSS clamp on real container traffic, UFW's handling of the
`proto esp` rules, whether AWS's inside address answers pings, failover with real tunnels, `down`,
and the boot unit across a real reboot. The first run on the node is the first test of all of
these, so run it with a session open and with central's tunnel alerts still paused.
