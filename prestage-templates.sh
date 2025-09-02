#!/usr/bin/env bash
set -euo pipefail

# --- Required environment variables ---
: "${VSPHERE_DATACENTER:?Must be set}"
: "${VSPHERE_DATASTORE:?Must be set}"
: "${VSPHERE_CLUSTER:?Must be set}"
: "${VSPHERE_RESOURCE_POOL:?Must be set}"
: "${VSPHERE_FOLDER:?Must be set}"
: "${VSPHERE_NETWORK:?Must be set}"

FILES_DIR="files"

# --- Verify network exists ---
if ! govc find "/${VSPHERE_DATACENTER}/network" -name "$VSPHERE_NETWORK" >/dev/null 2>&1; then
  echo "❌ Error: Network '$VSPHERE_NETWORK' not found in datacenter '$VSPHERE_DATACENTER'."
  echo "   Available networks are:"
  govc find "/${VSPHERE_DATACENTER}/network" -type n | sed 's#.*/##'
  exit 1
fi
echo "✅ Found network: $VSPHERE_NETWORK"

# --- Verify resource pool exists ---
if ! govc find "/${VSPHERE_DATACENTER}/host/${VSPHERE_CLUSTER}/Resources" -type p -name "$VSPHERE_RESOURCE_POOL" >/dev/null 2>&1; then
  echo "❌ Error: Resource pool '$VSPHERE_RESOURCE_POOL' not found in cluster '$VSPHERE_CLUSTER'."
  echo "   Available resource pools are:"
  govc find "/${VSPHERE_DATACENTER}/host/${VSPHERE_CLUSTER}/Resources" -type p | sed 's#.*/##'
  exit 1
fi
echo "✅ Found resource pool: $VSPHERE_RESOURCE_POOL"

# --- Templates to stage ---
declare -A templates=(
  ["ubuntu-22"]="${FILES_DIR}/jammy-server-cloudimg-amd64.ova"
  ["ubuntu-24"]="${FILES_DIR}/noble-server-cloudimg-amd64.ova"
  ["debian-12"]="${FILES_DIR}/debian-12-genericcloud-amd64.qcow2"
  ["debian-13"]="${FILES_DIR}/debian-13-genericcloud-amd64.qcow2"
)

# --- Prestage loop ---
for template in "${!templates[@]}"; do
  file="${templates[$template]}"
  echo "-----> Processing template: $template"

  if govc vm.info -json "$template" >/dev/null 2>&1; then
    echo "⚠️  Template '$template' already exists, skipping."
    continue
  fi

  if [[ ! -f "$file" ]]; then
    echo "❌ File not found: $file"
    exit 1
  fi

  if [[ "$file" == *.ova ]]; then
    echo "📦 Importing OVA -> $template"
    govc import.ova -options <(cat <<EOF
{
  "DiskProvisioning": "thin",
  "MarkAsTemplate": true,
  "Name": "$template",
  "NetworkMapping": [
    { "Name": "VM Network", "Network": "$VSPHERE_NETWORK" }
  ]
}
EOF
    ) -ds="$VSPHERE_DATASTORE" -pool="/${VSPHERE_DATACENTER}/host/${VSPHERE_CLUSTER}/Resources/${VSPHERE_RESOURCE_POOL}" "$file"
  else
    echo "📦 Importing QCOW2 -> $template"
    govc vm.create -on=false -template -ds="$VSPHERE_DATASTORE" -pool="/${VSPHERE_DATACENTER}/host/${VSPHERE_CLUSTER}/Resources/${VSPHERE_RESOURCE_POOL}" -folder="$VSPHERE_FOLDER" -net="$VSPHERE_NETWORK" -disk.controller pvscsi -disk 20GB -memory 2048 -c 2 "$template"

    govc datastore.upload -ds="$VSPHERE_DATASTORE" "$file" "$template/$template-disk1.vmdk"
    govc vm.disk.change -vm="$template" -disk.label "Hard disk 1" -disk.name "$template/$template-disk1.vmdk"
  fi

  echo "✅ Successfully staged template: $template"
done

echo "🎉 All templates processed."

