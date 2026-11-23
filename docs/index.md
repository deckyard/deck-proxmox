<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/proxmox

A client for the [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment)
API. `get`, `post`, `put` and `delete` reach every endpoint of `/api2/json`
and return the reply's `data` as a `json.Value`. Typed verbs cover the daily
work: nodes, guests (QEMU VMs and LXC containers), creating and deleting them,
power actions, cloning, templates, snapshots, IP addresses, migration,
disk resizing, cloud-init, backups and restores, ISOs and container
templates, metrics, pools, HA, firewall rules, permissions and background
tasks.

**Infrastructure as Code (IaC).** Guests, cloud-init, pools, HA, firewall
rules and permissions can be provisioned from a Jennifer program kept in
version control and reviewed like any other code. The create verbs are not
idempotent: `createVm`, `createContainer` and `createPool` fail when the id
exists, and `addFirewallRule` adds a rule on every run. A re-runnable script
lists what exists first (`guests`, `pools`, `firewallRules`); `setConfig`,
`setCloudInit` and `grant` can be applied again. There is no plan or diff
step, and the deck does not detect drift.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/proxmox/" as proxmox;

def c as proxmox.Client init proxmox.client("pve.example.com");
$c = proxmox.withToken($c, "root@pam!automation", "8d3f6c1e-...");
io.printf("%s\n", proxmox.version($c).version);
```

A `Client` is a value. `withToken`, `login` and the other `with*` functions
return a changed copy, so assign the result back to `$c`.

Parameters go in a `map of string to string`, Proxmox's names as they are.
GET and DELETE send them in the query string, POST and PUT as a form. Pass
booleans as `"1"` and `"0"`.

## Errors

Every failure of kind `"proxmox"` is a `proxmox.ProxmoxError`, with a
message that starts with `proxmox:` and names the request, and a `status`
field:

- a refused request has the HTTP status the API answered:
  `proxmox: POST /nodes/pve1/qemu/101/status/start: HTTP 500: VM 101 already running`.
  The reason is Proxmox's own. A parameter check adds each parameter's
  complaint in brackets.
- status 0 means the deck raised the error itself, with no HTTP status to
  report. Most are local checks, final whatever you repeat: input it
  refuses (an empty host, a malformed token id, UPID, disk size or volume
  id, an API path that could leave the host), a lookup that found nothing
  (`guest($c, 9999)`: `proxmox: no guest 9999`; `guestByName` with no match
  or several), `waitTask` running out of time, an expired ticket in
  `renew`. The others are a 2xx reply it cannot use (not JSON, a login
  without a ticket, no task id) and an `http` failure of a kind other than
  the generic ones below (a malformed HTTP reply, say).

Status 0 is not a network failure, and not a sign to retry: a host that
cannot be reached is kind `"net"` (below), never a `ProxmoxError`.

```jennifer
try {
    proxmox.start($c, proxmox.guest($c, 101));
} catch (e) {
    if ($e.kind == "proxmox" and $e.status == 401) {
        io.printf("log in again\n");
    } else {
        io.printf("%s\n", $e.message);
    }
}
```

A reply over its size cap, or a JSON reply nested past the decoder's cap, is
kind `"limit"` instead (a plain `Error`); a reply that does not come within
the timeout is kind `"timeout"`, a connection closed mid-reply kind
`"closed"`, and a cancelled task kind `"cancelled"`. A host
that cannot be reached (refused, reset, unreachable, no DNS answer, a failed
TLS handshake, closed before any reply) throws the `net.NetError` (kind
`"net"`) that `http` raised, unchanged: its `reason`, `op`, `sent` and
`replied` fields tell what happened, and a request that was not `sent` never
reached the host.

Writes are never retried. `withRetries` retries only GETs answered 429 or 5xx.

## Requirements

Jennifer 0.27.0 or newer, default `jennifer` binary: the deck needs the `net`
capability, which `jennifer-tiny` lacks. Tested against the API of Proxmox VE
7 and 8.
