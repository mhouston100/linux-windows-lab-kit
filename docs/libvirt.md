# libvirt

Local QEMU/KVM backend. Same menu and six stages as VirtualBox and Proxmox.

`HYPERVISOR=libvirt` selects `scripts/hypervisors/libvirt/` and `config/hypervisors/libvirt/`.

Use **qemu:///system** (Virt-Manager’s system URI). It can create isolated CorpNet and the `default` NAT network. `qemu:///session` cannot.

A live run on this host created, started, and stopped HYD-DC1, HYD-GW1, and HYD-CM1. First-boot set CorpNet addresses and RRAS; DC1 reached the Internet through the gateway with no hand edits.

## Settings

| Setting | Meaning |
|---------|---------|
| `LIBVIRT_URI` | Connection. Default `qemu:///system` |
| `LIBVIRT_VIRTIO_ISO` | virtio-win ISO for the qemu-ga plant. Blank also accepts `PVE_VIRTIO_ISO` |
| `VM_ROOT` | Per-guest qcow2 folder. Create/start set `711` on the folder and `644` on the disks so `libvirt-qemu` can open them |

Disk: qcow2, OVMF, SATA boot, e1000 NICs, virtio-serial channel `org.qemu.guest_agent.0`. CorpNet is `LAB_PREFIX-LAB_NETWORK_NAME` (default `HYD-CorpNet`). The gateway’s second NIC uses libvirt `default` NAT.

## First boot

Stage 3 mounts each converted qcow2 and plants the same offline payload as Proxmox: qemu-ga files, `C:\Windows\Temp\lab-kit\first-boot.ps1`, and RunOnce plus one-shot autologon. First-boot reads `config/guest-network.tsv`, matches kit hostnames (`DC1` / `GW1`) to topology names (`HYD-DC1` / `HYD-GW1`), sets addresses, finishes DHCP on the DC, and configures RRAS NAT. On the gateway, **full** NAT is the Up NIC with DHCP outside `10.0.0.0/24`; **private** is the other Up NIC. Then it runs the qemu-ga installer.

Re-arm after a disk has already booted (guests must be off):

```bash
HYPERVISOR=libvirt ./scripts/plant-first-boot.sh
# or replace live disks from the never-booted convert copies:
HYPERVISOR=libvirt ./scripts/plant-first-boot.sh --from-convert
```

Day-to-day control: `HYPERVISOR=libvirt ./scripts/lab-ctl.sh start|stop|status|health`.

## Host

Packages: `libvirt`, `qemu-desktop`, `virt-install`, `edk2-ovmf`, `dnsmasq`. This account in group `libvirt`. Nested VT-x should be `Y` if you later run Proxmox as a KVM guest (`/sys/module/kvm_intel/parameters/nested`).

```bash
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtnodedevd.socket virtstoraged.socket virtlogd.socket virtlockd.socket
```

**Test connection** opens the URI, checks `/dev/kvm`, and looks for the `default` network. It does not create a guest.

Remote `qemu+ssh://` is not implemented yet (board LV-02).
