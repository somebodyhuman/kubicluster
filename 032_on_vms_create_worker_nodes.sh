#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

function update_scripts_in_nodes() {
  # TODO only update worker scripts
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    echo ${RSYNC_CMD}
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[1]}:${NODE_SCRIPTS_DIR}
  done
}

function update_certs() {
  CERTS=''
  echo "updating certs: $@"
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    CERTS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.pem ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-key.pem"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function update_configs() {
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    CONFIGS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.kubeconfig"
    for config in "$@"; do CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}" ; done
    echo "updating configs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CONFIGS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

REMAINING_ARGS=''
CONTROLLERS='' ; NODES=''
CLUSTER_NAME='kubicluster'
# PEER_PORT=2380
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
        ;;
        -c|--controller-node)
        shift # past the key and to the value
        CONTROLLERS="${CONTROLLERS} $1"
        ;;
        -n|--worker-node)
        shift # past the key and to the value
        NODES="${NODES} $1"
        ;;
        *)
        PL=' ' ; if [ "${REMAINING_ARGS}" == "" ]; then PL=''; fi
        REMAINING_ARGS="${REMAINING_ARGS}${PL}$key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

RARGS_ARRAY=($(echo $REMAINING_ARGS | tr " " "\n"))
echo "running: ${RARGS_ARRAY[0]}"
case "${RARGS_ARRAY[0]}" in
  'update_scripts_in_nodes')
    update_scripts_in_nodes
    ;;
  update_certs)
    update_certs
    ;;
  update_configs)
    # TODO check for -cip/--controller-ip and exit if not specified
    update_configs "${RARGS_ARRAY[@]:1}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [update_scripts_in_node|update_certs|update_configs]}"
    ;;
  *)
    update_scripts_in_nodes
    # TODO check for -cip/--controller-ip and exit if not specified
    update_certs ca kubernetes service-accounts
    update_configs kube-proxy.kubeconfig
    ;;
esac
