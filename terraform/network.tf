data "oci_core_vcn" "existing" {
  count  = var.use_existing_vcn ? 1 : 0
  vcn_id = var.existing_vcn_ocid
}

locals {
  vcn_id   = var.use_existing_vcn ? var.existing_vcn_ocid : oci_core_vcn.k3s[0].id
  vcn_cidr = var.use_existing_vcn ? data.oci_core_vcn.existing[0].cidr_blocks[0] : var.vcn_cidr

  subnet_id = oci_core_subnet.k3s.id

  # Network resources live in the VCN compartment when reusing an existing VCN.
  network_compartment_ocid = var.use_existing_vcn ? var.vcn_compartment_ocid : var.compartment_ocid

  create_internet_gateway = var.existing_internet_gateway_id == ""

  igw_id = var.existing_internet_gateway_id != "" ? var.existing_internet_gateway_id : oci_core_internet_gateway.k3s[0].id
}

resource "oci_core_vcn" "k3s" {
  count = var.use_existing_vcn ? 0 : 1

  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "k3svcn"
}

resource "oci_core_internet_gateway" "k3s" {
  count = local.create_internet_gateway ? 1 : 0

  compartment_id = local.network_compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_route_table" "k3s" {
  compartment_id = local.network_compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${var.name_prefix}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = local.igw_id
  }
}

resource "oci_core_security_list" "k3s" {
  compartment_id = local.network_compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${var.name_prefix}-seclist"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "6"
    source   = var.ssh_allowed_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.vcn_cidr
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.vcn_cidr
    tcp_options {
      min = 10250
      max = 10250
    }
  }

  ingress_security_rules {
    protocol = "17"
    source   = local.vcn_cidr
    udp_options {
      min = 8472
      max = 8472
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.vcn_cidr
    tcp_options {
      min = 1
      max = 65535
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.expose_http ? [80, 443] : []
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
}

resource "oci_core_subnet" "k3s" {
  compartment_id             = local.network_compartment_ocid
  vcn_id                     = local.vcn_id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.name_prefix}-subnet"
  dns_label                  = "k3ssub"
  route_table_id             = oci_core_route_table.k3s.id
  security_list_ids          = [oci_core_security_list.k3s.id]
  prohibit_public_ip_on_vnic = false
}

check "existing_vcn_requires_ocid" {
  assert {
    condition     = !var.use_existing_vcn || var.existing_vcn_ocid != ""
    error_message = "existing_vcn_ocid must be set when use_existing_vcn is true."
  }
}

check "existing_vcn_requires_compartment" {
  assert {
    condition     = !var.use_existing_vcn || var.vcn_compartment_ocid != ""
    error_message = "vcn_compartment_ocid must be set when use_existing_vcn is true."
  }
}
