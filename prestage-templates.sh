#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Pre-stage cloud images (OVA/QCOW2) as vSphere templates
# =============================================================================

# Required environment variables
: "${VSPHERE_DATACENTER:?Must be set}"
: "${VSPHERE_CLUSTER:?Must be set}"
: "${VSPHERE_DATASTORE:?Must be set}"
: "${VSPHERE_RESOURCE_POOL:?Must be set}"
: "${VSPHERE_FOLDER:?Must be set}"

# Images to import (template name → file)
declare -A IMAGES=(
  ["ubuntu-24"]="noble-server-cloudimg-amd64.ova"
  ["ubuntu-22"]="jammy-server-cloudimg-amd64.ova"
  ["debian-13"]="debian-13-genericcloud-amd64.qcow2"
  ["debian-12"]="debian-12-genericcloud-amd64.qcow2"
)

echo "==> Using datacenter:     $VSPHERE_DATACENTER"
echo "==> Using cluster:        $VSPHERE_CLUSTER"
echo "==> Using datastore:      $VSPHERE_DATASTORE"
echo "==> Using resource pool:  $VSPHERE_RESOURCE_POOL"
echo "==> Using folder:         $VSPHERE_FOLDER"
echo

for TEMPLATE in "${!IMAGES[@]}"; do
  FILE="files/${IMAGES[$TEMPLATE]}"
  echo "==> Processing $TEMPLATE from $FILE"

  if [ ! -f "$FILE" ]; then
    echo "    [ERROR] File not found: $FILE"
    continue
  fi

  # Check if template already exists
  if govc vm.info -dc="$VSPHERE_DATACENTER" -vm.ipath="/${VSPHERE_DATACENTER}/vm/${VSPHERE_FOLDER}/${TEMPLATE}" >/dev/null 2>&1; then
    echo "    [SKIP] Template already exists in vSphere: $TEMPLATE"
    continue
  fi

  EXT="${FILE##*.}"

  if [ "$EXT" = "ova" ]; then
    echo "    Importing OVA → $TEMPLATE"
    govc import.ova \
      -dc="$VSPHERE_DATACENTER" \
      -ds="$VSPHERE_DATASTORE" \
      -pool="$VSPHERE_RESOURCE_POOL" \
      -folder="$VSPHERE_FOLDER" \
      -name="$TEMPLATE" \
      "$FILE"

  elif [ "$EXT" = "qcow2" ]; then
    echo "    Creating VM from QCOW2 → $TEMPLATE"

    govc vm.create \
      -dc="$VSPHERE_DATACENTER" \
      -ds="$VSPHERE_DATASTORE" \
      -pool="$VSPHERE_RESOURCE_POOL" \
      -folder="$VSPHERE_FOLDER" \
      -on=false \
      -m=2048 -c=2 -g=debian12_64Guest \
      "$TEMPLATE"

    govc import.vmdk \
      -dc="$VSPHERE_DATACENTER" \
      -ds="$VSPHERE_DATASTORE" \
      "$FILE" "$TEMPLATE"

    govc device.disk.change \
      -dc="$VSPHERE_DATACENTER" \
      -vm="$TEMPLATE" \
      -disk.label="disk-0" \
      -size=8G

  else
    echo "    [ERROR] Unknown file type for $FILE"
    continue
  fi

  echo "    Marking as template → $TEMPLATE"
  govc vm.markastemplate -dc="$VSPHERE_DATACENTER" "$TEMPLATE"

done

echo
echo "==> Prestage completed successfully"

