variable "ssh_public_key" { default = "<PASTE_PUBLIC_KEY_HERE>" }

source "vsphere-clone" "debian-12" {
  vcenter_server      = env("VSPHERE_SERVER")
  username            = env("VSPHERE_USER")
  password            = env("VSPHERE_PASSWORD")
  datacenter          = env("VSPHERE_DC")
  cluster             = env("VSPHERE_CLUSTER")
  datastore           = env("VSPHERE_DATASTORE")
  folder              = env("VSPHERE_FOLDER")

  template            = "debian-12-cloudimg"
  vm_name             = "debian-12-template"

  communicator        = "ssh"
  ssh_username        = "ansible"
  ssh_private_key_file = "../packer-offline-keys/id_rsa"
  ssh_timeout         = "30m"

  cd_files = [
    "cloud-init/meta-data",
    "cloud-init/user-data"
  ]
  cd_label = "cidata"

  convert_to_template = true
}

build { sources = ["source.vsphere-clone.debian-12"] }

