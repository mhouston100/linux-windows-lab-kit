# Linux Windows Lab Kit

Linux-side orchestration to stand up a Windows 11 / Server / Microsoft 365 / MECM-style lab on **VirtualBox**, driven by a user-supplied Microsoft lab archive.

This is an **independent project**. It is not affiliated with, endorsed by, or redistributed by Microsoft. You supply the lab ZIP and any licenses. This repo ships orchestration and templates only.

Copy `config/lab.env.example` to `config/lab.env` and set `LAB_ZIP_PATH` plus `LAB_ADMIN_PASSWORD` there. `config/lab.env` is gitignored.

## Storage layout (defaults)

Large media stays under `/virtualmachines`, not in this git repo and not under `/home`:

| Path | Purpose |
|------|---------|
| `/virtualmachines/source` | Lab ZIP + immediate unzip (`extract/` → `.zpaq`, `setup.exe`, `zpaq.exe`) |
| `/virtualmachines/tmp` | Transitive data: ZPAQ unpack, setup resources, organize inventory, convert scratch |
| `/virtualmachines` | VirtualBox machine folder (VM definitions + final disks), same idea as the VirtualBox default |

Scripts **prompt** for these paths on interactive runs (Enter = default). Use `--no-prompt` / `LAB_NONINTERACTIVE=1` for automation.

## Phase 1 — Extraction

```bash
cd ~/projects/linux-windows-lab-kit
./scripts/check-prereqs.sh
./scripts/phase1.sh                 # prompts for paths, then extract + verify
# or non-interactive with defaults / config/lab.env:
./scripts/phase1.sh --no-prompt
```

Step-by-step:

```bash
./scripts/extract-lab.sh --step zip
./scripts/extract-lab.sh --step zpaq      # long; tens of GB under TMP_DIR
./scripts/extract-lab.sh --step setup
./scripts/extract-lab.sh --step organize
./scripts/verify-phase1.sh
```

Notes:

- Prefer `/virtualmachines` over `/home` for free space.
- ZPAQ uses native `zpaq` if installed, otherwise **Wine + bundled `zpaq.exe`**. Mono is not required.
- Do not run `setup.exe` under Wine; we only unpack resources with `7z`.
- A finished step is skipped when its marker exists under `TMP_DIR/.markers`. Pass `--force` to run it again. Extracted files stay in `source/` and `tmp/` so later phases can reuse them.

## Repo layout

```text
config/     # lab.env.example, topology.tsv (local lab.env is gitignored)
docs/       # Spec and topology notes
scripts/    # Phase scripts
templates/  # Our unattend / first-boot templates
tools/      # VhdxFlatten source (DiscUtils). Build output is gitignored.
```

## Phase 2 — Disk conversion

Hyper-V lab disks are often **differencing VHDX** (child → `ServerParent.vhdx`). `qemu-img` cannot open those on Linux, so we:

1. Inventory disks / parents (`scripts/inventory-disks.sh`)
2. Flatten differencing VHDX with `tools/VhdxFlatten` (DiscUtils / .NET)
3. Convert to VirtualBox `VDI` with `qemu-img`
4. Verify with `VBoxManage showmediuminfo`

```bash
./scripts/phase2.sh --no-prompt          # long-running
# or: ./scripts/inventory-disks.sh && ./scripts/convert-disks.sh && ./scripts/verify-phase2.sh
```

Outputs land in `TMP_DIR/convert` (default `/virtualmachines/tmp/convert`).

## Phase 3 — Create VirtualBox VMs

Creates server VMs from `config/topology.tsv`, attaches converted VDIs under `VM_ROOT` (hardlinked from `TMP_DIR/convert` when possible), and wires:

- **CorpNet** → VirtualBox internal network `HYD-CorpNet` (nic1 on all servers)
- **Internet** → NAT on nic2 for `HYD-GW1`

```bash
./scripts/phase3.sh --no-prompt          # create + smoke power-on + verify
# or: ./scripts/create-lab-vms.sh && ./scripts/verify-phase3.sh
# recreate: ./scripts/phase3.sh --force --no-prompt
```

Client VMs (`WindowsParent` differencing) are optional follow-up.

## Phase 4 — Identity / unattend

```bash
cp config/lab.env.example config/lab.env   # set LAB_ADMIN_PASSWORD
./scripts/phase4.sh --no-prompt
# Outputs under TMP_DIR/identity/ (credentials notes + client unattend XML)
```

## Phase 5 — Ordered start / stop

```bash
./scripts/lab-ctl.sh start                 # DC → CM → GW with waits
./scripts/lab-ctl.sh start --no-wait
./scripts/lab-ctl.sh stop
./scripts/lab-ctl.sh status
./scripts/lab-ctl.sh health
./scripts/phase5.sh                        # health + start/stop smoke
```

## Phase 6 — Cleanup

```bash
./scripts/phase6.sh                        # verifies safety gates only
# Reclaim space (explicit; never deletes SOURCE ZIP / Kit/Original):
./scripts/cleanup-lab.sh --all-work --yes
```

## Status

This first stage scripts phases 1–6 for the three server VMs (`HYD-DC1`, `HYD-CM1`, `HYD-GW1`): extract, convert, create, identity templates, ordered start/stop, and confirmed cleanup. Client VMs from `WindowsParent.vdi` are not created yet.

Not in git: lab ZIPs, ZPAQ archives, disks, `config/lab.env`, and `tools/VhdxFlatten/{bin,obj}`.
