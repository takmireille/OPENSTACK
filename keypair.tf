resource "openstack_compute_keypair_v2" "keypair" {
  name = "key-terraform"
}

resource "local_file" "private_key" {
  content         = openstack_compute_keypair_v2.keypair.private_key
  filename        = "${path.module}/key-terraform.pem"
  file_permission = "0600"
}