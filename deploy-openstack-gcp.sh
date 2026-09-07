#!/usr/bin/env bash
#
# deploy-openstack-gcp.sh
# =======================
# Déploiement OpenStack AIO (All-In-One) avec Kolla-Ansible 22.0.0
# sur une VM GCP mono-NIC (Debian Trixie 13).
#
# Ce script encode le CHEMIN PROPRE : keepalived désactivé + VIP statique
# via systemd dès le départ, ce qui évite les blocages rencontrés en
# découverte (check ProxySQL cassé, user keepalived_script manquant, VIP
# qui ne monte pas). Voir README.md pour le détail de chaque choix.
#
# Prérequis VM (à créer AVANT, depuis ton poste avec gcloud) :
#   gcloud compute instances create os-aio \
#     --zone us-central1-a --machine-type e2-standard-4 \
#     --image-family debian-13 --image-project debian-cloud \
#     --boot-disk-size 50GB
#
# Usage :
#   ./deploy-openstack-gcp.sh all         # tout d'un trait
#   ./deploy-openstack-gcp.sh <phase>     # une phase précise
# Phases : check net hosts sysctl deps kolla config globals genpwd \
#          bootstrap prechecks pull deploy postdeploy verify
#
set -euo pipefail

# ----------------------------------------------------------------------
# Variables à adapter si besoin
# ----------------------------------------------------------------------
KOLLA_VERSION="22.0.0"
VENV="${HOME}/kolla-venv"
MGMT_IF="kolla0"                 # interface dummy de management
MGMT_IP="10.10.0.1/24"
VIP="10.10.0.2"                  # kolla_internal_vip_address
VIP_CIDR="${VIP}/24"
EXT_IF="dummy-ext"               # interface dummy pour br-ex (Neutron)
INVENTORY="${HOME}/all-in-one"

log()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\n\033[1;31m[x] $*\033[0m" >&2; }

# ----------------------------------------------------------------------
# PHASE check : dimensionnement minimal
# ----------------------------------------------------------------------
phase_check() {
  log "Vérification du dimensionnement de la VM"
  local mem_gb cpu disk_g
  mem_gb=$(free -g | awk '/^Mem:/{print $2}')
  cpu=$(nproc)
  disk_g=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  echo "RAM=${mem_gb}Go  CPU=${cpu}  Disque libre=${disk_g}Go"
  [ "${mem_gb}" -ge 14 ] || warn "RAM < 15Go : un AIO exige ~16Go (e2-standard-4). Risque d'OOM."
  [ "${cpu}"    -ge 2  ] || warn "CPU < 2 : trop peu pour un AIO."
  [ "${disk_g}" -ge 35 ] || warn "Disque < 35Go libre : les images Kolla ne tiendront pas."
  if [ ! -e /dev/kvm ]; then
    warn "/dev/kvm absent -> nova_compute_virt_type=qemu (obligatoire sur VM GCP standard)."
  fi
}

# ----------------------------------------------------------------------
# PHASE net : service systemd kolla-net (interfaces dummy + VIP statique)
#   - idempotent (prefixe '-' devant les ip => 'File exists' ignoré)
#   - purge la ligne GCP de /etc/hosts a chaque boot (ExecStartPre)
#   - le VIP est pose ICI, statiquement, car keepalived est desactive
# ----------------------------------------------------------------------
phase_net() {
  log "Installation du service réseau systemd (kolla-net)"
  sudo tee /etc/systemd/system/kolla-net.service > /dev/null <<EOF
[Unit]
Description=Kolla network: dummy interfaces + internal VIP (mono-node)
After=network.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/bash -c "sed -i '/Added by Google/d' /etc/hosts"
ExecStart=-/sbin/ip link add ${MGMT_IF} type dummy
ExecStart=/sbin/ip link set ${MGMT_IF} up
ExecStart=-/sbin/ip addr add ${MGMT_IP} dev ${MGMT_IF}
ExecStart=-/sbin/ip addr add ${VIP_CIDR} dev ${MGMT_IF}
ExecStart=-/sbin/ip link add ${EXT_IF} type dummy
ExecStart=/sbin/ip link set ${EXT_IF} up
ExecStop=-/sbin/ip addr del ${VIP_CIDR} dev ${MGMT_IF}
ExecStop=-/sbin/ip link del ${MGMT_IF}
ExecStop=-/sbin/ip link del ${EXT_IF}

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now kolla-net.service
  ip -br a | grep -E "${MGMT_IF}|${EXT_IF}" || true
  log "kolla0 doit porter ${MGMT_IP} ET ${VIP} (secondary) ; dummy-ext sans IP."
}

# ----------------------------------------------------------------------
# PHASE hosts : resolution du hostname vers l'IP de management
# ----------------------------------------------------------------------
phase_hosts() {
  log "Nettoyage de /etc/hosts (piège GCP)"
  sudo sed -i "/$(hostname)/d" /etc/hosts
  echo "10.10.0.1 $(hostname)" | sudo tee -a /etc/hosts
  grep "$(hostname)" /etc/hosts
}

# ----------------------------------------------------------------------
# PHASE sysctl : ip_forward persistant (GCP le desactive par defaut)
#   60-gce-network-security.conf met 0 ; notre 99-* (applique apres) met 1
# ----------------------------------------------------------------------
phase_sysctl() {
  log "Activation persistante d'ip_forward"
  echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-openstack.conf
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl --system >/dev/null
  echo "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward) (attendu : 1)"
}

# ----------------------------------------------------------------------
# PHASE deps : dependances systeme + Python (dans le venv)
#   - dbus-python se COMPILE : d'ou les -dev
#   - le SDK docker (import docker) est requis par les prechecks Kolla
# ----------------------------------------------------------------------
phase_deps() {
  log "Dépendances système"
  sudo apt-get update
  sudo apt-get install -y \
    python3-dev python3-venv libffi-dev gcc libssl-dev git \
    libdbus-1-dev libglib2.0-dev pkg-config build-essential \
    cloud-guest-utils

  log "Création du virtualenv + dépendances Python"
  [ -d "${VENV}" ] || python3 -m venv "${VENV}"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  pip install -U pip
  pip install "kolla-ansible==${KOLLA_VERSION}"
  pip install docker dbus-python            # combler les prechecks
  python3 -c "import docker, dbus; print('SDK docker + dbus OK')"
}

# ----------------------------------------------------------------------
# PHASE kolla : fichiers de config + collections Galaxy
# ----------------------------------------------------------------------
phase_kolla() {
  log "Mise en place de /etc/kolla et de l'inventaire"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  sudo mkdir -p /etc/kolla
  sudo chown "$USER":"$USER" /etc/kolla
  cp -r "${VENV}/share/kolla-ansible/etc_examples/kolla/"* /etc/kolla/
  cp "${VENV}/share/kolla-ansible/ansible/inventory/all-in-one" "${INVENTORY}"
  kolla-ansible install-deps
}

# ----------------------------------------------------------------------
# PHASE globals : bloc de config personnalise (le coeur des choix)
# ----------------------------------------------------------------------
phase_globals() {
  log "Écriture du bloc personnalisé dans globals.yml"
  # On retire un eventuel bloc precedent pour rester idempotent
  sudo sed -i '/### BLOC AIO GCP - debut ###/,/### BLOC AIO GCP - fin ###/d' /etc/kolla/globals.yml
  sudo tee -a /etc/kolla/globals.yml > /dev/null <<EOF
### BLOC AIO GCP - debut ###
kolla_base_distro: "debian"
kolla_internal_vip_address: "${VIP}"

# Reseau : contrainte mono-NIC GCP (ens4 est en /32, inutilisable)
network_interface: "${MGMT_IF}"
neutron_external_interface: "${EXT_IF}"
enable_neutron_provider_networks: "yes"

# HA : mono-noeud => keepalived DESACTIVE, VIP gere par systemd (kolla-net)
enable_haproxy: "yes"
enable_keepalived: "no"

# Nova : pas de /dev/kvm sur VM GCP standard => emulation qemu
nova_compute_virt_type: "qemu"

# Images : accepte le namespace de test quay.io/openstack.kolla
# (la variable est kolla_test_images, PAS le flag --use-test-images
#  qui n'est pas reconnu par 'pull' dans cette build)
kolla_test_images: true
### BLOC AIO GCP - fin ###
EOF
  tail -20 /etc/kolla/globals.yml
}

# ----------------------------------------------------------------------
# PHASE genpwd : generation des mots de passe
#   ATTENTION : la sous-commande n'existe pas ; c'est l'executable kolla-genpwd
# ----------------------------------------------------------------------
phase_genpwd() {
  log "Génération des mots de passe (kolla-genpwd)"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-genpwd
  echo "Clés remplies : $(grep -c ':' /etc/kolla/passwords.yml)"
}

# ----------------------------------------------------------------------
# PHASES kolla-ansible
# ----------------------------------------------------------------------
phase_bootstrap() {
  log "bootstrap-servers"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-ansible bootstrap-servers -i "${INVENTORY}"
  # Kolla peut recreer certains conteneurs sans restart-policy : on force
  # (utile surtout apres deploy, inoffensif ici)
}

phase_prechecks() {
  log "prechecks"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-ansible prechecks -i "${INVENTORY}"
}

phase_pull() {
  log "pull (téléchargement des images, long)"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-ansible pull -i "${INVENTORY}"
}

phase_deploy() {
  log "deploy"
  # Le VIP DOIT etre present avant deploy pour que HAProxy s'y bind et que
  # le handler 'Wait for haproxy to listen on VIP' passe. La phase 'net'
  # l'a deja pose ; on verifie par securite.
  ip a show "${MGMT_IF}" | grep -q "${VIP}" || sudo ip addr add "${VIP_CIDR}" dev "${MGMT_IF}"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-ansible deploy -i "${INVENTORY}"
  # Politique de redemarrage : tout conteneur doit remonter au boot
  sudo docker update --restart=unless-stopped "$(sudo docker ps -aq)" >/dev/null
}

phase_postdeploy() {
  log "post-deploy + client OpenStack"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  kolla-ansible post-deploy -i "${INVENTORY}"
  pip install python-openstackclient
}

# ----------------------------------------------------------------------
# PHASE verify : la plateforme repond-elle ?
# ----------------------------------------------------------------------
phase_verify() {
  log "Vérification finale"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  # shellcheck disable=SC1091
  source /etc/kolla/admin-openrc.sh
  openstack service list
  openstack network agent list
  openstack hypervisor list
  echo
  log "Astuce : ajoute à ~/.bashrc pour recharger l'env à chaque connexion :"
  echo "  source ${VENV}/bin/activate && source /etc/kolla/admin-openrc.sh"
}

# ----------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------
phase="${1:-help}"
case "${phase}" in
  check)      phase_check ;;
  net)        phase_net ;;
  hosts)      phase_hosts ;;
  sysctl)     phase_sysctl ;;
  deps)       phase_deps ;;
  kolla)      phase_kolla ;;
  globals)    phase_globals ;;
  genpwd)     phase_genpwd ;;
  bootstrap)  phase_bootstrap ;;
  prechecks)  phase_prechecks ;;
  pull)       phase_pull ;;
  deploy)     phase_deploy ;;
  postdeploy) phase_postdeploy ;;
  verify)     phase_verify ;;
  all)
    phase_check; phase_net; phase_hosts; phase_sysctl; phase_deps
    phase_kolla; phase_globals; phase_genpwd
    phase_bootstrap; phase_prechecks; phase_pull; phase_deploy
    phase_postdeploy; phase_verify
    log "Déploiement terminé. Teste un reboot pour valider la persistance." ;;
  *)
    cat <<USAGE
Usage : $0 <phase|all>
Phases (dans l'ordre) :
  check net hosts sysctl deps kolla config globals genpwd
  bootstrap prechecks pull deploy postdeploy verify
Exemple : $0 all
USAGE
    ;;
esac
