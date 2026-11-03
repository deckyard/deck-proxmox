# @deckyard/proxmox

[![test](https://github.com/deckyard/deck-proxmox/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-proxmox/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-proxmox/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-proxmox)](https://github.com/deckyard/deck-proxmox/releases/latest)

A [Jennifer](https://jennifer-lang.dev/) client for the
[Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment) API.
`get`, `post`, `put` and `delete` reach every endpoint; typed verbs cover
nodes, guests (QEMU VMs and LXC containers), creating and deleting them,
power actions, cloning, templates, snapshots, IP addresses, migration,
disk resizing, cloud-init, backups and restores, ISOs and container
templates, metrics, pools, HA, firewall rules, permissions and background
tasks. It authenticates with an API token
or a password ticket (TOTP included) and trusts the cluster's own CA.

**[Documentation](https://deckyard.github.io/deck-proxmox/)**

## Install

```sh
jvc add @deckyard/proxmox
```

Or unpack `src/` from a release archive (`deckyard-proxmox-<version>.tar.gz`)
into `vendor/deckyard/proxmox/`.

## Usage

```jennifer
use io;
import "@deckyard/proxmox/" as proxmox;

def c as proxmox.Client init proxmox.client("pve.example.com");
$c = proxmox.withCaCert($c, fs.readBytes("pve-root-ca.pem"));
$c = proxmox.withToken($c, "root@pam!automation", os.getEnv("PVE_TOKEN_SECRET"));

for (def g in proxmox.guests($c)) {
    io.printf("%6d %-20s %s\n", $g.vmid, $g.name, $g.status);
}

def web as proxmox.Guest init proxmox.guest($c, 101);
def t as proxmox.Task init proxmox.waitTask($c, proxmox.start($c, $web), 60000);
io.printf("start: %s\n", $t.exitStatus);
```

## Requirements

Jennifer 0.25.0 or newer and the default `jennifer` binary: the deck needs
the `net` capability, which `jennifer-tiny` lacks.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/proxmox_test.j     # the test overlay, offline
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

The tests answer from a fake server on a loopback port. The examples need a
real host; see their headers.

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

Proxmox is a registered trademark of Proxmox Server Solutions GmbH. This deck
is not affiliated with or endorsed by it.
