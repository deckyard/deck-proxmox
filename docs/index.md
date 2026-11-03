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

Every failure is `Error{kind: "proxmox"}`, with a message that starts with
`proxmox:` and names the request:

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
    io.printf("%s\n", $e.message);
}
```

Writes are never retried. `withRetries` retries only GETs answered 429 or 5xx.

## Requirements

Jennifer 0.25.0 or newer, default `jennifer` binary: the deck needs the `net`
capability, which `jennifer-tiny` lacks. Tested against the API of Proxmox VE
7 and 8.
