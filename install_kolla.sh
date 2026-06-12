#!/bin/bash
set -e  # Arrête le script si une commande échoue

echo "========================================="
echo "  Installation Kolla-Ansible - OpenStack"
echo "========================================="

# Étape 1 - Mise à jour du système
echo "[1/6] Mise à jour du système..."
sudo apt update && sudo apt upgrade -y

# Étape 2 - Installation des dépendances
echo "[2/6] Installation des dépendances..."
sudo apt install -y python3-pip python3-venv git curl docker.io

# Étape 3 - Activer Docker
echo "[3/6] Activation de Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Étape 4 - Environnement virtuel Python
echo "[4/6] Création de l'environnement virtuel..."
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate

# Étape 5 - Installation de Kolla-Ansible
echo "[5/6] Installation de Kolla-Ansible..."
pip install kolla-ansible

# Étape 6 - Copie des fichiers de config
echo "[6/6] Copie des fichiers de configuration..."
sudo mkdir -p /etc/kolla
sudo cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
sudo cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one /etc/kolla/

echo "========================================="
echo "  Installation terminée avec succès !"
echo "  Lance : source ~/kolla-venv/bin/activate"
echo "  Puis  : kolla-ansible --version"
echo "========================================="
