#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function install_dependencies() {
  apt-get install -y curl iptables-persistent ntp python3
}

function setup_virtualisation() {
  if ! grep --perl-regexp 'vmx|svm' /proc/cpuinfo; then
    echo "hardware virtualisation is not yet enabled. Please enable it in your BIOS. exiting..."
    exit 1
  else
    echo "hardware virtualisation successfully detected. continuing ..."
  fi

  apt-get install -y qemu qemu-kvm qemu-system qemu-utils libvirt-clients libvirt-daemon-system virtinst
  # enable port forwarding
  IP4="net.ipv4.ip_forward=1"
  IP6="net.ipv6.conf.all.forwarding=1"
  IP6DEF="net.ipv6.conf.default.forwarding=1"
  SYSCONF=/etc/sysctl.d/kubectl.conf

  CONFS=($IP4 $IP6 $IP6DEF)

  for IPC in "${CONFS[@]}"; do
    if egrep "^$IPC" $SYSCONF ; then
      echo "$IPC already configured"
    else
      echo $IPC >>$SYSCONF
    fi
  done
  sysctl -p

  if ! virsh net-list --all | grep -v inactive | grep default >/dev/null; then
    # start vm network
    virsh net-start default
  fi
  # enable autostart of vm network
  virsh net-autostart default
  # TODO vm network stuff: create default nw and ...
  # configure network if there is none configured yet
}

function setup_vm_cluster_net_os_bridge() {
  # TODO handle that better, but for now at least print a warning
  if cat /etc/network/interfaces | grep "iface vmbr" >/dev/null ; then
    echo "[WARN]: other interfaces called vmbr* are already defined in /etc/network/interfaces"
  fi

  if [ "${FORCE_UPDATE}" = true ]; then
    echo "forcing update of vm cluster network is not yet implemented. Clean-up /etc/network/interfaces manually and re-run."
  else
    ip_part=($(echo ${TEMPLATE_CLUSTER_CONNECTION_IP} | tr "." "\n"))

    if cat /etc/network/interfaces | grep "bridge-port ${BRIDGE_PORT}" >/dev/null ; then
      echo "[FAIL]: bridge-port ${BRIDGE_PORT} are already in use in /etc/network/interfaces"
    elif cat /etc/network/interfaces | grep "${ip_part[0]}.${ip_part[1]}.${ip_part[2]}" >/dev/null; then
      echo "[FAIL]: ip range for c-net ${ip_part[0]}.${ip_part[1]}.${ip_part[2]}.i is already in use in /etc/network/interfaces"
    else
      # TODO check all other virsh managed nets for ip range clashes
      if virsh net-list --all | grep ${VM_NET_IN_DEV_ENV} >/dev/null && virsh net-dumpxml ${VM_NET_IN_DEV_ENV} | grep "${ip_part[0]}.${ip_part[1]}.${ip_part[2]}" | grep -v "#" >/dev/null; then
        echo "dev net is running, disabling autostart and deactivating it to prevent potential ip range collision (needs to be reactivated manually after checking for ip range collisions)"
        virsh net-autostart --disable ${VM_NET_IN_DEV_ENV}
        virsh net-destroy ${VM_NET_IN_DEV_ENV}
      fi
      echo "defining and starting vm cluster network bridge (OS managed)"
      # TODO forcing - remove old ifdown, then remove from /etc/network/interfaces - side effects possible - so just exit 1 in this case
      cp -f ${DIR}/conf/vm-cluster-net-prod.tpl.sh ${VM_CONFIGS_DIR}/vm-cluster-net-prod.sh
      sed -i "s/192.168.24/${ip_part[0]}.${ip_part[1]}.${ip_part[2]}/g" ${VM_CONFIGS_DIR}/vm-cluster-net-prod.sh
      sed -i "s/vmbr24/${BRIDGE_INTERFACE}/g" ${VM_CONFIGS_DIR}/vm-cluster-net-prod.sh
      sed -i "s/eth1/${BRIDGE_PORT}/g" ${VM_CONFIGS_DIR}/vm-cluster-net-prod.sh
      cat ${VM_CONFIGS_DIR}/vm-cluster-net-prod.sh >>/etc/network/interfaces
      ip addr flush dev ${BRIDGE_INTERFACE}
      ifdown ${BRIDGE_INTERFACE}
      ifup ${BRIDGE_INTERFACE}
      echo -e "\nresulting interface:\n$(ip addr | grep -A 6 ${BRIDGE_INTERFACE})\n"
    fi
  fi
}

function setup_vm_cluster_net_in_dev_env() {
  if virsh net-list --all | grep ${VM_NET_IN_DEV_ENV} >/dev/null; then
    if [ "${FORCE_UPDATE}" = true ]; then
      echo -e "${VM_NET_IN_DEV_ENV} exists already ... forcefully deleting it, so it can be re-created\n"
      virsh net-destroy ${VM_NET_IN_DEV_ENV}
      virsh net-undefine ${VM_NET_IN_DEV_ENV}
    fi
  fi
  if ! virsh net-list --all | grep ${VM_NET_IN_DEV_ENV} >/dev/null; then
    cp -f ${DIR}/conf/vm-cluster-net-dev_instead_of_bridged_net_in_dev_env.xml ${VM_CONFIGS_DIR}/${VM_NET_IN_DEV_ENV}.xml
    ip_part=($(echo ${TEMPLATE_CLUSTER_CONNECTION_IP} | tr "." "\n"))
    sed -i "s/192.168.24/${ip_part[0]}.${ip_part[1]}.${ip_part[2]}/g" ${VM_CONFIGS_DIR}/${VM_NET_IN_DEV_ENV}.xml
    sed -i "s/vmbr24dev/${BRIDGE_INTERFACE}/g" ${VM_CONFIGS_DIR}/${VM_NET_IN_DEV_ENV}.xml
    sed -i "s/vm-cluster-net-dev/${VM_NET_IN_DEV_ENV}/g" ${VM_CONFIGS_DIR}/${VM_NET_IN_DEV_ENV}.xml
    virsh net-define ${VM_CONFIGS_DIR}/${VM_NET_IN_DEV_ENV}.xml
    virsh net-autostart ${VM_NET_IN_DEV_ENV}
    virsh net-start ${VM_NET_IN_DEV_ENV}
  else
    echo -e "${VM_NET_IN_DEV_ENV} exists already. Re-run with -f or --force-update to force an update."
  fi
}

function setup_vm_cluster_net() {
  source ${DIR}/utils/workdir ensure_vm_configs_dir_exists
  if [ "${USE_DEV_VM_NET}" = true ]; then
    setup_vm_cluster_net_in_dev_env
  else
    setup_vm_cluster_net_os_bridge
  fi
}

# TODO iptables rules
# TODO create /vms, /backups, mv /var/lib/libvirt into /vms, create symlink, check volume size of volumes, ...

function set_vm_template() {
  source ${DIR}/utils/workdir ensure_images_dir_exists
  FILE=$(basename -- "$1")
  FILE_EXT="${FILE##*.}"
  echo "setting ${FILE} (type ${FILE_EXT}) as vm template"
  # TODO extend this to support other vm storage file formats
  if [ "$FILE_EXT" != "qcow2" ]; then echo 'only .qcow2 is supported as a vm template type ... exiting'; exit 1; fi
  cp $1 ${IMAGES_DIR}/vm-template.${FILE_EXT}
  cp $2 ${TEMPLATE_ROOT_SSH_KEY}
}

function setup_kubectl() {
  # ensure kubectl exists in tools dir
  if [ ! -d ${KUBERNETES_ON_HYPERVISOR_DIR} ] || [ ! -e ${KUBECTL_CMD_ON_HYPERVISOR} ] \
     || [ "$(${KUBECTL_CMD_ON_HYPERVISOR} version --client --short)" != "Client Version: v${KUBERNETES_VERSION}" ]; then
    mkdir -p ${KUBERNETES_ON_HYPERVISOR_DIR}
    curl -s -L -o ${KUBERNETES_ON_HYPERVISOR_DIR}.tar.gz https://github.com/kubernetes/kubernetes/releases/download/v${KUBERNETES_VERSION}/kubernetes.tar.gz
    tar xzf ${KUBERNETES_ON_HYPERVISOR_DIR}.tar.gz -C ${KUBERNETES_ON_HYPERVISOR_DIR}
    cd ${KUBERNETES_ON_HYPERVISOR_DIR}/kubernetes
    KUBERNETES_SKIP_CONFIRM=true ./cluster/get-kube-binaries.sh
    if [ "$(${KUBECTL_CMD_ON_HYPERVISOR} version --client --short)" != "Client Version: v${KUBERNETES_VERSION}" ]; then
      echo "expected kubectl version ${KUBERNETES_VERSION}, but $(${KUBECTL_CMD_ON_HYPERVISOR} --client --short) is installed in tools dir"
      exit 1
    else
      echo "kubectl version ${KUBERNETES_VERSION} successfully installed."
    fi
  else
    echo "kubectl version ${KUBERNETES_VERSION} already exists."
  fi
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  install_dependencies)
    install_dependencies
    ;;
  setup_virtualisation)
    setup_virtualisation
    ;;
  setup_vm_cluster_net)
    setup_vm_cluster_net
    ;;
  set_vm_template)
    set_vm_template "${RARGS_ARRAY[@]}"
    ;;
  setup_kubectl)
    setup_kubectl
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster prepare PATH/TO/TEMPLATE_FILE TEMPLATE_ROOT_SSH_KEY [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster prepare [install_dependencies|setup_virtualisation|set_vm_template PATH/TO/TEMPLATE_FILE TEMPLATE_ROOT_SSH_KEY|setup_kubectl] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [install_dependencies|setup_virtualisation|set_vm_template PATH/TO/TEMPLATE_FILE TEMPLATE_ROOT_SSH_KEY|setup_kubectl] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "setup_vm_cluster_net -tcip=192.168.24.0|--template-cluster-ip=192.168.24.9 ip c-net over which the vms can communicate with each other in the cluster (across servers)"
    echo -e "setup_vm_cluster_net -bp=eth1|--bridge-port the name of the physical interface on the hypervisor which is connected to the cluster bridge (which connects vms across servers)"
    echo -e "setup_vm_cluster_net -bi=vmbr24|--bridge-interface the name of the bridge on the hypervisor which links the physical cluster interface to the virtual machines/nodes; don't forget to provide the same argument when running kubicluster create-vms"
    echo -e "setup_vm_cluster_net -ndev|--cluster-net-dev if argument is provided, a local vm net (managed with virsh) is created and used instead of a OS managed bridge (this is usually only suitable if the whole vm cluster lives on a single server e.g. in a development environment or a very small production environment; a note for advanced setups: you can prepare a hypervisor with both a virsh managed cluster network (for dev and testing traffic) and one or more OS managed bridges to be used to separate traffic of different clusters or parts of clusters running on the same server - to set this up, run the setup_vm_cluster_net sub-command for each virsh-managed net or OS managed bridge you would like to have at your disposal on this server and provide the same arguments when running kubicluster create-vms. To move a cluster vm later from one network (e.g. the dev-net) into the another one (e.g. the corresponding prod-net via the OS managed bridge) run virsh edit and remove the suffix 'dev' from the bridge name stated in the interface section."
    echo -e "setup_vm_cluster_net -f|--force-update forcefully overwrites/recreates the cluster network (use with caution)"
    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES:"
    echo -e "WORKDIR=./work\n\t use a custom workdir (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    echo -e "KUBERNETES_VERSION=1.18.5\n\t use a custom kubernetes version on the hypervisor"
    ;;
  *)
    install_dependencies
    setup_virtualisation
    setup_vm_cluster_net
    set_vm_template "${REMARGS_ARRAY[@]}"
    setup_kubectl
esac
