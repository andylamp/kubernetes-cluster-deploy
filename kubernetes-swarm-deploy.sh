#!/usr/bin/env bash
# This is a script to deploy kubernetes to a supported Ubuntu based swarm of linux servers.
#
# Please DO NOT run this as root (although we check).
#
# Author: Andreas Grammenos (ag926@cl.cam.ac.uk)
#
# Last touched: 13/09/2020
#

# pretty functions for log output
function cli_info { echo -e " -- \033[1;32m$1\033[0m" ; }
function cli_info_read { echo -e -n " -- \e[1;32m$1\e[0m" ; }
function cli_warning { echo -e " ** \033[1;33m$1\033[0m" ; }
function cli_warning_read { echo -e -n " ** \e[1;33m$1\e[0m" ; }
function cli_error { echo -e " !! \033[1;31m$1\033[0m" ; }

cli_info "Running the kubernetes deployment script."

# source the addresses
if ! source ./swarm-addresses.sh; then
  cli_error "There was an error while reading the swarm addresses - cannot continue"
  exit 1
fi

# check if the remote swarm script exists
if [[ ! -f ./kubernetes-swarm-remote-installer.sh ]]; then
  cli_error "Kubernetes swarm remote install script does not exist - cannot continue"
  exit 1
fi

# check if we are root
if [[ $(id -u) -eq 0 ]]; then cli_error "Error: You cannot run this as root, exiting\n\n"; exit 1;
else cli_info "Running as user $(whoami)" ;
fi

# configure your user who you want to use for ssh (has to be the same for all servers)
# USER=$(whoami)
USER="ag926"

# setup master flag
SETUP_MASTER=false

# cache the ssh-key so we don't have to type it over and over, in order to do this properly
# we have to use eval and just a regular call -- see: https://unix.stackexchange.com/questions/351725
cli_info "Caching ssh keys for the session."
eval "$(ssh-agent -s)"
# then add the key
ssh-add
cli_info "Cached the ssh keys."

# check if the master and slave node array is populated
if [[ -z ${MASTER_NODE} ]]; then
  cli_error "Master node address cannot be empty - cannot continue"
  exit 1
elif [[ -z ${SLAVE_NODES} ]]; then
  cli_error "Slave node array cannot be empty - cannot continue"
  exit 1
fi

# install the mater node
if [[ ${SETUP_MASTER} = true ]]; then
    cli_info "Setting up master node at ${MASTER_NODE}."
    ssh -t "${USER}@${MASTER_NODE}" \
    TARGET_NODE="$(printf '%q' "${MASTER_NODE}")" "$(<./kubernetes-swarm-remote-installer.sh)"
fi

cli_info "Trying to fetch the join command from the master node."

GET_JOIN_CMD=("kubeadm token create --print-join-command | grep \"^kubeadm\" | sed -n -e 's/^.*\(kubeadm\)/\1/p'")
# shellcheck disable=SC2029
JOIN_CMD=$(ssh "${USER}@${MASTER_NODE}" "${GET_JOIN_CMD[@]}")

if [[ $? -ne 0 ]]; then
  cli_error "An error occurred while fetching the join command."
  exit 1
else
cli_info "Join command fetched, please check if everything looks sane:"
cli_warning "\t${JOIN_CMD}"

  read -p "$(cli_info "Does this look sane? [y/n]: ")" -n 1 -r;
  if [[ $REPLY =~ ^[yY]$ ]] || [[ -z $REPLY ]]; then
    echo -ne "\n"
    cli_info "OK - proceeding with slave installation."
  else
    echo -ne "\n"
    cli_error "JOIN command looks sketchy, exiting."
    exit 1
  fi
fi

cli_info "Installing slave ${#SLAVE_NODES[@]} nodes."

# now get the join command from the master as a result
for slave in "${SLAVE_NODES[@]}"; do
  cli_info "Installing kubernetes as a SLAVE at: ${slave} as ${USER}."
  # there are couple of intricacies here:
  #
  # 1) script arguments are NOT accepted after the script - i.e.:
  #       ssh -t ${USER}@${slave} "$(<./kubernetes-swarm-remote-installer.sh)" TARGET_NODE="$(printf '%q' "${slave}")"
  #
  # 2) instead they need to be passed as *evaluated* environment variables which are passed to the ssh session; i.e.:
  #       ssh -t ${USER}@${slave} TARGET_NODE="$(printf '%q' "${slave}")" "$(<./kubernetes-swarm-remote-installer.sh)"
  #
  # 3) The remote script CANNOT be interactive when having to sudo commands in the remote script by using the common
  #    method of invoking bash and piping the script as such:
  #       ssh -t ${USER}@${slave} 'bash -s' < ./my-script.sh
  #    instead it has to be done by completely evaluating the script on the remote host - i.e.:
  #       ssh -t ${USER}@${slave} "$(<./kubernetes-swarm-remote-installer.sh)"
  #
  # these are like personal notes more than anything else...
  ssh -t "${USER}@${slave}" \
  TARGET_NODE="$(printf '%q' "${slave}")" \
  JOIN_CMD="$(printf '%q' "${JOIN_CMD}")" "$(<./kubernetes-swarm-remote-installer.sh)"
done

cli_info "Finished running the kubernetes deployment script."
