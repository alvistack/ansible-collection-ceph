#!/usr/bin/env bash
set -euxo pipefail

# Dynamically discover all unique hostnames from object keys under each daemon type
mapfile -t CEPH_NODES < <(
    ceph node ls 2>/dev/null | jq -r '.[] | keys[]' 2>/dev/null | sort -u
)

if [ "${#CEPH_NODES[@]}" -eq 0 ]; then
    echo "Error: Failed to dynamically discover Ceph nodes." >&2
    exit 1
fi

echo "Discovered cluster nodes: ${CEPH_NODES[*]}"

# Temporarily ensure dual-cipher support on MONs
ceph mon set auth_allowed_ciphers aes,aes256k
ceph mon set auth_preferred_cipher aes256k

for node in "${CEPH_NODES[@]}"; do
    # Discover instantiated RGW units only, stripping empty base templates (@.service)
    rgw_units=$(ssh -q "root@${node}" "systemctl list-units 'ceph-radosgw@*' 'ceph-rgw@*' --all --no-legend --plain | awk '{print \$1}' | grep -v '@\.service$' | grep -E '\.service$' || true")

    if [ -z "$rgw_units" ]; then
        echo "No instantiated RGW service found on ${node}, skipping..."
        continue
    fi

    for unit in $rgw_units; do
        if [[ "$unit" =~ ceph-radosgw@(.*)\.service ]] || [[ "$unit" =~ ceph-rgw@(.*)\.service ]]; then
            RAW_ID="${BASH_REMATCH[1]}"

            # Handle both 'rgw.hostname' and 'hostname' ID naming structures
            if [[ "$RAW_ID" =~ ^rgw\.(.*) ]]; then
                ENTITY="client.rgw.${BASH_REMATCH[1]}"
            else
                ENTITY="client.${RAW_ID}"
            fi

            KEYRING_PATH="/var/lib/ceph/radosgw/ceph-${RAW_ID}/keyring"

            echo "=== Processing ${ENTITY} on ${node} (${unit}) ==="

            # 1. Stop local service
            ssh root@"${node}" "systemctl stop ${unit}" || true

            # 2. Grant explicit RGW capability set (mon, osd, mgr)
            ceph auth caps "${ENTITY}" mon 'allow rw' osd 'allow rwx' mgr 'allow rw' || true

            # 3. Rotate key to aes256k and pull clean auth keyring format
            if ! ceph auth rotate --key-type=aes256k "${ENTITY}"; then
                echo "ERROR: Failed to rotate key for ${ENTITY} on ${node}." >&2
                exit 1
            fi

            ceph auth get "${ENTITY}" -o "/tmp/${ENTITY}.keyring"

            # 4. Copy file to target node and set correct permissions
            ssh root@"${node}" "mkdir -p \$(dirname '${KEYRING_PATH}')"
            scp -q "/tmp/${ENTITY}.keyring" "root@${node}:${KEYRING_PATH}"
            ssh root@"${node}" "chmod 600 '${KEYRING_PATH}' && chown -R ceph:ceph \$(dirname '${KEYRING_PATH}') 2>/dev/null || true"

            rm -f "/tmp/${ENTITY}.keyring"

            # 5. Clear systemd failed counter and start service
            ssh root@"${node}" "systemctl reset-failed ${unit} || true"
            ssh root@"${node}" "systemctl start ${unit}"
        fi
    done
done

echo "=== RGW Key Rotation Complete ==="
