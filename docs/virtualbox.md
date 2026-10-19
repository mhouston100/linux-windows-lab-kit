# VirtualBox

VirtualBox is the backend that has built this lab. Shared stages, the menu, and reset rules are in the [README](../README.md). This page is only what VirtualBox does differently.

`HYPERVISOR=virtualbox` selects `scripts/hypervisors/virtualbox/` and `config/hypervisors/virtualbox/`.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `VM_ROOT` | `/virtualmachines` | Machine folders and the final disks. The menu calls this VM directory |
| `VBOX_GUEST_ADDITIONS_ISO` | detected | Guest Additions ISO. Unset uses the ISO VirtualBox reports, then the usual install paths |

Disk format is VDI. The field is visible and locked. Guest OS ids are in `config/hypervisors/virtualbox/guests.tsv`.

## Host tools

| Tool | Used for |
|------|----------|
| `VBoxManage` | Create, start, stop, and inspect the lab VMs |
| `qemu-nbd`, `ntfs-3g` | Mount a guest disk to plant Guest Additions |

The menu asks for the administrator password once, before a run that includes stage 3 or stage 5. The password is sent only to sudo, then dropped. It is not stored, and it is not the lab account password. A root helper then accepts only the disk-mount commands for the rest of that run.

## Networks and disks

CorpNet is an internal network named `HYD-CorpNet` (the prefix plus `LAB_NETWORK_NAME`). HYD-GW1 has a second adapter on NAT, so the lab can reach the Internet. The other servers stay off the host network.

Stage 2 writes `tmp/convert/HYD-DC1.vdi` and the same for CM and the gateway. The backend checks each file with `VBoxManage showmediuminfo`.

Stage 3 copies that VDI into `VM_ROOT/<name>/` with `cp --reflink=always`, then gives the copy a new disk UUID. A hardlink would keep the original UUID, and VirtualBox refuses to register the same UUID at two paths. The copy is cheap on btrfs because of the reflink. Each VM is registered under `VM_ROOT`, given the memory and CPU count from the topology, and set to EFI. The disk is attached on SATA.

If the VM already exists and its disk is attached, creation is skipped. `--force` unregisters it and creates it again. If the VM exists without that disk, the disk is attached and creation is not repeated.

## Guest Additions

Stage 3 on its own boots HYD-GW1 headless after the VMs exist. Before that boot, the backend mounts the new disk and plants Guest Additions. A full run (`a` or `all`) skips that boot. Stage 5 plants the additions on each powered-off server and starts the lab, so the gateway is not booted twice.

The plant is a copy of the installer and `install-guest-additions.ps1` under `C:\Windows\Temp\vbox-ga` on the guest, plus a one-time autologon of `LabAdmin` and a RunOnce entry that runs the installer. The installer adds the VirtualBox publisher certificate, runs `VBoxWindowsAdditions-amd64.exe` silently, clears the stored password, and reboots. The script then waits until VirtualBox reports the additions service (up to 30 minutes by default). A reboot during that wait is expected. When the service reports in, the script turns on auto-resize of the guest display, the shared clipboard, and drag-and-drop. When stage 3 does boot a VM, that VM is HYD-GW1, and it is powered off after the additions service reports in.

Reading the Guest Additions ISO and writing the offline registry do not need sudo. The registry writer is `tools/HiveSet`. It uses the MIT-licensed DiscUtils packages stored in `third_party/nuget`.

## Start, health, and reset

`start` plants Guest Additions on any server that is powered off, then boots it. The settle time in `boot-order.tsv` runs while the additions service is reporting in. The next VM starts once the additions are up and that settle time has passed. `--no-wait` skips the settle time and still waits for the additions service.

`health` checks that each lab VM is registered, has a SATA disk, and is on the CorpNet internal network.

Reset deletes:

- every topology VM whose name starts with `LAB_PREFIX`, after powering it off
- that VM's folder under the VM directory
- VirtualBox media still registered under the lab directories
- `source/`, and everything under `tmp/` except `lab.log`

The kit ZIP stays. The VM directory itself stays, so other virtual machines on the host stay.

## Module hooks

Shared code calls these. It does not call `VBoxManage` itself.

| Hook | Behavior |
|------|----------|
| `hv_check_prereqs` | Require `VBoxManage` |
| `hv_disk_format` | `vdi` |
| `hv_verify_disk` | Open the converted medium |
| `hv_verify_create` | VM registered, SATA disk attached, CorpNet on nic1, NAT on the gateway |
| `hv_vm_exists`, `hv_vm_state`, `hv_delete_vm` | Query and unregister |
| `hv_close_lab_media` | Unregister disks, ISOs, and floppies under the lab directories |
| `hv_set_description`, `hv_description_ok` | VM description |
| `hv_stage_needs_privileges` | Stages 3 and 5, for the disk mount |
| `hv_prepare_privileged`, `hv_finish_privileged` | Ask for sudo once and run the mount helper |
