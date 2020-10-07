#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/env-variables "$@"

PROD_IS_ACTIVE=0
DEV_IS_ACTIVE=0

function status() {
  if virsh net-info ${VM_NET_IN_DEV_ENV} | grep -i Active | grep -i yes >/dev/null 2>&1; then
    echo "virsh managed network ${VM_NET_IN_DEV_ENV} is active."
    DEV_IS_ACTIVE=1
  else
    echo "virsh managed network ${VM_NET_IN_DEV_ENV} is inactive."
  fi

  if ip link show ${BRIDGE_INTERFACE//dev} >/dev/null 2>&1; then
    echo "prod cluster bridge ${BRIDGE_INTERFACE//dev} is active."
    PROD_IS_ACTIVE=1
  else
    echo "prod cluster bridge ${BRIDGE_INTERFACE//dev} is inactive."
  fi
}

function activate() {
  status

  if [ ${PROD_IS_ACTIVE} -eq 0 ] && [ ${DEV_IS_ACTIVE} -eq 0 ]; then
    if [ "${USE_DEV_VM_NET}" == true ]; then
      echo "activating dev cluster: activating virsh managed network ${VM_NET_IN_DEV_ENV}"
      virsh net-start ${VM_NET_IN_DEV_ENV}
    else
      echo "activating prod cluster: activating bridge ${BRIDGE_INTERFACE}"
      ifup ${BRIDGE_INTERFACE}
    fi
  else
    echo 'deactivate running cluster bridge/network before activating (another) one.'
    exit 1
  fi
}

function deactivate() {
  status

  if [ ${PROD_IS_ACTIVE} -eq 0 ] && [ ${DEV_IS_ACTIVE} -eq 0 ]; then
    echo "[INFO] No cluster-net running. exiting."
  else

    if [ ${DEV_IS_ACTIVE} -eq 1 ]; then
      echo "deactivating dev cluster: deactivating virsh managed network ${VM_NET_IN_DEV_ENV}"
      virsh net-destroy ${VM_NET_IN_DEV_ENV}
    fi
    if [ ${PROD_IS_ACTIVE} -eq 1 ]; then
      echo "deactivating prod cluster: deactivating bridge ${BRIDGE_INTERFACE}"
      ifdown ${BRIDGE_INTERFACE}
      ip addr flush dev ${BRIDGE_PORT}
      ip link set ${BRIDGE_PORT} up
    fi
  fi
}

case "${SUB_CMD}" in
  activate)
    activate
    ;;
  deactivate)
    deactivate
    ;;
  status)
    status
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster cluster-net [activate|deactivate|status|help] [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster cluster-net [activate|deactivate|status|help]} [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [activate|deactivate|status|help]} [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "setup_vm_cluster_net -bp=eth1|--bridge-port the name of the physical interface on the hypervisor which is connected to the cluster bridge (which connects vms across servers)"
    echo -e "setup_vm_cluster_net -bi=vmbr24|--bridge-interface the name of the bridge on the hypervisor which links the physical cluster interface to the virtual machines/nodes; don't forget to provide the same argument when running kubicluster create-vms"
    echo -e "setup_vm_cluster_net -ndev|--cluster-net-dev if argument is provided, a local vm net (managed with virsh) is created and used instead of a OS managed bridge (this is usually only suitable if the whole vm cluster lives on a single server e.g. in a development environment or a very small production environment; a note for advanced setups: you can prepare a hypervisor with both a virsh managed cluster network (for dev and testing traffic) and one or more OS managed bridges to be used to separate traffic of different clusters or parts of clusters running on the same server - to set this up, run the setup_vm_cluster_net sub-command for each virsh-managed net or OS managed bridge you would like to have at your disposal on this server and provide the same arguments when running kubicluster create-vms. To move a cluster vm later from one network (e.g. the dev-net) into the another one (e.g. the corresponding prod-net via the OS managed bridge) run virsh edit and remove the suffix 'dev' from the bridge name stated in the interface section."
    echo -e "-d|--debug\n\t show debug messages"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables
    ;;
  *)
    status
    ;;
esac
