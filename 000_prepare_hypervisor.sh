#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

function install_dependencies() {
  apt-get install -y -p curl iptables-persistent ntp
}

function setup_virtualisation() {
  apt-get install -y virsh libvirt-qemu
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
  # sysctl -p

  # enable autostart of vm network
  virsh net-autostart default
  # TODO vm network stuff: create default nw and ...
  # configure network if there is none configured yet
}

function set_vm_template() {
  ${DIR}/utils/workdir ensure_images_dir_exists
  FILE=$(basename -- "$1")
  FILE_EXT="${FILE##*.}"
  echo "setting ${FILE} (type ${FILE_EXT}) as vm template"
  if [ "$FILE_EXT" != "qcow2" ] && [ "$FILE_EXT" != "img" ]; then echo 'only .img and .qcow2 are supported as vm templates ... exiting'; exit 1; fi
  cp $1 ${IMAGES_DIR}/vm-template.${FILE_EXT}
  echo $2 >${IMAGES_DIR}/vm-template-ip.txt
  cp $3 ${IMAGES_DIR}/vm-template_rsa
}

case "$1" in
  install_dependencies)
    install_dependencies
    ;;
  setup_virtualisation)
    setup_virtualisation
    ;;
  set_vm_template)
    set_vm_template "${@:1}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [install_dependencies|setup_virtualisation|set_vm_template PATH/TO/TEMPLATE_FILE TEMPLATE_IP TEMPLATE_ROOT_SSH_KEY]}"
    ;;
  *)
    install_dependencies
    setup_virtualisation
    set_vm_template "${@:1}"
esac
