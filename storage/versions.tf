terraform {
  required_providers {
    template = {
      source = "hashicorp/template"
    }
    vsphere = {
      source = "vmware/vsphere"
    }
    ignition = {
      source = "community-terraform-providers/ignition"
      version = "2.4.1"
    }
    vcd = {
      source = "vmware/vcd"
    }
  }
  required_version = ">= 0.13"
}
