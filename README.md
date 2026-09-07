# OPENSTACK
deployement , utilisation des services centraux et automatisation
# OpenStack AIO sur GCP — notes de déploiement

Déploiement **All-In-One** d'OpenStack avec **Kolla-Ansible 22.0.0** (série
`2026.1`, images `debian-trixie`) sur **une seule VM GCP mono-NIC**.
Le script `deploy-openstack-gcp.sh` rejoue tout automatiquement ; ce document
explique l'architecture et surtout **pourquoi** chaque contournement est
nécessaire — c'est la partie qui fait gagner des heures à la prochaine install.

---

## 1. Dimensionnement de la VM

Un AIO fait tourner ~34 conteneurs (MariaDB, RabbitMQ, Nova, Neutron, Keystone,
Glance, Horizon, HAProxy, ProxySQL, OVS…). Le plancher réel :

| Ressource | Minimum | Recommandé | Type GCP |
|-----------|---------|------------|----------|
| RAM       | 8 Go    | **16 Go**  | `e2-standard-4` |
| vCPU      | 2       | 4          | |
| Disque    | 40 Go   | **50 Go**  | |

Une VM à 3,8 Go / 10 Go **échoue** (OOM killer + disque plein au `pull`).
Le redimensionnement exige la VM **arrêtée**, et se fait **depuis le poste**
(compte utilisateur), pas depuis la VM : le compte de service de l'instance a
des *scopes* restreints (`ACCESS_TOKEN_SCOPE_INSUFFICIENT`).

```bash
gcloud compute instances stop  <VM> --zone <ZONE>
gcloud compute instances set-machine-type <VM> --zone <ZONE> --machine-type e2-standard-4
gcloud compute instances start <VM> --zone <ZONE>
```

Sur l'image Debian 13 de GCP, la partition racine est **étendue automatiquement**
au boot (cloud-init) : après un disque à 50 Go, `df -h /` montre déjà ~49 Go,
`growpart`/`resize2fs` n'ont rien à faire.

---

## 2. Architecture réseau — le point central

### Contrainte GCP mono-NIC
L'unique interface `ens4` porte une adresse en **/32** (`10.128.0.x/32`). Kolla
exige une interface avec un vrai sous-réseau routable pour son management et son
VIP : `ens4` est donc **inutilisable** comme `network_interface`.

### Solution : deux interfaces *dummy*
| Interface   | Rôle Kolla | Adresse |
|-------------|------------|---------|
| `kolla0`    | `network_interface` (management) | `10.10.0.1/24` |
| `dummy-ext` | `neutron_external_interface` (br-ex) | **aucune** |
| (VIP)       | `kolla_internal_vip_address` | `10.10.0.2` sur `kolla0` |

**Pourquoi `dummy-ext` sans IP ?** Quand Neutron crée le bridge OVS `br-ex`, il
*enslave* l'interface externe. Si on lui donnait `ens4` (la NIC qui porte le SSH),
OVS déplacerait l'IP et **couperait la session SSH**. Une interface dummy sans
adresse n'a rien à déplacer → le SSH survit. C'est LE piège qui bloquait les
déploiements précédents à l'étape `br-ex`.

Ces interfaces sont créées par un **service systemd `kolla-net`** (voir §6),
rejoué à chaque boot.

---

## 3. Deux pièges système récurrents

### `/etc/hosts` réinjecté par GCP
L'agent invité GCP réécrit à chaque boot une ligne
`10.128.0.x <hostname> # Added by Google`, qui fait résoudre le hostname vers
l'IP GCP au lieu de `10.10.0.1`. Correctif : purge dans le service `kolla-net`
(`ExecStartPre` supprime la ligne `Added by Google`) + une ligne fixe
`10.10.0.1 <hostname>`.

### `ip_forward` désactivé par GCP
GCP livre `net.ipv4.ip_forward = 0` via `/etc/sysctl.d/60-gce-network-security.conf`.
Sans forwarding, Neutron ne route rien (« Networking will not work »). Correctif :
`/etc/sysctl.d/99-openstack.conf` avec `= 1`. Le préfixe **99** est appliqué
**après** le 60, donc il gagne — vérifiable par `cat /proc/sys/net/ipv4/ip_forward`.

---

## 4. Dépendances et commandes qui changent

- **SDK Docker Python** : `bootstrap-servers` installe le *daemon* Docker mais pas
  le module `import docker` dans le venv. Les prechecks échouent
  (`ModuleNotFoundError: docker`). → `pip install docker` **dans le venv**.
- **dbus-python** : autre precheck. Ce module **se compile** → il faut
  `libdbus-1-dev libglib2.0-dev pkg-config build-essential python3-dev` avant
  `pip install dbus-python`.
- **Génération des mots de passe** : la sous-commande `genpwd`/`gen-passwords`
  **n'existe pas** dans cette build. C'est l'exécutable séparé **`kolla-genpwd`**
  (dans `~/kolla-venv/bin/`).
- **Images de test** : la registry par défaut est `quay.io/openstack.kolla`, que
  Kolla signale « test only ». Le flag `--use-test-images` est accepté par
  `prechecks` mais **rejeté par `pull`**. Le correctif robuste est de poser la
  variable réelle testée par l'assertion — **`kolla_test_images: true`** dans
  `globals.yml` — ce qui vaut pour toutes les commandes.
- **`nova_compute_virt_type: qemu`** : une VM GCP standard n'expose pas `/dev/kvm`
  (pas de nested virtualization). Nova doit tourner en émulation QEMU (instances
  plus lentes, mais fonctionnelles). Pour du vrai KVM : créer la VM avec
  `--enable-nested-virtualization`.

---

## 5. Le VIP et keepalived — la grande décision

### Le problème observé
Avec keepalived activé (défaut Kolla), le déploiement bloque sur
`Wait for haproxy to listen on VIP` (timeout 300 s) : keepalived reste en FAULT
et ne pose jamais le VIP `10.10.0.2`. Deux causes cumulées dans l'image
`keepalived:2026.1-debian-trixie` :

1. **Check ProxySQL cassé.** `/checks/check_alive_proxysql.sh` fait
   `echo "show info" | socat unix-connect:/var/lib/kolla/proxysql/admin.sock`.
   Le socket existe et `socat` est présent, mais **toute** connexion est fermée
   (`Connection reset by peer`) — l'agrégateur `/check_alive.sh` retourne alors 1.
2. **Utilisateur manquant.** keepalived exécute ses scripts sous l'utilisateur
   `keepalived_script`, **absent de l'image**
   (`Script user 'keepalived_script' does not exist`). Sans lui, keepalived
   refuse de passer MASTER → pas de VIP.

### La solution retenue (mono-nœud)
En AIO **mono-nœud**, keepalived ne protège **rien** (aucune bascule VRRP
possible, et le multicast VRRP est de toute façon filtré sur GCP). On le
**désactive** et on gère le VIP en statique :

```yaml
enable_haproxy: "yes"
enable_keepalived: "no"
```

Le VIP `10.10.0.2` est posé par le service systemd `kolla-net` **avant** le
deploy. HAProxy s'y bind (Kolla active `ip_nonlocal_bind`), et le handler
« Wait for haproxy… » passe sans drame. C'est déterministe, incassable, et ça
survit au reboot.

> **Multi-nœud** : si un jour tu passes en cluster HA, garde keepalived activé et
> corrige plutôt les deux causes ci-dessus (créer `keepalived_script`, réparer ou
> neutraliser le check ProxySQL via `/etc/kolla/config/`). En mono-nœud, ne
> t'embête pas : le VIP statique est le bon choix.

---

## 6. Persistance au reboot

Trois choses doivent remonter seules, sinon la plateforme est morte après un
`reboot` :

1. **Interfaces + VIP** → service `kolla-net` (idempotent grâce au préfixe `-`
   devant les `ip`, qui ignore « File exists » sur un restart à chaud).
2. **`ip_forward`** → `99-openstack.conf` (persistant).
3. **Conteneurs** → politique `--restart=unless-stopped` sur tous
   (`sudo docker update --restart=unless-stopped $(sudo docker ps -aq)`).

Après `sudo reboot` et reconnexion, tout doit être là **sans intervention** :
2 IP sur `kolla0`, `ip_forward=1`, conteneurs `Up`, `openstack service list` OK.
Rappel : après reboot, **réactiver le venv** (`source ~/kolla-venv/bin/activate`)
avant d'utiliser le client `openstack`.

---

## 7. Ordre de déploiement (chemin propre)

```
check → net → hosts → sysctl → deps → kolla → globals → genpwd
      → bootstrap → prechecks → pull → deploy → postdeploy → verify
```

La clé du chemin propre : **poser les interfaces + le VIP (phase `net`) AVANT le
deploy**, et **désactiver keepalived dès `globals`**. Ainsi on n'entre jamais
dans le cycle d'échec du VIP.

---

## 8. Reste à faire (hors périmètre de ce déploiement)

- **`init-runonce`** : image Cirros, flavors, réseau/routeur/keypair de démo.
  Sur mono-NIC, surcharger `EXT_NET_*` pour coller à `dummy-ext`.
- **Accès Internet réel des floating IP** : nécessite une paire `veth` + SNAT
  (`iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE`) côté hôte, seul moyen
  propre sur une VM mono-NIC.
- **Horizon** : accès via tunnel SSH sur le VIP `10.10.0.2` (port 80/443).
- **TLS** : si activé, penser à `OS_CACERT` pour le client OpenStack.

---

## 9. Aide-mémoire commandes

```bash
# Recharger l'environnement (après chaque connexion / reboot)
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

# Santé de la plateforme
openstack service list
openstack network agent list        # agents Neutron : Alive :-)  State UP
openstack hypervisor list           # type QEMU, State up

# Interfaces + VIP
ip a show kolla0                     # doit montrer 10.10.0.1 ET 10.10.0.2
systemctl status kolla-net.service

# Conteneurs
sudo docker ps --format '{{.Names}}\t{{.Status}}' | sort
```
