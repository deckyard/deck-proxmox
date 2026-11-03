#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * snapshot example: snapshot one guest and wait for the task.
 *
 * Writes: it creates a snapshot named `deck-example`; delete it afterwards
 * with PVE_CLEANUP=1. Run with:
 *   PVE_HOST=pve.example.com PVE_TOKEN_ID='root@pam!ci' PVE_TOKEN_SECRET=... \
 *       PVE_VMID=101 jennifer run examples/snapshot.j
 */

use convert;
use io;
use os;

import "../src/proxmox.j" as proxmox;

def host as string init os.getEnv("PVE_HOST");
def vmid as string init os.getEnv("PVE_VMID");
if ($host == "" or $vmid == "") {
    io.printf("set PVE_HOST, PVE_TOKEN_ID, PVE_TOKEN_SECRET and PVE_VMID\n");
    exit 1;
}

def c as proxmox.Client init proxmox.client($host);
if (os.getEnv("PVE_INSECURE") == "1") {
    $c = proxmox.withInsecure($c);
}
$c = proxmox.withToken($c, os.getEnv("PVE_TOKEN_ID"), os.getEnv("PVE_TOKEN_SECRET"));

def g as proxmox.Guest init proxmox.guest($c, convert.toInt($vmid));
io.printf("%s %d (%s) on %s is %s\n", $g.kind, $g.vmid, $g.name, $g.node, $g.status);

def upid as string init proxmox.snapshot($c, $g, "deck-example", "taken by examples/snapshot.j");
def t as proxmox.Task init proxmox.waitTask($c, $upid, 300000);
io.printf("snapshot: %s\n", $t.exitStatus);
if ($t.exitStatus != "OK") {
    for (def line in proxmox.taskLog($c, $upid)) {
        io.printf("  %s\n", $line);
    }
    exit 1;
}

for (def s in proxmox.snapshots($c, $g)) {
    io.printf("  %-16s parent %-16s %s\n", $s.name, $s.parent, $s.description);
}

if (os.getEnv("PVE_CLEANUP") == "1") {
    $t = proxmox.waitTask($c, proxmox.deleteSnapshot($c, $g, "deck-example"), 300000);
    io.printf("deleted: %s\n", $t.exitStatus);
}
