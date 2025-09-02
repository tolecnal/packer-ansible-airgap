#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Prestage cloud images (OVA/QCOW2) as vSphere templates
# =============================================================================

# Required environment variables
: "${VSPHERE_DATACENTER:?Must be set}"
: "${VSPHERE_DATASTORE:?Must be set}"
: "${VSPHERE_CLUSTER:?Must be set}"
: "${VSPHERE_FOLDER:?Must be set}"
: "${VSPHERE_RESOURCE_POOL:?Must be set}"
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
if ! govc pool.info "$VSPHERE_RESOURCE_POOL" >/dev/null 2>&1; then
  echo "❌ Error: Resource pool '$VSPHERE_RESOURCE_POOL' not found."
  govc pool.ls
  exit 1
fi
echo "✅ Found resource pool: $VSPHERE_RESOURCE_POOL"

# --- Templates to stage ---
declare -A templates=(
  ["ubuntu-22-packer"]="${FILES_DIR}/jammy-server-cloudimg-amd64.ova"
  ["ubuntu-24-packer"]="${FILES_DIR}/noble-server-cloudimg-amd64.ova"
  ["debian-12-packer"]="${FILES_DIR}/debian-12-genericcloud-amd64.qcow2"
  ["debian-13-packer"]="${FILES_DIR}/debian-13-genericcloud-amd64.qcow2"
)

# --- Guest IDs per OS for QCOW2 imports ---
declare -A guest_ids=(
  ["debian-12-packer"]="other5xLinuxGuest"
  ["debian-13-packer"]="other5xLinuxGuest"
  ["ubuntu-22-packer"]="ubuntu64Guest"
  ["ubuntu-24-packer"]="ubuntu64Guest"
)

# --- Prestage loop ---
for template in "${!templates[@]}"; do
  file="${templates[$template]}"
  echo "-----> Processing template: $template"

  # --- Check if template exists ---
  if govc vm.info -json "$template" | jq -e '.virtualMachines != null' >/dev/null 2>&1; then
    echo "⚠️  Template '$template' already exists, skipping."
    continue
  fi

  if [[ ! -f "$file" ]]; then
    echo "❌ File not found: $file"
    continue
  fi

  EXT="${file##*.}"

  if [[ "$EXT" == "ova" ]]; then
    echo "📦 Importing OVA -> $template"
    govc import.ova \
      -ds="$VSPHERE_DATACENTER" \
      -pool="$VSPHERE_RESOURCE_POOL" \
      -folder="$VSPHERE_FOLDER" \
      -name="$template" \
      -net="$VSPHERE_NETWORK" \
      -options <(cat <<EOF
{
  "DiskProvisioning": "thin",
  "MarkAsTemplate": true
}
EOF
      ) 2> >(grep -v "enableMPTSupport" >&2) \
      "$file"

  elif [[ "$EXT" == "qcow2" ]]; then
    GUEST_ID="${guest_ids[$template]}"

    echo "📦 Creating VM -> $template (guestId=$GUEST_ID)"
    govc vm.create \
      -ds="$VSPHERE_DATASTORE" \
      -pool="$VSPHERE_RESOURCE_POOL" \
      -folder="$VSPHERE_FOLDER" \
      -on=false \
      -m=2048 \
      -c=2 \
      -g="$GUEST_ID" \
      -net="$VSPHERE_NETWORK" \
      "$template"

    echo "📦 Adding PVSCSI controller -> $template"
    controller_name=$(govc device.scsi.add -vm "$template" -type pvscsi | awk '/^pvscsi/ {print $1}')
    echo "    Controller created: $controller_name"

    echo "📦 Uploading QCOW2 as VMDK -> $template"
    govc datastore.upload -ds "$VSPHERE_DATASTORE" "$file" "$template/$template-disk1.vmdk"

    echo "📦 Attaching disk -> $template"
    govc vm.disk.attach \
      -vm "$template" \
      -disk "$template/$template-disk1.vmdk" \
      -controller "$controller_name" \
      -ds "$VSPHERE_DATASTORE"

    echo "📦 Marking as template -> $template"
    govc vm.markastemplate "$template"

  else
    echo "❌ Unknown file type: $file"
    continue
  fi

  echo "✅ Successfully staged template: $template"
done

echo "🎉 All templates processed."


