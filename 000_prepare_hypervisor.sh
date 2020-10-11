#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

PRINT_OUT_FIREWALL_INFO=false

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

  # enable modules to manage traffic between vms using iptables
  KERNEL_MODULES_FAILED=0
  for module in br_netfilter overlay; do
    if [ "$(grep ${module} /etc/modules)" = "" ]; then echo -e "\n${module}" >>/etc/modules ; modprobe ${module} ; fi
    if ! lsmod | grep ${module}; then echo "kernel module ${module} could not be activated" ; KERNEL_MODULES_FAILED=$((${KERNEL_MODULES_FAILED} + 1)) ; fi
  done

  if [[ ${KERNEL_MODULES_FAILED} -gt 0 ]]; then exit ${KERNEL_MODULES_FAILED} ; fi


  # enable port forwarding
  IP4="net.ipv4.ip_forward=1"
  IP6="net.ipv6.conf.all.forwarding=1"
  IP6DEF="net.ipv6.conf.default.forwarding=1"
  BRNF="net.bridge.bridge-nf-call-iptables=1"
  BRNF6="net.bridge.bridge-nf-call-ip6tables=1"

  SYSCONF=/etc/sysctl.d/kubectl.conf

  CONFS=($IP4 $IP6 $IP6DEF $BRNF $BRNF6)

  for IPC in "${CONFS[@]}"; do
    if egrep "^$IPC" $SYSCONF ; then
      echo "$IPC already configured"
    else
      echo $IPC >>$SYSCONF
    fi
  done

  cat <<EOF | tee /etc/sysctl.d/991-container-runtimes.conf
  net.ipv4.ip_forward=1
  net.ipv6.ip_forward=1
EOF

  sysctl --system

  if ! virsh net-list --all | grep -v inactive | grep default >/dev/null; then
    # start vm network
    virsh net-start default
  fi
  # enable autostart of vm network
  virsh net-autostart default

  PRINT_OUT_FIREWALL_INFO=true
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
  chmod 400 ${TEMPLATE_ROOT_SSH_KEY}
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

if [ "${PRINT_OUT_FIREWALL_INFO}" = true ]; then
  echo "[INFO]: The setup_virtualiation command has been run. Note, that libvirt automatically may adjust iptables rules by default."
  echo "[INFO]: In some versions libvirt adds new rules for every bridge/virtual network in nat-mode to iptables."
  echo "[INFO]: It is recommended that once the default network has been activated for the first time, to persist the generated rules and \"deactivate\" the re-addition of those rules."
  echo "More information about it/ the source of the following two suggestions can be found here: https://serverfault.com/questions/456708/how-do-i-prevent-libvirt-from-adding-iptables-rules-for-guest-nat-networks ."

  echo -e "\nOne way to achieve this is to switch to bridge mode and configure the bridge manually outside libvirt/virsh."
  echo "Another one is to use hooks to overwrite the rules (re-)generated (again and again) by libvirt/virsh by running the following commands accordingly for your firewall solution. To do this with plain iptables:"
  echo "# ensure iptables are persisted across reboots of the hypervisor"
  echo "apt-get install -y iptables-persistent"
  echo "# save the current rules after the first time activation of the default network, so they are included when restored"
  echo "iptables-save >/etc/iptables/rules.v4'"
  echo "# create the libvirt hooks"
  echo "mkdir /etc/libvirt/hooks"
  echo "for f in daemon qemu lxc libxl network; do"
  echo "  echo '#!/bin/sh"
  echo "  iptables-restore < /etc/iptables/rules.v4' >\"/etc/libvirt/hooks/$f\""
  echo "  chmod +x \"/etc/libvirt/hooks/$f\""
  echo "done"
  echo "systemctl restart libvirtd.service"

  echo -e "\n[WARN]: IF USING THE DEFAULT GENERATED FIREWALL RULES your vms will be able to communicate with each other over the hypervisor net."
  echo "[WARN]: IF YOU WISH TO ISOLATE TRAFFIC BETWEEN"
  echo "[WARN]: VMS (cluster traffic)"
  echo "[WARN]: and each vm and the hypervisor (internet connection for package installs and admin connection)"
  echo "[WARN]: REMOVE the auto-generated rules from ip-tables and configure the following for the default network:"

  echo -e "\n[INFO]: Firewall rules are not adjusted automatically to prevent unintended side effects on your hypervisor."
  echo "[INFO]: Ensure the following rules are configured in your respective firewall. The rules for iptables are:"
  if [ "${HYPERVISOR_NET}" = "" ]; then
    ip_part=($(echo ${TEMPLATE_DEFAULT_CONNECTION_IP} | tr "." "\n"))
    HYPERVISOR_NET="${ip_part[0]}.${ip_part[1]}.${ip_part[2]}"
  fi
  echo "# allowing ssh traffic initiated by the hypervisor to the vms (but not vice versa):"
  echo "iptables -I OUTPUT -s ${HYPERVISOR_NET}.1/32 -d ${HYPERVISOR_NET}.0/24 -o virbr0 -p tcp -m tcp --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"
  echo "iptables -I INPUT  -d ${HYPERVISOR_NET}.1/32 -s ${HYPERVISOR_NET}.0/24 -i virbr0 -p tcp -m tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT"
  echo "# allowing icmp traffic between the hypervisor and each vm (but not between vms):"
  echo "iptables -I OUTPUT -p icmp -s ${HYPERVISOR_NET}.1/32 -d ${HYPERVISOR_NET}.0/24 -o virbr0 -j ACCEPT"
  echo "iptables -I INPUT  -p icmp -d ${HYPERVISOR_NET}.1/32 -s ${HYPERVISOR_NET}.0/24 -i virbr0 -j ACCEPT"
fi
