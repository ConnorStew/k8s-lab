#!/bin/bash
set -euo pipefail

REDUCED_RAM=false
if [[ "${1:-}" == "--reduced-ram" ]]; then
    REDUCED_RAM=true
fi

ISOS_DIR="$(realpath "$(dirname "$0")/isos")"
BASE_IMAGE="$ISOS_DIR/debian-13-generic-amd64.qcow2"

echo "Isos dir: $ISOS_DIR"

read -rsp "Enter password: " PASSWORD_INPUT
echo

PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD_INPUT")

declare -A NODE_IPS=(
    [k8s-cp]=192.168.122.10
    [k8s-w1]=192.168.122.11
    [k8s-w2]=192.168.122.12
)

if $REDUCED_RAM; then
    echo "Using reduced RAM configuration (2-node cluster, 4.5 GB total)"
    declare -A NODE_MEM=(
        [k8s-cp]=3072
        [k8s-w1]=1536
    )
    NODES=(k8s-cp k8s-w1)
else
    declare -A NODE_MEM=(
        [k8s-cp]=4096
        [k8s-w1]=2048
        [k8s-w2]=2048
    )
    NODES=(k8s-cp k8s-w1 k8s-w2)
fi

for NODE in "${NODES[@]}"; do
    NODE_QCOW2="$ISOS_DIR/$NODE.qcow2"
    NODE_SEED="$ISOS_DIR/$NODE-seed.iso"
    NODE_IP="${NODE_IPS[$NODE]}"

    echo "Creating overlay for $NODE..."
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$NODE_QCOW2" 20G

    echo "Creating seed ISO for $NODE..."
    cloud-localds "$NODE_SEED" \
        <(cat <<EOF
#cloud-config
ssh_pwauth: true
users:
  - name: debian
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $PASSWORD_HASH
EOF
) \
        <(cat <<EOF
instance-id: $NODE
local-hostname: $NODE
EOF
) \
        --network-config <(cat <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - $NODE_IP/24
    gateway4: 192.168.122.1
    nameservers:
      addresses:
        - 192.168.122.1
EOF
)

    sudo virt-install \
        --name $NODE \
        --memory "${NODE_MEM[$NODE]}" \
        --vcpus 2 \
        --disk "path=$NODE_QCOW2,bus=virtio" \
        --disk "path=$NODE_SEED,device=cdrom" \
        --import \
        --os-variant debian13 \
        --network network=default \
        --graphics spice \
        --noautoconsole
done

echo "Updating known_hosts..."
for NODE in "${NODES[@]}"; do
    NODE_IP="${NODE_IPS[$NODE]}"
    ssh-keygen -R "$NODE_IP" 2>/dev/null || true
    echo -n "Waiting for $NODE_IP..."
    until ssh-keyscan -H "$NODE_IP" >> ~/.ssh/known_hosts 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo " done."
done

echo "Done."
