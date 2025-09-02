#!/usr/bin/env bash
mkdir -p packer-offline-keys
if [ ! -f packer-offline-keys/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f packer-offline-keys/id_rsa -N ""
    echo "SSH keypair created in packer-offline-keys/"
else
    echo "SSH keypair already exists. Skipping."
fi

