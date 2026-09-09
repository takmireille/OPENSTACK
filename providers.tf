# Define required providers
terraform {
  required_version = ">= 1.6"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

# Configure the OpenStack Provider
# Aucun identifiant ici : le provider lit les variables OS_* de l'environnement
# (chargées par : source ~/mireille-openrc.sh)
provider "openstack" {
  auth_url = "http://10.10.0.2:5000/v3"
  region   = "RegionOne"
}