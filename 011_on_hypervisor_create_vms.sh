#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables "$@"

MAX_ATTEMPTS=18

# note that we run the workdir command using source to make sure it shares the environment with the current shell in which this script is running
source ${DIR}/utils/workdir ensure_vm_configs_dir_exists

# ensure template exists
TEMPLATE_FILE=$(find ${IMAGES_DIR} -iregex "${IMAGES_DIR}/vm-template.*" | grep -e qcow2 -e img)

OVERALL_EXIT_CODE=0

for vm in ${REMAINING_ARGS}; do
  vm_name_ip=($(echo $vm | tr "," "\n"))
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
  if [ "$(sudo virsh list --all | grep ${vm_name_ip[0]})" != "" ]; then
    echo "virtual machine ${vm_name_ip[0]} exists already"
  else
    sudo virsh define ${VM_XML}
    sudo virsh start ${vm_name_ip[0]}

    # TODO handle failure t o configure template in following section better
    attempts=0
    vm_result=124
    while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
      # TODO make this resumable i.e. try to connect to both template ip and target ip
      ssh_out=$(${SSH_CMD} root@${TEMPLATE_IP} "echo ${vm_name_ip[0]} >/etc/hostname")
      result=$?
      if [[ ${result} -eq 0 ]]; then
        vm_result=64
        break
      fi
      if [ ${result} -eq 255 ]; then
        echo "connection problem, waiting ${SSH_TIMEOUT_IN_SEC} seconds before retry"
        sleep ${SSH_TIMEOUT_IN_SEC}
      else
        echo "setting hostname of ${vm_name_ip[0]} via SSH command not successful ... waiting ${SSH_TIMEOUT_IN_SEC} seconds, before retry"
      fi
      attempts=$((${attempts}+1))
      # sleep ${SSH_TIMEOUT_IN_SEC}
    done
    if [[ ${vm_result} -eq 124 ]]; then echo "ssh connection problem or hostname configuration problem while configuring ${vm_name_ip[0]}." ; exit ${vm_result} ; fi

    IP_RESULT=$(${SSH_CMD} root@${TEMPLATE_IP} "sed -i 's/${TEMPLATE_IP}/${vm_name_ip[1]}/g' /etc/network/interfaces")
    if [ "$(echo ${IP_RESULT})" != "" ]; then echo "problem while configuring ip address for ${vm_name_ip[0]}." ; exit ${vm_result} ; fi
    ${SSH_CMD} root@${TEMPLATE_IP} "reboot -h now"

    attempts=0
    while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
      ssh_out=$(${SSH_CMD} root@${vm_name_ip[1]} "hostname")
      result=$?
      if [[ ${result} -eq 0 ]]; then
        echo "hostname set to ${vm_name_ip[0]} and ip set to ${vm_name_ip[1]}"
        vm_result=0
        break
      fi
      if [ ${result} -eq 255 ]; then
        echo "connection problem, waiting ${SSH_TIMEOUT_IN_SEC} seconds before retry"
        sleep ${SSH_TIMEOUT_IN_SEC}
      else
        echo "configuration confirmation for ${vm_name_ip[0]} not successful ... waiting ${SSH_TIMEOUT_IN_SEC} seconds, before retry"
      fi
      attempts=$((${attempts}+1))
      # sleep ${SSH_TIMEOUT_IN_SEC}
    done

    if [[ ${vm_result} -ne 0 ]]; then echo "confirming configuration for ${vm_name_ip[0]} failed." ; exit ${vm_result} ; fi
  fi
done
