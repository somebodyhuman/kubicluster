#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

function install_dependencies() {
  apt-get install -y curl
}

function setup_virtualisation() {
  apt-get install -y virsh libvirt-qemu
}

function set_vm_template() {
  ${DIR}/utils/workdir ensure_images_dir_exists
  FILE=$(basename -- "$1")
  FILE_EXT="${FILE##*.}"
  echo "setting ${FILE} (type ${FILE_EXT}) as vm template"
  if [ "$FILE_EXT" != "qcow2" ] && [ "$FILE_EXT" != "img" ]; then echo 'only .img and .qcow2 are supported as vm templates ... exitiing'; exit 1; fi
  cp $1 ${IMAGES_DIR}/vm-template.${FILE_EXT}
  echo $2 >${IMAGES_DIR}/vm-template-ip.txt
}

case "$1" in
  install_dependencies)
    install_dependencies
    ;;
  setup_virtualisation)
    setup_virtualisation
    ;;
  set_vm_template)
    set_vm_template "${@:2}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] install_dependencies|setup_virtualisation|set_vm_template}"
    ;;
  *)
    install_dependencies
    setup_virtualisation
    set_vm_template "${@:2}"
esac
