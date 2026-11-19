# Set up the import service on the prod/us-east-2 appliance

This follows the host's bootstrap in
[the prod/us-east-2 appliance's setup](../RUNBOOK.md#the-produs-east-2-appliance-on-ist-1).

The import service is the `import-service` service in `nodes/prod/us-east-2/apps/compose.yml`.
`scripts/host/deploy-import.sh` deploys it, run last by every apps deploy and retried on its own by
reconcile while it is failing. Until every one of its settings is filled in, that script names the
ones left, starts nothing, removes a container an earlier deploy left, and lets the rest of the
apps deploy as usual. Removing that container fires central's "Appliance container is not running"
alert for `import-service`, which stays on until it is silenced or the service is deployed again,
so silence it before setting a value back to `PLACEHOLDER` on purpose. Bring the service up after
[the database VPN](set-up-database-vpn.md) and after
[the apps](../RUNBOOK.md#6-onboarding-then-the-apps), since it needs both: its ledger is in
central's VPC, and it reads packs back from Ingot.

How it is wired:

- **Its own mutual TLS.** The client certificate's common name is the key of its allow-list and of
  every record it writes, so it terminates TLS itself and Caddy stays out of its path. Its port is
  published on IPv4 alone, on `IMPORT_SERVICE_PORT` (8443).
- **No second port for Ingot.** Caddy already publishes Ingot on 443 at every host address, under
  `INGOT_HOSTNAME` with a certificate it obtains itself, and nothing on the host filters that
  port. Clients upload their packs there like any S3 client, path-style.
- **The filone network.** The VPN's table source-NATs the filone network's traffic
  into the tunnels, so the service reaches the ledger from there, and it reaches Ingot at
  `http://ingot:9000` as rag-engine does on staging. The service refuses to listen on the wildcard
  address, so `deploy-import.sh` gives it the last usable address of the network's subnet and stops
  if another container holds that address.
- **The firewall.** UFW does not filter a port Docker publishes. `scripts/host/import-firewall.sh`
  loads the nftables table `filone_import`, which drops every connection Docker translated to the
  service's port unless it comes from an address in `/etc/fil-one/import-clients`. An empty or
  missing list closes the port to everyone. `deploy-import.sh` applies the list on every run, before
  it starts the service. After a reboot the service cannot start until that deploy renders its
  certificates. Once the service has come up, every reconcile pass applies the list as well, so a
  table flushed or deleted by hand is back within five minutes.

## Settings and secrets

Its settings:

| Setting | Where | Value |
|---|---|---|
| `IMPORT_SERVICE_IMAGE` | `apps/versions.env` | `<image>:<release tag>@sha256:<digest>`, from the release notes of the repository that publishes it |
| `IMPORT_SERVICE_ALLOWED_CLIENTS` | `node.env` | the client certificates' common names, comma-separated. This repository is public, so the names must say nothing about a client but which one it is |
| `IMPORT_SERVICE_LEASE_HOLDER` | `node.env` | the site's name in its serving leases |
| `IMPORT_SERVICE_S3_BUCKET`, `IMPORT_SERVICE_S3_PREFIX` | `node.env` | the Ingot bucket the clients upload packs to, and its key prefix if any |
| `IMPORT_SERVICE_RECOVERY_PUBLIC_KEY` | `node.env` | the estate recovery public key, hex |
| the client addresses | `/etc/fil-one/import-clients` on the host | the source IPv4 addresses or networks of the clients, one per line |

Its secrets, in the node's OpenBao at `filone/import-service`:

| Field | What |
|---|---|
| `tls_cert`, `tls_key` | the service's certificate, with its chain, and its key, PEM |
| `client_ca` | the CA that signs the clients' certificates, PEM |
| `ledger_dsn` | the ledger's libpq DSN, without a password. `deploy-import.sh` refuses one that carries a password |
| `ledger_password` | the ledger role's password, which goes into a libpq password file |
| `s3_access_key_id`, `s3_secret_key` | the Ingot access key the service reads packs with |
| `site_secret` | the site secret every pack's keys derive from, base64. `deploy-import.sh` refuses a value that is not base64 or that decodes to fewer than 32 bytes once surrounding whitespace is stripped |
| `registry_username`, `registry_token` | a read-only pull credential for the image's private registry |

The site secret lives in the node's OpenBao and on no persistent disk. Every deploy renders it, as
the bytes the base64 decodes to, into a memory-backed file the service reads once at start.
Every pack the service accepts is sealed under keys derived from it, so replacing it once packs
exist makes them unreadable. Write it once, before the first import, and never again.

No value may hold a quote or a line break, except the PEMs. Store them with the `bao_exec` helper
defined under
[the eu-central-3 staging appliance](../RUNBOOK.md#the-eu-central-3-staging-appliance-on-serverscom),
`put` for the first field and `patch` for the rest, each from a root-only file or from a prompt so
no value lands in the shell's history:

```sh
bao_exec kv put -mount=filone import-service tls_cert=- <server.pem
bao_exec kv patch -mount=filone import-service tls_key=- <server-key.pem
bao_exec kv patch -mount=filone import-service client_ca=- <client-ca.pem
read -rsp 'ledger password: ' value; echo
bao_exec kv patch -mount=filone import-service ledger_password=- <<<"$value"
# ... and the same for each remaining field but site_secret
unset value
```

Store the site secret the clients seal their packs under. Copy its file to the host's `/run`
tmpfs through the jump host, readable by root only, then write it only if the field is still
empty, and remove the copy:

```sh
if bao_exec kv get -mount=filone -field=site_secret import-service >/dev/null 2>&1; then
  echo 'site_secret is already stored; leave it'
else
  base64 -w 0 </run/site-secret | bao_exec kv patch -mount=filone import-service site_secret=-
fi
rm /run/site-secret
```

`deploy-import.sh` renders the files, the site secret's included, into
`/run/fil-one/secrets/import-service/`, owned by the service's user (uid 10001) and read-only,
and the rest into `/run/fil-one/secrets/import-service.env`, root-only. It pulls the image only
when the host does not have it, logging in through a Docker configuration directory on the same
tmpfs that it removes after the pull, so no registry credential is left on the disk.

## The client list

Write the client list, then load it and check it:

```sh
install -m 0600 /dev/null /etc/fil-one/import-clients   # once
"${EDITOR:-vi}" /etc/fil-one/import-clients             # one address or network per line
scripts/host/import-firewall.sh
scripts/host/import-firewall.sh status
```

The script refuses a line that is not an IPv4 address or a network with no host bits set, an entry
that overlaps another, and `0.0.0.0/0`, and a refused list changes nothing. It replaces the whole
table in one load, so an address taken off the list loses its access, open connections included.
It touches no other table and no UFW rule. A second run with the same list loads nothing.

The table filters only what reaches the host. When the provider runs a firewall or translates the
host's address in front of it, as `VPN_BEHIND_NAT` allows for the VPN, that firewall must also
pass TCP to `IMPORT_SERVICE_PORT` from the clients' addresses, and the translation must forward
the port to the host.

## Deploy and check

Commit the settings, then deploy and check the service:

```sh
scripts/host/deploy-import.sh
docker ps --filter name=filone-import-service   # healthy
```

The healthcheck opens a TLS handshake with no client certificate, which the service refuses; that
refusal is the healthy answer. A client with a certificate the CA signed, whose common name is in
`IMPORT_SERVICE_ALLOWED_CLIENTS` and whose address is on the list, then reaches it at
`https://<host's public address>:<IMPORT_SERVICE_PORT>`.

## Take it off the node

To take the service off the node, remove it from `compose.yml` and its settings from `node.env` and
`versions.env`, and once that is deployed:

```sh
docker rm -f filone-import-service
# First, so no reconcile pass loads the table again.
rm -f /mnt/data/fil-one/control/state/import-retry /mnt/data/fil-one/control/state/apps-import-service.sha256
nft delete table ip filone_import
rm -rf /run/fil-one/secrets/import-service /run/fil-one/secrets/import-service.env /etc/fil-one/import-clients
```

## Not yet run on a host

The scripts are tested only against stubs
(`scripts/host/tests/import-firewall.test.sh`, and the import service's cases in `lib.test.sh` and
`reconcile.test.sh`). Not yet exercised: `deploy-import.sh` itself on a host, the `filone_import`
table as `nft` parses it, the drop on real translated traffic, the fixed address on the filone
network, the image and its healthcheck under this compose file, the ledger over the VPN, reads from
Ingot over the filone network, the password file, certificate files and site secret file as the
service reads them, and the registry login and pull. No image has been released, so the service
has never started on this node.
