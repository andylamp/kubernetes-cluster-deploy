#!/usr/bin/env bash
# This is a script to deploy kubernetes to a supported Ubuntu based linux swarm of servers.
#
# Please DO NOT run this as root (but we check anyway).
#
# Author: Andreas Grammenos (ag926@cl.cam.ac.uk)
#

NODE_HOSTNAME="$(hostname)"

# pretty functions for log output
function cli_info { echo -e " -- \033[1;32m$1\033[0m" ; }
function cli_info_read { echo -e -n " -- \e[1;32m$1\e[0m" ; }
function cli_warning { echo -e " ** \033[1;33m$1\033[0m" ; }
function cli_warning_read { echo -e -n " ** \e[1;33m$1\e[0m" ; }
function cli_error { echo -e " !! \033[1;31m$1\033[0m" ; }

# check if we are root
if [[ $(id -u) -eq 0 ]]; then cli_error "Error: You cannot run this as root, exiting\n\n"; exit 1;
else cli_info "Running as user $(whoami) on host: ${NODE_HOSTNAME}" ;
fi

if [[ ! -x "$(command -v kubeadm)" ]] && [[ ! -x "$(command -v docker)" ]]; then
    cli_warning "Kubernetes (and Docker) appear to be already installed on this node -- skipping"
    exit 1
else
    cli_info "Kubernetes (and Docker) appear to be missing from this node -- installing"
fi

# put ubuntu etc
REPO_LINK="https://download.docker.com/linux"
DIST_FLAVOR="ubuntu"
DIST_VERSION="$(lsb_release -cs)"
CHANNEL="stable"

KUBE_DEB="deb https://apt.kubernetes.io/ kubernetes-xenial main"
KUBE_LIST="/etc/apt/sources.list.d/kubernetes.list"

DOCK_COMP_OUT="/usr/local/bin/docker-compose"
DOCK_COMP_REPO="https://github.com/docker/compose"
DOCK_COMP_DOWN_LINK="${DOCK_COMP_REPO}/releases/download"

# check if we have the proper arguments
if [[ -z ${TARGET_NODE} ]]; then
    cli_error "Target node environment variable cannot be empty - bye."
    exit
elif [[ -z ${JOIN_CMD} ]]; then
    cli_info "No cluster join CMD provided -- assuming a MASTER node"
    IS_MASTER=true
else
    cli_info "Join CMD has been provided -- assuming a SLAVE node"
fi

# check for docker compose installation
if [[ -z ${INSTALL_COMPOSE} ]]; then
    cli_info "No install docker-compose preference found - using default (true)"
    INSTALL_COMPOSE=true
fi

# check if the name resolves
if [[ -z $(dig +short "${TARGET_NODE}") ]]; then
    cli_error "Error, the target node could not be resolved - ensure that it is connected to the internet"
fi

# split links, if any
HEAD_NAME=${TARGET_NODE%%.*}
TAIL_NAME=${TARGET_NODE#*.}

cli_info "Using head name: ${HEAD_NAME} and tail name: ${TAIL_NAME}"

cli_info "Deploying Docker..."

# remove old versions, if installed
sudo apt-get remove docker docker-engine docker.io containerd runc
# update the apt index
sudo apt-get update
# install the required packages
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

# fetch and install the docker GPG key
cli_info "Getting the docker key"
curl -fsSL ${REPO_LINK}/${DIST_FLAVOR}/gpg | sudo apt-key add -
cli_info "Got docker key"

# add the official docker repo
sudo add-apt-repository \
   "deb [arch=amd64] ${REPO_LINK}/${DIST_FLAVOR} \
   ${DIST_VERSION} \
   ${CHANNEL}"

# now installing docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# find the latest (released) docker compose version
DOCK_COMPOSE_VER="$(git ls-remote ${DOCK_COMP_REPO} | \
grep refs/tags | \
grep -oE "[0-9]+\.[0-9][0-9]+\.[0-9]+$" | \
sort --version-sort | \
tail -n 1)"

# now generate the link
DOCK_COMPOSE_LINK="${DOCK_COMP_DOWN_LINK}/${DOCK_COMPOSE_VER}/docker-compose-$(uname -s)-$(uname -m)"

if [[ ${INSTALL_COMPOSE} = true ]]; then
    cli_info "Installing docker-compose as well!"
    # download it
    if sudo curl -L "${DOCK_COMPOSE_LINK}" -o "${DOCK_COMP_OUT}" && sudo chmod +x "${DOCK_COMP_OUT}"; then
      cli_info "Docker compose installed successfully"
    else
      cli_error "There was an error installing docker-compose, cannot continue"
      exit 1
    fi
fi

# add the user to the docker group
if [[ "$(whoami)" != "root" ]]; then
    cli_info "Non root user found $(whoami), adding to docker group"
    if sudo groupadd docker && sudo usermod -aG docker "$(whoami)"; then
      cli_info "Group permissions to access docker were edited successfully"
    else
      cli_error "There was an error while altering the group and user permissions for docker - cannot continue"
      exit 1
    fi
    cli_info "Do not forget to restart your login session for the permissions to take effect!"
fi

cli_info "Docker deployment finished!"

# now install kubernetes onto the server
if [[ ! -x "$(command -v snap)" ]]; then cli_info "SNAP package manager exists, using that"
    if ! sudo snap install kubectl --classic && sudo snap install kubeadm --classic; then
      cli_error "There was an error while installing kubectl and kubeadm - cannot continue"
      exit 1
    fi
else
    cli_info "SNAP does not exist, resorting to good ol' apt"
    sudo apt-get update && sudo apt-get install -y apt-transport-https
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    # check if the repo exists
    if ! grep -Fxq "${KUBE_DEB}" ${KUBE_LIST}; then
        cli_info "Kubernetes repo is missing - adding."
        echo "${KUBE_DEB}" | sudo tee -a ${KUBE_LIST}
    else
        cli_info "Kubernetes repo already existing - not adding again."
    fi
    sudo apt-get update
    sudo apt-get install -y kubectl kubeadm
fi

# comment swap on fstab as that's required by kublet
if ! sudo swapoff -a && sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab; then
  cli_error "There was an error while turning swap off - cannot continue"
  exit 1
fi

cli_info "Fixing iptables entry so the dns is discoverable"
if ! sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X; then
  cli_error "There was an error while setting up the iptables configuration - cannot continue"
  exit 1
fi

# install the network but only on the master node
if [[ ${IS_MASTER} = true ]]; then
    cli_info "Configuring a MASTER node"
    # apply flannel
    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
else
    cli_info "Configuring a SLAVE node"
    cli_info "Executing join command"
    sudo sh -c "eval ${JOIN_CMD}"
fi

cli_warning "Please reboot the node for the swap to be completely off"
