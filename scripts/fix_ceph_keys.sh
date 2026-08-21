#!/usr/bin/env bash
set -euxo pipefail

# Ceph Cluster Nodes
CEPH_NODES=("node22" "node23" "node24")
LEADER_NODE="${CEPH_NODES[0]}" # node22 used as key export target

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root on ansible21."
  exit 1
fi

echo "================================================="
echo "  Cephx Key Migration Orchestration (from ansible21)"
echo "================================================="

# Helper function to get default daemon keyring paths
get_keyring_path() {
    local type="$1"
    local id="$2"
    case "$type" in
        osd)     echo "/var/lib/ceph/osd/ceph-${id}/keyring" ;;
        mgr)     echo "/var/lib/ceph/mgr/ceph-${id}/keyring" ;;
        mds)     echo "/var/lib/ceph/mds/ceph-${id}/keyring" ;;
        radosgw) echo "/var/lib/ceph/radosgw/ceph-${id}/keyring" ;;
        *)       echo "" ;;
    esac
}

echo ""
echo "=== Phase 1: Rotating Service Daemon Keys Across All Nodes ==="

for host in "${CEPH_NODES[@]}"; do
    echo "-------------------------------------------------"
    echo "Scanning active Ceph daemons on host: ${host}"
    echo "-------------------------------------------------"

    # Discover running Ceph units remotely
    units=$(ssh -q "root@${host}" "systemctl list-units 'ceph-*@*.service' --state=running --no-legend | awk '{print \$1}'" || true)

    if [ -z "$units" ]; then
        echo "No active daemons found on ${host}."
        continue
    fi

    for unit in $units; do
        daemon_str=$(echo "$unit" | sed -E 's/ceph-([^@]+)@([^.]+)\.service/\1 \2/')
        read -r TYPE ID <<< "$daemon_str"

        # Skip MONs (MONs do not use standard auth entity keyrings for their service identity)
        if [[ -z "$TYPE" || -z "$ID" || "$TYPE" == "mon" ]]; then
            continue
        fi

        ENTITY=$([ "$TYPE" == "radosgw" ] && echo "client.rgw.${ID}" || echo "${TYPE}.${ID}")
        KEYRING_PATH=$(get_keyring_path "$TYPE" "$ID")

        echo "--> Processing ${ENTITY} on ${host}..."

        # 1. Stop local service on node
        ssh -q "root@${host}" "systemctl stop ceph-${TYPE}@${ID}" || true

        # 2. Mark OSD down if applicable
        if [ "$TYPE" == "osd" ]; then
            ceph osd down "$ID" || true
        fi

        # 3. Rotate key from ansible21 and write output directly to the remote node's keyring file
        if [ -n "$KEYRING_PATH" ]; then
            echo "    Rotating ${ENTITY} to aes256k on ${host}:${KEYRING_PATH}..."
            ssh -q "root@${host}" "mkdir -p \$(dirname '${KEYRING_PATH}')"
            ceph auth rotate --key-type=aes256k "${ENTITY}" | ssh -q "root@${host}" "cat > '${KEYRING_PATH}'"
            ssh -q "root@${host}" "chmod 600 '${KEYRING_PATH}' && chown ceph:ceph '${KEYRING_PATH}' 2>/dev/null || true"
        else
            ceph auth rotate --key-type=aes256k "${ENTITY}"
        fi

        # 4. Restart service on remote node
        ssh -q "root@${host}" "systemctl start ceph-${TYPE}@${ID}"
        sleep 2
    done
done

echo ""
echo "=== Phase 2: Rotating Admin & Bootstrap Keyrings ==="

rotate_and_distribute() {
    local entity="$1"
    local path="$2"

    echo "--> Rotating ${entity}..."
    
    # Check if file exists on ansible21 controller; update locally if present
    if [ -f "$path" ]; then
        ceph auth rotate --key-type=aes256k "$entity" -o "$path"
        chmod 600 "$path"
    else
        # Otherwise generate updated key file on ansible21
        ceph auth rotate --key-type=aes256k "$entity" > /tmp/temp_keyring
        path="/tmp/temp_keyring"
    fi

    # Sync keyring out to all target cluster nodes
    for node in "${CEPH_NODES[@]}"; do
        echo "    Syncing ${entity} keyring -> ${node}:${path}..."
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

echo ""
echo "=== Phase 3: Purging Legacy Service Tickets ==="
echo "--> Flushing old rotating keys in MON store..."
ceph auth wipe-rotating-service-keys

echo ""
echo "================================================="
echo " Migration Complete! Checking cluster health..."
echo "================================================="
sleep 5
ceph health detail
