#!/usr/bin/env bash
set -euxo pipefail

# Dynamically discover all nodes in the cluster
mapfile -t CEPH_NODES < <(ceph node ls all 2>/dev/null | jq -r 'keys[]' || ceph node ls 2>/dev/null | jq -r 'keys[]')

if [ "${#CEPH_NODES[@]}" -eq 0 ]; then
    echo "Error: Failed to dynamically discover Ceph nodes." >&2
    exit 1
fi

echo "Discovered cluster nodes: ${CEPH_NODES[*]}"

# Temporarily ensure dual-cipher support on MONs
ceph mon set auth_allowed_ciphers aes,aes256k

for node in "${CEPH_NODES[@]}"; do
    # Discover RGW systemd service units installed/running on the remote node
    rgw_units=$(ssh -q "root@${node}" "systemctl list-units 'ceph-radosgw@*' 'ceph-rgw@*' --all --no-legend | awk '{print \$1}'" || true)

    if [ -z "$rgw_units" ]; then
        echo "No RGW service found on ${node}, skipping..."
        continue
    fi

    for unit in $rgw_units; do
        # Extract RGW daemon ID (e.g., extracts 'epdwr83n' from 'ceph-radosgw@rgw.epdwr83n.service')
        if [[ "$unit" =~ ceph-radosgw@(.*)\.service ]] || [[ "$unit" =~ ceph-rgw@(.*)\.service ]]; then
            RAW_ID="${BASH_REMATCH[1]}"
            ID="${RAW_ID#rgw.}"
            ENTITY="client.rgw.${ID}"
            KEYRING_PATH="/var/lib/ceph/radosgw/ceph-rgw.${ID}/keyring"

            echo "=== Processing ${ENTITY} on ${node} (${unit}) ==="

            # 1. Stop local service
            ssh root@"${node}" "systemctl stop ${unit}" || true

            # 2. Rotate key directly to a temporary file
            if ! ceph auth rotate --key-type=aes256k "${ENTITY}" -o "/tmp/${ENTITY}.keyring"; then
                echo "ERROR: Failed to rotate key for ${ENTITY} on ${node}." >&2
                exit 1
            fi

            # 3. Copy file to target node and set correct permissions
            ssh root@"${node}" "mkdir -p \$(dirname '${KEYRING_PATH}')"
            scp -q "/tmp/${ENTITY}.keyring" "root@${node}:${KEYRING_PATH}"
            ssh root@"${node}" "chmod 600 ${KEYRING_PATH} && chown ceph:ceph ${KEYRING_PATH} 2>/dev/null || true"

            rm -f "/tmp/${ENTITY}.keyring"

            # 4. Restart service
            ssh root@"${node}" "systemctl start ${unit}"
        fi
    done
done

echo "=== RGW Key Rotation Complete ==="
