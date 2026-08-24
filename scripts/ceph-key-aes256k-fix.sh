#!/usr/bin/env bash
set -euxo pipefail

# Dynamic Discovery: Extract unique hostnames from nested 'ceph node ls all' output
mapfile -t CEPH_NODES < <(ceph node ls all 2>/dev/null | jq -r '.[][] | keys[]' | sort -u || ceph node ls 2>/dev/null | jq -r 'keys[]')

if [ "${#CEPH_NODES[@]}" -eq 0 ]; then
    echo "Error: Failed to dynamically discover Ceph nodes."
    exit 1
fi

echo "Discovered nodes: ${CEPH_NODES[*]}"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root on ansible21."
    exit 1
fi

echo "================================================="
echo "  Cephx Key Migration Orchestration (ansible21)"
echo "================================================="

get_keyring_path() {
    local type="$1"
    local id="$2"
    case "$type" in
        osd)     echo "/var/lib/ceph/osd/ceph-${id}/keyring" ;;
        mgr)     echo "/var/lib/ceph/mgr/ceph-${id}/keyring" ;;
        mds)     echo "/var/lib/ceph/mds/ceph-${id}/keyring" ;;
        radosgw) echo "/var/lib/ceph/radosgw/ceph-rgw.${id}/keyring" ;;
        *)       echo "" ;;
    esac
}

echo "=== Phase 1: Enabling Dual Cipher Mode (aes, aes256k) ==="
ceph mon set auth_allowed_ciphers aes,aes256k
ceph mon set auth_preferred_cipher aes256k

echo "=== Phase 2: Rotating Service Daemon Keys Across Nodes ==="

for host in "${CEPH_NODES[@]}"; do
    echo "Scanning active Ceph daemons on host: ${host}"

    # Discover running Ceph units remotely
    units=$(ssh -q "root@${host}" "systemctl list-units 'ceph-*@*.service' --state=running --no-legend | awk '{print \$1}'" || true)

    if [ -z "$units" ]; then
        echo "No active daemons found on ${host}."
        continue
    fi

    for unit in $units; do
        # Robust parsing for systemd daemon units
        if [[ "$unit" =~ ceph-radosgw@(.*)\.service ]] || [[ "$unit" =~ ceph-rgw@(.*)\.service ]]; then
            TYPE="radosgw"
            RAW_ID="${BASH_REMATCH[1]}"
            # Normalize ID: strip leading 'rgw.' prefix if present to avoid double prefixes
            ID="${RAW_ID#rgw.}"
            SYSTEMD_SERVICE="$unit"
            ENTITY="client.rgw.${ID}"
            KEYRING_PATH="/var/lib/ceph/radosgw/ceph-rgw.${ID}/keyring"
        else
            daemon_str=$(echo "$unit" | sed -E 's/ceph-([^@]+)@([^.]+)\.service/\1 \2/')
            TYPE=$(echo "$daemon_str" | awk '{print $1}')
            ID=$(echo "$daemon_str" | awk '{print $2}')
            SYSTEMD_SERVICE="ceph-${TYPE}@${ID}"
            ENTITY="${TYPE}.${ID}"
            KEYRING_PATH=$(get_keyring_path "$TYPE" "$ID")
        fi

        # Skip MONs or malformed lines
        if [[ -z "$TYPE" || "$TYPE" == "mon" ]]; then
            continue
        fi

        echo "Processing ${ENTITY} (${SYSTEMD_SERVICE}) on ${host}..."

        # 1. Stop local service on node
        ssh -q "root@${host}" "systemctl stop ${SYSTEMD_SERVICE}" || true

        # 2. Mark OSD down if applicable
        if [ "$TYPE" == "osd" ]; then
            ceph osd down "$ID" || true
        fi

        # 3. Rotate key to aes256k and write output to remote keyring file
        if [ "$TYPE" == "radosgw" ]; then
            # RGW-specific fixup logic
            if ! ceph auth rotate --key-type=aes256k "${ENTITY}" -o "/tmp/${ENTITY}.keyring"; then
                echo "ERROR: Failed to rotate key for ${ENTITY} on ${host}." >&2
                exit 1
            fi

            ssh -q "root@${host}" "mkdir -p \$(dirname '${KEYRING_PATH}')"
            scp -q "/tmp/${ENTITY}.keyring" "root@${host}:${KEYRING_PATH}"
            ssh -q "root@${host}" "chmod 600 ${KEYRING_PATH} && chown ceph:ceph ${KEYRING_PATH} 2>/dev/null || true"

            rm -f "/tmp/${ENTITY}.keyring"
        elif [ -n "$KEYRING_PATH" ]; then
            echo "Rotating ${ENTITY} to aes256k on ${host}:${KEYRING_PATH}..."
            ssh -q "root@${host}" "mkdir -p \$(dirname '${KEYRING_PATH}')"

            ceph auth rotate --key-type=aes256k "${ENTITY}" > /tmp/ceph_rotated_key.tmp
            scp -q /tmp/ceph_rotated_key.tmp "root@${host}:${KEYRING_PATH}"

            # Extract raw secret string from generated keyring for BlueStore fixup
            RAW_SECRET=$(awk -F'= ' '/key =/ {print $2}' /tmp/ceph_rotated_key.tmp | tr -d ' \r\n')

            # If daemon is an OSD, write updated key into raw BlueStore block metadata
            if [ "$TYPE" == "osd" ]; then
                echo "Writing updated osd_key label to raw BlueStore device on ${host} for OSD.${ID}..."
                ssh -q "root@${host}" "
                block_dev=\$(readlink -f /var/lib/ceph/osd/ceph-${ID}/block || true)
                if [ -n \"\$block_dev\" ] && [ -b \"\$block_dev\" ]; then
                    ceph-bluestore-tool --dev \"\$block_dev\" set-label-key --key osd_key -v '${RAW_SECRET}'
                else
                    echo 'Warning: Could not resolve raw block device for OSD.${ID}'
            fi
            "
            fi

            rm -f /tmp/ceph_rotated_key.tmp
            ssh -q "root@${host}" "chmod 600 '${KEYRING_PATH}' && chown ceph:ceph '${KEYRING_PATH}' 2>/dev/null || true"
        else
            ceph auth rotate --key-type=aes256k "${ENTITY}"
        fi

        # 4. Restart service on remote node
        ssh -q "root@${host}" "systemctl start ${SYSTEMD_SERVICE}"
        sleep 2
    done
done

echo "=== Phase 3: Rotating Admin & Bootstrap Keyrings ==="

rotate_and_distribute() {
    local entity="$1"
    local path="$2"

    echo "Rotating ${entity} to aes256k..."

    if [ -f "$path" ]; then
        ceph auth rotate --key-type=aes256k "$entity" -o "$path"
        chmod 600 "$path"
    else
        ceph auth rotate --key-type=aes256k "$entity" > /tmp/temp_keyring
        path="/tmp/temp_keyring"
    fi

    # Distribute to all target cluster nodes
    for node in "${CEPH_NODES[@]}"; do
        echo "Syncing ${entity} keyring -> ${node}:${2}..."
        ssh -q "root@${node}" "mkdir -p \$(dirname '${2}')"
        scp -q "$path" "root@${node}:${2}"
        ssh -q "root@${node}" "chmod 600 '${2}'"
    done

    rm -f /tmp/temp_keyring
}

rotate_and_distribute "client.admin"                 "/etc/ceph/ceph.client.admin.keyring"
rotate_and_distribute "client.bootstrap-mds"         "/var/lib/ceph/bootstrap-mds/ceph.keyring"
rotate_and_distribute "client.bootstrap-mgr"         "/var/lib/ceph/bootstrap-mgr/ceph.keyring"
rotate_and_distribute "client.bootstrap-osd"         "/var/lib/ceph/bootstrap-osd/ceph.keyring"
rotate_and_distribute "client.bootstrap-rbd"         "/var/lib/ceph/bootstrap-rbd/ceph.keyring"
rotate_and_distribute "client.bootstrap-rbd-mirror"  "/var/lib/ceph/bootstrap-rbd-mirror/ceph.keyring"
rotate_and_distribute "client.bootstrap-rgw"         "/var/lib/ceph/bootstrap-rgw/ceph.keyring"

echo "=== Phase 4: Enforcing Service Ticket Ciphers & Wiping Legacy Keys ==="
ceph mon set auth_service_cipher aes256k
ceph auth wipe-rotating-service-keys

echo "=== Phase 5: Cluster Lockdown ==="
ceph mon set auth_allowed_ciphers aes256k
ceph config set mon auth_allow_insecure_global_id_reclaim false || true

echo "================================================="
echo " Migration Complete! Checking cluster health..."
echo "================================================="
sleep 5
ceph health detail
