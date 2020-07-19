#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

REMAINING_ARGS=''
VMS=''
VCPUS=''
VMEM=''
QEMU_TYPE='qcow2'
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -c=*|--cpus=*)
        VCPUS="${key#*=}"
        ;;
        -m=*|--mem=*)
        VMEM="${key#*=}"
        ;;
        -n|--worker-node)
        shift # past the key and to the value
        VMS="${VMS} $1"
        ;;
        *)
        REMAINING_ARGS="${REMAINING_ARGS} $key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [ "${VCPUS}" == "" ]; then VCPUS='1' ; fi
if [ "${VMEM}" == "" ]; then VMEM='4194304' ; fi


${DIR}/utils/workdir ensure_vm_configs_dir_exists

# ensure template exists
TEMPLATE_FILE=$(find ${IMAGES_DIR} -iregex "${IMAGES_DIR}/vm-template.*" | grep -e qcow2 -e img)

for vm in ${VMS}; do
  vm_name_ip=($(echo $vm | tr "=" "\n"))
  VM_XML=${VM_CONFIGS_DIR}/${vm_name_ip[0]}.xml
  VM_FILE=${VIRT_STORAGE_DIR}/${vm_name_ip[0]}.qcow2
  if [ ! -e ${VM_FILE} ]; then
    echo "copying template to ${VM_FILE}"
    sudo cp ${TEMPLATE_FILE} ${VM_FILE}
  else
    echo "vm storage file for ${vm_name_ip[0]} already exists (${VM_FILE})"
  fi
  if [ ! -e ${VM_XML} ]; then
    echo "generating virsh xml for ${vm_name_ip[0]}"
    cp ${TEMPLATE_XML} ${VM_XML}
    sed -i "s/#VM_NAME#/${vm_name_ip[0]}/g" ${VM_XML}
    sed -i "s@#VM_SOURCE_FILE#@${VM_FILE}@g" ${VM_XML}  # using an @ here because otherwise the file path slashes would need to be escaped
    sed -i "s/#QEMU_TYPE#/${QEMU_TYPE}/g" ${VM_XML}
    vm_mac=$(${DIR}/utils/macgen.py)
    sed -i "s/#VM_MAC#/${vm_mac}/g" ${VM_XML}
    sed -i "s/#VCPUS#/${VCPUS}/g" ${VM_XML}
    sed -i "s/#VMEM#/${VMEM}/g" ${VM_XML}
  else
    echo "virsh xml for ${vm_name_ip[0]} exists already"
  fi
  if [ "$(sudo virsh list --all | grep ${vm_name_ip[0]})" == "" ]; then
    sudo virsh create ${VM_XML}
  else
    echo "virtual machine ${vm_name_ip[0]} exists already"
  fi
done
