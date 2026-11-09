#!/usr/bin/env bash

# Définition du fichier de log
LOGFILE="${HOME}/kubernetes-control-node-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

info(){ printf "\n=== %s ===\n" "$1"; }
err(){ printf "\n!!! %s\n" "$1" >&2; }

# Variables
KUBE_VERSION="v1.28"
POD_NETWORK_CIDR="10.244.0.0/16"
TARGET_USER=$(whoami)

# Fonction d'exécution root/sudo
run_as_root() {
    local cmd="$*"
    if [[ "$(id -u)" -eq 0 ]]; then
        bash -c "$cmd"
    else
        sudo bash -c "$cmd"
    fi
}

# --- ÉTAPE 1: PRÉREQUIS ET OUTILS DE BASE ---
setup_prerequisites() {
    info "Étape 1: Configuration des prérequis et mise à jour du système"

    info "Mise à jour du cache et upgrade complet du système"
    run_as_root "apt update -y"
    run_as_root "apt upgrade -y"
    
    info "Installation de qemu-guest-agent (optionnel, utile dans les VMs)"
    run_as_root "DEBIAN_FRONTEND=noninteractive apt install qemu-guest-agent -y"

    info "Installation des outils de base pour Kubernetes"
    run_as_root "DEBIAN_FRONTEND=noninteractive apt install curl ca-certificates apt-transport-https -y"
}

# --- ÉTAPE 2: INSTALLATION ET CONFIGURATION DE CONTAINERD ---
setup_containerd() {
    info "Étape 2: Installation et configuration de Containerd"

    info "Installation de Containerd"
    run_as_root "DEBIAN_FRONTEND=noninteractive apt install containerd -y"

    info "Démarrage du service Containerd"
    run_as_root "systemctl enable --now containerd"

    info "Génération du fichier de configuration par défaut"
    run_as_root "mkdir -p /etc/containerd"
    run_as_root "containerd config default | tee /etc/containerd/config.toml"
    
    info "Configuration de SystemdCgroup à 'true' (requis par Kubernetes)"
    run_as_root "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml"

    info "Redémarrage de Containerd pour appliquer les changements"
    run_as_root "systemctl restart containerd"
}

# --- ÉTAPE 3: CONFIGURATION DU SYSTÈME ET DU NOYAU ---
setup_kernel_config() {
    info "Étape 3: Configuration du noyau (Swap, Modules, Sysctl)"

    info "Désactivation temporaire du Swap"
    run_as_root "swapoff -a"

    info "Désactivation permanente du Swap dans /etc/fstab"
    run_as_root "sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

    info "Chargement permanent des modules du noyau (overlay et br_netfilter)"
    run_as_root "echo 'overlay' | tee /etc/modules-load.d/containerd.conf"
    run_as_root "echo 'br_netfilter' | tee -a /etc/modules-load.d/containerd.conf"
    run_as_root "modprobe overlay"
    run_as_root "modprobe br_netfilter"

    info "Configuration des paramètres Sysctl pour Kubernetes"
    run_as_root "echo 'net.bridge.bridge-nf-call-ip6tables = 1' | tee /etc/sysctl.d/kubernetes.conf"
    run_as_root "echo 'net.bridge.bridge-nf-call-iptables = 1' | tee -a /etc/sysctl.d/kubernetes.conf"
    run_as_root "echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/kubernetes.conf"
    
    info "Application immédiate des paramètres Sysctl"
    run_as_root "sysctl --system"
}

# --- ÉTAPE 4: INSTALLATION DES OUTILS KUBERNETES (kubeadm, kubectl, kubelet) ---
install_kube_tools() {
    info "Étape 4: Installation de Kubeadm, Kubelet et Kubectl ($KUBE_VERSION)"

    info "Ajout de la clé GPG et du dépôt Kubernetes"
    run_as_root "curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBE_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    
    run_as_root "echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBE_VERSION/deb/ /\" | tee /etc/apt/sources.list.d/kubernetes.list"

    info "Mise à jour du cache APT et installation des paquets Kubernetes"
    run_as_root "apt update -y"
    run_as_root "DEBIAN_FRONTEND=noninteractive apt install kubeadm kubectl kubelet -y"

    info "Maintien des paquets Kubernetes (prevent updates)"
    run_as_root "apt-mark hold kubeadm kubelet kubectl"
}

# --- ÉTAPE 5: INITIALISATION DU CLUSTER (Nœud de Contrôle) ---
initialize_cluster() {
    info "Étape 5: Initialisation du Cluster Kubernetes (Control Plane)"

    # Récupérer l'adresse IP de la VM (Control Plane Endpoint)
    # Ceci est une approximation, souvent c'est l'IP par défaut.
    # On utilise 'hostname -I' et on prend la première IP (sans le 127.0.0.1)
    CONTROL_PLANE_IP=$(hostname -I | awk '{print $1}')

    if [ -z "$CONTROL_PLANE_IP" ]; then
        err "Impossible de déterminer l'adresse IP du nœud de contrôle. Abandon."
        exit 1
    fi
    
    info "Adresse IP détectée pour le Control Plane : $CONTROL_PLANE_IP"

    # Exécution de kubeadm init
    run_as_root "kubeadm init --control-plane-endpoint=$CONTROL_PLANE_IP --pod-network-cidr=$POD_NETWORK_CIDR"

    if [ $? -ne 0 ]; then
        err "L'initialisation de kubeadm a échoué. Veuillez vérifier les logs."
        exit 1
    fi

    info "Configuration de Kubectl pour l'utilisateur $TARGET_USER"
    mkdir -p $HOME/.kube
    run_as_root "cp -i /etc/kubernetes/admin.conf $HOME/.kube/config"
    run_as_root "chown $TARGET_USER:$TARGET_USER $HOME/.kube/config"

    info "Installation du CNI (Container Network Interface) - Flannel"
    # Note: L'utilisateur doit avoir les permissions Kubectl (fait juste au-dessus)
    kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.27.3/kube-flannel.yml
}

# --- ÉTAPE 6: AFFICHAGE DE LA COMMANDE DE JONCTION ---
display_join_command() {
    info "Étape 6: Affichage de la commande de jonction"
    
    info "Veuillez attendre quelques instants que le Control Plane soit stable."
    sleep 10
    
    # Générer la commande de jonction pour les Workers (doit être exécuté par un utilisateur avec le rôle kubeadm)
    JOIN_COMMAND=$(run_as_root "kubeadm token create --print-join-command 2>/dev/null")

    if [ -z "$JOIN_COMMAND" ]; then
        err "Impossible de générer la commande de jonction. Exécutez manuellement: sudo kubeadm token create --print-join-command"
    else
        printf "\n========================================================================="
        printf "\n✅ INSTALLATION DU CONTROL PLANE TERMINÉE."
        printf "\n\nCOMMANDE À UTILISER POUR JOINDRE LES WORKER NODES (dans les 24h) :"
        printf "\n\n%s\n" "$JOIN_COMMAND"
        printf "\n=========================================================================\n"
    fi
}


# --- EXECUTION PRINCIPALE ---
main() {
    info "Début de l'installation de Kubernetes (Control Node)"
    info "Log: $LOGFILE"

    setup_prerequisites
    setup_containerd
    setup_kernel_config
    install_kube_tools
    initialize_cluster
    display_join_command

    info "Script terminé."
}

main "$@"