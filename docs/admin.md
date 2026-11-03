<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Administration

## Monitoring

`proxmox.nodeStatus` returns a node's CPU model and load, memory, swap, root
disk, kernel and Proxmox version as a `json.Value`. `proxmox.nodeMetrics`
and `proxmox.guestMetrics` return load over time, one averaged sample per
step, for `hour`, `day`, `week`, `month` or `year`.

```jennifer
import "@deckyard/proxmox/" as proxmox;

def samples as json.Value init proxmox.guestMetrics($c, proxmox.guest($c, 101), "hour");
def last as int init json.length($samples) - 1;
io.printf("cpu %.1f%%\n", json.asFloat($samples, "/" + convert.toString($last) + "/cpu") * 100.0);
```

`proxmox.recentTasks` lists the cluster's recent tasks, running ones
included; a stopped task's `exitStatus` is `OK` or its error.

## Pools

A pool groups guests and storage, mostly to grant permissions on them
together.

```jennifer
proxmox.createPool($c, "lab", "test machines");
proxmox.addToPool($c, "lab", [101, 102, 200]);
```

`proxmox.deletePool` deletes a pool once it is empty.

## High availability

`proxmox.enableHa($c, $g, "started")` puts a guest under HA: when its node
fails, the cluster starts it on another one. It needs a cluster of three or
more nodes and shared storage. `proxmox.disableHa` takes the guest out
without stopping it; `proxmox.haResources` lists the guests under HA.

## Firewall

`proxmox.firewallRules` lists a guest's rules in order;
`proxmox.addFirewallRule` adds one at the top, enabled;
`proxmox.deleteFirewallRule` removes one by position.

```jennifer
def r as proxmox.FirewallRule;
$r.type = "in";
$r.action = "ACCEPT";
$r.proto = "tcp";
$r.dport = "443";
$r.comment = "https";
proxmox.addFirewallRule($c, $web, $r);
```

Rules apply only while the firewall is on for the guest (its firewall
options) and for the NIC (`firewall=1` in `net0`).

## Users and permissions

`proxmox.users` lists the accounts, `proxmox.permissions` the access control
list. `proxmox.grant` gives a user, group or API token a role on a path;
`proxmox.revoke` takes it away.

```jennifer
def a as proxmox.Acl init proxmox.Acl{path: "/pool/lab", type: "group", ugid: "devs", roleid: "PVEVMAdmin", propagate: true};
proxmox.grant($c, $a);
```

Creating users, groups and roles has no typed function; post to
`/access/users`, `/access/groups` and `/access/roles`.
