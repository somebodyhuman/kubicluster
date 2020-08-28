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

  # start vm network
  virsh net-start default
  # enable autostart of vm network
  virsh net-autostart default
  # TODO vm network stuff: create default nw and ...
  # configure network if there is none configured yet
}

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
    echo -e "\nOPTIONAL ARUGMENTS:"
    echo -e "none"
    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES:"
    echo -e "WORKDIR=./work\n\t use a custom workdir (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    echo -e "KUBERNETES_VERSION=1.18.5\n\t use a custom kubernetes version on the hypervisor"
    ;;
  *)
    install_dependencies
    setup_virtualisation
    set_vm_template "${REMARGS_ARRAY[@]}"
    setup_kubectl
esac
