[k3s_server]
${server_name} ansible_host=${server_public_ip} node_private_ip=${server_private_ip}

[k3s_agents]
%{ for a in agents ~}
${a.name} ansible_host=${a.public_ip} node_private_ip=${a.private_ip}
%{ endfor ~}

[k3s_cluster:children]
k3s_server
k3s_agents

[k3s_cluster:vars]
ansible_user=ubuntu
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
server_private_ip=${server_private_ip}
