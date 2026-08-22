#!/usr/bin/env bash
#
# ceph-osd-key-sync-check.sh
# Audits and optionally repairs out-of-sync BlueStore OSD device keys.
#

set -euo pipefail

# Set to "true" to auto-apply fixes using set-label-key
AUTO_FIX="false"

echo "=== Ceph BlueStore Key Drift Audit ==="

for osd_dir in /var/lib/ceph/osd/ceph-*; do
    [[ -d "$osd_dir" ]] || continue

    osd_id=$(basename "$osd_dir" | cut -d'-' -f2)
    block_dev=$(readlink -f "${osd_dir}/block" 2>/dev/null || true)

    if [[ -z "$block_dev" || ! -b "$block_dev" ]]; then
        echo "[!] OSD.${osd_id}: Cannot resolve underlying block device for ${osd_dir}."
        continue
    fi

  # Get key from Ceph MON auth
  mon_key=$(ceph auth get-key "osd.${osd_id}" 2>/dev/null || true)

  if [[ -z "$mon_key" ]]; then
      echo "[!] OSD.${osd_id}: Failed to fetch key from MON cluster."
      continue
  fi

  # Get key from local tmpfs keyring
  local_key=""
  if [[ -f "${osd_dir}/keyring" ]]; then
      local_key=$(awk -F'= ' '/key =/ {print $2}' "${osd_dir}/keyring" | tr -d ' \r\n')
  fi

  echo "----------------------------------------"
  echo "OSD ID:       ${osd_id}"
  echo "Block Dev:    ${block_dev}"
  echo "MON Key:      ${mon_key}"
  echo "Local Key:    ${local_key:-<MISSING>}"

  if [[ "$mon_key" == "$local_key" ]]; then
      echo "Status:       [ OK ] Keyring is synchronized."
  else
      echo "Status:       [ MISMATCH ] Key on disk does not match MON cluster key!"

      if [[ "$AUTO_FIX" == "true" ]]; then
          echo "--> Repairing OSD.${osd_id} metadata on ${block_dev}..."

          tmp_keyring=$(mktemp)
          ceph auth get "osd.${osd_id}" -o "$tmp_keyring"

          systemctl stop "ceph-osd@${osd_id}.service" || true

          ceph-bluestore-tool --dev "$block_dev" set-label-key --key osd_key -v "$tmp_keyring"

          rm -f "$tmp_keyring"
          systemctl reset-failed "ceph-osd@${osd_id}.service"
          systemctl start "ceph-osd@${osd_id}.service"

          echo "--> Repair complete for OSD.${osd_id}."
      else
          echo "--> Run fix manually:"
          echo "    1. ceph auth get osd.${osd_id} -o /tmp/osd${osd_id}.keyring"
          echo "    2. systemctl stop ceph-osd@${osd_id}.service"
          echo "    3. ceph-bluestore-tool --dev ${block_dev} set-label-key --key osd_key -v /tmp/osd${osd_id}.keyring"
          echo "    4. systemctl start ceph-osd@${osd_id}.service"
      fi
  fi
done
