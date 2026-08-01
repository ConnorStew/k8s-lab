# k8s-lab

Spins up a local Kubernetes cluster on libvirt VMs with cloud-init provisioning, kubeadm bootstrap via Ansible and Calico CNI.

Two shell scripts manage the VM lifecycle; one Ansible run takes the nodes from blank Debian cloud images to a working cluster. Built for practising cluster administration.

## Cluster topology

- **OS**: Debian 13 (Trixie) cloud image
- **Network**: libvirt default NAT (`virbr0`, `192.168.122.0/24`)
- **Runtime**: containerd (from Docker's apt repo, `SystemdCgroup` enabled)
- **CNI**: Calico (operator install, pod CIDR patched via kustomize)
- **VM user**: `debian`, password auth (set at VM-creation time, never stored)

# Default
Default cluster configuration:

| VM | Role | vCPUs | RAM | IP |
|----|------|-------|-----|----|
| `k8s-cp` | Control plane | 2 | 4 GB | 192.168.122.10 |
| `k8s-w1` | Worker | 2 | 2 GB | 192.168.122.11 |
| `k8s-w2` | Worker | 2 | 2 GB | 192.168.122.12 |


## Reduced RAM
A reduced ram variant for lower spec hosts:

| VM | Role | vCPUs | RAM | IP |
|----|------|-------|-----|----|
| `k8s-cp` | Control plane | 2 | 4 GB | 192.168.122.10 |
| `k8s-w1` | Worker | 2 | 2 GB | 192.168.122.11 |


## HA
A HA variant with three control plane nodes behind an HAProxy VM, which becomes the kubeadm control plane endpoint:

| VM | Role | vCPUs | RAM | IP |
|----|------|-------|-----|----|
| `k8s-lb` | HAProxy (TCP :6443) | 2 | 1 GB | 192.168.122.9 |
| `k8s-cp` | Control plane (first) | 2 | 4 GB | 192.168.122.10 |
| `k8s-cp2` | Control plane | 2 | 4 GB | 192.168.122.13 |
| `k8s-cp3` | Control plane | 2 | 4 GB | 192.168.122.14 |
| `k8s-w1` | Worker | 2 | 2 GB | 192.168.122.11 |
| `k8s-w2` | Worker | 2 | 2 GB | 192.168.122.12 |

## How it works

1. **`create-vms.sh`** creates a qcow2 overlay per node on top of a single
   shared base image (no disk duplication), builds a cloud-init seed ISO per
   node (hostname, static IP, user + password hash), boots each VM with
   `virt-install`, then polls with `ssh-keyscan` until every node is reachable
   and its host key is in `known_hosts`.
2. **`ansible/site.yml`** then:
   - Installs prerequisites and any configuration needed for nodes and the load balancer, if using HA.
   - Initialises kubernetes nodes and joins them to the cluster.
   - Installs Calico via the Tigera operator, with the pod CIDR patched to
     `10.244.0.0/16` through the kustomization in [`calico/`](calico/)
   - Fetches the admin kubeconfig to `~/.kube/k8s-lab.config` on the host.

## Host requirements

One-time setup, using Arch packages:

```shell
sudo pacman -S qemu-full libvirt virt-install dnsmasq cloud-image-utils ansible kustomize
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"
ansible-galaxy collection install -r requirements.yml
```

## Usage

**1. Download the base image**

The lab uses a Debian cloud image, qcow2 flavour, saved into `isos/`:

```shell
curl -Lo isos/debian-13-generic-amd64.qcow2 \
    https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
```

**2. Create the VMs**

Prompts once for the password the `debian` user gets:

```shell
# Default
./create-vms.sh

# Reduced Ram
./create-vms.sh --reduced-ram 

# HA
./create-vms.sh --ha
```

**3. Provision the cluster**:

```shell
# Default
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-pass --ask-become-pass

# Reduced Ram
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-pass --ask-become-pass --limit 'all:!k8s-w2'

# HA
ansible-playbook -i ansible/inventory.ini -i ansible/inventory-ha.ini ansible/site.yml --ask-pass --ask-become-pass
```

**4. Install the lab helm chart.**
```shell
cd helm/lab
helm dependency build
helm install lab . -n lab --create-namespace
```

The chart uses a NodePort service to expose the headlamp web UI, access it here: `http://<node-ip>:3007`

You'll need to generate a service account token for each login, using kubectl:
```shell
kubectl create token headlamp -n lab
```

**5. Access kubectl.** 

The playbook creates the admin kubeconfig on the host:
```shell
export KUBECONFIG=~/.kube/k8s-lab.config
kubectl get nodes
```

**Teardown**

This shell script destroys the VMs, their disks, and the fetched kubeconfig (the base image is kept):
```shell
./delete-vms.sh
```

## Networking

The VMs sit on libvirt's default NAT network (`192.168.122.0/24`) - they can
reach the internet, but are only reachable from the host.

The pod network CIDR (`10.244.0.0/16`) must not overlap the VM network, and is
set in two places that have to match: `ansible/site.yml` and the kustomize
patch in `calico/calico-patch.yaml`.

## Troubleshooting

Known host-side issues (libvirt/Docker firewall conflict, home-directory
permissions) are documented in [troubleshooting.md](troubleshooting.md).