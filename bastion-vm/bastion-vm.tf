

provider "vcd" {
  user                 = var.vcd_user
  password             = var.vcd_password
  org                  = var.vcd_org
  url                  = var.vcd_url
  max_retry_timeout    = 30
  allow_unverified_ssl = true
  logging              = true
}

// Get VDC Group
data "vcd_vdc_group" "dc_group" {
  org  = var.vcd_org
  name = var.vcd_dcg_name
}

// Get Edge Gateway for VDC Group
data "vcd_nsxt_edgegateway" "dcg_edge_gw" {
  org      = var.vcd_org
  owner_id = data.vcd_vdc_group.dc_group.id
  name     = var.vcd_edge_name
}

// Retrieve VApp Template ID
data "vcd_catalog" "my_cat" {
  org  = var.vcd_org
  name = var.vcd_catalog
}

data "vcd_catalog_vapp_template" "bastion_template" {
  org        = var.vcd_org
  catalog_id = data.vcd_catalog.my_cat.id
  name       = var.initialization_info["bastion_template"]
}

 locals {
    ansible_directory = "/tmp"
    additional_trust_bundle_dest = dirname(var.additionalTrustBundle)
    pull_secret_dest = dirname(var.openshift_pull_secret)
    nginx_repo        = "${path.cwd}/bastion-vm/ansible"
    login_to_bastion          =  "Next Step login to Bastion via: ssh -i ~/.ssh/id_bastion root@${var.initialization_info["public_bastion_ip"]}" 
 }

// resource "vcd_network_routed" "net" {
//   org          = var.vcd_org
//   vdc          = var.vcd_vdc
//   name         = var.initialization_info["network_name"]
//   interface_type = "internal"
//   edge_gateway = element(data.vcd_resource_list.edge_gateway_name.list,1)
//   gateway      = cidrhost(var.initialization_info["machine_cidr"], 1)
//
//   static_ip_pool {
//     start_address = var.initialization_info["static_start_address"]
//     end_address   = var.initialization_info["static_end_address"]
//   }
//  
// }

// Define IP Sets for firewall rules
resource "vcd_nsxt_ip_set" "bastion_internal_ips" {
  org              = var.vcd_org
  edge_gateway_id  = data.vcd_nsxt_edgegateway.dcg_edge_gw.id
  name             = "${var.cluster_id}-bastion_internal_address"
  ip_addresses     = [
    var.initialization_info["internal_bastion_ip"],
  ]
  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
  ]
}
resource "vcd_nsxt_ip_set" "bastion_public_ips" {
  org              = var.vcd_org
  edge_gateway_id  = data.vcd_nsxt_edgegateway.dcg_edge_gw.id
  name             = "${var.cluster_id}-bastion_public_address"
  ip_addresses     = [
    var.initialization_info["public_bastion_ip"],
  ]
  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
  ]
}  

// Define app profiles for firewall rules
resource "vcd_nsxt_app_port_profile" "bastion_inbound_apps_ports" {
  org              = var.vcd_org
  context_id       = data.vcd_vdc_group.dc_group.id
  name             = "${var.cluster_id}-bastion_app_port_profile"
  scope            = "TENANT"
  app_port {
    protocol       = "TCP"
    port           = ["22", "5000-5010"]
  }
  
  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
  ]
}
// Create edge gateway firewall rules
resource "vcd_nsxt_firewall" "bastion_firewall_rules" {
  org              = var.vcd_org
  edge_gateway_id  = data.vcd_nsxt_edgegateway.dcg_edge_gw.id    

  // Allow bastion internal outbound to Internet
  rule {
    action               = "ALLOW"
    name                 = "${var.cluster_id} Bastion outbound"
    direction            = "OUT"
    ip_protocol          = "IPV4"
    source_ids           = [vcd_nsxt_ip_set.bastion_internal_ips.id]
    destination_ids      = []
    app_port_profile_ids = []
    logging              = true
  }

  // Allow bastion public IP inbound from internet
  rule {
    action               = "ALLOW"
    name                 = "${var.cluster_id} Bastion inbound"
    direction            = "IN"
    ip_protocol          = "IPV4"
    source_ids           = []
    destination_ids      = [vcd_nsxt_ip_set.bastion_public_ips.id]
    app_port_profile_ids = [vcd_nsxt_app_port_profile.bastion_inbound_apps_ports.id]
    logging              = true
  }

  depends_on = [
    vcd_nsxt_ip_set.bastion_internal_ips,
    vcd_nsxt_ip_set.bastion_public_ips,
    vcd_nsxt_app_port_profile.bastion_inbound_apps_ports,
  ]
}

// NAT Rules
resource "vcd_nsxt_nat_rule" "bastion_dnat_rule" {
  org              = var.vcd_org
  edge_gateway_id  = data.vcd_nsxt_edgegateway.dcg_edge_gw.id

  name             = "${var.cluster_id}-bastion_dnat_rule"
  rule_type        = "DNAT"
  description      = "${var.cluster_id} Bastion DNAT rule"

  firewall_match   = "MATCH_EXTERNAL_ADDRESS"

  priority         = 1
  enabled          = true

  external_address = var.initialization_info["public_bastion_ip"]
  internal_address = var.initialization_info["internal_bastion_ip"]
  
  logging            = true

  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
  ]
}

resource "vcd_nsxt_nat_rule" "snat_priv" {
  org              = var.vcd_org
  edge_gateway_id  = data.vcd_nsxt_edgegateway.dcg_edge_gw.id

  name             = "${var.cluster_id}-bastion_snat_rule"
  rule_type        = "SNAT"
  description      = "${var.cluster_id} SNAT rule"

  firewall_match   = "MATCH_INTERNAL_ADDRESS"

  priority         = 1
  enabled          = true

  external_address = var.initialization_info["public_bastion_ip"]
  internal_address = var.initialization_info["machine_cidr"]
  dnat_external_port = "ANY"

  logging            = true

  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
  ]
}

// Create a Vapp (needed by the VM)
resource "vcd_vapp" "bastion" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name         = "bastion-${var.vcd_vdc}-${var.cluster_id}"
}
// Associate the route network with the Vapp
resource "vcd_vapp_org_network" "vappOrgNet" {
  org                    = var.vcd_org
  vdc                    = var.vcd_vdc
  vapp_name              = vcd_vapp.bastion.name

  org_network_name       = var.initialization_info["network_name"]
  reboot_vapp_on_removal = true
  // depends_on = [vcd_network_routed.net]
}
// Create the bastion VM
resource "vcd_vapp_vm" "bastion" { 
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  vapp_name     = vcd_vapp.bastion.name
  name          = "bastion-${var.vcd_vdc}-${var.cluster_id}"
  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
    vcd_nsxt_nat_rule.bastion_dnat_rule,
    vcd_nsxt_nat_rule.snat_priv,
    vcd_nsxt_firewall.bastion_firewall_rules,
  ]
  vapp_template_id = data.vcd_catalog_vapp_template.bastion_template.id
  memory        = 8192
  cpus          = 2
  cpu_cores     = 1
  
  override_template_disk {
    bus_type           = "paravirtual"
    size_in_mb         = var.bastion_disk
    bus_number         = 0
    unit_number        = 0
  }
  # Assign IP address on the routed network 
  network {
    type               = "org"
    name               = var.initialization_info["network_name"]
    ip_allocation_mode = "MANUAL"
    ip                 = var.initialization_info["internal_bastion_ip"]
    is_primary         = true
    connected          = true
  }
  # define Password for the vm. The the script could use it to do the ssh-copy-id to upload the ssh key
   customization {
    allow_local_admin_password = true 
    auto_generate_password = false
    admin_password = var.initialization_info["bastion_password"]
  }
  power_on = true
  # upload the ssh key on the VM. it will avoid password authentification for later interaction with the vm

}
 

 data "template_file" "ansible_inventory" {
  template = <<EOF
${var.initialization_info["public_bastion_ip"]} ansible_connection=ssh ansible_ssh_private_key_file=~/.ssh/id_bastion ansible_user=root ansible_python_interpreter="/usr/libexec/platform-python" 
EOF
}

 data "template_file" "ansible_main_yaml" {
       template = file ("${path.module}/ansible/main.yaml.tmpl")
       
       vars ={
         vcd                  = var.vcd_vdc
         public_bastion_ip    = var.initialization_info["public_bastion_ip"]
         rhel_key      = var.initialization_info["rhel_key"]
         cluster_id    = var.cluster_id
         base_domain   = var.base_domain
         lb_ip_address = var.lb_ip_address
         openshift_version = var.openshift_version
         terraform_ocp_repo = var.initialization_info["terraform_ocp_repo"]
         nginx_repo_dir = local.nginx_repo
         openshift_pull_secret = var.openshift_pull_secret
         pull_secret_dest   = local.pull_secret_dest
         terraform_root = path.cwd
         additional_trust_bundle   =  var.additionalTrustBundle
         additional_trust_bundle_dest   = local.additional_trust_bundle_dest 
         run_cluster_install       =  var.initialization_info["run_cluster_install"]
         
       }
 }
 
resource "local_file" "ansible_inventory" {
  content  = data.template_file.ansible_inventory.rendered
  filename = "${local.ansible_directory}/inventory"
  depends_on = [
         null_resource.setup_ssh 
  ]
}

resource "local_file" "ansible_main_yaml" {
  content  = data.template_file.ansible_main_yaml.rendered
  filename = "${local.ansible_directory}/main.yaml"
  depends_on = [
         null_resource.setup_ssh 
  ]
}

resource "null_resource" "setup_bastion" {
   #launch ansible script. 

  
  provisioner "local-exec" {
      command = " ansible-playbook -i ${local.ansible_directory}/inventory ${local.ansible_directory}/main.yaml"
  }
  depends_on = [
      local_file.ansible_inventory,
      local_file.ansible_main_yaml,
  ]
}
resource "null_resource" "setup_ssh" {
 
  provisioner "local-exec" {
      command = templatefile("${path.module}/scripts/fix_ssh.sh.tmpl" , {
         bastion_password            = var.initialization_info["bastion_password"]
         public_bastion_ip           = var.initialization_info["public_bastion_ip"] 
    })
  }
    depends_on = [
        vcd_vapp_vm.bastion 
  ]
}

  data "local_file" "read_final_args" {
  filename = pathexpand("~/${var.cluster_id}info.txt")
  depends_on = [
    null_resource.setup_bastion
  ]
}

resource "local_file" "write_args" {
  content  = local.login_to_bastion
  filename = pathexpand("~/${var.cluster_id}info.txt")
  depends_on = [
         null_resource.setup_ssh 
  ]
}
