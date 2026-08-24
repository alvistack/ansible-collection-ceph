#!/usr/bin/env bash
#
# ceph-osd-key-sync-check.sh
# Automated remote OSD key migration & BlueStore label repair from Ansible controller.
#

set -euo pipefail

AUTO_FIX="true"

echo "=== Ceph BlueStore Key Drift Audit & Repair ==="

# Dynamically discover all cluster hostnames from nested 'ceph node ls all' output
mapfile -t CEPH_NODES < <(ceph node ls all 2>/dev/null | jq -r '.[][] | keys[]' | sort -u || ceph node ls 2>/dev/null | jq -r 'keys[]')

if [ "${#CEPH_NODES[@]}" -eq 0 ]; then
    echo "Error: Failed to dynamically discover Ceph nodes." >&2
    exit 1
fi

echo "Discovered cluster nodes: ${CEPH_NODES[*]}"

# Ensure dual-cipher support on MONs before key rotation
ceph mon set auth_allowed_ciphers aes,aes256k 2>/dev/null || true

for node in "${CEPH_NODES[@]}"; do
    echo "========================================"
    echo "Scanning active OSD daemons on node: ${node}"
    echo "========================================"

    # Discover active OSD service units on the remote node
    osd_units=$(ssh -q "root@${node}" "systemctl list-units 'ceph-osd@*.service' --state=running --no-legend | awk '{print \$1}'" || true)

    if [ -z "$osd_units" ]; then
        echo "No active OSD services found on ${node}, skipping..."
        continue
    fi

    for unit in $osd_units; do
        if [[ "$unit" =~ ceph-osd@(.*)\.service ]]; then
            osd_id="${BASH_REMATCH[1]}"
            osd_dir="/var/lib/ceph/osd/ceph-${osd_id}"
            entity="osd.${osd_id}"

            # Resolve remote block device path
            block_dev=$(ssh -q "root@${node}" "readlink -f '${osd_dir}/block' 2>/dev/null" || true)

            if [[ -z "$block_dev" ]]; then
                echo "[!] OSD.${osd_id} on ${node}: Cannot resolve underlying block device for ${osd_dir}."
                continue
            fi

            echo "----------------------------------------"
            echo "Node:         ${node}"
            echo "OSD ID:       ${osd_id}"
            echo "Block Dev:    ${block_dev}"

            # Step 1: Rotate MON key from aes to aes256k
            echo "--> Rotating MON key for ${entity} to aes256k..."
            if ! ceph auth rotate --key-type=aes256k "${entity}" -o "/tmp/${entity}.keyring"; then
                echo "ERROR: Failed to rotate key for ${entity} in MON cluster." >&2
                exit 1
            fi

            mon_key=$(awk -F'= ' '/key =/ {print $2}' "/tmp/${entity}.keyring" | tr -d ' \r\n')
            echo "Rotated Key:  ${mon_key}"

            if [[ "$AUTO_FIX" == "true" ]]; then
                echo "--> Repairing OSD.${osd_id} metadata on ${node}:${block_dev}..."

                # Step 2: Stop remote service before flashing device metadata
                ssh -q "root@${node}" "systemctl stop 'ceph-osd@${osd_id}.service'" || true

                # Step 3: Copy new aes256k keyring to target node
                ssh -q "root@${node}" "mkdir -p '${osd_dir}'"
                scp -q "/tmp/${entity}.keyring" "root@${node}:${osd_dir}/keyring"
                ssh -q "root@${node}" "chmod 600 '${osd_dir}/keyring' && chown ceph:ceph '${osd_dir}/keyring' 2>/dev/null || true"

                # Step 4: Burn raw secret string directly into BlueStore label
                ssh -q "root@${node}" "ceph-bluestore-tool --dev '${block_dev}' set-label-key --key osd_key -v '${mon_key}'"

                # Step 5: Restart service
                ssh -q "root@${node}" "systemctl reset-failed 'ceph-osd@${osd_id}.service' || true"
                ssh -q "root@${node}" "systemctl start 'ceph-osd@${osd_id}.service'"

                echo "--> Key rotation and BlueStore label repair complete for OSD.${osd_id} on ${node}."
            fi

            rm -f "/tmp/${entity}.keyring"
        fi
    done
done

echo "========================================"
echo "=== All OSD Keys Rotated & Synchronized ==="
echo "========================================"
