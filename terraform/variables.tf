variable "tenancy_ocid" {
  description = "OCID of your tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the API user"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API signing key"
  type        = string
}

variable "private_key" {
  description = "Content of the OCI API signing private key (PEM)"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "OCI region, e.g. eu-frankfurt-1"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment where compute instances are created (e.g. k3-staging)"
  type        = string
}

variable "use_existing_vcn" {
  description = "If true, attach to an existing VCN instead of creating a new one"
  type        = bool
  default     = false
}

variable "existing_vcn_ocid" {
  description = "OCID of the existing VCN to use when use_existing_vcn is true"
  type        = string
  default     = ""
}

variable "vcn_compartment_ocid" {
  description = "Compartment where the existing VCN lives. Required when use_existing_vcn is true."
  type        = string
  default     = ""
}

variable "existing_internet_gateway_id" {
  description = "Optional. OCID of an existing internet gateway on the VCN. Leave empty to let Terraform create one (typical for a bare VCN)."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "Public SSH key content injected into the instances"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH (port 22). Lock this to your IP/32 for safety."
  type        = string
  default     = "0.0.0.0/0"
}

variable "availability_domain" {
  description = "Optional. Full AD name to launch instances in (e.g. 'kIdk:UK-LONDON-1-AD-2'). Empty = use availability_domain_number / first AD. Use to hunt for A1 capacity."
  type        = string
  default     = ""
}

variable "availability_domain_number" {
  description = "Optional. 1-based AD index to launch instances in (1, 2, or 3 in multi-AD regions). 0 = first AD. Ignored if availability_domain is set."
  type        = number
  default     = 0
}

variable "agent_count" {
  description = "Number of k3s agent (worker) nodes. Total nodes = 1 server + agent_count."
  type        = number
  default     = 2
}

variable "instance_shape" {
  description = "Compute shape. 'VM.Standard.A1.Flex' (ARM, Always Free) or a paid AMD flex like 'VM.Standard.E4.Flex'/'VM.Standard.E5.Flex' (better availability, uses trial credits). The Ubuntu image auto-matches this shape's architecture."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "OCPUs per node. Flex shapes (A1/E4/E5) minimum is 1."
  type        = number
  default     = 1
}

variable "instance_memory_gbs" {
  description = "Memory (GB) per node. Up to 6GB per OCPU."
  type        = number
  default     = 8
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "k3s-staging"
}

variable "expose_http" {
  description = "Open ports 80/443 to the internet for the ingress controller"
  type        = bool
  default     = true
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "inventory_output_path" {
  description = "Where to write the generated Ansible inventory"
  type        = string
  default     = "../ansible/inventory/hosts.ini"
}
