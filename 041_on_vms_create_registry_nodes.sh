#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


function update_scripts_in_nodes() {
  # TODO only update controller scripts
  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[2]}:${NODE_SCRIPTS_DIR}
  done
}

function setup_nexus_oss() {
  echo 'setting up nexus oss'
  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))

    if [ "${DEBUG}" = true ]; then echo "[DEBUG]: calling: ${SSH_CMD} root@${name_ip[2]} bash ${NODE_SCRIPTS_DIR}/registry/setup_nexus_oss.sh $@ ${NODE_ARGS}" ; fi
    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/registry/setup_nexus_oss.sh $@ ${NODE_ARGS}"
  done
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  update_scripts_in_nodes)
    update_scripts_in_nodes
    ;;
  setup_nexus_oss)
  # TODO rargs may be removed ?
    setup_nexus_oss "${RARGS_ARRAY[@]}"
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-registry -r [REGISTRY_HOSTNAME],[REGISTRY_CLUSTER_NET_IP],[REGISTRY_HYPERVISOR_NET_IP] [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster create-registry [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "-f|--force-update\n\t force update, caution this updates every file affected by the run command/sub-command"
    echo -e "-d|--debug\n\t show debug messages"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables (and make them configurable)
    ;;
  *)
    update_scripts_in_nodes
    setup_nexus_oss
    ;;
esac
