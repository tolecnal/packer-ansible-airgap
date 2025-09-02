#!/usr/bin/env bash
set -euo pipefail

: "${VSPHERE_SERVER:?}"
: "${VSPHERE_USER:?}"
: "${VSPHERE_PASSWORD:?}"
: "${VSPHERE_DC:?}"
: "${VSPHERE_CLUSTER:?}"
: "${VSPHERE_FOLDER:?}"
: "${VSPHERE_DATASTORE:?}"

FILES_DIR="./files"

declare -A IMAGES=(
  ["debian-12"]="debian-12-genericcloud-amd64.qcow2"
  ["debian-13"]="debian-13-genericcloud-amd64.qcow2"
  ["ubuntu-22"]="jammy-server-cloudimg-amd64.ova"
  ["ubuntu-24"]="noble-server-cloudimg-amd64.ova"
)

for NAME in "${!IMAGES[@]}"; do
  IMAGE="${FILES_DIR}/${IMAGES[$NAME]}"
  TEMPLATE_NAME="${NAME}-cloudimg"

  echo "=== Processing $NAME ($IMAGE) ==="

  if govc object.exists "/${VSPHERE_DC}/vm/${TEMPLATE_NAME}" >/dev/null 2>&1; then
    echo "Template $TEMPLATE_NAME already exists. Skipping."
    continue
  fi

  if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: File $IMAGE does not exist. Skipping $NAME."
    continue
  fi

  if [[ "$IMAGE" == *.qcow2 ]]; then
    VMDK_NAME="${IMAGE%.qcow2}.vmdk"
    if [[ ! -f "$VMDK_NAME" ]]; then
      echo "Converting $IMAGE -> $VMDK_NAME ..."
      qemu-img convert -f qcow2 -O vmdk "$IMAGE" "$VMDK_NAME" || { echo "Conversion failed"; continue; }
    fi

    VM_NAME="${NAME}-vm"
    echo "Creating VM $VM_NAME ..."
    govc vm.create -m 2048 -c 2 -g otherGuest64 -ds "$VSPHERE_DATASTORE" -folder "$VSPHERE_FOLDER" "$VM_NAME" || { echo "VM creation failed"; continue; }

    echo "Attaching disk $VMDK_NAME ..."
    govc device.disk.add -vm "$VM_NAME" -disk "path=$VMDK_NAME,controller=0" || { echo "Disk attach failed"; continue; }

    echo "Marking $VM_NAME as template $TEMPLATE_NAME ..."
    govc vm.markastemplate "$VM_NAME" || { echo "Mark as template failed"; continue; }

  elif [[ "$IMAGE" == *.ova ]]; then
    echo "Importing OVA $IMAGE ..."
    govc import.ova -folder "$VSPHERE_FOLDER" -options /dev/null "$IMAGE" || { echo "OVA import failed"; continue; }

    IMPORTED_VM=$(govc vm.info | grep -Eo '^[^ ]+' | tail -n1)
    echo "Marking $IMPORTED_VM as template $TEMPLATE_NAME ..."
    govc vm.markastemplate "$IMPORTED_VM" || { echo "Mark as template failed"; continue; }
  fi

  echo "=== Finished $NAME ==="
done

echo "All templates processed."

