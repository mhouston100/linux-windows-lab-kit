# Lab Kit Spec

Independent Linux orchestration for a Windows 11 / Server / Microsoft 365 / MECM-style lab. `HYPERVISOR` selects the backend. libvirt (`scripts/hypervisors/libvirt/`) has a live local create/start/stop with first-boot LAN and RRAS. VirtualBox and Proxmox backends are also present; nested Proxmox under VirtualBox fails (EPT), so finish that path under KVM. Shared lab shape stays in `config/topology.tsv`.

The operator guide is [README.md](../README.md), with [libvirt](libvirt.md), [VirtualBox](virtualbox.md), and [Proxmox](proxmox.md). Users supply the original Microsoft lab ZIP and any required licenses. This project does not redistribute Microsoft media or scripts.

## Storage paths

| Variable | Default | Role |
|----------|---------|------|
| `SOURCE_DIR` | `/virtualmachines/source` | ZIP + immediate extract |
| `TMP_DIR` | `/virtualmachines/tmp` | ZPAQ originals, setup unpack, organize, convert scratch |
| `VM_ROOT` | `/virtualmachines` | VirtualBox / libvirt machine folders and final disks. Proxmox does not put guests here |
| `LAB_ZIP_PATH` | prompted | User-supplied lab archive |

## Topology (from Set Up Guide — our words)

| Name | Role | Products / notes |
|------|------|------------------|
| HYD-DC1 | Domain controller | AD DS, DNS, DHCP, Certificate Services |
| HYD-CM1 | Management | Microsoft Configuration Manager 2603, SQL Server 2022, WSUS, WDS, ADK |
| HYD-GW1 | Edge / Internet | Remote Access for lab Internet connectivity |
| HYD-CLIENT1–2 | Clients | Windows 11 25H2, domain-joined (created from `WindowsParent`) |
| HYD-CLIENT3–4 | Clients | Windows 11 25H2, workgroup |
| HYD-CLIENT5–6 | Bare metal | No OS (Autopilot / OSD labs) |

### Networks

| Logical name | VirtualBox | libvirt | Proxmox | Purpose |
|--------------|------------|---------|---------|---------|
| CorpNet | Internal `HYD-CorpNet` | Network `HYD-CorpNet` | Bridge `PVE_BRIDGE` | Lab corporate LAN |
| Internet | NAT on the gateway | libvirt `default` NAT | Bridge `PVE_INTERNET_BRIDGE` | Outbound Internet for the gateway |

### Default credentials (override via config)

| Type | User | Password |
|------|------|----------|
| Local Administrator | `Administrator` | set in `lab.env` (kit default was documented as evaluation password) |
| Domain admin | `CORP\LabAdmin` | set in `lab.env` |

See `config/topology.tsv` for the shared lab shape and `config/guest-network.tsv` for first-boot addresses. Guest ids live under `config/hypervisors/<name>/`.

## Phase goals

1. **Prerequisites** + path prompts — `check-prereqs.sh` / `phase1.sh`  
2. **Extract** ZIP → ZPAQ → setup → organize (`TMP_DIR`) — `extract-lab.sh`  
3. **Convert** VHDX to the backend disk format (flatten via `tools/VhdxFlatten`) — `phase2.sh`  
4. **Create** networks + VMs; attach disks — `phase3.sh` (the selected hypervisor module)  
5. **Unattend / identity** (config-driven) — `phase4.sh` → `TMP_DIR/identity/`  
6. **Run** ordered start/stop + health — `lab-ctl.sh` / `phase5.sh`  
7. **Cleanup** with `--yes` confirmations — `cleanup-lab.sh` / `phase6.sh`  

## Tooling

| Purpose | Tool |
|---------|------|
| ZIP | `unzip` |
| ZPAQ | native `zpaq` or Wine + bundled `zpaq.exe` |
| setup.exe | `7z` (do not run under Wine) |
| Differencing VHDX | `tools/VhdxFlatten` (DiscUtils 0.16.13, MIT, included under `third_party/nuget`) |
| Offline registry | `tools/HiveSet` (DiscUtils.Registry, same MIT packages) |
| Convert | `qemu-img` |
| Hypervisor | `scripts/hypervisors/${HYPERVISOR}` (`virsh` / `virt-install`, `VBoxManage`, or the Proxmox API) |
