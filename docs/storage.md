<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Backups and storage

## Backups

`proxmox.backup` runs `vzdump` for one guest, zstd-compressed, to a storage
that holds backups. `snapshot` mode keeps the guest running; `suspend`
pauses it briefly; `stop` shuts it down for the backup.

```jennifer
import "@deckyard/proxmox/" as proxmox;

def web as proxmox.Guest init proxmox.guestByName($c, "web3");
def t as proxmox.Task init proxmox.waitTask($c, proxmox.backup($c, $web, "backup-nfs", "snapshot"), 0);
io.printf("backup: %s\n", $t.exitStatus);
```

`proxmox.backups` lists the backups on a storage, oldest first, with the
guest id, size, time and notes. `proxmox.restore` brings one back as a guest:
a `vzdump-qemu-...` archive, or a Proxmox Backup Server snapshot under
`backup/vm/`, becomes a VM; `vzdump-lxc-...` or `backup/ct/` a container. Give it a free id for a copy, or the original id of a stopped
guest to overwrite it.

```jennifer
def all as list of proxmox.Volume init proxmox.backups($c, "pve1", "backup-nfs");
def latest as proxmox.Volume init $all[len($all) - 1];
proxmox.waitTask($c, proxmox.restore($c, "pve1", proxmox.nextId($c), $latest.volid, "local-lvm"), 0);
```

`proxmox.deleteVolume` deletes a backup, an ISO, a template or an unused disk
by its volume id. Pruning old backups is a loop over `backups`.

## ISOs and templates

`proxmox.contents` lists what a storage holds: `iso`, `vztmpl` (container
templates), `backup`, `images` (VM disks), `rootdir` (container disks), or
everything with `""`.

A node downloads an ISO or a template straight from a URL:

```jennifer
def iso as string init "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.7.0-amd64-netinst.iso";
proxmox.waitTask($c, proxmox.downloadUrl($c, "pve1", "local", "iso", $iso, "debian-12.7.0-amd64-netinst.iso"), 0);
```

Proxmox's own container templates, the ones `pveam` offers, are listed by
`proxmox.appliances` and fetched by `proxmox.downloadAppliance`. Afterwards
the template is `<storage>:vztmpl/<template>`, ready for `createContainer`.

```jennifer
for (def a in proxmox.appliances($c, "pve1")) {
    if ($a.os == "debian-12" and $a.section == "system") {
        proxmox.waitTask($c, proxmox.downloadAppliance($c, "pve1", "local", $a.template), 0);
    }
}
```
