# Troubleshooting
Issues I had running locally and fixes.

### libvirt + Docker firewall conflict

libvirt defaults to nftables for its firewall rules, but Docker uses iptables
(via `iptables-nft`). Both end up as nftables rules in separate tables:
Docker's FORWARD chain has policy DROP with no rule for the libvirt subnet, so
it drops VM traffic even though libvirt's own rules accept it.

Fix — force libvirt onto iptables so both tools manage the same FORWARD chain:

```shell
sudo sed -i 's/#firewall_backend = "nftables"/firewall_backend = "iptables"/' /etc/libvirt/network.conf
sudo systemctl restart libvirtd
sudo virsh net-destroy default && sudo virsh net-start default
```

### Permission denied on the qcow2/seed ISO

`virt-install` runs QEMU as the `libvirt-qemu` system user, which needs
execute (search) permission on every parent directory of a disk image — not
just read access to the file. If `$HOME` doesn't allow "other" to traverse it
(e.g. mode `710`), VM creation fails with `Cannot access storage file ... (as
uid:955, gid:955): Permission denied`.

Fix — grant traverse-only access via ACL (doesn't otherwise loosen anything):

```shell
setfacl -m u:libvirt-qemu:x "$HOME"
```
