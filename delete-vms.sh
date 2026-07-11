#!/bin/bash
set -euo pipefail

ISOS_DIR="$(realpath "$(dirname "$0")/isos")"
NODES=(k8s-cp k8s-w1 k8s-w2)

for NODE in "${NODES[@]}"; do
    # Skip nodes that don't exist (e.g. k8s-w2 with --reduced-ram)
    if ! sudo virsh dominfo "$NODE" &>/dev/null; then
        echo "$NODE not defined, skipping..."
        continue
    fi
    echo "Removing $NODE..."
    # Stops the VM if running
    if sudo virsh domstate "$NODE" 2>/dev/null | grep -q "running"; then
        sudo virsh destroy "$NODE"
    fi
    # Removes the VM from libvirt
    sudo virsh undefine "$NODE"
    rm -f "$ISOS_DIR/$NODE.qcow2"
    rm -f "$ISOS_DIR/$NODE-seed.iso"
done

echo "Removing fetched kubeconfig..."
rm -f ~/.kube/k8s-lab.config

echo "Done."
