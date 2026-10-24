# libvirt

libvirt is the third backend, beside VirtualBox and Proxmox. The menu, the six stages, and the work directory are the same. This page is the local QEMU/KVM connection.

`HYPERVISOR=libvirt` selects `scripts/hypervisors/libvirt/` and `config/hypervisors/libvirt/`.

Use **qemu:///system**. That is the URI Virt-Manager calls QEMU/KVM. It can create the isolated CorpNet and the default NAT network. `qemu:///session` does not.

## Settings

| Setting | Meaning |
|---------|---------|
| `LIBVIRT_URI` | libvirt connection. Default `qemu:///system` |
| `LIBVIRT_VIRTIO_ISO` | virtio-win ISO on this machine. Stage 3 plants the QEMU guest agent from it. A blank value also accepts `PVE_VIRTIO_ISO` |
| `VM_ROOT` | Folder for each guest's qcow2 |

Disk format is qcow2. Firmware is OVMF. The boot disk is SATA and the NICs are e1000 so the Hyper-V image can start before virtio drivers exist. CorpNet is an isolated libvirt network named `LAB_PREFIX-LAB_NETWORK_NAME` (default `HYD-CorpNet`). The gateway's second NIC uses the `default` NAT network.

Stage 3 plants the guest agent the same way as Proxmox: it mounts the converted qcow2 on this machine and writes `RunOnce` plus a one-shot autologon. See [Proxmox](proxmox.md) for that plant.

## Host

Packages on this machine: `libvirt`, `qemu-desktop`, `virt-install`, `edk2-ovmf`, `dnsmasq`. This account must be in the `libvirt` group. Nested VT-x should be on if a later step runs Proxmox as a KVM guest (`/sys/module/kvm_intel/parameters/nested` is `Y`).

The modular sockets must be enabled for `qemu:///system`:

```bash
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtnodedevd.socket virtstoraged.socket virtlogd.socket virtlockd.socket
```

**Test connection** opens the URI, checks `/dev/kvm`, and looks for the `default` network. It does not create a guest.
