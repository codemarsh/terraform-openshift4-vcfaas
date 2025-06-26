terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
    tls = {
      source = "hashicorp/tls"
    }
    vsphere = {
      source = "vmware/vsphere"
    }
    vcd = {
      source = "vmware/vcd"
  }
  }
  required_version = ">= 0.13"
}
