data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  ad_name  = data.oci_identity_availability_domains.ads.availability_domains[0].name
  image_id = data.oci_core_images.ubuntu.images[0].id
  ssh_key  = var.ssh_public_key
}

resource "oci_core_instance" "server" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  display_name        = "${var.name_prefix}-server"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    hostname_label   = "server"
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }

  metadata = {
    ssh_authorized_keys = local.ssh_key
  }
}

resource "oci_core_instance" "agent" {
  count               = var.agent_count
  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  display_name        = "${var.name_prefix}-agent-${count.index + 1}"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    hostname_label   = "agent${count.index + 1}"
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }

  metadata = {
    ssh_authorized_keys = local.ssh_key
  }
}

resource "local_file" "ansible_inventory" {
  filename = var.inventory_output_path
  content = templatefile("${path.module}/templates/inventory.tpl", {
    server_name       = oci_core_instance.server.display_name
    server_public_ip  = oci_core_instance.server.public_ip
    server_private_ip = oci_core_instance.server.private_ip
    agents = [
      for a in oci_core_instance.agent : {
        name       = a.display_name
        public_ip  = a.public_ip
        private_ip = a.private_ip
      }
    ]
  })
}
