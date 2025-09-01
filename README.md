# Packer Build Role

This role builds vSphere templates for:
- Debian 12
- Debian 13
- Ubuntu 22.04
- Ubuntu 24.04

## Requirements
- Ansible
- Hashicorp Packer
- vSphere credentials (set as env vars)

## Usage

Run with:

```bash
ansible-playbook site.yml --tags packerbuild
´´´

SSH Keys

Persistent SSH keys for Packer are stored in:

packer-offline-keys/


These are generated once and reused, so multiple users share the same build keys.

Security

On first boot of clones, cloud-init deletes template host keys and regenerates fresh ones.

Ensures no template host keys leak into production.

vSphere Upload

Cloud images must be uploaded to your datastore manually or with Ansible before running builds:

[datastore]/iso/debian-12-genericcloud-amd64.qcow2

[datastore]/iso/debian-13-genericcloud-amd64.qcow2

[datastore]/iso/ubuntu-22.04-server-cloudimg-amd64.iso

[datastore]/iso/ubuntu-24.04-server-cloudimg-amd64.iso


