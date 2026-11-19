# Join My Homelab — Proxmox VE node installer

One command creates a VM on Proxmox that joins the [Join My Homelab](https://joinmyhomelab.com/) community cloud. The VM is the node: stop it to stop lending, delete it to leave.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/joinmyhomelab/proxmox/main/joinmyhomelab-node.sh)" -- --iso 'https://…/joinmyhomelab-<account>.iso'
```

The ISO link is personal. Get it from your dashboard:

```bash
ssh dashboard@joinmyhomelab.com     # then "Download your ISO"
```

## What it does

1. Checks it is running on a Proxmox VE host (refuses otherwise).
2. Checks nested virtualisation and, with your consent, turns it on. The node needs it: it runs KVM inside the VM.
3. Creates a VM (defaults: 4 cores, 8 GiB RAM, 50 GiB disk, `vmbr0`, boot on host start).
4. Downloads your personal image, checks it is a real ISO, attaches it.
5. Boots it. First boot installs to the VM's own disk, the next boot joins the cluster.

Nothing else on the host is touched: no packages, no services, no changes to other VMs.

## Options

| flag | default | meaning |
|---|---|---|
| `--iso URL` | prompt | personal ISO (or `RMHL_ISO_URL`) |
| `--name` | `joinmyhomelab-node-<n>` | VM name, numbered automatically |
| `--vmid` | first free from 900 | VM id |
| `--cores` | 4 | CPU cores |
| `--ram` | 8192 | memory, MiB |
| `--disk` | 50 | disk, GiB |
| `--bridge` | `vmbr0` | network bridge |
| `--storage` | auto | disk storage |
| `--enable-nested` | off | enable nested virt without asking |
| `--uninstall` | | stop and delete the node VM(s) |
| `--dry-run` | | print commands, change nothing |
| `-y`, `--yes` | | no prompts |

## Requirements

- Proxmox VE 8 or newer, x86_64, root.
- Nested virtualisation for the CPU vendor, otherwise the node joins but cannot run VMs:
  ```bash
  # Intel
  echo 'options kvm_intel nested=1' > /etc/modprobe.d/kvm-nested.conf
  # AMD
  echo 'options kvm_amd nested=1'   > /etc/modprobe.d/kvm-nested.conf
  # then reboot (or unload/reload the module while no VMs are running)
  ```
- A bridge with internet access (`vmbr0` by default).

## Check it is healthy

```bash
# The Proxmox web UI console (noVNC) shows the boot and install.
# "Installing" is followed by a reboot, then the node joins.
ssh dashboard@joinmyhomelab.com     # NODES shows it green when ready
```

`qm terminal <vmid>` shows the boot menu and early kernel messages; Talos then
switches to the graphical console, so use the web console for the install log.

A node that says `no /dev/kvm — enable nested virtualization` means the VM is up but nested virt is off on the host.

## Remove it

```bash
bash joinmyhomelab-node.sh --uninstall
```

Stops and deletes only the `joinmyhomelab-node*` VMs, after a confirmation.

## Security notes

The ISO URL contains your account token. The script never prints it and does not store it; the downloaded image lives in `/var/lib/vz/template/iso/joinmyhomelab-node.iso`. Your node's VMs are readable by you as host operator — the platform says so plainly, and nothing confidential belongs on them.

## Development

```bash
shellcheck joinmyhomelab-node.sh
./joinmyhomelab-node.sh --dry-run --iso https://example.com/x.iso   # no changes
```

MIT licensed.