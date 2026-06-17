output "server_public_ip" {
  description = "Public IP of the k3s server (control-plane) node"
  value       = oci_core_instance.server.public_ip
}

output "server_private_ip" {
  description = "Private IP of the k3s server node"
  value       = oci_core_instance.server.private_ip
}

output "agent_public_ips" {
  description = "Public IPs of the k3s agent nodes"
  value       = [for a in oci_core_instance.agent : a.public_ip]
}

output "agent_private_ips" {
  description = "Private IPs of the k3s agent nodes"
  value       = [for a in oci_core_instance.agent : a.private_ip]
}

output "ssh_server" {
  description = "Convenience SSH command for the server"
  value       = "ssh ubuntu@${oci_core_instance.server.public_ip}"
}

output "ansible_inventory_path" {
  description = "Path to the generated Ansible inventory"
  value       = var.inventory_output_path
}
