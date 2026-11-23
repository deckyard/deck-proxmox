#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * inventory example: list the nodes, their storage, and every guest.
 *
 * Read-only. Run with an API token:
 *   PVE_HOST=pve.example.com PVE_TOKEN_ID='root@pam!ci' PVE_TOKEN_SECRET=... \
 *       jennifer run examples/inventory.j
 * or with a password (PVE_USER=root@pam PVE_PASSWORD=...). PVE_INSECURE=1
 * accepts a self-signed certificate.
 */

use io;
use os;

import "../src/proxmox.j" as proxmox;

def host as string init os.getEnv("PVE_HOST");
if ($host == "") {
    io.printf("set PVE_HOST and PVE_TOKEN_ID / PVE_TOKEN_SECRET (or PVE_USER / PVE_PASSWORD)\n");
    exit 1;
}

def c as proxmox.Client init proxmox.client($host);
if (os.getEnv("PVE_INSECURE") == "1") {
    $c = proxmox.withInsecure($c);
}
if (os.getEnv("PVE_TOKEN_ID") != "") {
    $c = proxmox.withToken($c, os.getEnv("PVE_TOKEN_ID"), os.getEnv("PVE_TOKEN_SECRET"));
} else {
    $c = proxmox.login($c, os.getEnv("PVE_USER"), os.getEnv("PVE_PASSWORD"));
}

def v as proxmox.Version init proxmox.version($c);
io.printf("Proxmox VE %s\n\n", $v.version);

for (def n in proxmox.nodes($c)) {
    def gib as int init 1073741824;
    io.printf(
        "%s|pad=12 %s|pad=8 %d|pad=3|align=right CPUs  %f|prec=1|pad=5|align=right%% load  %d/%d GiB\n",
        $n.node,
        $n.status,
        $n.maxcpu,
        $n.cpu * 100.0,
        $n.mem // $gib,
        $n.maxmem // $gib);
    if ($n.status == "online") {
        for (def s in proxmox.storages($c, $n.node)) {
            io.printf(
                "    %s|pad=16 %s|pad=8 %d GiB free\n",
                $s.storage,
                $s.type,
                $s.avail // $gib);
        }
    }
}

io.printf("\n");
for (def g in proxmox.guests($c)) {
    def what as string init $g.kind;
    if ($g.template) {
        $what = $what + " template";
    }
    io.printf(
        "%d|pad=6|align=right  %s|pad=20 %s|pad=14 %s|pad=8 %s\n",
        $g.vmid,
        $g.name,
        $what,
        $g.node,
        $g.status);
}
