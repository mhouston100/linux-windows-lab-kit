# Proxmox

Proxmox is a second backend beside VirtualBox. The menu, the six stages, and the work directory are the same. This page is the node, the API token, and what create and reset do on Proxmox.

> **Use root.** The menu defaults to `root@pam!root` and SSH user `root`. A large disk upload through the API fails. pveproxy writes the whole file under `/var/tmp` and logs `multipart upload complete`, then allows 5 seconds for the hand-off that creates the import task. A 26 GB file finishes in that window. A 54 GB file does not: the worker logs `Connection timed out`, exits, and the client gets curl error 52 with no HTTP response. There is no setting for that timer. The kit copies each qcow2 with rsync over SSH into the import directory from the storage record, then the API imports that file onto the guest disk. rsync keeps a partial file. The same run tries the copy again, and a later run continues it. The menu asks for the SSH password before Test connection and before the first stage of a run. It is not stored. A user you create still needs the API roles below, plus an SSH login and write permission on that import directory. The API roles do not grant that write.

The code is in the tree and covered by unit tests against a fake API. A live run created the first guest, then the 54 GB API upload hit the timeout above. The copy is now rsync. Stage 5 waits for the QEMU guest agent, and that agent is not planted in the disk, so a full start stops there.

`HYPERVISOR=proxmox` selects `scripts/hypervisors/proxmox/` and `config/hypervisors/proxmox/`.

## Settings

Choosing Proxmox replaces the VM directory with these fields. They are saved in gitignored `config/lab.env`. The token secret is masked. A blank secret keeps the current one. The secret is never written to the log, and curl reads it from a short-lived root-only config file rather than its command line.

**Test connection** is on the right of this box. It asks for the SSH password first, then asks the API for the version, checks that the node lists guests, and that the import storage allows Import and the disk storage allows Disk image. It does not create a guest or copy a disk. It also checks the two bridge names, and that the SSH login can write the import directory. Proxmox leaves Linux bridges out of that list until the token can see `/sdn/zones/localnetwork`. A `root@pam` token with privilege separation off already can. A separated token needs `PVESDNUser` on that path.

| Setting | Meaning |
|---------|---------|
| `PVE_API_HOST` | Address the kit connects to, with an optional `:port`. The default port is 8006 |
| `PVE_TLS_FINGERPRINT` | Optional SHA256 pin of that node's web certificate. Blank skips the check. A value is compared before the token is sent |
| `PVE_NODE` | Proxmox node name from the left tree, often `pve`. This is which node receives the guests, and it can differ from the API host |
| `PVE_IMPORT_STORAGE` | Directory, NFS, or CIFS storage for the temporary qcow2 upload. It needs the Import content type. Default `local` |
| `PVE_STORAGE` | Storage for the guest disks and the EFI disk. It needs Disk image. Default `local-lvm` |
| `PVE_KEEP_IMPORTS` | `1` leaves each uploaded qcow2 on the import storage. Default `0`, which removes it after that guest disk exists |
| `PVE_BRIDGE` | Existing bridge for CorpNet. Default `vmbr1` |
| `PVE_INTERNET_BRIDGE` | Existing bridge for the gateway's second NIC. Default `vmbr0` |
| `PVE_TOKEN_ID` | Token id. Default `root@pam!root`, which is the Linux root user in the PAM realm and token name `root`. The field stays editable |
| `PVE_TOKEN_SECRET` | Token secret from the Proxmox UI. Shown once. No default |
| `PVE_SSH_USER` | Login for the disk copy. Default `root` |
| `PVE_SSH_HOST` | SSH address. Blank uses the API host without its port |
| `PVE_SSH_PORT` | SSH port. Default `22` |
| `PVE_SSH_IDENTITY` | Optional private key for a shell run outside the menu. A menu run asks for the SSH password instead |
| `PVE_AGENT_WAIT` | Seconds to wait for the guest agent. Default 1800 |

Disk format is qcow2. The field is visible and locked. Guest ids and VMIDs are in `config/hypervisors/proxmox/guests.tsv`: HYD-DC1 is 9101, HYD-CM1 is 9102, HYD-GW1 is 9103. Change those numbers before the first create if the cluster already uses them.

The work directory stays on this machine. `source/` and `tmp/` are still under it. Proxmox does not create machine folders in the VM directory, and reset does not delete local `HYD-*` folders.

## What to create on the node

The menu already shows node `pve`, import storage `local`, disk storage `local-lvm`, CorpNet bridge `vmbr1`, Internet bridge `vmbr0`, and token id `root@pam!root`. **Keep uploaded images** is off. Change any of them. The first start writes each missing default from `config/lab.env.example` into `config/lab.env`. A line that is already there stays, and that saved value is what the stages use. The kit does not look up a user, a token, or a pool by a special name.

A pool is not required. The kit does not take a pool name and does not put the three guests in one. A permission that exists only on the pool does not cover these guests. Keep the pool if you want it for your own grouping, and still add the permissions below.

The default is aimed at a development node. A token on `root@pam` with privilege separation off can do anything root can do through the API.

### 1. Token on root

`root@pam` already exists. It is the Linux root account. No new user is required.

Datacenter → Permissions → API Tokens → Add.

| Field | Value | What it means |
|-------|-------|----------------|
| User | `root@pam` | The existing root user |
| Token ID | `root` | A short name for this token. It is not the full id |
| Privilege Separation | disabled | The token keeps root's permissions. No role rows are required |

The dialog shows a Secret once. Copy it before you close the dialog. If you already closed it, remove that token and add it again.

The menu's **Token id** is `root@pam!root`. That is `user@realm!tokenname`. The menu's **Token secret** is the Secret from the dialog, not the token name.

Leave privilege separation off for the default lab setup. If you turn it on, root still has every privilege, and the token does not. Add the roles in the next section to the token only. The user side is already satisfied.

### 2. Roles when the token is separated, or the user is not root

Privilege separation keeps a privilege only when both the user and the token have it. A role on the token alone is not enough, and a role on the user alone is not enough. A pool role is not used, because the kit does not put the guests in a pool. The node name is not a permission path.

Datacenter → Permissions → Permissions. Leave Propagate checked.

For `root@pam!root` with separation on, add each row once with **Add → API Token Permission**.

For any other user, add each row twice: once with **Add → User Permission**, once with **Add → API Token Permission**.

| Path | User | API token | Role |
|------|------|-----------|------|
| `/vms` | the user id | the token id | `PVEVMAdmin` |
| `/storage/local` | the user id | the token id | `PVEDatastoreAdmin` |
| `/storage/local-lvm` | the user id | the token id | `PVEDatastoreAdmin` |
| `/sdn/zones/localnetwork` | the user id | the token id | `PVESDNUser` |

The storage path is `/storage/` plus the storage id in the menu. Add a row for the import storage and a row for the disk storage when those ids are not `local` and `local-lvm`. An import storage named `unraid01` uses `/storage/unraid01`.

`PVEVMAdmin` on `/vms` can create the guest, set CPU, memory, disk, and NIC, and power it on and off. `PVEDatastoreAdmin` can create the guest disk from the copied image and remove that image afterward. `PVESDNUser` on `/sdn/zones/localnetwork` is what lets the token see `vmbr0` and `vmbr1` and attach a guest NIC to them. On the node, `pveum user permissions root@pam!root` lists the privileges that survive the intersection. An empty list means one of the two sides is missing.

### 3. Another user

Use this when the token should not be root. The menu's Token id field accepts any `user@realm!tokenname`.

**Proxmox VE realm.** Datacenter → Permissions → Users → Add. User name `labkit`, realm Proxmox VE authentication server, and a password. Leave **Key IDs** blank. That field is a YubiKey id, and the kit does not read it. The user id is `labkit@pve`. The kit does not log in with this password.

**Linux PAM realm.** Create the Linux account on the node first. The user dialog does not create it:

```bash
adduser labkit
```

Then Datacenter → Permissions → Users → Add. User name `labkit`, realm Linux PAM. Leave **Key IDs** blank. The user id is `labkit@pam`. The Linux password is for SSH. The kit's API calls still use the token secret, not that password.

Then Datacenter → Permissions → API Tokens → Add. Choose that user, set Token ID to a short name such as `labkit`, and leave Privilege Separation enabled. The menu value is `labkit@pve!labkit` or `labkit@pam!labkit`.

Add the roles in the previous section to both the user and the token. These roles do not make a Linux account the owner of an import directory. A CIFS or directory mount owned by root still refuses a write from `labkit` until that directory is writable by `labkit`. Put that user's SSH public key in the account's `authorized_keys`. The menu's SSH user is that account name, not the token id. A Proxmox VE realm user such as `labkit@pve` is not a Linux account and cannot SSH.

### 4. Storage content

A stock install has two storages. `local` is a folder on the root disk, about 96 GB at most. `local-lvm` (or `local-zfs` when the installer used ZFS) holds the guest disks.

Datacenter → Storage → `local` → Edit → Content → include **Import** → OK. Leave the existing content types checked. `local-lvm` does not offer Import. Confirm **Disk image** is checked on `local-lvm`.

The menu's **Import storage** is the temporary upload. **Disk storage** is where the guest disk is created. **Keep uploaded images** is off. Each qcow2 is removed from the import storage after that guest disk exists, so the import storage only has to hold the largest file. Turn the checkbox on when that storage should keep the files. If they do not all fit, the run says so and removes each upload anyway. If the largest file does not fit, or the guest disks do not fit on the disk storage, stage 3 stops before it creates a guest.

### 5. Bridges

The node name is the name in the left tree under Datacenter. It is often `pve`. That exact string is the menu's Node field.

Node → System → Network. A physical NIC such as `eno1` cannot be used as a menu bridge. `vmbr0` is usually already there and is the host's LAN. Use it as the Internet bridge. If the list has only physical NICs, create the Linux bridges below. An empty bridge does not move the host address off the physical NIC.

Create → Linux Bridge:

| Field | Value |
|-------|--------|
| Name | `vmbr1` |
| Bridge ports | empty |

Leave the ports empty so CorpNet is not attached to a physical network. Create, then Apply Configuration. Do not change `vmbr0` in the same edit.

| Menu field | Example | Where it comes from |
|------------|---------|---------------------|
| API host | `pve.example:8006` | The node address. Port 8006 is the API |
| TLS fingerprint | blank, or the `SHA256=` value | Optional. Blank skips the check. The command below reads it |
| Node | `pve` | The node name in the left tree |
| Import storage | `local` | The directory storage with Import enabled |
| Disk storage | `local-lvm` | The storage with Disk image enabled |
| CorpNet bridge | `vmbr1` | The empty bridge |
| Internet bridge | `vmbr0` | The bridge that already has the host's network |
| Token id | `root@pam!root` | User id, `!`, token name. Editable |
| Token secret | the Secret from the token dialog | Shown once |
| SSH user | `root` | The Linux account that can write the import directory |
| SSH host | blank | Uses the API host without the port |
| SSH port | `22` | The SSH port on that host |
| SSH identity | blank | Optional. A menu run asks for the password |

Both bridge fields can be `vmbr0` for a first test. The two lab networks are then the same bridge.

Read the fingerprint from the Linux machine that runs the kit, with the node address you will type as the API host:

```bash
openssl s_client -connect pve.example:8006 </dev/null | openssl x509 -fingerprint -sha256 -noout
```

The kit calls `https://<host>:8006/api2/json`. Host tools are `curl`, `openssl`, `ssh`, and `rsync`, plus `python3` to read the JSON replies. `qemu-img` still does the local convert.

The menu asks for the SSH password before Test connection and before the first stage of Run next or Run all. Enter it once. The dialog logs in with that password and stays open until the login works. A wrong password, a refused connection, or a missing SSH host does not start the stage. That run uses the password for every copy, including a retry after a dropped connection. When the run ends, the password is dropped. It is not written to `config/lab.env`. The next run asks again. The login message is written to the log, and the size check reads only the number `stat` prints.

A shell run outside the menu has no dialog. Leave SSH identity blank to use the default keys, or set that field to a key file. Test connection checks the login and the import directory before a disk is copied.

## Disks and guests

Stage 2 writes `tmp/convert/HYD-DC1.qcow2` and the same for CM and the gateway. `qemu-img info` must report qcow2.

Stage 3 checks free space, then creates each VM. It copies that guest's qcow2 with rsync into the import directory, then attaches it as SATA with `import-from` on the disk storage. The directory comes from the storage record: its `path`, plus the `import` folder, or the folder named by `content-dirs`. The guest disk on LVM or ZFS is still created by the API, because those pools have no directory to copy into. With **Keep uploaded images** off, the copied file is removed before the next guest.

rsync writes straight to that directory. It does not stage the file under `/var/tmp`. `--partial` leaves an unfinished file in place, and `--append-verify` continues it. A dropped connection is tried up to five times in the same run. The next stage 3 continues the same file when the remote size is still short. A remote file that is already the same size is left as it is. A remote file that is longer is removed and copied again.

Each guest is OVMF on machine `q35`, with an EFI disk and e1000 NICs, so the Hyper-V image can boot before virtio drivers exist. CorpNet is `PVE_BRIDGE`. The gateway's second NIC is `PVE_INTERNET_BRIDGE`. There is no VirtualBox-style NAT device. Memory and CPU come from `config/topology.tsv`. The guest agent flag is turned on in the VM config. The agent program is not copied into the disk.

If the name already exists on the node with the expected VMID and a SATA disk, creation is skipped. `--force` deletes that guest and creates it again. A VMID that belongs to a different name is left alone.

Stage 3 on its own powers the gateway on and then off. It does not wait for the guest agent. A full run skips that power cycle.

## Start, health, and reset

`start` boots DC, then CM, then the gateway, and polls the QEMU guest agent. The default wait is 30 minutes. Until the agent is planted, that wait ends with a failure. `--no-wait` skips the settle time in `boot-order.tsv` and still waits for the agent.

Stop sends an ACPI shutdown, then a hard stop if the guest is still up after about 45 seconds.

`health` checks that each lab VM is registered, has a SATA disk, and that net0 is on the CorpNet bridge.

Reset deletes a guest only when its name is in the topology, starts with `LAB_PREFIX`, and its VMID is the one in `guests.tsv`. It then removes that guest's import image. It does not delete local machine folders, the kit ZIP, or any other guest on the cluster.
