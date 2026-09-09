resource "openstack_compute_instance_v2" "vm" {
  name            = var.instance_name
  image_name      = var.image_name
  flavor_name     = var.flavor_name
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_networking_secgroup_v2.secgroup.name]

  network {
    uuid = openstack_networking_network_v2.private_net.id
  }
}