<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# proxmox cheatsheet

Every export of `@deckyard/proxmox`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/proxmox/" as proxmox;
```

Every function that sends a request throws `Error{kind: "proxmox"}` when it
fails. A `guest` argument is a `Guest` from `proxmox.guests` or
`proxmox.guest`; an `upid` is the string an action returned.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"proxmox"` | the `kind` of every error the deck throws |
| `DEFAULT_PORT` | `8006` | the port `client` adds to a bare host |
| `MAX_POLL_FAILURES` | `5` | failed checks in a row after which `waitTask` gives up |
| `TICKET_LIFETIME` | `7200` | seconds a ticket is valid |

## Types

### `Client`

| Field | Meaning |
|---|---|
| `url as string` | `https://host:8006`, no trailing slash |
| `tokenId as string` | API token id, `user@realm!name`; `""` for none |
| `secret as string` | API token secret |
| `ticket as string` | ticket from `login`; `""` for none |
| `csrf as string` | CSRF prevention token that came with the ticket |
| `tls as http.TlsOptions` | certificate checking |
| `timeoutMs as int` | idle timeout per request; 0 for the `http` default |
| `retries as int` | retries of a GET answered 429 or 5xx |
| `pollMs as int` | interval of `waitTask`'s status checks |

### `Version`

| Field | Meaning |
|---|---|
| `version as string` | e.g. `8.2.4` |
| `release as string` | e.g. `8.2` |
| `repoid as string` | the build's repository id |

### `Node`

| Field | Meaning |
|---|---|
| `node as string` | node name |
| `status as string` | `online`, `offline` or `unknown` |
| `cpu as float` | CPU load, 0 to 1 |
| `maxcpu as int` | CPU count |
| `mem as int` | memory in use, bytes |
| `maxmem as int` | memory, bytes |
| `uptime as int` | seconds |

### `Guest`

| Field | Meaning |
|---|---|
| `vmid as int` | guest id, unique in the cluster |
| `name as string` | guest name |
| `node as string` | the node it lives on |
| `kind as string` | `qemu` or `lxc` |
| `status as string` | `running`, `stopped`, ... |
| `template as bool` | whether it is a template |
| `cpu as float` | CPU load, 0 to 1 |
| `maxcpu as int` | virtual CPUs |
| `mem as int` | memory in use, bytes |
| `maxmem as int` | memory, bytes |
| `disk as int` | root disk in use, bytes (containers only) |
| `maxdisk as int` | root disk size, bytes |
| `uptime as int` | seconds |
| `tags as list of string` | the guest's tags |

### `Snapshot`

| Field | Meaning |
|---|---|
| `name as string` | snapshot name; `current` is the running state |
| `description as string` | its description |
| `parent as string` | the snapshot before it; `""` for the first |
| `snaptime as int` | Unix time it was taken; 0 for `current` |
| `vmstate as bool` | whether it holds the RAM of a running VM |

### `Storage`

| Field | Meaning |
|---|---|
| `storage as string` | storage id |
| `type as string` | `dir`, `lvmthin`, `zfspool`, `nfs`, ... |
| `content as list of string` | `images`, `rootdir`, `iso`, `backup`, ... |
| `active as bool` | usable now |
| `enabled as bool` | enabled |
| `shared as bool` | every node sees the same storage |
| `total as int` | size, bytes |
| `used as int` | bytes in use |
| `avail as int` | bytes free |

### `Task`

| Field | Meaning |
|---|---|
| `upid as string` | the task's id |
| `node as string` | node it runs on |
| `type as string` | e.g. `qmstart`, `vzdump` |
| `id as string` | what it works on, often the guest id |
| `user as string` | who started it |
| `status as string` | `running` or `stopped`; `""` from `parseUpid` |
| `exitStatus as string` | `OK` or the error, once stopped |

### `Interface`

| Field | Meaning |
|---|---|
| `name as string` | interface name |
| `mac as string` | hardware address |
| `addresses as list of string` | addresses with prefix, e.g. `10.0.0.5/24` |

### `Volume`

| Field | Meaning |
|---|---|
| `volid as string` | `<storage>:<path>` |
| `content as string` | `images`, `rootdir`, `iso`, `vztmpl`, `backup` |
| `format as string` | `raw`, `qcow2`, `iso`, `vma.zst`, ... |
| `size as int` | bytes |
| `ctime as int` | Unix time it was created |
| `vmid as int` | its guest; 0 for none |
| `notes as string` | a backup's notes |

### `Appliance`

| Field | Meaning |
|---|---|
| `template as string` | file name, for `downloadAppliance` |
| `section as string` | `system`, `turnkeylinux`, `mail` |
| `os as string` | e.g. `debian-12` |
| `version as string` | template version |
| `headline as string` | one-line description |

### `CloudInit`

| Field | Meaning |
|---|---|
| `user as string` | user to create |
| `password as string` | its password |
| `sshKeys as list of string` | public keys |
| `ipConfig as list of string` | per NIC: `ip=dhcp`, `ip=10.0.0.5/24,gw=10.0.0.1` |
| `nameserver as string` | DNS servers, space-separated |
| `searchDomain as string` | DNS search domain |

### `Pool`

| Field | Meaning |
|---|---|
| `poolid as string` | pool id |
| `comment as string` | its comment |

### `HaResource`

| Field | Meaning |
|---|---|
| `sid as string` | `vm:<vmid>` or `ct:<vmid>` |
| `state as string` | `started`, `stopped`, `disabled`, `ignored` |
| `group as string` | HA group; `""` for none |

### `FirewallRule`

| Field | Meaning |
|---|---|
| `pos as int` | position, 0 first |
| `type as string` | `in`, `out`, `group` |
| `action as string` | `ACCEPT`, `DROP`, `REJECT`, or a security group |
| `enable as bool` | active |
| `source as string` | source; `""` for any |
| `dest as string` | destination; `""` for any |
| `proto as string` | `tcp`, `udp`, `icmp`, ...; `""` for any |
| `dport as string` | destination port or range |
| `macro as string` | predefined service, e.g. `SSH` |
| `comment as string` | its comment |

### `User`

| Field | Meaning |
|---|---|
| `userid as string` | `user@realm` |
| `enabled as bool` | may log in |
| `expire as int` | Unix time it expires; 0 for never |
| `firstname as string` | first name |
| `lastname as string` | last name |
| `email as string` | e-mail address |
| `comment as string` | its comment |

### `Acl`

| Field | Meaning |
|---|---|
| `path as string` | `/`, `/vms/101`, `/pool/lab`, `/storage/local`, ... |
| `type as string` | `user`, `group` or `token` |
| `ugid as string` | the user, group or token |
| `roleid as string` | e.g. `PVEVMUser` |
| `propagate as bool` | applies below the path |

## Client

| Function | Returns | Does |
|---|---|---|
| `proxmox.client(address)` | `Client` | a client for `host`, `host:port` or a URL; a bare host gets `https://` and port 8006 |
| `proxmox.withToken(c, tokenId, secret)` | `Client` | authenticate with an API token |
| `proxmox.withTicket(c, ticket, csrf)` | `Client` | use a ticket kept from an earlier `login` |
| `proxmox.withCaCert(c, pem)` | `Client` | trust this PEM certificate too |
| `proxmox.withInsecure(c)` | `Client` | accept any certificate |
| `proxmox.withTimeout(c, ms)` | `Client` | idle timeout per request |
| `proxmox.withRetries(c, n)` | `Client` | retry a GET answered 429 or 5xx |
| `proxmox.withPollInterval(c, ms)` | `Client` | how often `waitTask` asks |
| `proxmox.login(c, username, password)` | `Client` | get a ticket; throws for an account with a second factor |
| `proxmox.loginTotp(c, username, password, code)` | `Client` | get a ticket with a TOTP code |
| `proxmox.renew(c)` | `Client` | trade the ticket for a fresh one |
| `proxmox.fresh(c)` | `Client` | renew a ticket older than an hour; anything else unchanged |
| `proxmox.describe(c)` | `string` | the client for a log line, without its secret |

## Any endpoint

`path` is under `/api2/json`; the result is the reply's `data`.

| Function | Returns | Does |
|---|---|---|
| `proxmox.call(c, method, path, params)` | `json.Value` | any method; `params` in the query (GET, DELETE) or as a form (POST, PUT) |
| `proxmox.get(c, path, params)` | `json.Value` | GET |
| `proxmox.post(c, path, params)` | `json.Value` | POST |
| `proxmox.put(c, path, params)` | `json.Value` | PUT |
| `proxmox.delete(c, path, params)` | `json.Value` | DELETE |

## Cluster

| Function | Returns | Does |
|---|---|---|
| `proxmox.version(c)` | `Version` | the API's version |
| `proxmox.nodes(c)` | `list of Node` | the nodes, by name |
| `proxmox.storages(c, node)` | `list of Storage` | the storages a node sees, by id |
| `proxmox.nextId(c)` | `int` | a free guest id |
| `proxmox.nodeStatus(c, node)` | `json.Value` | CPU, memory, disk, kernel, version, uptime |
| `proxmox.nodeMetrics(c, node, timeframe)` | `json.Value` | load over `hour`, `day`, `week`, `month` or `year` |
| `proxmox.recentTasks(c)` | `list of Task` | the cluster's recent tasks |

## Pools, HA, firewall, access

| Function | Returns | Does |
|---|---|---|
| `proxmox.pools(c)` | `list of Pool` | the resource pools |
| `proxmox.createPool(c, poolid, comment)` | `null` | create a pool |
| `proxmox.addToPool(c, poolid, vmids)` | `null` | add guests to it |
| `proxmox.deletePool(c, poolid)` | `null` | delete an empty pool |
| `proxmox.haResources(c)` | `list of HaResource` | guests under HA |
| `proxmox.enableHa(c, g, state)` | `null` | put a guest under HA |
| `proxmox.disableHa(c, g)` | `null` | take it out |
| `proxmox.firewallRules(c, g)` | `list of FirewallRule` | a guest's rules, in order |
| `proxmox.addFirewallRule(c, g, rule)` | `null` | add a rule at the top, enabled |
| `proxmox.deleteFirewallRule(c, g, pos)` | `null` | delete a rule |
| `proxmox.users(c)` | `list of User` | the accounts |
| `proxmox.permissions(c)` | `list of Acl` | the access control list |
| `proxmox.grant(c, acl)` | `null` | grant a role on a path |
| `proxmox.revoke(c, acl)` | `null` | take it away |

## Guests

| Function | Returns | Does |
|---|---|---|
| `proxmox.guests(c)` | `list of Guest` | every VM and container, by id |
| `proxmox.guest(c, vmid)` | `Guest` | one guest; throws when there is none |
| `proxmox.guestByName(c, name)` | `Guest` | the one guest with this name |
| `proxmox.status(c, g)` | `string` | live status: `running`, `stopped`, `paused`, ... |
| `proxmox.start(c, g)` | `string` | start; returns the UPID |
| `proxmox.stop(c, g)` | `string` | stop at once |
| `proxmox.shutdown(c, g, timeoutSec)` | `string` | shut down through the guest OS; 0 for the default timeout |
| `proxmox.reboot(c, g)` | `string` | reboot through the guest OS |
| `proxmox.suspend(c, g)` | `string` | pause a VM, freeze a container |
| `proxmox.resume(c, g)` | `string` | resume |
| `proxmox.config(c, g)` | `json.Value` | the configuration |
| `proxmox.setConfig(c, g, params)` | `null` | change keys; `{"delete": "a,b"}` removes them |
| `proxmox.clone(c, g, newid, name)` | `string` | full clone |
| `proxmox.linkedClone(c, g, newid, name)` | `string` | linked clone of a template |
| `proxmox.createVm(c, node, vmid, params)` | `string` | create a VM from Proxmox's configuration keys |
| `proxmox.createContainer(c, node, vmid, params)` | `string` | create a container; `params` needs `ostemplate` |
| `proxmox.destroy(c, g, purge)` | `string` | delete a stopped guest and its disks |
| `proxmox.toTemplate(c, g)` | `string` | turn a stopped guest into a template; `""` for a container |
| `proxmox.snapshots(c, g)` | `list of Snapshot` | oldest first, `current` last |
| `proxmox.snapshot(c, g, name, description)` | `string` | take a snapshot |
| `proxmox.rollback(c, g, name)` | `string` | roll back to a snapshot |
| `proxmox.deleteSnapshot(c, g, name)` | `string` | delete a snapshot |
| `proxmox.interfaces(c, g)` | `list of Interface` | network interfaces, through the guest agent for a VM |
| `proxmox.ipAddresses(c, g)` | `list of string` | its addresses, without loopback and link-local |
| `proxmox.migrate(c, g, target, online)` | `string` | move to another node; live for a running VM |
| `proxmox.resizeDisk(c, g, disk, size)` | `string` | grow a disk: `+10G` or `64G`; `""` when done at once |
| `proxmox.setCloudInit(c, g, ci)` | `null` | set a VM's cloud-init settings |
| `proxmox.guestMetrics(c, g, timeframe)` | `json.Value` | load over `hour`, `day`, `week`, `month` or `year` |

## Backups and storage

| Function | Returns | Does |
|---|---|---|
| `proxmox.backup(c, g, storage, mode)` | `string` | `vzdump` in mode `snapshot`, `suspend` or `stop` |
| `proxmox.backups(c, node, storage)` | `list of Volume` | backups on a storage, oldest first |
| `proxmox.restore(c, node, vmid, volid, storage)` | `string` | restore a backup; `""` storage keeps the original |
| `proxmox.contents(c, node, storage, content)` | `list of Volume` | what a storage holds; `""` for every kind |
| `proxmox.deleteVolume(c, node, volid)` | `string` | delete a backup, ISO, template or unused disk |
| `proxmox.downloadUrl(c, node, storage, content, url, filename)` | `string` | fetch an `iso` or `vztmpl` from a URL |
| `proxmox.appliances(c, node)` | `list of Appliance` | container templates on offer |
| `proxmox.downloadAppliance(c, node, storage, template)` | `string` | fetch one |

## Tasks

| Function | Returns | Does |
|---|---|---|
| `proxmox.parseUpid(upid)` | `Task` | what the UPID says, without a request |
| `proxmox.taskStatus(c, upid)` | `Task` | where the task stands |
| `proxmox.waitTask(c, upid, timeoutMs)` | `Task` | wait until it stops; 0 waits for ever |
| `proxmox.taskLog(c, upid)` | `list of string` | its log lines |
