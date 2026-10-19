# Proxmox

Proxmox is a second backend beside VirtualBox. The menu, the six stages, and the work directory are the same. This page is the node, the API token, and what create and reset do on Proxmox.

The code is in the tree and covered by unit tests against a fake API. It has not been run against a live node yet. Stage 5 waits for the QEMU guest agent, and that agent is not planted in the disk, so a full start stops there.

`HYPERVISOR=proxmox` selects `scripts/hypervisors/proxmox/` and `config/hypervisors/proxmox/`.

## Settings

Choosing Proxmox replaces the VM directory with these fields. They are saved in gitignored `config/lab.env`. The token secret is masked. A blank secret keeps the current one. The secret is never written to the log, and curl reads it from a short-lived root-only config file rather than its command line.

| Setting | Meaning |
|---------|---------|
| `PVE_API_HOST` | Host, with an optional `:port`. The default port is 8006 |
| `PVE_TLS_FINGERPRINT` | SHA256 fingerprint of the API certificate. A call is refused when it does not match |
| `PVE_NODE` | Node the guests are created on |
| `PVE_STORAGE` | Storage that allows the `import` content type |
| `PVE_BRIDGE` | Existing bridge for CorpNet |
| `PVE_INTERNET_BRIDGE` | Existing bridge for the gateway's second NIC |
| `PVE_TOKEN_ID` | Token id, shaped like `user@pve!labkit` |
| `PVE_TOKEN_SECRET` | Token secret from the Proxmox UI. Shown once |
| `PVE_AGENT_WAIT` | Seconds to wait for the guest agent. Default 1800 |

Disk format is qcow2. The field is visible and locked. Guest ids and VMIDs are in `config/hypervisors/proxmox/guests.tsv`: HYD-DC1 is 9101, HYD-CM1 is 9102, HYD-GW1 is 9103. Change those numbers before the first create if the cluster already uses them.

The work directory stays on this machine. `source/` and `tmp/` are still under it. Proxmox does not create machine folders in the VM directory, and reset does not delete local `HYD-*` folders.

## API token

Do this on the Proxmox host. Keep the secret in `config/lab.env`.

1. Add a user in the Proxmox realm, for example `labkit@pve`.
2. Add an API token on that user with privilege separation enabled. The token id the kit sends is `labkit@pve!labkit` when the token name is `labkit`.
3. Grant that token a role that can create a VM, set CPU, memory, disk, and NIC, power it on and off, and delete it, on a pool that will hold only these guests. Grant allocate-space on the storage. An existing bridge is enough for the NICs. The token does not need permission to change the host network.
4. Read the certificate fingerprint and paste it into the menu:

   ```bash
   openssl s_client -connect HOST:8006 </dev/null | openssl x509 -fingerprint -sha256 -noout
   ```

The kit calls `https://<host>:8006/api2/json`. Host tools are `curl` and `openssl`, plus `python3` to read the JSON replies. `qemu-img` still does the local convert.

## Disks and guests

Stage 2 writes `tmp/convert/HYD-DC1.qcow2` and the same for CM and the gateway. `qemu-img info` must report qcow2.

Stage 3 uploads each file into the storage import area, then creates the VM and attaches that image as SATA with `import-from`. The storage has to allow content type `import` (Datacenter, Storage, edit the storage, Content). A directory storage such as `local` can do this. The upload is the large copy. It has not been timed on a live node.

Each guest is OVMF on machine `q35`, with an EFI disk and e1000 NICs, so the Hyper-V image can boot before virtio drivers exist. CorpNet is `PVE_BRIDGE`. The gateway's second NIC is `PVE_INTERNET_BRIDGE`. There is no VirtualBox-style NAT device. Memory and CPU come from `config/topology.tsv`. The guest agent flag is turned on in the VM config. The agent program is not copied into the disk.

If the name already exists on the node with the expected VMID and a SATA disk, creation is skipped. `--force` deletes that guest and creates it again. A VMID that belongs to a different name is left alone.

Stage 3 on its own powers the gateway on and then off. It does not wait for the guest agent. A full run skips that power cycle.

## Start, health, and reset

`start` boots DC, then CM, then the gateway, and polls the QEMU guest agent. The default wait is 30 minutes. Until the agent is planted, that wait ends with a failure. `--no-wait` skips the settle time in `boot-order.tsv` and still waits for the agent.

Stop sends an ACPI shutdown, then a hard stop if the guest is still up after about 45 seconds.

`health` checks that each lab VM is registered, has a SATA disk, and that net0 is on the CorpNet bridge.

Reset deletes a guest only when its name is in the topology, starts with `LAB_PREFIX`, and its VMID is the one in `guests.tsv`. It then removes that guest's import image. It does not delete local machine folders, the kit ZIP, or any other guest on the cluster.
