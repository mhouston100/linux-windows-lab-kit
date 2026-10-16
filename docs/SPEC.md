# Lab Kit Spec

Independent Linux orchestration for a Windows 11 / Server / Microsoft 365 / MECM-style lab. The current backend is VirtualBox (`scripts/hypervisors/virtualbox/`, `config/hypervisors/virtualbox/`). `HYPERVISOR` selects the backend. Shared lab shape stays in `config/topology.tsv`.
Users supply the original Microsoft lab ZIP and any required licenses. This project does not redistribute Microsoft media or scripts.

## Storage paths

| Variable | Default | Role |
|----------|---------|------|
| `SOURCE_DIR` | `/virtualmachines/source` | ZIP + immediate extract |
| `TMP_DIR` | `/virtualmachines/tmp` | ZPAQ originals, setup unpack, organize, convert scratch |
| `VM_ROOT` | `/virtualmachines` | Hypervisor machine folder + final disks |
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

| Logical name | VirtualBox backend | Purpose |
|--------------|--------------------|---------|
| CorpNet | Internal network `HYD-CorpNet` | Lab corporate LAN |
| Internet | NAT (`nic` attached to GW) | Outbound Internet for gateway |

### Default credentials (override via config)

| Type | User | Password |
|------|------|----------|
| Local Administrator | `Administrator` | set in `lab.env` (kit default was documented as evaluation password) |
| Domain admin | `CORP\LabAdmin` | set in `lab.env` |

See `config/topology.tsv` for the shared lab shape. VirtualBox guest OS ids are in `config/hypervisors/virtualbox/guests.tsv`.

## Phase goals

1. **Prerequisites** + path prompts — `check-prereqs.sh` / `phase1.sh`  
2. **Extract** ZIP → ZPAQ → setup → organize (`TMP_DIR`) — `extract-lab.sh`  
3. **Convert** VHDX→VDI (flatten via `tools/VhdxFlatten`) — `phase2.sh`  
4. **Create** networks + VMs; attach disks — `phase3.sh` (VirtualBox module today)  
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
| Hypervisor | `scripts/hypervisors/${HYPERVISOR}` (`VBoxManage` for `virtualbox`) |
