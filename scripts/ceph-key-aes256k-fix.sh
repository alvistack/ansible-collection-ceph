#!/usr/bin/env bash
set -euxo pipefail

# Dynamic Discovery: Extract hostnames from object keys under each daemon type
mapfile -t CEPH_NODES < <(
    ceph node ls 2>/dev/null | jq -r '.[] | keys[]' 2>/dev/null | sort -u
)

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

    # Discover instantiated systemd units only, stripping empty base templates (@.service)
    units=$(ssh -q "root@${host}" "systemctl list-units 'ceph-*@*.service' --all --no-legend --plain | awk '{print \$1}' | grep -v '@\.service$' | grep -E '\.service$' || true")

    if [ -z "$units" ]; then
        echo "No active daemons found on ${host}."
        continue
    fi

    for unit in $units; do
        # Robust parsing for systemd daemon units
        if [[ "$unit" =~ ceph-radosgw@(.*)\.service ]] || [[ "$unit" =~ ceph-rgw@(.*)\.service ]]; then
            TYPE="radosgw"
            RAW_ID="${BASH_REMATCH[1]}"
            SYSTEMD_SERVICE="$unit"

            # Normalize RGW Entity string to handle both rgw.host and host naming formats
            if [[ "$RAW_ID" =~ ^rgw\.(.*) ]]; then
                ENTITY="client.rgw.${BASH_REMATCH[1]}"
            else
                ENTITY="client.${RAW_ID}"
            fi

            KEYRING_PATH="/var/lib/ceph/radosgw/ceph-${RAW_ID}/keyring"
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
            # Ensure RGW entity has explicit required caps before rotating
            ceph auth caps "${ENTITY}" mon 'allow rw' osd 'allow rwx' mgr 'allow rw' || true

            # Rotate key and retrieve full keyring format
            if ! ceph auth rotate --key-type=aes256k "${ENTITY}"; then
                echo "ERROR: Failed to rotate key for ${ENTITY} on ${host}." >&2
                exit 1
            fi

            ceph auth get "${ENTITY}" -o "/tmp/${ENTITY}.keyring"

            ssh -q "root@${host}" "mkdir -p \$(dirname '${KEYRING_PATH}')"
            scp -q "/tmp/${ENTITY}.keyring" "root@${host}:${KEYRING_PATH}"
            ssh -q "root@${host}" "chmod 600 '${KEYRING_PATH}' && chown -R ceph:ceph \$(dirname '${KEYRING_PATH}') 2>/dev/null || true"

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

        # 4. Clear failed systemd state and restart service on remote node
        ssh -q "root@${host}" "systemctl reset-failed ${SYSTEMD_SERVICE} || true"
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

set +ux -e

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
