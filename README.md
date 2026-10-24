NOTE: This was written almost entirely by Cursor. I didn't really want to make this project, I was just trying to get a working lab on Linux and I got sick of the bullshit Microsoft trial versions expiring. This should ease that process of re-staging the dev lab quickly.

# Linux Windows Lab Kit

Bash scripts that build a Windows lab on a Linux host from a Microsoft lab ZIP you already have. You supply the archive and the licenses. The repository holds the orchestration only.

- **Three servers.** A domain controller, a Configuration Manager server, and a gateway. They share a lab LAN. The gateway also has a path to the Internet.
- **Six stages.** Extract the archive, convert the Hyper-V disks, create the virtual machines, write the lab account notes, start the machines in order, then check that cleanup will not delete the lab by accident.
- **One screen.** `./scripts/lab.sh` opens a Python menu. Pick the hypervisor, check the settings, then Run all or Run next. Reset and Quit are there too. The keys `a`, `n`, `c`, and `q` do the same things. The stage scripts stay Bash.
- **It picks up where it stopped.** A finished step is skipped until you reset or pass `--force`. Reset removes this lab only. The ZIP and any other virtual machines stay.
- **Platforms**
  - [VirtualBox](docs/virtualbox.md) — the backend that has built this lab
  - [Proxmox](docs/proxmox.md) — API create, start, and stop. Disk images are copied with rsync. Download the virtio-win ISO and set Virtio ISO to that file. Every stage stops until the file exists. Stage 3 plants the QEMU guest agent from it on each disk before the copy
  - [libvirt](docs/libvirt.md) — local QEMU/KVM. Stage 3 plants the QEMU guest agent on each disk before create
  - VMware Workstation — pending

The project is independent. It is not affiliated with, endorsed by, or redistributed by Microsoft. You supply the lab ZIP and any licenses the software inside it requires. This repository contains orchestration, templates, and two small .NET tools. It does not contain Windows media, product keys, or passwords.

`HYPERVISOR` in `config/lab.env` selects the backend. Shared stages live in `scripts/`. Each backend is a directory under `scripts/hypervisors/` and `config/hypervisors/`. `docs/SPEC.md` is the short design note.

## What the lab is

The archive this kit was written against is the Windows 11 25H2 evaluation lab (`Win11_25H2_Lab.zip`, about 32 GB). The scripts follow the lab shape described in that kit's setup guide, restated here in our own words.

| Name | Role | Memory | CPUs | Networks |
|------|------|--------|------|----------|
| HYD-DC1 | Active Directory, DNS, DHCP, Certificate Services | 4 GB | 2 | CorpNet |
| HYD-CM1 | Configuration Manager, SQL Server, WSUS, WDS, ADK | 8 GB | 4 | CorpNet |
| HYD-GW1 | Remote Access, the lab's path to the Internet | 4 GB | 2 | CorpNet and Internet |

CorpNet is the lab LAN. Only the gateway has a second adapter, so the lab can reach the Internet. How those two networks are attached depends on the hypervisor. See [VirtualBox](docs/virtualbox.md), [Proxmox](docs/proxmox.md), or [libvirt](docs/libvirt.md).

The domain, account, and network names come from configuration. The defaults are domain `Corp`, user `LabAdmin`, prefix `HYD`, and network `CorpNet`. The password is whatever you set in `config/lab.env`. The scripts never print it and the file is gitignored.

Client VMs (domain-joined and workgroup Windows 11 machines built from `WindowsParent`) are described in the topology and have an unattend template, but they are not created yet. Bare-metal Autopilot and OSD seats in the original guide are out of scope.

## What a run actually does

`./scripts/lab.sh` is the entry point. On a terminal it opens the Python menu and stays there. Press a key; Enter is not required.

| Key | Action |
|-----|--------|
| `a` | Run every stage that has not passed yet, in order. Stage 3 does not boot a VM |
| `n` | Run the next unfinished stage, starting at stage 1. Stage 3 boots the gateway briefly |
| `c` | Reset this lab, after you confirm |
| `q` | Leave the menu |

The screen is a stack of titled boxes. Hypervisor choice is first, with VirtualBox in the first spot. The next box is that platform's settings. Under it are the lab settings: kit, work directory, domain, account, password, and Parallel disks. Fields you can change are text boxes. Fields you cannot change are plain text. Parallel disks is on unless you turn it off. It converts independent server disks at the same time. The machines still boot one after another. Leaving a field writes `config/lab.env`. A blank password keeps the current one, and the password is never shown. Progress for each stage stays on the screen, with Run all, Run next, Reset, and Quit underneath, then the live log. While a stage is running, the settings stay as they were when the stage started. The same lines are appended to `tmp/lab.log` under the work directory (default `/virtualmachines/tmp/lab.log`). That file stays when you quit and when you reset the lab. Interrupt a running stage and the menu comes back; the stage's marker is left unset, so the next run retries it.

The menu asks for your sudo password on this computer only when a stage mounts a guest disk here. VirtualBox does that in stages 3 and 5 for Guest Additions. Proxmox does it in stage 3, to plant the QEMU guest agent on each disk before the copy.

From a shell without a terminal, `./scripts/lab.sh` prints the checklist and exits 0 only when every marker is present.

```bash
./scripts/lab.sh
./scripts/lab.sh --kit /virtualmachines/Kit/Original/Win11_25H2_Lab.zip --dest /virtualmachines
./scripts/lab.sh phase1 --no-prompt
./scripts/lab.sh all --no-prompt
./scripts/lab.sh status
```

`phaseN` uses the same dependency rules and exits 1 when the stage is blocked or the script fails. `all` walks stages 1–6, skips stages that already passed, and stops on the first failure. Stage 5 powers the VMs on and then off. Stage 6 only checks that cleanup refuses to delete anything; it does not delete the lab.

Finished steps record a timestamp under `TMP_DIR/.markers`. The next run skips a step while its marker exists, even if you removed the files by hand. `--force` ignores the markers and runs the step again.

## Before you start

1. Copy the example config and set the password. Leave the file uncommitted.

   ```bash
   cp config/lab.env.example config/lab.env
   ```

2. Put the lab ZIP somewhere with a lot of free space. The default path is `/virtualmachines/Kit/Original/Win11_25H2_Lab.zip`. Extraction and the flattened disks need substantially more than the 32 GB archive.
3. Install the host tools, then the menu's Python library. The scripts do not install packages for you. Backend tools are listed in the hypervisor guide.

   ```bash
   ./scripts/check-prereqs.sh
   python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
   ```

| Tool | Used for |
|------|----------|
| `unzip` | Open the lab ZIP |
| `7z` (or `7za`) | Unpack `setup.exe` resources. Do not run `setup.exe` under Wine |
| `zpaq`, or `wine` | Unpack the ZPAQ payload. Native `zpaq` is used when it is installed; otherwise Wine runs the `zpaq.exe` shipped inside the kit. Mono is not required |
| `qemu-img` | Convert VHDX to the hypervisor disk format |
| `dotnet` | Build `tools/VhdxFlatten` and `tools/HiveSet` |
| `python3`, Textual | The menu. Stage scripts stay Bash. Install Textual with the venv command above |

Large media stays under the work directory, default `/virtualmachines`. It does not go into this git repository and it does not need to go under your home directory.

| Path | Role |
|------|------|
| `/virtualmachines/Kit/Original/` | The ZIP you downloaded. The scripts never delete it |
| `/virtualmachines/source` | Immediate unzip of the ZIP |
| `/virtualmachines/tmp` | ZPAQ unpack, setup resources, inventory, converted disks, identity files, markers, `lab.log` |

`--kit` selects the ZIP. `--dest` sets both the work directory and the VM directory for that one command. The menu can save those two directories separately. Flags override `config/lab.env`. A phase script run on its own still asks for the paths; Enter accepts the default. `--no-prompt` or `LAB_NONINTERACTIVE=1` skips those prompts. Proxmox keeps the work directory local and creates the guests on the node. It does not use the VM directory for machine folders.

## Configuration

`config/lab.env.example` lists every setting. `config/lab.env` is the local copy. Hypervisor settings are on the [VirtualBox](docs/virtualbox.md) and [Proxmox](docs/proxmox.md) pages.

| Setting | Default | Meaning |
|---------|---------|---------|
| `LAB_WORK_DIR` | `/virtualmachines` | Unzip, converted disks, and the log. `source/` and `tmp/` are created under it |
| `SOURCE_DIR` | `/virtualmachines/source` | Immediate unzip |
| `TMP_DIR` | `/virtualmachines/tmp` | Converted disks, markers, and the log |
| `LAB_ZIP_PATH` | the Kit/Original ZIP | Archive for this run |
| `HYPERVISOR` | `virtualbox` | Backend directory name |
| `LAB_PREFIX` | `HYD` | VM name prefix and network prefix |
| `LAB_NETWORK_NAME` | `CorpNet` | Logical LAN name |
| `LAB_PARALLEL` | `1` | Convert independent disks together. `0` converts one at a time |

The lab account is `Corp\LabAdmin` with the password that comes with the kit. It is cached on every guest, so it is not a setting, and `lab.env` does not override it.

Shared lab shape is `config/topology.tsv`: name, role, memory, CPUs, disk, and NICs. Guest OS ids live under `config/hypervisors/<name>/`, so each backend can map the same three servers to its own types. Boot order and the pause after each start are `config/boot-order.tsv`: DC, then the gateway, then CM, with waits of 90, 30, and 60 seconds. CM is last because its first boot is the heaviest.

## Stages

### Stage 1 — Extract and organize

The ZIP is only an input. Phase 1 checks prerequisites, then:

1. Unzips the archive into `source/`.
2. Unpacks the ZPAQ payload into `tmp/`. This is the long step.
3. Unpacks `setup.exe` resources with `7z`.
4. Organizes disks, original VM trees, and tools into a known layout and writes an inventory.

`./scripts/verify-phase1.sh` checks that layout and writes the phase checkpoint. You can run one extract step with `./scripts/extract-lab.sh --step zip|zpaq|setup|organize`.

### Stage 2 — Convert disks

The kit's disks are Hyper-V VHDX, and several of them are differencing disks whose parent is `ServerParent.vhdx`. `qemu-img` cannot open those differencing files on Linux.

1. `scripts/inventory-disks.sh` records each disk and its parent.
2. `tools/VhdxFlatten` walks a differencing chain and writes a flat VHDX. A message that the first open could not find a parent is the tool switching to an explicit parent path. Small checkpoint AVHDX files are skipped on purpose.
3. `qemu-img` converts the flat image to the backend's disk format. VirtualBox uses VDI. Proxmox uses qcow2. `--format vdi|vmdk|qcow2` overrides that. Each disk logs its start and how many seconds it took.
4. The backend checks that it can open the result.

`VhdxFlatten` is built only when its Release binary is missing or older than the tool's sources. Converted files land in `tmp/convert`. Parallel disks runs up to three independent conversions at once. Parents finish before children.

### Stage 3 — Create the virtual machines

`scripts/create-lab-vms.sh` loads the backend and creates the servers listed in the topology. Run next boots the gateway briefly, then powers it off. Run all skips that boot. Disk placement, firmware, and what the smoke boot waits for are in the hypervisor guide.

### Stage 4 — Identity templates

This stage writes operator files. It does not rebuild the servers.

`scripts/prepare-identity.sh` renders:

- `tmp/identity/credentials.md` — where the account is recorded. The password is not written there
- `tmp/identity/first-boot-notes.md` — start order and a guest-tools note
- `tmp/identity/unattend/HYD-CLIENT*-oobe.xml` — client OOBE stubs for a later step
- a VM description on each server (role, domain, account name, network). The password is not part of the description

The client unattend XML is not applied to a disk yet.

### Stage 5 — Start and stop

`scripts/lab-ctl.sh` is the runtime control for the selected hypervisor.

```bash
./scripts/lab-ctl.sh start          # DC, then gateway, then CM, with the waits in boot-order.tsv
./scripts/lab-ctl.sh start --no-wait
./scripts/lab-ctl.sh stop
./scripts/lab-ctl.sh status
./scripts/lab-ctl.sh health
```

`start` boots in the order in `boot-order.tsv` and waits for that backend's guest service. The settle time (90s for the domain controller, then 30s, then 60s) starts when that VM starts. `--no-wait` skips the settle time. It does not skip the guest-service wait. Stop walks the boot order in reverse. `health` checks that each lab VM is registered, has its disk, and is on CorpNet.

Phase 5 runs health, a start with `--no-wait`, and a stop, then checks that the three servers are powered off.

### Stage 6 — Cleanup safety, and reset

Phase 6 does not delete the lab. It checks that `cleanup-lab.sh` refuses to run without `--yes`, refuses to run when nothing is selected, refuses `--reset` without `--yes`, and that the three lab VMs are still present.

Press `c` in the menu to reset the lab. The menu asks you to confirm, then deletes every VM named by an active row in `config/topology.tsv` after powering it off, plus `source/`, and everything under `tmp/` except `lab.log`. The kit ZIP stays. A name is removed only when it is in the topology and starts with `LAB_PREFIX`. Folders, registered media, and remote disks follow the hypervisor guide.

```bash
./scripts/cleanup-lab.sh --reset --yes
```

On an interactive terminal that command also asks you to type `YES`. `a` does not run this. After a reset the markers are gone, so the next build starts at stage 1.

`--all-work` still means the VMs plus the scratch trees under `tmp/`, and it leaves `source/` in place. Other flags are `--vms`, `--tmp`, `--convert`, and `--identity`.

## Repository layout

```text
config/lab.env.example          # copy to lab.env; lab.env is gitignored
config/topology.tsv             # shared VM shape
config/boot-order.tsv           # start order and pauses
config/hypervisors/virtualbox/  # VirtualBox guest OS ids
config/hypervisors/proxmox/     # Proxmox guest ids and VMIDs
config/hypervisors/libvirt/     # libvirt osinfo variants
scripts/lab.sh                  # starts the Python menu
python/labkit/                  # Textual menu, settings, stage runner
scripts/phase1.sh … phase6.sh   # one Bash stage each
scripts/lib/                    # config, checklist, hypervisor loader
scripts/hypervisors/virtualbox/ # VirtualBox create, control, Guest Additions
scripts/hypervisors/proxmox/    # Proxmox API create, control, disk import
scripts/hypervisors/libvirt/    # libvirt / QEMU create, control, guest agent plant
templates/                      # identity notes and client unattend
tools/VhdxFlatten/              # differencing VHDX flattener
tools/HiveSet/                  # offline registry writer
third_party/nuget/              # DiscUtils and Registry packages, MIT
docs/SPEC.md                    # short spec
docs/virtualbox.md              # VirtualBox operator guide
docs/proxmox.md                 # Proxmox operator guide
docs/libvirt.md                 # libvirt operator guide
```

`scripts/create-lab-vms.sh` and `scripts/lab-ctl.sh` stay the public commands. They load `scripts/hypervisors/$HYPERVISOR/load.sh` and run that backend's create and control scripts.

Build output under `tools/**/bin` and `tools/**/obj` is gitignored. So are `config/lab.env`, archives, and disk images.

## Included software

`third_party/nuget/` holds DiscUtils 0.16.13 (Kenneth Bell, Quamotion, LordMike, and other contributors) and `Microsoft.Win32.Registry` 5.0.0. Both are MIT licensed. The notice is `third_party/nuget/LICENSE.txt`. `nuget.config` resolves those packages from the repository and leaves nuget.org available for the .NET SDK's own targeting packs.

The menu uses [Textual](https://textual.textualize.io/), which is MIT licensed and installed from `requirements.txt`. It is not vendored. The stage scripts stay Bash. There is no Node dependency.

## What is not in git

Lab ZIPs, ZPAQ archives, VHDX and converted disks, `config/lab.env`, and tool build output. Commit those and you would be publishing Microsoft media or a password.
