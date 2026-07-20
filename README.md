# k8s-lab

Spins up a local three-node Kubernetes cluster on libvirt VMs with cloud-init provisioning, kubeadm bootstrap via Ansible and Calico CNI.

Two shell scripts manage the VM lifecycle; one Ansible run takes the nodes from
blank Debian cloud images to a working cluster. Built for practising cluster administration.

## Cluster topology

| VM | Role | vCPUs | RAM | IP |
|----|------|-------|-----|----|
| `k8s-cp` | Control plane | 2 | 4 GB | 192.168.122.10 |
| `k8s-w1` | Worker | 2 | 2 GB | 192.168.122.11 |
| `k8s-w2` | Worker | 2 | 2 GB | 192.168.122.12 |

- **OS**: Debian 13 (Trixie) cloud image
- **Network**: libvirt default NAT (`virbr0`, `192.168.122.0/24`)
- **Runtime**: containerd (from Docker's apt repo, `SystemdCgroup` enabled)
- **CNI**: Calico (operator install, pod CIDR patched via kustomize)
- **VM user**: `debian`, password auth (set at VM-creation time, never stored)

`create-vms.sh --reduced-ram` builds a two-node variant instead (3 GB control
plane + 1.5 GB worker, ~4.5 GB total) for lower-spec hosts.

## How it works

1. **`create-vms.sh`** creates a qcow2 overlay per node on top of a single
   shared base image (no disk duplication), builds a cloud-init seed ISO per
   node (hostname, static IP, user + password hash), boots each VM with
   `virt-install`, then polls with `ssh-keyscan` until every node is reachable
   and its host key is in `known_hosts`.
2. **`ansible/site.yml`** then:
   - installs containerd, kubelet, kubeadm, kubectl and extra clis, enables the CRI and
     `SystemdCgroup` in containerd, and turns on `ip_forward` (`prerequisites.yml`)
   - runs `kubeadm init` on the control plane, generates a join token, and
     joins the workers (`kubernetes.yml`) — all guarded with `creates:` so
     re-runs are idempotent
   - installs Calico via the Tigera operator, with the pod CIDR patched to
     `10.244.0.0/16` through the kustomization in [`calico/`](calico/)
   - fetches the admin kubeconfig to `~/.kube/k8s-lab.config` on the host
     (a separate file, so your existing `~/.kube/config` is never touched)

## Host requirements

One-time setup (package names are Arch's; `virt-manager` is an optional GUI):

```shell
sudo pacman -S qemu-full libvirt virt-install dnsmasq cloud-image-utils ansible kustomize
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"
ansible-galaxy collection install -r requirements.yml
```

## Usage

**1. Download the base image** (Debian cloud image, qcow2 flavour) into `isos/`:

```shell
curl -Lo isos/debian-13-generic-amd64.qcow2 \
    https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
```

**2. Create the VMs** — prompts once for the password the `debian` user gets:

```shell
./create-vms.sh              # 3-node cluster
./create-vms.sh --reduced-ram  # 2-node, ~4.5 GB total
```

**3. Provision the cluster.**:

```shell
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-pass --ask-become-pass
```

For the `--reduced-ram` variant, exclude the third node:
`--limit 'all:!k8s-w2'`.


**4 Install the lab helm chart.** Current used for headlamp web UI:
```shell
cd helm/lab
helm dependency build
helm install lab . -n lab --create-namespace
```

This uses a NodePort service to expose the web UI, access it here: `http://<node-ip>:3007`

You'll need to generate a service account token for each login, using kubectl:
```shell
kubectl create token headlamp -n lab
```

**5. Access kubectl.** The playbook creates the admin kubeconfig on the host:

```shell
export KUBECONFIG=~/.kube/k8s-lab.config
kubectl get nodes
```

Or SSH straight in: `ssh debian@192.168.122.10`.

**Teardown** — destroys the VMs, their disks, and the fetched kubeconfig
(the base image is kept):

```shell
./delete-vms.sh
```

## Networking

The VMs sit on libvirt's default NAT network (`192.168.122.0/24`) — they can
reach the internet, but are only reachable from the host.

The pod network CIDR (`10.244.0.0/16`) must not overlap the VM network, and is
set in two places that have to match: `ansible/site.yml` and the kustomize
patch in `calico/calico-patch.yaml`.

## Troubleshooting

Known host-side issues (libvirt/Docker firewall conflict, home-directory
permissions) are documented in [troubleshooting.md](troubleshooting.md).