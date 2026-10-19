NOTE: This was written almost entirely by Cursor. I didn't really want to make this project, I was just trying to get a working lab on Linux and I got sick of the bullshit Microsoft trial versions expiring. This should ease that process of re-staging the dev lab quickly.

# Linux Windows Lab Kit

Bash scripts that build a Windows lab on a Linux host from a Microsoft lab ZIP you already have. You supply the archive and the licenses. The repository holds the orchestration only.

- **Three servers.** A domain controller, a Configuration Manager server, and a gateway. They share an internal network. The gateway also has NAT, so the lab can reach the Internet.
- **Six stages.** Extract the archive, convert the Hyper-V disks, create the virtual machines, write the lab account notes, start the machines in order, then check that cleanup will not delete the lab by accident.
- **One screen.** `./scripts/lab.sh` opens a Python menu. Each stage, Run all, Settings, Reset, and Quit are buttons. The keys `1`–`6`, `a`, `s`, `c`, and `q` still do the same things. The stage scripts stay Bash.
- **It picks up where it stopped.** A finished step is skipped until you reset or pass `--force`. Reset removes this lab only. The ZIP and any other virtual machines on the host stay.
- **Platforms**
  - ✅ VirtualBox
  - libvirt — pending
  - Proxmox — pending
  - VMware Workstation — pending

## Operator guide

This repository builds a Windows lab on a Linux host from a Microsoft lab archive you already have. You point the scripts at that ZIP. They extract it, turn the Hyper-V disks into disks the hypervisor can boot, create the server virtual machines, and start them in a safe order.

The project is independent. It is not affiliated with, endorsed by, or redistributed by Microsoft. You supply the lab ZIP and any licenses the software inside it requires. This repository contains orchestration, templates, and two small .NET tools. It does not contain Windows media, product keys, or passwords.

The hypervisor in use today is VirtualBox. `HYPERVISOR` in `config/lab.env` selects the backend. Shared stages live in `scripts/`. Anything that talks to VirtualBox lives in `scripts/hypervisors/virtualbox/` and `config/hypervisors/virtualbox/`. A later backend (VMware Workstation, libvirt, Proxmox, or another) is a new directory beside that one, with the same hooks. Those backends are not written yet.

`docs/SPEC.md` is the short design note. The sections below are the operator guide.

## What the lab is

The archive this kit was written against is the Windows 11 25H2 evaluation lab (`Win11_25H2_Lab.zip`, about 32 GB). The scripts follow the lab shape described in that kit's setup guide, restated here in our own words.

Three server virtual machines are created:

| Name | Role | Memory | CPUs | Networks |
|------|------|--------|------|----------|
| HYD-DC1 | Active Directory, DNS, DHCP, Certificate Services | 4 GB | 2 | CorpNet |
| HYD-CM1 | Configuration Manager, SQL Server, WSUS, WDS, ADK | 8 GB | 4 | CorpNet |
| HYD-GW1 | Remote Access, the lab's path to the Internet | 2 GB | 2 | CorpNet and NAT |

CorpNet is the lab LAN. On VirtualBox it is an internal network named `HYD-CorpNet`. Only the gateway has a second adapter, attached to NAT, so the lab can reach the Internet without putting every VM on the host network.

The domain, account, and network names come from configuration. The defaults are domain `Corp`, user `LabAdmin`, prefix `HYD`, and network `CorpNet`. The password is whatever you set in `config/lab.env`. The scripts never print it and the file is gitignored.

Client VMs (domain-joined and workgroup Windows 11 machines built from `WindowsParent`) are described in the topology and have an unattend template, but they are not created yet. Bare-metal Autopilot and OSD seats in the original guide are out of scope.

## What a run actually does

`./scripts/lab.sh` is the entry point. On a terminal it opens the Python menu and stays there. Press a key; Enter is not required.

| Key | Action |
|-----|--------|
| `1`–`6` | Run that stage |
| `a` | Run every stage that has not passed yet, in order. Stage 3 does not boot a VM |
| `s` | Change kit, destination, domain, account, password, or platform |
| `c` | Reset this lab, after you confirm |
| `q` | Leave the menu |

The screen shows the current settings, a progress bar for each stage, a Parallel disks checkbox, buttons for each stage, Run all, settings, reset, and quit, and the live log. Parallel disks is on unless you turn it off. It converts independent server disks at the same time. The machines still boot one after another. `s` opens a form and writes `config/lab.env`. A blank password keeps the current one, and the password is never shown. While a stage is running, the settings stay as they were when the stage started. A blocked stage is refused until the stage it depends on has passed. The same lines are appended to `tmp/lab.log` under the destination (default `/virtualmachines/tmp/lab.log`). That file stays when you quit and when you reset the lab. Interrupt a running stage and the menu comes back; the stage's marker is left unset, so the next run retries it.

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

2. Put the lab ZIP somewhere with a lot of free space. The default path is `/virtualmachines/Kit/Original/Win11_25H2_Lab.zip`. Extraction, the flattened disks, and the VM copies need substantially more than the 32 GB archive.
3. Install the host tools, then the menu's Python library. The scripts do not install packages for you.

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
| `VBoxManage` | The VirtualBox backend |
| `qemu-nbd`, `ntfs-3g` | Mount a guest disk to plant Guest Additions. The menu asks for sudo once, before a run that needs this mount |
| `python3`, Textual | The menu. Stage scripts stay Bash. Install Textual with the venv command above |

Large media stays under the destination, default `/virtualmachines`. It does not go into this git repository and it does not need to go under your home directory.

| Path | Role |
|------|------|
| `/virtualmachines/Kit/Original/` | The ZIP you downloaded. The scripts never delete it |
| `/virtualmachines/source` | Immediate unzip of the ZIP |
| `/virtualmachines/tmp` | ZPAQ unpack, setup resources, inventory, converted disks, identity files, markers, `lab.log` |
| `/virtualmachines/HYD-*` | Virtual machine folders and the disks those VMs boot |

`--kit` selects the ZIP. `--dest` selects the output root: `source/` and `tmp/` are created under it, and the root itself is the virtual machine folder. Flags override `config/lab.env`. The menu edits the same file with `s`. A phase script run on its own still asks for the paths; Enter accepts the default. `--no-prompt` or `LAB_NONINTERACTIVE=1` skips those prompts.

## Configuration

`config/lab.env.example` lists every setting. `config/lab.env` is the local copy.

| Setting | Default | Meaning |
|---------|---------|---------|
| `SOURCE_DIR` | `/virtualmachines/source` | Unzip destination |
| `TMP_DIR` | `/virtualmachines/tmp` | Working tree |
| `VM_ROOT` | `/virtualmachines` | Hypervisor machine folder |
| `LAB_ZIP_PATH` | the Kit/Original ZIP | Archive for this run |
| `HYPERVISOR` | `virtualbox` | Backend directory name |
| `LAB_PREFIX` | `HYD` | VM name prefix and network prefix |
| `LAB_NETWORK_NAME` | `CorpNet` | Logical LAN name |
| `LAB_DOMAIN` | `Corp` | Domain used in notes and the one-time logon |
| `LAB_ADMIN_USER` | `LabAdmin` | Account named in the notes and the one-time logon |
| `LAB_ADMIN_PASSWORD` | empty | Required for client unattend XML and the Guest Additions logon. Set it locally |

Shared lab shape is `config/topology.tsv`: name, role, memory, CPUs, disk, and NICs. VirtualBox guest OS ids are separate, in `config/hypervisors/virtualbox/guests.tsv`, so a different hypervisor can map the same three servers to its own guest types. Boot order and the pause after each start are `config/boot-order.tsv`: DC, then CM, then the gateway, with waits of 90, 60, and 30 seconds.

## Stage 1 — Extract and organize

The ZIP is only an input. Phase 1 checks prerequisites, then:

1. Unzips the archive into `source/`.
2. Unpacks the ZPAQ payload into `tmp/`. This is the long step.
3. Unpacks `setup.exe` resources with `7z`.
4. Organizes disks, original VM trees, and tools into a known layout and writes an inventory.

`./scripts/verify-phase1.sh` checks that layout and writes the phase checkpoint. You can run one extract step with `./scripts/extract-lab.sh --step zip|zpaq|setup|organize`.

## Stage 2 — Convert disks

The kit's disks are Hyper-V VHDX, and several of them are differencing disks whose parent is `ServerParent.vhdx`. `qemu-img` cannot open those differencing files on Linux.

1. `scripts/inventory-disks.sh` records each disk and its parent.
2. `tools/VhdxFlatten` walks a differencing chain and writes a flat VHDX. A message that the first open could not find a parent is the tool switching to an explicit parent path. Small checkpoint AVHDX files are skipped on purpose.
3. `qemu-img` converts the flat image to the backend's disk format. VirtualBox uses VDI. `--format vdi|vmdk` overrides that. Each disk logs its start and how many seconds it took.
4. The backend checks that it can open the result. For VirtualBox that check is `VBoxManage showmediuminfo`.

`VhdxFlatten` is built only when its Release binary is missing or older than the tool's sources.

Converted files land in `tmp/convert`, including `HYD-DC1.vdi`, `HYD-CM1.vdi`, and `HYD-GW1.vdi`. Those files stay there. The VM disks in stage 3 are copies.

## Stage 3 — Create the virtual machines

`scripts/create-lab-vms.sh` loads the backend and creates the servers listed in the topology.

On VirtualBox each VM is registered under `VM_ROOT`, given the memory and CPU count from the topology, set to EFI, and attached to CorpNet. HYD-GW1 also receives a NAT adapter. The converted VDI is copied onto the VM folder with `cp --reflink=always` and then given a new disk UUID. A hardlink would keep the original UUID, and VirtualBox refuses to register the same UUID at two paths. The copy is cheap on btrfs because of the reflink.

If the VM already exists and its disk is attached, creation is skipped. `--force` unregisters it and creates it again. If the VM exists without that disk, the disk is attached and creation is not repeated.

Stage 3 on its own boots HYD-GW1 headless after the VMs exist. Before that boot, the VirtualBox backend mounts the new disk and plants Guest Additions. A full run (`a` or `all`) skips that boot. Stage 5 plants the additions on each powered-off server and starts the lab, so the gateway is not booted twice. Mounting uses `qemu-nbd`. When a run includes a disk mount, the menu asks for the administrator password once before anything starts. The password is sent only to sudo, then dropped. It is not stored. A root helper then accepts only the disk-mount commands for the rest of that run. Reading the Guest Additions ISO and writing the offline registry do not need sudo.

The plant is a copy of the installer and `install-guest-additions.ps1` under `C:\Windows\Temp\vbox-ga` on the guest, plus a one-time autologon of `LabAdmin` and a RunOnce entry that runs the installer. The installer adds the VirtualBox publisher certificate, runs `VBoxWindowsAdditions-amd64.exe` silently, clears the stored password, and reboots. The script then waits until VirtualBox reports the additions service (up to 30 minutes by default). A reboot during that wait is expected. When the service reports in, the script turns on auto-resize of the guest display, the shared clipboard, and drag-and-drop. When stage 3 does boot a VM, that VM is HYD-GW1, and it is powered off after the additions service reports in.

The registry writer is `tools/HiveSet`. It uses the MIT-licensed DiscUtils packages stored in `third_party/nuget`, so that build does not download them. The .NET SDK may still contact NuGet for its own targeting packs.

## Stage 4 — Identity templates

This stage writes operator files. It does not rebuild the servers.

With `LAB_ADMIN_PASSWORD` set, `scripts/prepare-identity.sh` renders:

- `tmp/identity/credentials.md` — where the account is recorded, with the password length rather than the password
- `tmp/identity/first-boot-notes.md` — start order and the Guest Additions note
- `tmp/identity/unattend/HYD-CLIENT*-oobe.xml` — client OOBE stubs for a later step
- a VM description on each server (role, domain, account name, network). The password is not part of the description

The client unattend XML is not applied to a disk yet. Server disks receive the Guest Additions logon from stage 3, not this unattend file.

## Stage 5 — Start and stop

`scripts/lab-ctl.sh` is the runtime control for the selected hypervisor.

```bash
./scripts/lab-ctl.sh start          # DC, then CM, then gateway, with the waits in boot-order.tsv
./scripts/lab-ctl.sh start --no-wait
./scripts/lab-ctl.sh stop
./scripts/lab-ctl.sh status
./scripts/lab-ctl.sh health
```

`start` plants Guest Additions on any server that is powered off, then boots it. The settle time in `boot-order.tsv` (90s for the domain controller, then 60s, then 30s) starts when that VM starts, and it runs while the additions service is reporting in. The next VM starts once the additions are up and that settle time has passed. `--no-wait` skips the settle time. Stop walks the boot order in reverse. `health` checks that each lab VM is registered, has its disk, and is on CorpNet.

Phase 5 runs health, a start with `--no-wait`, and a stop, then checks that the three servers are powered off.

## Stage 6 — Cleanup safety, and reclaiming space

Phase 6 does not delete the lab. It checks that `cleanup-lab.sh` refuses to run without `--yes`, refuses to run when nothing is selected, refuses `--reset` without `--yes`, and that the three lab VMs are still present.

Press `c` in the menu to reset the lab. The menu asks you to confirm, then deletes:

- every VM named by an active row in `config/topology.tsv`, after powering it off
- that VM's folder under the destination
- `source/`, and everything under `tmp/` except `lab.log` (markers and the Guest Additions cache are removed)
- VirtualBox media still registered under those paths

The kit ZIP stays. The destination itself stays, so other virtual machines on the host stay. A name is removed only when it is in the topology and starts with `LAB_PREFIX`. The same reset from a shell is:

```bash
./scripts/cleanup-lab.sh --reset --yes
```

On an interactive terminal that command also asks you to type `YES`. `a` does not run this. After a reset the markers are gone, so the next build starts at stage 1.

`--all-work` still means the VMs plus the scratch trees under `tmp/`, and it leaves `source/` in place. Other flags are `--vms`, `--tmp`, `--convert`, and `--identity`.

## Hypervisor backends

Shared code asks the backend to do hypervisor work. It does not call `VBoxManage` itself. The VirtualBox module implements:

| Hook | VirtualBox behavior |
|------|---------------------|
| `hv_check_prereqs` | Require `VBoxManage` |
| `hv_disk_format` | `vdi` |
| `hv_verify_disk` | Open the converted medium |
| `hv_verify_create` | VM registered, SATA disk attached, CorpNet on nic1, NAT on the gateway |
| `hv_vm_exists`, `hv_vm_state`, `hv_delete_vm` | Query and unregister |
| `hv_close_lab_media` | Unregister disks, ISOs, and floppies under the lab directories |
| `hv_set_description`, `hv_description_ok` | VM description |
| `hv_stage_needs_privileges` | Stages 3 and 5, for the disk mount |
| `hv_prepare_privileged`, `hv_finish_privileged` | Ask for sudo once and run the mount helper |

`scripts/create-lab-vms.sh` and `scripts/lab-ctl.sh` stay the public commands. They load `scripts/hypervisors/$HYPERVISOR/load.sh` and run that backend's create and control scripts.

## Repository layout

```text
config/lab.env.example          # copy to lab.env; lab.env is gitignored
config/topology.tsv             # shared VM shape
config/boot-order.tsv           # start order and pauses
config/hypervisors/virtualbox/  # VirtualBox guest OS ids
scripts/lab.sh                  # starts the Python menu
python/labkit/                  # Textual menu, settings, stage runner
scripts/phase1.sh … phase6.sh   # one Bash stage each
scripts/lib/                    # config, checklist, hypervisor loader
scripts/hypervisors/virtualbox/ # VirtualBox create, control, Guest Additions
templates/                      # identity notes and client unattend
tools/VhdxFlatten/              # differencing VHDX flattener
tools/HiveSet/                  # offline registry writer
third_party/nuget/              # DiscUtils and Registry packages, MIT
docs/SPEC.md                    # short spec
```

Build output under `tools/**/bin` and `tools/**/obj` is gitignored. So are `config/lab.env`, archives, and disk images.

## Included software

`third_party/nuget/` holds DiscUtils 0.16.13 (Kenneth Bell, Quamotion, LordMike, and other contributors) and `Microsoft.Win32.Registry` 5.0.0. Both are MIT licensed. The notice is `third_party/nuget/LICENSE.txt`. `nuget.config` resolves those packages from the repository and leaves nuget.org available for the .NET SDK's own targeting packs.

The menu uses [Textual](https://textual.textualize.io/), which is MIT licensed and installed from `requirements.txt`. It is not vendored. The stage scripts stay Bash. There is no Node dependency.

## What is not in git

Lab ZIPs, ZPAQ archives, VHDX and VDI files, `config/lab.env`, and tool build output. Commit those and you would be publishing Microsoft media or a password.
