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

Every failure is a `proxmox.ProxmoxError` (kind `"proxmox"`), with a message
that starts with `proxmox:` and names the request, and the HTTP `status` the
API answered as a field (0 when there was no answer):

- a refused request: `proxmox: POST /nodes/pve1/qemu/101/status/start: HTTP 500: VM 101 already running`.
  The reason is Proxmox's own. A parameter check adds each parameter's
  complaint in brackets.
- a network failure or timeout, with the `http` module's message.
- a reply that is not JSON, a login without a ticket, a malformed UPID, a
  guest id that does not exist, an API path that could leave the host.

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

A reply over its size cap is kind `"limit"` instead (a plain `Error`).

Writes are never retried. `withRetries` retries only GETs answered 429 or 5xx.

## Requirements

Jennifer 0.26.0 or newer, default `jennifer` binary: the deck needs the `net`
capability, which `jennifer-tiny` lacks. Tested against the API of Proxmox VE
7 and 8.
