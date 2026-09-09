output "instance_name" {
  value = openstack_compute_instance_v2.vm.name
}

output "instance_ip" {
  value = openstack_compute_instance_v2.vm.access_ip_v4
}

output "keypair_name" {
  value = openstack_compute_keypair_v2.keypair.name
}