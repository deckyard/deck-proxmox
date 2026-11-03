<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Guests and tasks

## Finding guests

`proxmox.guests` reads `/cluster/resources` once and returns every VM and
container in the cluster, templates included, sorted by id. `proxmox.guest`
picks one by id.

```jennifer
import "@deckyard/proxmox/" as proxmox;

for (def g in proxmox.guests($c)) {
    if ($g.kind == "lxc" and $g.status == "running") {
        io.printf("%d %s on %s, tags %s\n", $g.vmid, $g.name, $g.node, strings.join($g.tags, ","));
    }
}
def web as proxmox.Guest init proxmox.guest($c, 101);
```

A `Guest` carries its node and kind, so the verbs below build the right path
(`/nodes/<node>/qemu/<vmid>` or `/nodes/<node>/lxc/<vmid>`) on their own. The
numbers in it are a snapshot; `proxmox.status($c, $g)` asks for the live
state.

## Power

`proxmox.start`, `proxmox.stop`, `proxmox.shutdown`, `proxmox.reboot`,
`proxmox.suspend` and `proxmox.resume` each start a task and return its UPID
at once.

`stop` cuts the power. `shutdown` asks the guest's operating system (ACPI
for a VM, which needs the guest to listen; the QEMU guest agent helps) and
takes a timeout in seconds, 0 for Proxmox's default.

## Tasks

Most changes run as background tasks. Their id, the UPID, says where the
task runs and what it does; `proxmox.parseUpid` reads it without a request.

```jennifer
def upid as string init proxmox.shutdown($c, $web, 120);
def t as proxmox.Task init proxmox.waitTask($c, $upid, 180000);
if ($t.exitStatus != "OK") {
    for (def line in proxmox.taskLog($c, $upid)) {
        io.printf("%s\n", $line);
    }
}
```

`proxmox.waitTask` asks once a second (`proxmox.withPollInterval` changes it)
and throws when the timeout runs out; 0 waits for ever. A network failure or
a 5xx answer during the wait is retried, up to `MAX_POLL_FAILURES` (5) in a
row; a 4xx answer, such as an expired ticket, ends the wait at once. A stopped task
succeeded when `exitStatus` is `OK`; otherwise it holds the error. A finished
task does not throw: check `exitStatus`.

## Configuration

`proxmox.config` returns the guest's configuration as a `json.Value`, with
Proxmox's keys (`cores`, `memory`, `net0`, `scsi0` ...). `proxmox.setConfig`
changes keys and returns when the change is done; `delete` removes keys:

```jennifer
proxmox.setConfig($c, $web, {"memory": "8192", "delete": "net1"});
```

## Creating and deleting

`proxmox.createVm` and `proxmox.createContainer` take Proxmox's own
configuration keys, the ones `proxmox.config` returns, and start a task. The
id comes from `proxmox.nextId`.

A VM booting an installer ISO, with a new 32 GiB disk:

```jennifer
import "@deckyard/proxmox/" as proxmox;

def id as int init proxmox.nextId($c);
def vm as map of string to string init {
    "name": "web3",
    "ostype": "l26",
    "cores": "2",
    "memory": "4096",
    "scsihw": "virtio-scsi-single",
    "scsi0": "local-lvm:32,discard=on",
    "ide2": "local:iso/debian-12.7.0-amd64-netinst.iso,media=cdrom",
    "net0": "virtio,bridge=vmbr0",
    "agent": "1",
    "start": "1"
};
proxmox.waitTask($c, proxmox.createVm($c, "pve1", $id, $vm), 120000);
```

`<storage>:<size>` makes a new disk of that many GiB. A container starts from
a template that `pveam download` has fetched to a storage:

```jennifer
def ct as map of string to string init {
    "ostemplate": "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst",
    "hostname": "dns2",
    "memory": "512",
    "rootfs": "local-lvm:8",
    "net0": "name=eth0,bridge=vmbr0,ip=dhcp",
    "ssh-public-keys": fs.readString("id_ed25519.pub"),
    "unprivileged": "1"
};
proxmox.waitTask($c, proxmox.createContainer($c, "pve1", proxmox.nextId($c), $ct), 300000);
```

`proxmox.destroy($c, $g, true)` deletes a stopped guest with its disks; `true`
also removes it from backup jobs, replication and HA and deletes disks that
no configuration refers to.

`proxmox.toTemplate` turns a stopped guest into a template. For a VM it
returns a task; a container is converted before the call returns, and the
result is `""`.

## Cloning and snapshots

```jennifer
def id as int init proxmox.nextId($c);
proxmox.waitTask($c, proxmox.clone($c, proxmox.guest($c, 9000), $id, "web2"), 0);

proxmox.waitTask($c, proxmox.snapshot($c, $web, "preupgrade", "before 8.3"), 0);
for (def s in proxmox.snapshots($c, $web)) {
    io.printf("%s (after %s)\n", $s.name, $s.parent);
}
proxmox.waitTask($c, proxmox.rollback($c, $web, "preupgrade"), 0);
proxmox.waitTask($c, proxmox.deleteSnapshot($c, $web, "preupgrade"), 0);
```

`clone` makes a full copy. `linkedClone` makes a linked one, which shares the
template's disks and stores only its changes; it needs a template on storage
with snapshots (LVM-thin, ZFS, Ceph, qcow2 on a directory).
`snapshots` lists the oldest first and ends with `current`, the running
state, whose `parent` is the snapshot it runs on.

## Finding a guest's address

`proxmox.ipAddresses` returns what the guest reports, without loopback and
link-local addresses; `proxmox.interfaces` returns every interface with its
MAC address and prefixes. A container answers on its own. A VM answers
through the QEMU guest agent, which must run in the guest and be enabled
(`agent: 1`); without it the call fails with `QEMU guest agent is not
running`.

```jennifer
def web as proxmox.Guest init proxmox.guestByName($c, "web3");
io.printf("%s\n", strings.join(proxmox.ipAddresses($c, $web), ", "));
```

The agent starts with the guest, so right after `start` the call may fail a
few times; retry it.

## Cloud-init

A VM built from a cloud image takes its user, keys and network from a
cloud-init drive. Add the drive once, then set the values:

```jennifer
proxmox.setConfig($c, $web, {"ide2": "local-lvm:cloudinit"});

def ci as proxmox.CloudInit;
$ci.user = "ada";
$ci.sshKeys = [fs.readString("id_ed25519.pub")];
$ci.ipConfig = ["ip=10.0.0.5/24,gw=10.0.0.1"];
$ci.nameserver = "10.0.0.1";
proxmox.setCloudInit($c, $web, $ci);
```

Proxmox wants the SSH keys percent-encoded once more inside the request;
`setCloudInit` does it and strips the trailing newline of a key file. The
guest reads the values at its next boot. A container takes the same
settings directly in `createContainer` (`ssh-public-keys`, `net0`).

## Moving and growing

`proxmox.migrate($c, $g, "pve2", true)` moves a guest to another node. A
running VM moves live; a running container is stopped, moved and started
again; with `false` the guest must be stopped. Local disks of a running VM
need `with-local-disks`: post to `/nodes/<node>/qemu/<vmid>/migrate`
yourself.

`proxmox.resizeDisk($c, $g, "scsi0", "+10G")` grows a disk by 10 GiB; `"64G"`
sets the size. Disks never shrink. The partition and filesystem inside the
guest still need growing (cloud images do it at boot).

## Nodes and storage

`proxmox.nodes` lists the cluster's nodes with their load and memory;
`proxmox.storages($c, node)` lists what one node sees, with its size and
content types.
