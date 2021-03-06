#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

MAX_ATTEMPTS=18

function create_vms() {
  # note that we run the workdir command using source to make sure it shares the environment with the current shell in which this script is running
  source ${DIR}/utils/workdir ensure_vm_configs_dir_exists

  # ensure template exists
  TEMPLATE_FILE=$(find ${IMAGES_DIR} -iregex "${IMAGES_DIR}/vm-template.*" | grep -e qcow2 -e img)

  OVERALL_EXIT_CODE=0

  for vm in ${REMAINING_ARGS}; do
    echo "$vm is going to be created."
  done

  for vm in ${REMAINING_ARGS}; do
    vm_name_ip=($(echo $vm | tr "," "\n"))
    VM_XML=${VM_CONFIGS_DIR}/${vm_name_ip[0]}.xml
    VM_FILE=${VIRT_STORAGE_DIR}/${vm_name_ip[0]}.qcow2
    if [ ! -e ${VM_FILE} ] || [ "${FORCE_UPDATE}" = true ]; then
      echo "copying template to ${VM_FILE}"
      cp ${TEMPLATE_FILE} ${VM_FILE}
    else
      echo "vm storage file for ${vm_name_ip[0]} already exists (${VM_FILE})"
    fi
    if [ ! -e ${VM_XML} ] || [ "${FORCE_UPDATE}" = true ]; then
      echo "generating virsh xml for ${vm_name_ip[0]}"
      cp ${TEMPLATE_XML} ${VM_XML}
      sed -i "s/#VM_NAME#/${vm_name_ip[0]}/g" ${VM_XML}
      sed -i "s@#VM_SOURCE_FILE#@${VM_FILE}@g" ${VM_XML}  # using an @ here because otherwise the file path slashes would need to be escaped
      sed -i "s/#QEMU_TYPE#/${QEMU_TYPE}/g" ${VM_XML}
      sed -i "s/#VCPUS#/${VCPUS}/g" ${VM_XML}
      sed -i "s/#VMEM#/${VMEM}/g" ${VM_XML}
      # TODO adjust first interface
      vm_mac=$(${DIR}/utils/macgen.py)
      sed -i "s/#VM_MAC#/${vm_mac}/g" ${VM_XML}
      # adjust or remove second interface
      vm_cluster_mac=$(${DIR}/utils/macgen.py)
      sed -i "s/#VM_CLUSTER_MAC#/${vm_cluster_mac}/g" ${VM_XML}
      sed -i "s/#VM_CLUSTER_NET#/${BRIDGE_INTERFACE}/g" ${VM_XML}
    else
      echo "virsh xml for ${vm_name_ip[0]} exists already"
    fi
    if [ "$(virsh list --all | grep ${vm_name_ip[0]})" != "" ]; then
      echo "virtual machine ${vm_name_ip[0]} exists already"
    else
      # TODO undefine domain first if it exists already and -f|--force-update is set
      virsh define ${VM_XML}
      echo "Domain ${vm_name_ip[0]} uses $(cat ${VM_XML} | grep 'source file')"
      virsh start ${vm_name_ip[0]}
      virsh autostart ${vm_name_ip[0]}

      # TODO handle failure to configure template in following section better
      attempts=0
      vm_result=124
      while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
        # TODO make this resumable i.e. try to connect to both template ip and target ip
        echo "trying to set HOSTNAME to ${vm_name_ip[0]}"
        ssh_out=$(${SSH_CMD} root@${TEMPLATE_DEFAULT_CONNECTION_IP} "echo ${vm_name_ip[0]} >/etc/hostname")
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
      done
      if [[ ${vm_result} -eq 124 ]]; then echo "ssh connection problem or hostname configuration problem while configuring ${vm_name_ip[0]}." ; exit ${vm_result} ; fi

      echo "trying to set default connection IP to ${vm_name_ip[2]}"
      # NOTE: the network configuration is debian/ubuntu specific (TODO support more OS)
      IP_RESULT=$(${SSH_CMD} root@${TEMPLATE_DEFAULT_CONNECTION_IP} "sed -i 's/${TEMPLATE_DEFAULT_CONNECTION_IP}/${vm_name_ip[2]}/g' /etc/network/interfaces")
      if [ "$(echo ${IP_RESULT})" != "" ]; then echo "problem while configuring default connection ip address for ${vm_name_ip[0]}." ; exit ${vm_result} ; fi
      ${SSH_CMD} root@${TEMPLATE_DEFAULT_CONNECTION_IP} "reboot -h now"

      attempts=0
      while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
        ssh_out=$(${SSH_CMD} root@${vm_name_ip[2]} "hostname")
        result=$?
        if [[ ${result} -eq 0 ]]; then
          echo "hostname set to ${vm_name_ip[0]} and default connection ip set to ${vm_name_ip[2]}"

          # NOTE: the network configuration is debian/ubuntu specific (TODO support more OS)
          # virtual machines should be able to talk to each other across servers
          ssh_out_checkif=$(${SSH_CMD} root@${vm_name_ip[2]} "grep ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} /etc/network/interfaces")
          checkif=$?
          if [[ $checkif -eq 0 ]]; then
            echo "on ${vm_name_ip[0]}: interface ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} found in /etc/network/interfaces"
            if [ "${vm_name_ip[1]}" != "" ] && [ "${vm_name_ip[1]}" != "${vm_name_ip[2]}" ]; then
              ssh_out_vmnet2=$(${SSH_CMD} root@${vm_name_ip[2]} "sed -i 's/${TEMPLATE_CLUSTER_CONNECTION_IP}/${vm_name_ip[1]}/g' /etc/network/interfaces")
              ssh_out_vmnet3=$(${SSH_CMD} root@${vm_name_ip[2]} "sed -i 's/${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} inet manual/${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} inet static/g' /etc/network/interfaces ; ifdown ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} ; ip addr flush dev ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} ; ifup ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE}")
              result3=$?
              echo "ifup ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} was $(if [[ $result2 -eq 0 ]] ; then echo successful ; else echo failed ; fi)."
              echo "hostname set to ${vm_name_ip[0]} and CLUSTER connection ip set to ${vm_name_ip[1]}"
              # TODO add checks if CLUSTER ip config was successful
            else
              ssh_out_vmnet=$(${SSH_CMD} root@${vm_name_ip[2]} "sed -i 's/${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} inet static/${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} inet manual/g' /etc/network/interfaces")
              echo "[WARN]: no cluster network ip provided, cluster network interface has been deactivated, CONFIGURE IT manually now before proceeding with create-controllers/create-workers"
            fi
          else
            echo "[WARN]:on ${vm_name_ip[0]}: interface ${TEMPLATE_CLUSTER_CONNECTION_INTERFACE} not in /etc/network/interfaces, CONFIGURE IT manually now before proceeding with create-controllers/create-workers"
          fi
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
      done

      if [[ ${vm_result} -ne 0 ]]; then echo "confirming configuration for ${vm_name_ip[0]} failed." ; exit ${vm_result} ; fi
    fi
  done
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  create_vms)
    create_vms "${RARGS_ARRAY[@]}"
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-vms HOSTNAME,IP HOSTNAME,IP ... [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nDirect command usage:\n$0 [install_dependencies|setup_virtualisation|set_vm_template PATH/TO/TEMPLATE_FILE TEMPLATE_ROOT_SSH_KEY|setup_kubectl] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARUGMENTS:"
    echo -e "-c=1|--cpus=1\n\t number of virtual CPUs each defined virtual machine will get"
    echo -e "-m=4194304|--mem=4194304\n\t number of virtual memory each defined virtual machine will get in KB"
    echo -e "-sd=/var/lib/libvirt/images|--storage-dir=/var/lib/libvirt/images directory on hypervisor in which disk image of virtual machine is stored (should be defined as a storage location in libvirt/qemu) "
    echo -e "-bi=|--bridge-interface the name of the bridge on the hypervisor which links the physical cluster interface to the virtual machines/nodes"
    echo -e "-tif=enp1s0|--template-interface=enp1s0 interface name inside the vm over which the host can communicate with the vm"
    echo -e "-tip=192.168.122.254|--template-ip=192.168.122.254 ip over which the host can communicate with the vm"
    echo -e "-tcif=enp7s0|--template-cluster-interface=enp7s0 interface name inside the vm over which the host can communicate with other vms in the cluster (across servers)"
    echo -e "-tcip=192.168.24.254|--template-cluster-ip=192.168.24.254 ip over which the vm can communicate with other vms in the cluster (across servers)"
    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES:"
    echo -e "WORKDIR=./work\n\t use a custom workdir (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    ;;
    # TODO add less commonly changed env variables from ./utils/env-variables
  *)
    create_vms "${REMARGS_ARRAY[@]}"
esac
