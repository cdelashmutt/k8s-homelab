# Homelab Bootstrap Guide

This documents how to rebuild the cluster from scratch. The goal is: install
Ubuntu manually on each node, then let Ansible and GitOps handle everything else.

## Hardware

3x Intel NUC nodes:
- ubuntu1.home — NUC6, 223GB SSD (OS), 931GB NVMe (Longhorn storage)
- ubuntu2.home — NUC6, 111GB SSD (OS), 931GB NVMe (Longhorn storage)
- ubuntu3.home — NUC5, 232GB SSD (OS), 931GB NVMe (Longhorn storage)

**NUC BIOS tips (headless operation):**
- After Power Failure → Power On
- Fast Boot → Disabled
- Deep Sleep (S4/S5) → Disabled
- Consider HDMI dummy plugs to prevent GPU hang on reboot

## Step 1: Install Ubuntu on each node (manual)

1. Boot Ubuntu Server LTS from USB
2. Use default partitioning on the SSD — leave the NVMe unformatted
3. Create user: `cdelashmutt`
4. Enable OpenSSH server during install
5. Set hostname: `ubuntu1`, `ubuntu2`, or `ubuntu3`
6. After boot, add your SSH public key:
   ```bash
   ssh-copy-id cdelashmutt@ubuntu1.home
   ```
7. Enable passwordless sudo (required for Ansible):
   ```bash
   echo "cdelashmutt ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/cdelashmutt
   ```
8. Verify passwordless SSH works: `ssh ubuntu1.home`

Repeat for all 3 nodes.

## Step 2: Configure nodes (Ansible)

Install required packages, unattended-upgrades, and NFS/iSCSI support:

```bash
ansible-playbook -i ansible/inventory.ini ansible/configure-unattended-upgrades.yaml
```

Format and mount the dedicated storage disk for Longhorn:

```bash
ansible-playbook -i ansible/inventory.ini ansible/configure-storage.yaml
```

> If a node has no dedicated disk, skip this step — Longhorn uses the OS disk.
> To use a different disk on a specific node, edit `ansible/inventory.ini` and
> set `longhorn_disk=<device>` for that host (e.g. `longhorn_disk=sdb`).

## Step 3: Install k3s

```bash
ansible-playbook -i ansible/inventory.ini ansible/install-k3s.yaml \
  -e k3s_token=<your-secret-token>
```

- `k3s_token` is a shared secret used by nodes to join the cluster. Use any
  string. Store it somewhere safe (e.g. a password manager).
- The first node in `[k3s_init]` (ubuntu1) bootstraps the cluster with embedded
  etcd. The others join as additional server nodes.
- The playbook saves a kubeconfig to `~/.kube/k3s-homelab.yaml`.

Fix the server address in the kubeconfig:

```bash
sed -i 's/127.0.0.1/ubuntu1.home/' ~/.kube/k3s-homelab.yaml
export KUBECONFIG=~/.kube/k3s-homelab.yaml
kubectl get nodes  # should show all 3 nodes Ready
```

## Step 4: Bootstrap GitOps

```bash
./install.sh
```

This deploys kapp-controller and secretgen-controller, which then sync
everything else from this GitHub repo automatically (cert-manager, Longhorn,
Traefik, Harbor, external-dns, system-upgrade-controller, kured).

Wait a few minutes, then check:

```bash
kubectl get apps -n bootstrap
```

All apps should eventually show `Reconcile succeeded`.

## Step 5: Install Renovate Bot (one-time)

Install the free [Renovate GitHub App](https://github.com/apps/renovate) on
this repo. It will open PRs when new k3s minor versions are released.

---

## Adding a new node

1. Install Ubuntu, set up SSH as above
2. Add the node to `ansible/inventory.ini` under `[k8s]` and `[k3s_join]`
3. Run `configure-unattended-upgrades.yaml` and `configure-storage.yaml`
4. Run `install-k3s.yaml` — existing nodes are skipped automatically

## Ongoing upgrade operations

| Task | How |
|---|---|
| OS security patches | Automatic (unattended-upgrades + kured, reboots Saturdays 2-6am) |
| OS major version upgrade | `ansible-playbook ansible/upgrade-os.yaml` |
| k3s patch upgrades | Automatic (system-upgrade-controller watches stable channel) |
| k3s minor/major upgrade | Merge the PR opened by Renovate Bot |

## Secrets

Secrets are encrypted with SOPS + Age. The Age private key must be present at
`$HOME/.config/sops/age/keys.txt` on your workstation before running `install.sh`.

The Age public key is in `.sops.yaml`. To re-encrypt or edit secrets:

```bash
sops clusters/bare-metal/values/secret-values.sops.yaml
```
