variable "image_name" {
  default = "cirros"
}

variable "flavor_name" {
  default = "m1.tiny"
}

variable "instance_name" {
  default = "vm-terraform-01"
}

variable "private_cidr" {
  default = "192.168.100.0/24"
}