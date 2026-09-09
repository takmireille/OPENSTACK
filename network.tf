resource "openstack_networking_network_v2" "private_net" {
  name           = "net-terraform"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name            = "subnet-terraform"
  network_id      = openstack_networking_network_v2.private_net.id
  cidr            = var.private_cidr
  ip_version      = 4
  dns_nameservers = ["8.8.8.8"]
}

resource "openstack_networking_router_v2" "router" {
  name           = "router-terraform"
  admin_state_up = true
}

resource "openstack_networking_router_interface_v2" "router_iface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private_subnet.id
}