#!/bin/bash

set -e

mapfile -t CEPH_NODES < <(
    ceph node ls 2>/dev/null | jq -r '.[] | keys[]' 2>/dev/null | sort -u
)


echo "================================================="
echo " MANUAL EXECUTION COMMANDS"
echo " Please copy and run the following block manually:"
echo "================================================="
echo ""
echo "ceph auth rotate --key-type=aes256k mon."
echo "ceph auth get mon. > /tmp/updated_mon.keyring"
echo "ceph auth get client.admin >> /tmp/updated_mon.keyring"

for node in "${CEPH_NODES[@]}"; do
    echo "ssh root@${node} 'mkdir -p /var/lib/ceph/tmp'"
    echo "scp /tmp/updated_mon.keyring root@${node}:/var/lib/ceph/tmp/ceph.mon.keyring"
    echo "ssh root@${node} 'chmod 600 /var/lib/ceph/tmp/ceph.mon.keyring'"
done

echo "rm -f /tmp/updated_mon.keyring"
echo ""
echo "================================================="
